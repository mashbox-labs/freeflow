import FreeFlowKit
import SwiftUI
import UIKit
import os

/// The Free Flow keyboard. It types like a normal keyboard; the mic key asks the Free Flow app
/// (which owns the microphone) to listen, then inserts the text it gets back.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardView>?
    /// Full Access seen and written down during this appearance.
    private var accessProven = false
    /// When this opening began, and whether it already told the app it has no Full Access (once per opening).
    private var appearedAt: Date?
    private var noAccessPosted = false
    private var accessTimer: Timer?
    /// Watches the field while the keyboard is up (build 18): moving to another field of a web page with the keyboard
    /// kept up sends no callback (KeyboardMatchUITests testM1FieldKinds, iOS 27.2 Safari), so the field's identity and
    /// traits are read three times a second; a change re-reads the layout.
    private var fieldTimer: Timer?
    private var fieldSeen: (UUID?, Int, Int) = (nil, -1, -1)
    private var heightConstraint: NSLayoutConstraint?

    /// Tall enough for Apple's four rows under the action row, the same in every layout (ComfortMetrics.height).
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let h = ComfortMetrics.height(width: view.bounds.width)
        if let c = heightConstraint, c.constant != h { c.constant = h }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        FFFont.register()
        model.type = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        model.insert = { [weak self] text in self?.insertDictation(text) }
        model.deleteBackward = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.nextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        model.inputController = self
        model.openApp = { [weak self] done in self?.openApp(done) ?? false }
        model.contextBefore = { [weak self] in self?.textDocumentProxy.documentContextBeforeInput ?? "" }
        model.dismiss = { [weak self] in self?.dismissKeyboard() }
        model.feel.micReady = { [weak self] in self?.model.sessionLive ?? false }
        // Contact names and text replacements (every custom keyboard gets this list): autocorrect never changes them.
        let allow = model.autocorrect.allow
        requestSupplementaryLexicon { lexicon in
            allow.setSystemLexicon(lexicon.entries.map { (userInput: $0.userInput, documentText: $0.documentText) })
        }
        let host = UIHostingController(rootView: KeyboardView(model: model, showsGlobe: needsInputModeSwitchKey))
        host.view.backgroundColor = .clear
        // No supported API tints Apple's globe/mic strip, so the keys sit on the same system keyboard
        // material as that strip in every app. A near-invisible floor stays edge to edge: iOS does not deliver touches
        // to fully transparent parts of a keyboard extension, and the gaps between keys must still type.
        view.backgroundColor = KeyColors.touchFloor
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 280)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
        self.host = host
        for (direction, touches) in [(UISwipeGestureRecognizer.Direction.up, 2), (.down, 2), (.up, 3), (.down, 3)] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = touches
            swipe.cancelsTouchesInView = false
            view.addGestureRecognizer(swipe)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        accessProven = false
        noAccessPosted = false
        appearedAt = Date()
        model.hasFullAccess = hasFullAccess
        if hasFullAccess {
            SharedSession.keyboardFullAccess = true
            SharedSession.keyboardSeen = Date()
            // The app's layout previews draw the globe key only where this keyboard does.
            if SharedSession.keyboardGlobe != needsInputModeSwitchKey { SharedSession.keyboardGlobe = needsInputModeSwitchKey }
        }
        // Build 19 (a repeat report from an iPad: setup said not done while the keyboard worked): the proof was written
        // only when the keyboard closed, and the flag iOS reports can be off for a moment at open. Prove it now, and
        // every half second while the keyboard is up until it lands.
        noteFullAccess()
        accessTimer?.invalidate()
        accessTimer = accessProven ? nil : Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.noteFullAccess() }
        }
        followAppearance()
        model.feel.load(fullAccess: hasFullAccess)
        model.autocorrect.fieldAllows = fieldAllowsAutocorrect
        model.appear()
        readField(textChanged: true)
        fieldTimer?.invalidate()
        fieldTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchField() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        accessTimer?.invalidate(); accessTimer = nil
        fieldTimer?.invalidate(); fieldTimer = nil
        model.disappear()
        model.feel.save()
    }

    private func watchField() {
        let p = textDocumentProxy
        // Build 32: a nil identifier from iOS is no field (reading it as a Swift UUID trapped, builds 19 to 30).
        guard let field = FieldIdentity.read(p) else { return }
        let now: (UUID?, Int, Int) = (field, p.keyboardType?.rawValue ?? 0, p.returnKeyType?.rawValue ?? 0)
        guard now != fieldSeen else { return }
        let newDocument = now.0 != fieldSeen.0
        fieldSeen = now
        model.autocorrect.fieldAllows = fieldAllowsAutocorrect
        readField(textChanged: newDocument)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        followAppearance()
        model.autocorrect.fieldAllows = fieldAllowsAutocorrect
        readField(textChanged: true)
        // Moving to another field with the keyboard up: the new field's traits can reach the proxy after this call
        // (KeyboardMatchUITests testM1FieldKinds, iOS 27.2 Safari: every field showed the one before's layout).
        for delay in [0.12, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.model.autocorrect.fieldAllows = self.fieldAllowsAutocorrect
                self.readField(textChanged: false)
            }
        }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        readField(textChanged: false)
    }

    /// The field's keyboard type (which page and bottom row), return key label and capitals rule, as Apple's keyboard
    /// follows them (build 18). textChanged = also recheck the automatic capital (never on a selection or a late
    /// re-read, which would undo a shift the person just tapped).
    private func readField(textChanged: Bool) {
        let p = textDocumentProxy
        model.readField(keyboardType: p.keyboardType?.rawValue ?? 0, returnType: p.returnKeyType?.rawValue ?? 0,
                        autocap: p.autocapitalizationType?.rawValue ?? 2, textChanged: textChanged)
    }

    /// Autocorrect follows the field: none where the app turned autocorrection off, none in URL or email fields.
    private var fieldAllowsAutocorrect: Bool {
        let proxy = textDocumentProxy
        if proxy.autocorrectionType == .no { return false }
        return !(proxy.keyboardType == .URL || proxy.keyboardType == .emailAddress)
    }

    /// Light or dark like the system keyboard: the field's own keyboard appearance, else the system setting.
    private func followAppearance() {
        let style: UIUserInterfaceStyle = textDocumentProxy.keyboardAppearance == .dark ? .dark : .unspecified
        if view.overrideUserInterfaceStyle != style { view.overrideUserInterfaceStyle = style }
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        guard SharedSession.keyboardGestures else { return }
        if swipe.direction == .up { model.tapMic() } else { model.finish() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS can still report Full Access as off in viewWillAppear, and setup then never sees it. Check again once
        // the keyboard is on screen, then once a second while it shows until it is proven.
        noteFullAccess()
        accessTimer?.invalidate()
        accessTimer = accessProven ? nil : Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.noteFullAccess() }
        }
    }

    /// Full Access as this keyboard can really use it: the flag iOS reports, or a write that landed in the App Group
    /// folder, which a keyboard cannot do without Full Access. Either one is written down for the app's setup check.
    /// `model.hasFullAccess` follows it: read that, not the flag from viewWillAppear, for anything that needs access.
    private func noteFullAccess() {
        guard !accessProven else { return }
        let flag = hasFullAccess
        model.hasFullAccess = KeyboardProof.record(flag: flag) || flag
        // Setup is told what iOS reports, checked every half second while the keyboard is up (it can read off for a
        // moment as the keyboard starts). A write that landed is not taken as proof on its own: the simulator lets a
        // keyboard without Full Access write into the App Group (measured 10-30, flag false).
        guard flag else {
            // Still no access 2 s after opening: tell the app (once per opening).
            if !noAccessPosted, let at = appearedAt, Date().timeIntervalSince(at) >= 2 {
                noAccessPosted = true
                DarwinBus.shared.post(.keyboardNoAccess)
            }
            return
        }
        accessProven = true
        accessTimer?.invalidate(); accessTimer = nil
        model.feel.load(fullAccess: true)
        SharedSession.keyboardFullAccess = true
        SharedSession.keyboardSeen = Date()
        DarwinBus.shared.post(.keyboardSeen)
    }

    private func insertDictation(_ text: String) {
        guard !text.isEmpty else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let needsSpace = !(before.isEmpty || before.last?.isWhitespace == true)
        textDocumentProxy.insertText((needsSpace ? " " : "") + text)
    }

    /// Opens Free Flow with its own URL scheme by reaching UIApplication through the responder chain,
    /// the method Apple DTS describes for keyboards (developer.apple.com/forums/thread/812091). `done` gets iOS's
    /// answer (false = it refused to open Free Flow).
    private func openApp(_ done: @escaping (Bool) -> Void) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let appClass = NSClassFromString("UIApplication") else { return false }
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: appClass), current.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                let answer: @convention(block) (Bool) -> Void = { opened in DispatchQueue.main.async { done(opened) } }
                open(current, selector, FF.dictateURL as NSURL, NSDictionary(), unsafeBitCast(answer, to: AnyObject.self))
                return true
            }
            responder = current.next
        }
        return false
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    /// starting (build 26): back from Free Flow, the keyboard asked for the start and waits for the app to record.
    enum Mode: Equatable { case idle, opening, openFailed, starting, listening, writing, message(String) }
    @Published var mode: Mode = .idle
    @Published var levels = [Float](repeating: 0, count: 32)
    @Published var style = SharedSession.style
    /// Build 37: the style key only with Apple Intelligence cleanup on (SharedSession.styleKeyShown).
    @Published var styleKey = SharedSession.styleKeyShown
    @Published var sessionLive = false
    /// From SessionTruth only: "Tap to turn on", "Ready · 12 min", "Listening", "Writing".
    @Published var status = "Tap to turn on"
    @Published var inputName = "Microphone"
    /// What the app is doing after Finish (SharedSession.stage, build 18), shown as the busy title.
    @Published var stage = "Transcribing"
    var hasFullAccess = true
    @Published var layout = KeyLayoutKind.current
    @Published var hand = KeyHand.current
    /// Build 18, Apple's keyboard in full: the page of keys, shift and caps lock, the field's kind and return key.
    @Published var page: KeyPage = .letters
    @Published var shift = false
    @Published var capsLock = false
    @Published var field: KeyField = .text
    @Published var returnRaw = 0
    private var autocapRaw = 2
    private var lastShiftTap: Date?
    private var lastSpaceAt: Date?
    var contextBefore: (() -> String)?
    var dismiss: (() -> Void)?
    private var visible = false
    let feel = KeyFeel()
    var type: ((String) -> Void)?
    var insert: ((String) -> Void)?
    var deleteBackward: (() -> Void)?
    var nextKeyboard: (() -> Void)?
    /// Build 23: the controller whose handleInputModeList(from:with:) takes the globe key's touches (KeySurfaceView).
    weak var inputController: UIInputViewController?
    var openApp: ((@escaping (Bool) -> Void) -> Bool)?
    private var timer: Timer?
    private var lastResult = ""
    private var openedAt: Date?
    /// Build 26: when this keyboard asked for the start after a trip, and whether the dictation running is that one
    /// (its title says "Listening, speak now").
    private var startingAt: Date?
    @Published var afterTrip = false
    /// Showing KeyboardLiveRule.stalledText: the app went quiet mid-dictation and may come back.
    private var stalled = false
    /// Autocorrect on space (Settings > Keyboard > Autocorrect). Does nothing until a word list is loaded.
    let autocorrect = AutocorrectTyper()
    private var lastUpWrite = Date.distantPast
    /// Build 28: the result this keyboard is writing with Apple's model now (KeyboardWriting), and that work.
    private var writingID: String?
    private var writeTask: Task<Void, Never>?
    /// The keyboard that appeared last in this process. iOS can keep an earlier keyboard alive after its app has gone
    /// (it never gets viewWillDisappear, so it still counts itself visible). That keyboard took a finished dictation,
    /// typed it into the dead app and marked it done, and the keyboard on screen sat on Writing (UI tests test3Keyboard
    /// after test3bKeyboardAutocorrect, testRT1ReturnToHost). Only the keyboard that appeared last types.
    private static weak var onScreen: KeyboardModel?
    private static let log = Logger(subsystem: FF.subsystem, category: "keyboard")

    init() {
        DarwinBus.shared.observe(.state) { [weak self] in Task { @MainActor in self?.poll() } }
        autocorrect.loadBundledWordList()
    }

    func appear() {
        visible = true
        Self.onScreen = self
        autocorrect.enabled = SharedSession.keyboardAutocorrect
        DictionaryStore.shared.reload()
        autocorrect.allow.setDictionary(DictionaryStore.shared.words)
        style = SharedSession.style
        styleKey = SharedSession.styleKeyShown
        layout = KeyLayoutKind.current
        hand = KeyHand.current
        // A dictation started here and still running (or finished while the keyboard was hidden) lands when the
        // keyboard comes back; anything else from before is old.
        lastResult = Self.awaitedResult ?? SharedSession.resultID
        poll()
        startIfHandedOff()
        timer?.invalidate()
        // 10 a second: the meter and the state; phase changes also arrive at once through DarwinBus .state.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func disappear() {
        timer?.invalidate(); timer = nil
        visible = false
        if Self.onScreen === self { Self.onScreen = nil }
        autocorrect.reset()
        SharedSession.keyboardUpAt = nil
        // Hidden while opening Free Flow: Free Flow came to the front. Coming back, the poll picks up its listening.
        if mode == .opening || mode == .openFailed || mode == .starting { mode = .idle }
        // A hidden keyboard types nothing: the writing stops, and the result stays owed as heard (KeyboardWriting),
        // so a keyboard shown again writes it again. A write that finishes after this is never typed.
        if let id = writingID {
            Self.log.notice("FFWRITE kbd cancelled id=\(id.prefix(8), privacy: .public): keyboard hidden")
            WriteDiagnostics.note("kbd", "cancelled-hidden", ["id": String(id.prefix(8))])
            writeTask?.cancel(); writeTask = nil; writingID = nil
        }
    }

    /// Build 26 (ColdStart): Free Flow is armed for a trip back and this keyboard is on screen in an app: ask for the
    /// start at once, the same nonce-checked start as a warm tap. One ask per arming, whichever keyboard shows first.
    func startIfHandedOff() {
        guard visible, hasFullAccess, mode == .idle || mode == .opening || mode == .openFailed else { return }
        guard let h = SharedSession.handoff,
              ColdStart.keyboardShouldStart(handoff: h, claimed: SharedSession.handoffClaimed, truth: SharedSession.micState) else { return }
        SharedSession.handoffClaimed = h.armedAt
        lastResult = SharedSession.resultID
        Self.awaitedResult = lastResult
        KeyboardCommand.write(.start)
        DarwinBus.shared.post(.start)
        startingAt = Date()
        afterTrip = true
        mode = .starting
        Self.log.notice("FFHANDOFF keyboard asked (armed \(String(format: "%.1f", Date().timeIntervalSince(h.armedAt)), privacy: .public) s ago)")
    }

    /// The result ID current when this keyboard asked for a dictation, kept in the App Group so the text still lands
    /// after the keyboard is hidden and shown again (iOS may start a fresh keyboard process). Build 8 dropped it 600 s
    /// after the tap, so a dictation over 10 minutes was never typed; KeyboardAwait keeps it while Free Flow records or
    /// writes, and for 10 minutes after the text is ready.
    private static var awaitedResult: String? {
        get {
            let at = FF.defaults.object(forKey: "keyboard.awaitAt") as? Date
            guard KeyboardAwait.isLive(awaitAt: at, now: Date(), phase: SharedSession.phase, resultAt: SharedSession.resultAt) else { return nil }
            return FF.defaults.string(forKey: "keyboard.awaitResult")
        }
        set {
            FF.defaults.set(newValue, forKey: "keyboard.awaitResult")
            FF.defaults.set(newValue == nil ? nil : Date(), forKey: "keyboard.awaitAt")
        }
    }

    // MARK: pages, shift, the field (build 18)

    /// What the field asks for. A new kind of field opens on its own page (number fields on the pad).
    func readField(keyboardType: Int, returnType: Int, autocap: Int, textChanged: Bool) {
        let f = KeyField(keyboardType: keyboardType)
        let newField = f != field
        if newField { field = f; page = f.firstPage; capsLock = false; shift = false }
        if returnRaw != returnType { returnRaw = returnType }
        let newCaps = autocapRaw != autocap
        autocapRaw = autocap
        if newField || newCaps || textChanged { autoShift() }
    }

    /// Capitals at the start of a sentence (or each word, or all), as the field asks: shift turns on by itself.
    func autoShift() {
        guard page == .letters, !capsLock else { return }
        let want = AutoCapital.wantsShift(before: contextBefore?() ?? "", mode: autocapRaw)
        if shift != want { shift = want }
    }

    /// Shift: one tap for one capital, two quick taps for caps lock, one more tap to end it.
    func tapShift() {
        let now = Date()
        if !capsLock, let t = lastShiftTap, now.timeIntervalSince(t) < 0.35 {
            capsLock = true; shift = true; lastShiftTap = nil
            return
        }
        lastShiftTap = now
        if capsLock { capsLock = false; shift = false } else { shift.toggle() }
    }

    func setPage(_ p: KeyPage) {
        page = p
        if p == .letters { autoShift() }
    }

    /// A letter, symbol or long-press variant: types it, drops a one-letter shift, then capitals as the field asks.
    func typeLetter(_ text: String) {
        typeKey(text)
        if shift && !capsLock { shift = false }
        autoShift()
    }

    func typeReturn() {
        typeKey("\n")
        autoShift()
    }

    // MARK: typing keys (ComfortKeyboard)

    /// A key that types text: letters, symbols, return. The word is looked up off the main thread as it is typed.
    func typeKey(_ text: String) {
        lastSpaceAt = nil
        // Build 17: return and . , ! ? ; : end a word like space does, so the word before them is corrected too.
        if text != " ", AutocorrectTyper.endsWord(text) {
            let edit = autocorrect.wordBreak(text, contextBefore: contextBefore?() ?? "")
            for _ in 0..<edit.deleteCount { deleteBackward?() }
            let body = String(edit.insert.dropLast(text.count))
            if !body.isEmpty { type?(body) }
            type?(text)   // return is always its own insert
            if text != "\n" { autocorrect.didType(contextBefore: contextBefore?() ?? "") }
            return
        }
        type?(text)
        autocorrect.didType(contextBefore: contextBefore?() ?? "")
    }

    /// Space: corrects the word before the cursor first when autocorrect says so (FFAC log line: time per press).
    func typeSpace() {
        // Apple's "." shortcut: a second space soon after a word types ". " (DoubleSpace).
        if let t = lastSpaceAt, Date().timeIntervalSince(t) < DoubleSpace.window, DoubleSpace.makesPeriod(before: contextBefore?() ?? "") {
            lastSpaceAt = nil
            autocorrect.reset()
            deleteBackward?()
            type?(". ")
            autoShift()
            return
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        apply(autocorrect.space(contextBefore: contextBefore?() ?? ""))
        autocorrect.logSpace(totalMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        lastSpaceAt = Date()
        autoShift()
    }

    /// One delete (touch down or VoiceOver). Right after a correction it puts the typed word back instead.
    func deleteKey() {
        lastSpaceAt = nil
        if let edit = autocorrect.delete(contextBefore: contextBefore?() ?? "") { apply(edit) } else { deleteBackward?() }
        autoShift()
    }

    /// A held delete repeating: plain deletes.
    func deleteRepeat() {
        autocorrect.reset()
        deleteBackward?()
        autoShift()
    }

    private func apply(_ edit: AutocorrectTyper.Edit) {
        for _ in 0..<edit.deleteCount { deleteBackward?() }
        if !edit.insert.isEmpty { type?(edit.insert) }
    }

    func cycleStyle() { style = style.next; SharedSession.style = style }

    func tapMic() {
        switch mode {
        case .listening: finish(); return
        case .writing, .opening, .starting: return
        case .openFailed: openFreeFlow(); return
        default: break
        }
        lastResult = SharedSession.resultID
        Self.awaitedResult = lastResult
        SharedSession.tapAt = Date()
        afterTrip = false
        if SharedSession.micState != .off {
            KeyboardCommand.write(.start)      // security: the app acts only on this keyboard's fresh nonce
            DarwinBus.shared.post(.start)
            mode = .listening
            return
        }
        // No warm session: open the app once. It starts listening right away and keeps the session warm.
        openFreeFlow()
    }

    /// Asks iOS to bring Free Flow to the front. When iOS refuses, or the keyboard is still on screen a few seconds
    /// later with Free Flow not listening, the keyboard says so and offers the next step: never a silent wait.
    func openFreeFlow() {
        KeyboardCommand.write(.start)          // security: the app starts only for a start this keyboard wrote
        SharedSession.pendingStart = Date()
        openedAt = Date()
        mode = .opening
        let asked = openApp?({ [weak self] opened in
            guard let self, !opened, self.mode == .opening else { return }
            self.mode = .openFailed
        }) ?? false
        if !asked {
            mode = hasFullAccess ? .openFailed : .message("Turn on Allow Full Access for Free Flow in Settings, then try again.")
        }
    }

    func finish() {
        guard mode == .listening else { return }
        KeyboardCommand.write(.finish)
        DarwinBus.shared.post(.finish)
        mode = .writing
    }

    func cancel() {
        if mode == .listening || mode == .starting { KeyboardCommand.write(.cancel); DarwinBus.shared.post(.cancel) }
        Self.awaitedResult = nil
        stalled = false
        mode = .idle
    }

    /// Types a finished dictation this keyboard still owes (KeyboardInsertRule). A hidden keyboard keeps it until it is
    /// shown again (textDocumentProxy only types while visible). Once typed, the words leave the App Group at once.
    /// Build 23 (security): the dictation running (or last finished) is the one this keyboard asked for, or a
    /// Start/Stop Free Flow press (KeyboardCommand.triggerSession); never one any other app could have started.
    private var ownsDictation: Bool {
        let mine = SharedSession.keyboardSession, running = SharedSession.dictationSession
        return (!mine.isEmpty && running == mine) || running == KeyboardCommand.triggerSession
    }

    private func typeOwed() {
        guard ownsDictation else { return }   // never type text this keyboard did not ask for
        let id = SharedSession.resultID
        guard KeyboardInsertRule.owed(phase: SharedSession.phase, resultID: id, lastResult: lastResult,
                                      insertedID: SharedSession.insertedID, visible: visible,
                                      waiting: mode == .writing || mode == .listening,
                                      awaitLive: Self.awaitedResult != nil) else { return }
        guard Self.onScreen === self else {
            Self.log.notice("FFINSERT left for the keyboard on screen id=\(id.prefix(8), privacy: .public)")
            return
        }
        if writingID == id { return }   // Apple's model is writing it now
        if let style = KeyboardWriting.style(ofResultID: id) {
            let p = KeyboardWriting.pending.flatMap { $0.id == id ? $0 : nil } ?? KeyboardWriting.Pending(id: id, style: style, history: "")
            writeThenType(id: id, pending: p); return
        }
        typeNow(id: id, text: SharedSession.resultText)
    }

    private func typeNow(id: String, text: String) {
        lastResult = id
        Self.awaitedResult = nil
        autocorrect.reset()
        insert?(text)
        Self.log.notice("FFINSERT typed id=\(id.prefix(8), privacy: .public) chars=\(text.count, privacy: .public)")
        SharedSession.insertedID = id
        SharedSession.resultText = ""
        stalled = false
        mode = .idle
    }

    /// Build 28: the app finished this dictation in the background and handed it over (KeyboardWriting). Apple's
    /// model writes it here, while the keyboard is on screen, then the keyboard types it. Unavailable, an error or the
    /// time limit: the heard text (per piece, AppleRewrite).
    private func writeThenType(id: String, pending p: KeyboardWriting.Pending) {
        let heard = SharedSession.resultText
        let words = WritingReadout.words(heard)
        var unavailableReason: String? = heard.isEmpty ? "empty text" : nil
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), !heard.isEmpty {
            let check = AppleRewrite.check
            if check.available {
                writingID = id
                mode = .writing
                stage = "Writing · Apple Intelligence"
                let limit = KeyboardWriting.seconds(words: words)
                let mem0 = DeviceProfile.footprintBytes()
                Self.log.notice("FFWRITE kbd start id=\(id.prefix(8), privacy: .public) words=\(words, privacy: .public) limit=\(limit, privacy: .public)s mem=\(mem0 / 1_000_000, privacy: .public)MB")
                WriteDiagnostics.note("kbd", "start", ["id": String(id.prefix(8)), "words": words, "limit": limit, "memMB": Int(mem0 / 1_000_000)])
                let os = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
                writeTask = Task { @MainActor [weak self] in
                    let o = await AppleRewrite.write(heard, style: p.style, deadline: Date().addingTimeInterval(limit), os: os, tag: "kbd")
                    let mem1 = DeviceProfile.footprintBytes()
                    guard let self, self.writingID == id else {
                        Self.log.notice("FFWRITE kbd dropped id=\(id.prefix(8), privacy: .public): keyboard hidden while writing")
                        return
                    }
                    self.writingID = nil; self.writeTask = nil
                    let readout = WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models in the keyboard",
                                                 background: false, wordsIn: words, wordsOut: WritingReadout.words(o.text),
                                                 seconds: o.seconds, keptRaw: o.kept,
                                                 note: o.reasons.isEmpty ? nil : o.reasons.joined(separator: ", "), used: o.used)
                    Self.log.notice("FFWRITE kbd done id=\(id.prefix(8), privacy: .public) used=\(o.used, privacy: .public) kept=\(o.kept, privacy: .public) requests=\(o.requests, privacy: .public) rate-limited=\(o.rateLimited, privacy: .public) ms=\(Int(o.seconds * 1000), privacy: .public) mem=\(mem1 / 1_000_000, privacy: .public)MB")
                    WriteDiagnostics.note("kbd", "done", ["id": String(id.prefix(8)), "memMB": Int(mem1 / 1_000_000),
                                                          "typed": SharedSession.resultID == id && Self.onScreen === self && self.visible])
                    KeyboardWriting.pending = nil
                    KeyboardWriting.done = KeyboardWriting.Done(id: id, text: o.text, history: p.history, used: o.used, kept: o.kept,
                                                                seconds: o.seconds, wordsIn: words, wordsOut: readout.wordsOut,
                                                                reason: readout.note)
                    DarwinBus.shared.post(.keyboardWrote)
                    guard SharedSession.resultID == id, SharedSession.insertedID != id, Self.onScreen === self, self.visible else {
                        // Another keyboard is on screen now: it types the written text (KeyboardInsertRule).
                        if SharedSession.resultID == id, SharedSession.insertedID != id { SharedSession.resultText = o.text }
                        Self.log.notice("FFWRITE kbd left for the keyboard on screen id=\(id.prefix(8), privacy: .public)")
                        return
                    }
                    self.typeNow(id: id, text: o.text)
                }
                return
            }
            unavailableReason = check.reason ?? String(describing: AppleRewrite.model.availability)
            Self.log.notice("FFWRITE kbd unavailable id=\(id.prefix(8), privacy: .public): \(check.reason ?? "-", privacy: .public)")
            WriteDiagnostics.note("kbd", "unavailable", ["reason": check.reason ?? "-"])
        }
        #endif
        if unavailableReason == nil { unavailableReason = "needs iOS 26" }
        KeyboardWriting.pending = nil
        let why = "Apple Intelligence not available in the keyboard" + (unavailableReason.map { " (" + $0 + ")" } ?? "")
        KeyboardWriting.done = KeyboardWriting.Done(id: id, text: heard, history: p.history, used: 0, kept: 1, seconds: 0,
                                                    wordsIn: words, wordsOut: words, reason: why)
        DarwinBus.shared.post(.keyboardWrote)
        WriteDiagnostics.note("kbd", "as-heard", ["reason": why])
        typeNow(id: id, text: heard)
    }

    func poll() {
        if visible, Date().timeIntervalSince(lastUpWrite) > 0.5 {
            SharedSession.keyboardUpAt = Date()
            lastUpWrite = Date()
        }
        // Assign only what changed: every @Published assignment redraws the keyboard, equal or not.
        let truth = SharedSession.micState
        if sessionLive != (truth != .off) { sessionLive = truth != .off }
        let label = SessionTruth.label(truth, endsAt: SharedSession.endsAt, offReason: SharedSession.offReason)
        if status != label { status = label }
        let input = SharedSession.inputName
        if inputName != input { inputName = input }
        let st = writingID != nil ? "Writing · Apple Intelligence" : (SharedSession.stage.isEmpty ? "Transcribing" : SharedSession.stage)
        if stage != st { stage = st }
        // The app can end its session in the same second the text is ready (KeyboardInsertRule): type owed text before
        // reading the mic state, so a finished dictation is never dropped or shown as "stopped listening".
        if truth == .off { typeOwed() }
        // Never show a live mic that isn't: if the app turned the mic off, say so. A quiet app whose last phase is still
        // live is a stall, not a stop (KeyboardLiveRule): say so, and go back to the live view when it beats again.
        let shown: KeyboardLiveRule.Live? = mode == .listening ? .listening : (mode == .writing ? .writing : nil)
        switch KeyboardLiveRule.step(shown: shown, stalled: stalled, truth: truth, phase: SharedSession.phase, offReason: SharedSession.offReason) {
        case .keep: break
        case .stalled: stalled = true; mode = .message(KeyboardLiveRule.stalledText)
        case .stopped(let text): stalled = false; mode = .message(text)
        case .resume(let live): stalled = false; mode = live == .listening ? .listening : .writing
        case .idle: stalled = false; mode = .idle
        }
        if truth == .off {
            if mode == .opening, let t = openedAt, Date().timeIntervalSince(t) > 20 { mode = .idle }
            if mode == .starting { mode = .message(SharedSession.offReason.isEmpty ? ColdStart.Words.didNotStart : SharedSession.offReason) }
            return
        }
        // Build 26: the keyboard can be on screen before Free Flow has finished arming (or appear was missed).
        if mode == .idle || mode == .opening || mode == .openFailed { startIfHandedOff() }
        switch SharedSession.phase {
        case .listening:
            let late = mode == .message(ColdStart.Words.didNotStart)   // it did start after all: show it, never hide a live mic
            if (mode == .idle || mode == .opening || mode == .openFailed || mode == .starting || late) && ownsDictation {
                if mode == .starting, let t = startingAt {
                    Self.log.notice("FFHANDOFF keyboard saw listening \(String(format: "%.0f", Date().timeIntervalSince(t) * 1000), privacy: .public) ms after asking")
                }
                mode = .listening
            }
            if mode == .listening {
                let now = Array(SharedSession.levels.suffix(32))
                if now != levels { levels = now }
            }
        case .transcribing:
            if mode == .listening { mode = .writing }
        case .done:
            typeOwed()
        case .error:
            if mode == .listening || mode == .writing || mode == .opening {
                Self.awaitedResult = nil
                let e = SharedSession.error
                mode = .message(e.isEmpty ? "Something went wrong. Try again." : e)
            }
        case .ready, .off:
            if mode == .listening, !sessionLive { mode = .idle }
        }
        // This poll only runs while the keyboard is on screen. Still here 4 s after asking iOS to open Free Flow, and
        // Free Flow is not listening: it did not come up.
        if mode == .opening, let t = openedAt, Date().timeIntervalSince(t) > 4 { mode = .openFailed }
        if mode == .starting, let t = startingAt, Date().timeIntervalSince(t) > ColdStart.keyboardGiveUp {
            mode = .message(ColdStart.Words.didNotStart)
        }
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let showsGlobe: Bool

    var body: some View {
        content.dynamicTypeSize(...DynamicTypeSize.large)   // like Apple's keyboard: keys keep their size at large text sizes
    }

    @ViewBuilder private var content: some View {
        if model.mode == .listening || model.mode == .writing || model.mode == .starting {
            ListeningKeyboard(model: model, showsGlobe: showsGlobe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.primary)
        } else if model.mode == .idle {
            ComfortKeyboard(model: model, showsGlobe: showsGlobe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.primary)
        } else {
            classic
        }
    }

    /// The opening and message states, every layout (the keys themselves are ComfortKeyboard's).
    private var classic: some View {
        GeometryReader { geo in classicStack(width: geo.size.width) }
    }

    private func classicStack(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            switch model.mode {
            case .listening, .writing, .starting:
                EmptyView()   // ListeningKeyboard shows these, in both layouts
            case .opening:
                topBar(width: width)
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Text(ColdStart.Words.opening).font(FFFont.text(17, .bold))
                    Text(ColdStart.Words.openingHow).font(FFFont.text(14)).foregroundStyle(Palette.muted)
                }
                .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            case .openFailed:
                topBar(width: width)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Text("Free Flow didn't open").font(FFFont.text(17, .bold)).accessibilityIdentifier("kb.openFailed")
                    Text("Open Free Flow from the Home Screen and tap its mic once, then come back here and tap the mic again.")
                        .font(FFFont.text(14)).foregroundStyle(Palette.muted)
                    HStack(spacing: 18) {
                        Button("Try again") { model.openFreeFlow() }.font(FFFont.text(16, .bold)).tint(Palette.accentText)
                            .accessibilityIdentifier("kb.openAgain")
                        Button("OK") { model.mode = .idle }.font(FFFont.text(16, .bold)).tint(Palette.accentText)
                    }
                }
                .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            case .message(let text):
                topBar(width: width)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Text(text).font(FFFont.text(16, .semibold)).multilineTextAlignment(.center)
                    Button("OK") { model.mode = .idle }.font(FFFont.text(16, .bold)).tint(Palette.accentText)
                }
                Spacer(minLength: 0)
            case .idle:
                EmptyView()   // ComfortKeyboard shows the keys, in every layout
            }
        }
        .padding(.horizontal, KeyboardTopBar.stackPadding).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.primary)
    }

    /// One line, built from FreeFlowKit KeyboardTopBar's numbers (its tests check the style pill's text fits at every
    /// width): every item keeps its size except the style pill, which gets the rest; the spacers can shrink to nothing.
    /// Build 12: no cleanup chip (no rule-based cleanup).
    private func topBar(width: CGFloat) -> some View {
        typealias M = KeyboardTopBar
        return HStack(spacing: M.spacing) {
            if model.styleKey {
                Button(model.style.pill) { model.cycleStyle() }
                    .font(FFFont.fixed(M.styleSize, .bold)).lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, M.stylePadding).padding(.vertical, 7).layoutPriority(1)
                    .background(Capsule(style: .continuous).fill(KeyColors.modifier))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("kb.style")
            }
            Spacer(minLength: 0)
            MicButton(size: M.mic, id: "kb.mic") { model.tapMic() }.buttonStyle(ClickStyle(kind: .mic, feel: model.feel))
            Spacer(minLength: 0)
            // The dot alone (filled green = ready, hollow = not ready). VoiceOver still reads the status.
            StatusDot(ready: model.sessionLive, ring: Palette.muted, size: 10)
                .frame(width: M.dot, height: M.dot)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.sessionLive ? "Ready" : "Not ready").accessibilityValue(model.status)
                .accessibilityIdentifier("kb.status")
            HideKey(model: model, width: model.styleKey ? M.hide : 84, height: 40)
        }
        .padding(.horizontal, M.barPadding)
    }
}

/// Hides the keyboard (UIInputViewController.dismissKeyboard), in both layouts and while listening.
struct HideKey: View {
    @ObservedObject var model: KeyboardModel
    var width: CGFloat = 54
    var height: CGFloat = 44

    var body: some View {
        Button { model.dismiss?() } label: {
            Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 20, weight: .medium))
                .frame(width: width, height: height)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KeyColors.modifier))
                .contentShape(Rectangle())
        }
        .buttonStyle(ClickStyle(kind: .modifier, feel: model.feel))
        .foregroundStyle(.primary)
        .accessibilityIdentifier("kb.hide").accessibilityLabel("Hide keyboard")
    }
}
