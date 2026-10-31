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
@MainActor
final class FnKeyMonitor {
    /// fn went down (true) or up (false); the Bool after it: Command, Control, Option or Shift were held too.
    var onFn: ((Bool, Bool) -> Void)?
    /// A key went down; return true to keep it from the app in front.
    var onKey: ((FnGesture.Key) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var fnHeld = false

    var running: Bool { tap != nil }

    /// Starts the tap once Accessibility is on; until then it checks again every 2 seconds, without asking.
    func start() {
        guard tap == nil else { return }
        if AXIsProcessTrusted(), install() { retry?.invalidate(); retry = nil; return }
        guard retry == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap == nil else { return }
                if AXIsProcessTrusted(), self.install() { self.retry?.invalidate(); self.retry = nil }
            }
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
    // The tap's run loop source is on the main run loop, so this runs on the main thread.
    let keep = MainActor.assumeIsolated { monitor.handle(type, event) }
    return keep ? nil : Unmanaged.passUnretained(event)
}
