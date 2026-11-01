#if targetEnvironment(macCatalyst)
import AVFAudio
import FreeFlowKit
import UIKit
import os

private let log = Logger(subsystem: FF.subsystem + ".mac", category: "dictation")

/// The plug-in's protocol, declared again here under the same Objective-C name (MacBridge/Bridge.swift has the
/// documented copy). The two must stay identical.
@objc(FFMacBridging) protocol FFMacBridging: NSObjectProtocol {
    func start(_ onEvent: @escaping (String) -> Void)
    func resetGesture()
    func accessibilityTrusted() -> Bool
    func askAccessibility()
    func insert(_ text: String, _ done: @escaping (Bool) -> Void)
    func pill(_ look: String, _ text: String, _ seconds: Double)
    func level(_ value: Float)
    func menu(_ titles: [String], _ checked: [NSNumber], _ enabled: [NSNumber])
    func activate()
    func inputName() -> String
    func openSettings(_ page: String)
    func inputDevices() -> [String]
    func defaultInputUID() -> String
    func startInput(_ uid: String, _ onAudio: @escaping (UnsafePointer<Float>, Int, Double) -> Void) -> String
    func stopInput()
    #if DEBUG || FF_TESTS
    /// Test builds only (security): the mic test's input switch, fn presses, opening a file, the focused field.
    func switchInput() -> String
    func restoreInput() -> String
    func postFn(_ down: Bool)
    func testOpen(_ path: String, _ app: String)
    func focusedText() -> String
    #endif
}

/// Free Flow for Mac around the iPhone app (build 20): loads the AppKit plug-in, and turns fn into the iPhone app's own
/// dictation (DictationEngine, the same model, dictionary, writer, history, stats and saved recordings). fn's text goes
/// in at the cursor of the app in front; the pill and the menu-bar item are the Mac's extras.
@MainActor
final class MacHost: ObservableObject {
    static let shared = MacHost()

    private(set) var bridge: FFMacBridging?
    /// Accessibility (fn in every app and pasting into other apps), read again whenever Free Flow becomes active.
    @Published private(set) var accessibility = false
    /// The default input (the mic Free Flow records from).
    @Published private(set) var micName = ""
    /// Build 26: the input devices (the mic picker in Settings and the menu-bar menu) and the default one's uid.
    struct Input: Identifiable, Equatable { let uid: String, name: String, kind: String; var id: String { uid } }
    @Published private(set) var inputs: [Input] = []
    @Published private(set) var defaultUID = ""
    /// The picked mic: MacMic.builtIn (the default), MacMic.systemDefault or a device uid (MacMic.deviceKey).
    @Published private(set) var picked = MacMic.picked(stored: UserDefaults.standard.string(forKey: MacMic.deviceKey))
    #if DEBUG || FF_TESTS
    /// Tests: a mic for this run only, never saved (same values as `picked`).
    var testPicked: String?
    #endif
    /// The dictation in progress was started by fn: its text goes in at the cursor.
    private var fnDictation = false
    private var handsFree = false
    /// fn was let go (or pressed again) before the mic had started: finish as soon as it is listening.
    private var stopWhenStarted = false
    /// Build 26: a cancel (a tap under half a second, Esc) that came while the mic was still starting (the start runs off
    /// the main thread now, so fn's next events arrive during it): done as soon as it is listening, unless another fn
    /// press comes first and keeps the recording going (the double press's second press, or a new hold).
    private var cancelWhenStarted = false
    private var starting = false
    /// The last text fn put in, for "Paste last dictation" when a paste did not land.
    private var lastText = ""

    var engine: DictationEngine { .shared }

    func start() {
        guard bridge == nil else { return }
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FreeFlowMacBridge.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? NSObject.Type,
              let b = type.init() as? FFMacBridging else {
            log.error("Mac plug-in did not load")
            return
        }
        bridge = b
        let original = engine.capture.onLevel
        engine.capture.onLevel = { [weak b] level in
            original?(level)
            DispatchQueue.main.async { b?.level(level) }
        }
        engine.capture.externalStart = { [weak b] uid, onAudio in b?.startInput(uid, onAudio) ?? "Free Flow's Mac part did not load" }
        engine.capture.externalStop = { [weak b] in b?.stopInput() }
        engine.macOwnInput = { [weak self] in self?.ownInput() }
        b.start { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        refresh()
        updateMenu()
        log.log("Mac host started, accessibility=\(self.accessibility, privacy: .public)")
        #if DEBUG || FF_TESTS
        MacTests.runIfAsked(self)
        #endif
    }

    #if DEBUG || FF_TESTS
    /// Tests (Catalyst/MacTests.swift): fn as a keyboard would press it, and what is in the field afterwards.
    func postFn(_ down: Bool) { bridge?.postFn(down) }
    func testOpen(_ path: String, _ app: String) { bridge?.testOpen(path, app) }
    func focusedText() -> String { bridge?.focusedText() ?? "" }
    var lastInserted: String { lastText }
    #endif

    func refresh() {
        accessibility = bridge?.accessibilityTrusted() ?? false
        micName = bridge?.inputName() ?? ""
        inputs = (bridge?.inputDevices() ?? []).compactMap { line in
            let f = line.components(separatedBy: "\t")
            return f.count == 3 && !f[0].isEmpty ? Input(uid: f[0], name: f[1], kind: f[2]) : nil
        }
        defaultUID = bridge?.defaultInputUID() ?? ""
    }

    var builtInUID: String? { inputs.first { $0.kind == "builtin" }?.uid }

    /// Build 26: the picked mic when it is connected (it records through the plug-in), else nil (the system default
    /// input records, through the audio session).
    func ownInput() -> (uid: String, name: String)? {
        refresh()
        var p = picked
        #if DEBUG || FF_TESTS
        if let t = testPicked { p = t }
        #endif
        let uid = MacMic.ownInput(picked: p, connected: inputs.map(\.uid), builtInUID: builtInUID)
        guard !uid.isEmpty, let input = inputs.first(where: { $0.uid == uid }) else { return nil }
        return (uid, input.name)
    }

    /// The mic fn records from now, as Settings names it.
    var micInUse: String {
        let uid = MacMic.ownInput(picked: picked, connected: inputs.map(\.uid), builtInUID: builtInUID)
        if let input = inputs.first(where: { $0.uid == uid }) { return input.name }
        return micName.isEmpty ? "None found" : micName + " (system default input)"
    }

    /// A picker or menu line for an input: a Bluetooth headset's mic says what it costs.
    func label(_ input: Input) -> String {
        input.kind == "bluetooth" ? input.name + " (slower to start; music plays in call quality while it is on)" : input.name
    }

    /// Build 26: pick a mic. A mic kept ready closes, so the next press opens the new one.
    func pick(_ choice: String) {
        picked = choice
        UserDefaults.standard.set(choice, forKey: MacMic.deviceKey)
        if engine.sessionLive, engine.phase != .listening, engine.phase != .transcribing {
            engine.endSession("You picked another mic")
        }
        updateMenu()
    }

    func askAccessibility() { bridge?.askAccessibility() }
    func openSettings(_ page: String) { bridge?.openSettings(page) }

    private func handle(_ message: String) {
        // Build 26: "start@<fn down>@<tap saw it>" (systemUptime seconds, the plug-in's times, for the FFSTART line).
        let parts = message.split(separator: "@", maxSplits: 2)
        let event = parts.first.map(String.init) ?? message
        let pressedAt = parts.count > 1 ? Double(parts[1]) : nil
        let tapAt = parts.count > 2 ? Double(parts[2]) : nil
        if (event == "start" || event == "startHandsFree"), starting, cancelWhenStarted, fnDictation {
            // The first press's mic is still starting: this press keeps that recording instead of starting another.
            cancelWhenStarted = false
            handsFree = event == "startHandsFree"
            bridge?.pill(handsFree ? "handsFree" : "listening", "", 0)
            return
        }
        switch event {
        case "start": startFn(handsFree: false, pressedAt: pressedAt, tapAt: tapAt)
        case "startHandsFree": startFn(handsFree: true, pressedAt: pressedAt, tapAt: tapAt)
        case "becomeHandsFree":
            guard fnDictation else { return }
            handsFree = true
            bridge?.pill("handsFree", "", 0)
        case "stop":
            guard fnDictation else { return }
            if starting { stopWhenStarted = true } else { Task { await finishFn() } }
        case "cancel":
            guard fnDictation else { return }
            if starting {
                stopWhenStarted = false
                cancelWhenStarted = true
                bridge?.pill("hide", "", 0)
                return
            }
            engine.cancelDictation()
            endFn()
            releaseMicIfAsked()
            bridge?.pill("hide", "", 0)
        case "wake":
            refresh()
            if engine.sessionLive, engine.phase != .listening, engine.phase != .transcribing { engine.endSession("The Mac woke from sleep") }
        case "devices":
            // A device came or went, the default input changed, or the Mac woke: a mic kept ready closes, and the next
            // press opens the picked one again (or the system default if it is gone). The audio session's own private
            // aggregates come and go with every session, so only a real change in the mics counts.
            let before = inputs.map(\.uid) + [defaultUID]
            refresh()
            updateMenu()
            let changed = inputs.map(\.uid) + [defaultUID] != before
            if changed, engine.sessionLive, engine.phase != .listening, engine.phase != .transcribing {
                engine.endSession("The microphones changed")
            }
        default:
            if event.hasPrefix("menu:"), let i = Int(event.dropFirst(5)) { menuPicked(i) }
        }
    }

    // MARK: fn dictation

    private func startFn(handsFree: Bool, pressedAt: Double? = nil, tapAt: Double? = nil) {
        guard !fnDictation, engine.phase != .listening, engine.phase != .transcribing else { bridge?.resetGesture(); return }
        engine.trace = .init(keyDown: pressedAt, tap: tapAt ?? 0, host: DictationEngine.now())
        guard ModelManager.shared.activeReady else {
            refuse("Set up Free Flow first")
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            refuse("Free Flow needs the microphone")
            return
        }
        fnDictation = true
        self.handsFree = handsFree
        starting = true
        stopWhenStarted = false
        cancelWhenStarted = false
        bridge?.pill(handsFree ? "handsFree" : "listening", "", 0)
        Task {
            await engine.startDictation(target: .fn)
            starting = false
            guard engine.phase == .listening else {
                let why = engine.errorText ?? "No microphone found"
                endFn()
                releaseMicIfAsked()
                bridge?.pill("message", why, 3)
                return
            }
            if cancelWhenStarted {
                cancelWhenStarted = false
                engine.cancelDictation()
                endFn()
                releaseMicIfAsked()
                return
            }
            if stopWhenStarted { await finishFn() }
        }
    }

    private func refuse(_ text: String) {
        bridge?.resetGesture()
        bridge?.pill("message", text, 2.4)
        showWindow()
    }

    private func finishFn() async {
        bridge?.pill("working", "", 0)
        let text = await engine.finishDictation()
        endFn()
        guard !text.isEmpty else {
            releaseMicIfAsked()
            bridge?.pill("message", engine.errorText ?? "Didn't catch that. Try again.", 2.4)
            return
        }
        lastText = text
        updateMenu()
        bridge?.insert(text) { [weak self] pasted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    log.log("inserted: \(pasted ? "pasted" : "copied", privacy: .public)")
                    // The mic goes off after the paste, not before it: stopping the audio engine first could cost
                    // the paste its moment in the app in front.
                    self?.releaseMicIfAsked()
                    if pasted {
                        self?.bridge?.pill("hide", "", 0)
                    } else {
                        self?.bridge?.pill("message", "Copied. Turn on Accessibility to paste, or press ⌘V", 3.5)
                    }
                }
            }
        }
    }

    /// Build 23: with Settings > Keep mic ready on "Off right after each dictation" (build 26: default 2 minutes), the mic goes off as
    /// soon as a fn dictation ends; build 22 left it on for the whole session window (15 minutes) after every press.
    private func releaseMicIfAsked() {
        guard MacMic.releasesAfterDictation(stored: UserDefaults.standard.object(forKey: MacMic.key) as? Int),
              engine.sessionLive, engine.phase != .listening, engine.phase != .transcribing else { return }
        engine.endSession("Off right after the fn dictation (Settings > Keep mic ready)")
    }

    private func endFn() {
        fnDictation = false
        handsFree = false
        starting = false
        cancelWhenStarted = false
        bridge?.resetGesture()
    }

    // MARK: Menu-bar item (the Mac's extra)

    private var menuActions: [() -> Void] = []

    func updateMenu() {
        var titles: [String] = [], checked: [NSNumber] = [], enabled: [NSNumber] = []
        menuActions = []
        func item(_ title: String, on: Bool = false, enabled e: Bool = true, _ action: @escaping () -> Void = {}) {
            titles.append(title); checked.append(NSNumber(value: on)); enabled.append(NSNumber(value: e)); menuActions.append(action)
        }
        item(accessibility ? "Hold fn to dictate" : "Turn on Accessibility to use fn", enabled: false)
        item("-")
        let style = SharedSession.style
        for s in DictationStyle.allCases {
            item(s.pill, on: s == style) { [weak self] in SharedSession.style = s; self?.updateMenu() }
        }
        item("-")
        // Build 26: the mic picker, one click from the menu bar.
        item("Microphone", enabled: false)
        if builtInUID != nil {
            item("Built-in microphone", on: picked == MacMic.builtIn) { [weak self] in self?.pick(MacMic.builtIn) }
        }
        item("System default input" + (micName.isEmpty ? "" : " (\(micName))"), on: picked == MacMic.systemDefault) { [weak self] in
            self?.pick(MacMic.systemDefault)
        }
        for input in inputs where input.kind != "builtin" {
            item(label(input), on: picked == input.uid) { [weak self] in self?.pick(input.uid) }
        }
        item("-")
        item("Paste last dictation", enabled: !lastText.isEmpty) { [weak self] in
            guard let self, !self.lastText.isEmpty else { return }
            self.bridge?.insert(self.lastText) { _ in }
        }
        item("Open Free Flow") { [weak self] in self?.showWindow() }
        bridge?.menu(titles, checked, enabled)
    }

    private func menuPicked(_ i: Int) {
        guard i < menuActions.count else { return }
        menuActions[i]()
    }

    func showWindow() { bridge?.activate() }

    #if DEBUG || FF_TESTS
    // MARK: Mic test (FF_MAC_TEST=1 --mictest <s> [--switch]), test builds only

    func switchInput() -> String { bridge?.switchInput() ?? "" }
    func restoreInput() -> String { bridge?.restoreInput() ?? "" }
    #endif
}
#endif
