import AppKit
import ApplicationServices
import CoreAudio
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "freeflow.mac", category: "bridge")

/// What the Mac Catalyst app asks of this plug-in. The app declares the same protocol under the same Objective-C name
/// (Catalyst/MacHost.swift), so the class below is reached through it. Strings, numbers and blocks only.
@objc(FFMacBridging) public protocol FFMacBridging: NSObjectProtocol {
    /// Starts watching fn (it needs Accessibility; until that is on it checks again every 2 s, without asking).
    /// Events: "start", "startHandsFree", "becomeHandsFree", "stop", "cancel" (fn, Esc or the pill's buttons), and
    /// "menu:<n>" when item n of the menu-bar menu is chosen.
    func start(_ onEvent: @escaping (String) -> Void)
    /// fn's state machine goes back to idle (a dictation that could not start, or ended some other way).
    func resetGesture()
    func accessibilityTrusted() -> Bool
    /// macOS's own Accessibility request (it opens System Settings at the Free Flow switch).
    func askAccessibility()
    /// Puts the text at the cursor of the app in front (clipboard, Command-V, your clipboard back). done(true) =
    /// pasted, done(false) = left on the clipboard (no Accessibility).
    func insert(_ text: String, _ done: @escaping (Bool) -> Void)
    /// The floating pill: "listening", "handsFree", "working", "message" (text, gone after `seconds`) or "hide".
    func pill(_ look: String, _ text: String, _ seconds: Double)
    func level(_ value: Float)
    /// The menu-bar menu: one item per title ("-" = a separator); checked and enabled per item.
    func menu(_ titles: [String], _ checked: [NSNumber], _ enabled: [NSNumber])
    /// Brings Free Flow to the front (its window), from the menu-bar item or a pill message.
    func activate()
    /// The system's default input (the mic Free Flow records from).
    func inputName() -> String
    /// Opens a System Settings page: "accessibility", "microphone", "keyboard" or "sound".
    func openSettings(_ page: String)
    /// Build 26: the input devices, one "uid<TAB>name<TAB>kind" each (kind: builtin, bluetooth, usb, other); the
    /// default input's uid. A change in the list comes as the event "devices".
    func inputDevices() -> [String]
    func defaultInputUID() -> String
    /// Build 26: records from the input with this uid (a mic picked in Settings) until stopInput; "" when it started,
    /// else why not. onAudio: mono Float32 samples, their count and rate, on the audio thread.
    func startInput(_ uid: String, _ onAudio: @escaping (UnsafePointer<Float>, Int, Double) -> Void) -> String
    func stopInput()
    #if DEBUG || FF_TESTS
    /// Test builds only (security). The mic test (--mictest --switch): moves the default input to the built-in mic,
    /// or from it to a Bluetooth or USB input (never an iPhone's); returns the new device's name, or "" when there is none.
    func switchInput() -> String
    /// Puts the default input back as it was before switchInput; returns its name.
    func restoreInput() -> String
    /// A synthetic fn press or release, posted where a keyboard's would be (--fntest).
    func postFn(_ down: Bool)
    /// Opens a file in an app (bundle id) and brings it to the front.
    func testOpen(_ path: String, _ app: String)
    /// The text of the focused field in the app in front, read through Accessibility.
    func focusedText() -> String
    #endif
}

/// The plug-in's principal class (Info.plist NSPrincipalClass).
@objc(FFMacBridgeMain)
public final class FFMacBridgeMain: NSObject, FFMacBridging {
    private var onEvent: ((String) -> Void)?
    private var monitor: FnKeyMonitor?
    private var gesture = FnGesture()
    private var pillPanel: PillPanel?
    private var status: NSStatusItem?
    private var originalInput: AudioDeviceID?

    public override init() { super.init() }

    public func start(_ onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent
        // Build 26: the fn monitor and its closures are made outside MainActor.assumeIsolated, so the closures the tap
        // calls carry no actor isolation and no runtime actor check (build 26.1's crash, FnKeyMonitor's note).
        let m = FnKeyMonitor()
        m.onFn = { [weak self] down, others in
            guard let self else { return }
            let t = ProcessInfo.processInfo.systemUptime
            // Build 26: a start carries when fn went down (the key's own time, on the systemUptime clock) for FFSTART.
            self.apply(down ? self.gesture.fnPressed(at: t, otherModifiers: others) : self.gesture.fnReleased(at: t),
                       at: t - (self.monitor?.lastFnLagMs ?? 0) / 1000, tap: t)
        }
        m.onKey = { [weak self] key in
            guard let self else { return false }
            let r = self.gesture.keyPressed(key, at: ProcessInfo.processInfo.systemUptime)
            let now = ProcessInfo.processInfo.systemUptime
            self.apply(r.action, at: now, tap: now)
            return r.swallow
        }
        m.start()
        monitor = m
        watchDevices()
        MainActor.assumeIsolated {
            let panel = PillPanel()
            panel.onStop = { [weak self] in self?.send("stop") }
            panel.onCancel = { [weak self] in self?.send("cancel") }
            pillPanel = panel
        }
        log.log("bridge started, accessibility=\(AXIsProcessTrusted(), privacy: .public)")
    }

    private func apply(_ action: FnGesture.Action, at t: Double, tap: Double) {
        switch action {
        case .none: break
        case .start: send("start@\(t)@\(tap)")
        case .startHandsFree: send("startHandsFree@\(t)@\(tap)")
        case .becomeHandsFree: send("becomeHandsFree")
        case .stopAndInsert: send("stop")
        case .cancel: send("cancel")
        }
    }

    private func send(_ event: String) { onEvent?(event) }

    public func resetGesture() { gesture.reset() }

    public func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    public func askAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func insert(_ text: String, _ done: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let result = await TextInserter.insert(text)
            done(result == .pasted)
        }
    }

    public func pill(_ look: String, _ text: String, _ seconds: Double) {
        MainActor.assumeIsolated {
            guard let p = pillPanel else { return }
            switch look {
            case "listening": p.show(.listening)
            case "handsFree": p.show(.handsFree)
            case "working": p.show(.working)
            case "message": p.flash(text, seconds: seconds > 0 ? seconds : 2.4)
            default: p.hide()
            }
        }
    }

    public func level(_ value: Float) { MainActor.assumeIsolated { pillPanel?.push(value) } }

    public func menu(_ titles: [String], _ checked: [NSNumber], _ enabled: [NSNumber]) {
        MainActor.assumeIsolated {
            if status == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Free Flow")
                image?.isTemplate = true
                item.button?.image = image
                status = item
            }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (i, title) in titles.enumerated() {
                if title == "-" { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = (i < checked.count && checked[i].boolValue) ? .on : .off
                item.isEnabled = i < enabled.count ? enabled[i].boolValue : true
                menu.addItem(item)
            }
            status?.menu = menu
        }
    }

    @objc private func picked(_ sender: NSMenuItem) { send("menu:\(sender.tag)") }

    public func activate() {
        MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
    }

    public func inputName() -> String { AudioDevices.name(AudioDevices.defaultInput()) }

    private let inputMic = InputMic()
    private var devicesWatched = false

    public func inputDevices() -> [String] {
        // The audio session's own private aggregates (CADefaultDeviceAggregate-<pid>-<n>) are not mics to pick.
        AudioDevices.inputs().filter { !AudioDevices.uid($0).hasPrefix("CADefaultDeviceAggregate") }
            .map { "\(AudioDevices.uid($0))\t\(AudioDevices.name($0))\t\(AudioDevices.kind($0))" }
    }

    public func defaultInputUID() -> String { AudioDevices.uid(AudioDevices.defaultInput()) }

    public func startInput(_ uid: String, _ onAudio: @escaping (UnsafePointer<Float>, Int, Double) -> Void) -> String {
        inputMic.start(uid: uid, onAudio)
    }

    public func stopInput() { inputMic.stop() }

    /// Devices added or removed, or a new default input: the app refreshes its picker.
    private func watchDevices() {
        guard !devicesWatched else { return }
        devicesWatched = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main) { [weak self] _, _ in
                self?.send("devices")
            }
        }
        // After sleep an input unit kept open may be stale: the app reopens it at the next press.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.send("wake")
        }
    }

    #if DEBUG || FF_TESTS
    public func switchInput() -> String {
        let now = AudioDevices.defaultInput()
        if originalInput == nil { originalInput = now }
        guard let other = AudioDevices.switchTarget(from: now) else { return "" }
        AudioDevices.setDefaultInput(other)
        return AudioDevices.name(other)
    }

    public func restoreInput() -> String {
        if let original = originalInput, AudioDevices.defaultInput() != original { AudioDevices.setDefaultInput(original) }
        originalInput = nil
        return inputName()
    }
    #endif

    public func openSettings(_ page: String) {
        let anchor: String
        switch page {
        case "accessibility": anchor = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case "microphone": anchor = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case "keyboard": anchor = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        default: anchor = "x-apple.systempreferences:com.apple.Sound-Settings.extension?input"
        }
        if let url = URL(string: anchor) { NSWorkspace.shared.open(url) }
    }

    #if DEBUG || FF_TESTS
    public func postFn(_ down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        e.post(tap: .cghidEventTap)
    }

    public func testOpen(_ path: String, _ app: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config) { _, _ in }
    }

    public func focusedText() -> String {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return "" }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
    #endif
}
