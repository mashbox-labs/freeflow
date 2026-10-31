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
    /// The dictation in progress was started by fn: its text goes in at the cursor.
    private var fnDictation = false
    private var handsFree = false
    /// fn was let go (or pressed again) before the mic had started: finish as soon as it is listening.
    private var stopWhenStarted = false
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
    }

    func askAccessibility() { bridge?.askAccessibility() }
    func openSettings(_ page: String) { bridge?.openSettings(page) }

    private func handle(_ event: String) {
        switch event {
        case "start": startFn(handsFree: false)
        case "startHandsFree": startFn(handsFree: true)
        case "becomeHandsFree":
            guard fnDictation else { return }
            handsFree = true
            bridge?.pill("handsFree", "", 0)
        case "stop":
            guard fnDictation else { return }
            if starting { stopWhenStarted = true } else { Task { await finishFn() } }
        case "cancel":
            guard fnDictation else { return }
            if starting { stopWhenStarted = false }
            engine.cancelDictation()
            endFn()
            releaseMicIfAsked()
            bridge?.pill("hide", "", 0)
        default:
            if event.hasPrefix("menu:"), let i = Int(event.dropFirst(5)) { menuPicked(i) }
        }
    }

    // MARK: fn dictation

    private func startFn(handsFree: Bool) {
        guard !fnDictation, engine.phase != .listening, engine.phase != .transcribing else { bridge?.resetGesture(); return }
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

    /// Build 23 (F2): with Settings > Mic after fn on "Off right after each dictation" (the default), the mic goes off as
    /// soon as a fn dictation ends; build 22 left it on for the whole session window (15 minutes) after every press.
    private func releaseMicIfAsked() {
        guard MacMic.releasesAfterDictation(stored: UserDefaults.standard.object(forKey: MacMic.key) as? Int),
              engine.sessionLive, engine.phase != .listening, engine.phase != .transcribing else { return }
        engine.endSession("Off right after the fn dictation (Settings > Mic after fn)")
    }

    private func endFn() {
        fnDictation = false
        handsFree = false
        starting = false
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
