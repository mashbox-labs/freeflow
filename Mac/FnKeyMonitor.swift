import AppKit
import ApplicationServices
import CoreGraphics
#if !FF_MAC_BRIDGE
import FreeFlowKit   // the plug-in compiles FnGesture.swift into itself instead
#endif

/// Watches fn system-wide through a session event tap and hands each press to FnGesture (via MacDictation). The tap
/// needs Accessibility, the same permission that lets Free Flow paste into other apps, so one switch covers both.
/// It sees fn (flagsChanged, key code 63) and key downs; it keeps a key from the app in front only when FnGesture says
/// the key is Free Flow's (fn+Space for hands-free, Esc while recording). fn itself always goes through.
/// Build 26: not @MainActor, and nothing on the tap path asks Swift which actor it is on. Build 26.1 (Xcode 27.2) crashed
/// with EXC_BAD_ACCESS inside MainActor.assumeIsolated in the tap callback (Free Flow-2026-11-01-055008.ips, main
/// thread). The tap's run loop source and the retry timer are on the main run loop, and start/stop are called on the
/// main thread, so every member is touched on the main thread only.
final class FnKeyMonitor: @unchecked Sendable {
    /// fn went down (true) or up (false); the Bool after it: Command, Control, Option or Shift were held too.
    var onFn: ((Bool, Bool) -> Void)?
    /// A key went down; return true to keep it from the app in front.
    var onKey: ((FnGesture.Key) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var fnHeld = false
    /// Build 26: ms from the key's own timestamp to this tap seeing it (a busy main thread shows here), for FFSTART.
    private(set) var lastFnLagMs: Double = 0

    var running: Bool { tap != nil }

    /// Starts the tap once Accessibility is on; until then it checks again every 2 seconds, without asking.
    func start() {
        guard tap == nil else { return }
        if AXIsProcessTrusted(), install() { retry?.invalidate(); retry = nil; return }
        guard retry == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.tap == nil else { return }
            if AXIsProcessTrusted(), self.install() { self.retry?.invalidate(); self.retry = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    func stop() {
        retry?.invalidate(); retry = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    private func install() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: fnTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// An event's timestamp is mach_absolute_time ticks on this clock; ms from it to now (nil-safe: 0 when unreadable).
    private static func lagMs(_ stamp: CGEventTimestamp) -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let now = mach_absolute_time()
        guard stamp > 0, stamp <= now, tb.denom > 0 else { return 0 }
        return Double(now - stamp) * Double(tb.numer) / Double(tb.denom) / 1_000_000
    }

    /// true = keep the event from the app in front.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 63 else { return false }   // kVK_Function
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != fnHeld else { return false }
            fnHeld = down
            lastFnLagMs = Self.lagMs(event.timestamp)
            let others = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            onFn?(down, !others.isEmpty)
            return false
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let key: FnGesture.Key = code == 49 ? .space : code == 53 ? .escape : .other
            // A held key repeats: only its first down counts, and a repeat of a key Free Flow kept stays kept.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return key == .space && fnHeld
            }
            return onKey?(key) ?? false
        default:
            return false
        }
    }
}

private func fnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run loop source is on the main run loop, so this runs on the main thread; build 26: no actor check here
    // (see the class note). Anywhere else the event passes through untouched.
    guard Thread.isMainThread else { return Unmanaged.passUnretained(event) }
    let keep = monitor.handle(type, event)
    return keep ? nil : Unmanaged.passUnretained(event)
}
