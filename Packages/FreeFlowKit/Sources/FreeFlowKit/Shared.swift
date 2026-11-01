import Foundation

/// Identifiers shared by the app, the keyboard and the widgets.
public enum FF {
    /// From each target's Info.plist (FFAppGroup = $(FF_APP_GROUP), set in Configuration/Local.xcconfig).
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "FFAppGroup") as? String ?? "group.freeflow.local"
    /// Free Flow's own link name, from each target's Info.plist (FFURLScheme = $(FF_BUNDLE_PREFIX).freeflow, so the
    /// bundle prefix plus ".freeflow"). A plain "freeflow" can be claimed by any other app: on the iPad simulator a
    /// second Free Flow install with another prefix answered the keyboard's freeflow://dictate and opened on its
    /// setup page. Build 23: "freeflow" is no longer registered or accepted.
    /// The log subsystem and queue-label prefix: the bundle identifier up to and including ".freeflow" (the keyboard
    /// and the widgets log under the app's name), or "freeflow" when there is no bundle identifier.
    public static let subsystem: String = {
        let id = Bundle.main.bundleIdentifier ?? "freeflow"
        if let r = id.range(of: ".freeflow") { return String(id[..<r.upperBound]) }
        return id
    }()
    public static let urlScheme = Bundle.main.object(forInfoDictionaryKey: "FFURLScheme") as? String ?? "freeflow"
    public static var dictateURL: URL { URL(string: urlScheme + "://dictate") ?? URL(string: "freeflow://dictate")! }
    public static func isOurs(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == urlScheme.lowercased()
    }

    /// The Mac app (Mac Catalyst, build 20) has no keyboard extension to share with, and a group container outside
    /// the sandbox makes macOS ask for access to other apps' data: it keeps its own defaults and folder.
    public static var defaults: UserDefaults {
        #if targetEnvironment(macCatalyst)
        return .standard
        #else
        return UserDefaults(suiteName: appGroup) ?? .standard
        #endif
    }

    /// The App Group folder on this device (falls back to Application Support). On the Mac:
    /// ~/Library/Application Support/Free Flow, the folder the Mac app used before build 20.
    public static var containerURL: URL {
        #if targetEnvironment(macCatalyst)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Free Flow", isDirectory: true)
        #else
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum SessionPhase: String, Codable, Sendable {
    case off, ready, listening, transcribing, done, error
}

/// Cross-process signals between the keyboard and the app (no payload; state lives in the App Group).
public enum DarwinName: String, CaseIterable, Sendable {
    case start, finish, cancel, state
    /// The keyboard opened and proved Allow Full Access (build 19), or opened without it. A keyboard without Full Access
    /// can't write to the App Group, but a Darwin notification (no data) still reaches the app, so setup can show
    /// "added, Full Access off" instead of an old answer.
    case keyboardSeen, keyboardNoAccess
    /// Build 28: the keyboard finished (or gave up) writing a handed-over dictation (KeyboardWriting.done).
    case keyboardWrote
    var notificationName: String { FF.appGroup + "." + rawValue }
}

public final class DarwinBus: @unchecked Sendable {
    public static let shared = DarwinBus()
    private var handlers: [String: [() -> Void]] = [:]
    private let lock = NSLock()

    public func post(_ name: DarwinName) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name.notificationName as CFString), nil, nil, true)
    }

    /// Handlers run on the main queue.
    public func observe(_ name: DarwinName, _ handler: @escaping () -> Void) {
        lock.lock()
        let first = handlers[name.notificationName] == nil
        handlers[name.notificationName, default: []].append(handler)
        lock.unlock()
        guard first else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, name, _, _ in
            guard let observer, let name else { return }
            Unmanaged<DarwinBus>.fromOpaque(observer).takeUnretainedValue().fire(name.rawValue as String)
        }, name.notificationName as CFString, nil, .deliverImmediately)
    }

    private func fire(_ name: String) {
        lock.lock(); let list = handlers[name] ?? []; lock.unlock()
        DispatchQueue.main.async { list.forEach { $0() } }
    }
}

/// Build 23 (security): a keyboard command (start, finish, cancel) is real only with a fresh, unused one-time nonce
/// the keyboard wrote to the App Group just before it posted the Darwin notification. Darwin notifications carry no
/// sender and any app can post one; only Free Flow's own processes can write the App Group. `session` is the nonce of
/// the start the keyboard sent, so a finish or cancel acts only on the dictation that keyboard started.
public struct KeyboardCommand: Codable, Equatable, Sendable {
    public let name: String
    public let nonce: String
    public let session: String
    public let at: Date

    public init(name: String, nonce: String, session: String, at: Date) {
        self.name = name; self.nonce = nonce; self.session = session; self.at = at
    }

    /// The session of a Start/Stop Free Flow press (Action Button, control, Siri, Back Tap): system entry points no
    /// other app can reach, so the keyboard on screen follows that dictation and types it, as before.
    public static let triggerSession = "trigger"

    /// How long a command stays usable after the keyboard wrote it.
    public static let freshFor: TimeInterval = 2
    /// How long a start written just before the keyboard opens Free Flow stays usable (a cold launch takes seconds).
    public static let openFreshFor: TimeInterval = 15

    /// True when `command` is the keyboard's real `name` request: written within `fresh` seconds, not used before, a
    /// start that opens its own session, or a finish or cancel for the dictation `currentSession` the keyboard started.
    /// Security (Mac, build 32): the Mac has no keyboard extension, and its shared store is the app's own preferences,
    /// which any process running as the user can write. So on the Mac no keyboard command is real.
    public static var platformHasKeyboard: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return true
        #endif
    }

    public static func accepts(_ command: KeyboardCommand?, name: DarwinName, lastNonce: String?, currentSession: String?,
                               fresh: TimeInterval = freshFor, now: Date = Date(),
                               keyboard: Bool = platformHasKeyboard) -> Bool {
        guard keyboard, let c = command, c.name == name.rawValue, !c.nonce.isEmpty, c.nonce != lastNonce else { return false }
        let age = now.timeIntervalSince(c.at)
        guard age >= -1, age <= fresh else { return false }
        switch name {
        case .start: return c.session == c.nonce
        case .finish, .cancel: return currentSession.map { !$0.isEmpty && $0 == c.session } ?? false
        default: return false
        }
    }

    /// The keyboard: writes a new command to the App Group (a start opens a new session) before posting `name`.
    @discardableResult
    public static func write(_ name: DarwinName, now: Date = Date()) -> KeyboardCommand {
        let nonce = UUID().uuidString
        if name == .start { SharedSession.keyboardSession = nonce }
        let command = KeyboardCommand(name: name.rawValue, nonce: nonce,
                                      session: name == .start ? nonce : SharedSession.keyboardSession, at: now)
        SharedSession.keyboardCommand = command
        return command
    }
}

/// Session state the app publishes for the keyboard. Stored in the App Group on this device only.
public enum SharedSession {
    private enum Key {
        static let heartbeat = "session.heartbeat", endsAt = "session.endsAt", phase = "session.phase"
        static let levels = "session.levels", resultText = "result.text", resultID = "result.id"
        static let style = "style.current", error = "session.error", input = "session.input"
        static let pendingStart = "keyboard.pendingStart", gestures = "keyboard.gestures"
        static let stage = "session.stage"
    }
    private static var d: UserDefaults { FF.defaults }

    public static var heartbeat: Date? {
        get { d.object(forKey: Key.heartbeat) as? Date }
        set { d.set(newValue, forKey: Key.heartbeat) }
    }
    /// A session counts as live while the app's heartbeat is fresh (it beats every second).
    public static var isLive: Bool { heartbeat.map { Date().timeIntervalSince($0) < 3.5 } ?? false }
    public static var endsAt: Date? {
        get { d.object(forKey: Key.endsAt) as? Date }
        set { d.set(newValue, forKey: Key.endsAt) }
    }
    public static var phase: SessionPhase {
        get { SessionPhase(rawValue: d.string(forKey: Key.phase) ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: Key.phase) }
    }
    public static var levels: [Float] {
        get { (d.array(forKey: Key.levels) as? [NSNumber])?.map(\.floatValue) ?? [] }
        set { d.set(newValue.map { NSNumber(value: $0) }, forKey: Key.levels) }
    }
    /// Security (Mac, build 32): only the iOS keyboard reads the text. The Mac has no keyboard, and its store is the
    /// app's plain preferences file, so there the text is never written and any old copy is removed.
    public static var resultText: String {
        get { d.string(forKey: Key.resultText) ?? "" }
        set {
            if let kept = storedResultText(newValue, keyboard: KeyboardCommand.platformHasKeyboard) {
                d.set(kept, forKey: Key.resultText)
            } else {
                d.removeObject(forKey: Key.resultText)
            }
        }
    }
    /// What goes into the store for a result: the text where a keyboard reads it, nothing where none can.
    public static func storedResultText(_ text: String, keyboard: Bool) -> String? { keyboard ? text : nil }
    public static var resultID: String {
        get { d.string(forKey: Key.resultID) ?? "" }
        set { d.set(newValue, forKey: Key.resultID) }
    }
    public static var style: DictationStyle {
        get { DictationStyle(rawValue: d.string(forKey: Key.style) ?? "") ?? .formal }
        set { d.set(newValue.rawValue, forKey: Key.style) }
    }
    public static var error: String {
        get { d.string(forKey: Key.error) ?? "" }
        set { d.set(newValue, forKey: Key.error) }
    }
    /// Name of the microphone in use, e.g. "iPhone Microphone".
    public static var inputName: String {
        get { d.string(forKey: Key.input) ?? "Microphone" }
        set { d.set(newValue, forKey: Key.input) }
    }
    /// What the app is doing after Finish, for the keyboard and the app (build 18): "Preparing speech model",
    /// "Transcribing" or "Writing · Apple Intelligence". Empty when idle. Never holds words of the text.
    public static var stage: String {
        get { d.string(forKey: Key.stage) ?? "" }
        set { d.set(newValue, forKey: Key.stage) }
    }
    /// Set by the keyboard just before it opens the app, so the app starts listening at once.
    public static var pendingStart: Date? {
        get { d.object(forKey: Key.pendingStart) as? Date }
        set { d.set(newValue, forKey: Key.pendingStart) }
    }
    /// Build 26 (ColdStart): Free Flow armed for a keyboard's trip back, written by the app; nil when not waiting.
    public static var handoff: Handoff? {
        get { d.data(forKey: "session.handoff").flatMap { try? JSONDecoder().decode(Handoff.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "session.handoff") }
    }
    /// The arming (Handoff.armedAt) a keyboard already asked to start, so one trip starts one dictation.
    public static var handoffClaimed: Date? {
        get { d.object(forKey: "session.handoffClaimed") as? Date }
        set { d.set(newValue, forKey: "session.handoffClaimed") }
    }
    /// Build 23 (security): the keyboard's last command (KeyboardCommand), written by the keyboard.
    public static var keyboardCommand: KeyboardCommand? {
        get { d.data(forKey: "keyboard.command").flatMap { try? JSONDecoder().decode(KeyboardCommand.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "keyboard.command") }
    }
    /// The keyboard's session: the nonce of the last start it sent. Written by the keyboard.
    public static var keyboardSession: String {
        get { d.string(forKey: "keyboard.session") ?? "" }
        set { d.set(newValue, forKey: "keyboard.session") }
    }
    /// The session of the dictation the app runs (or last ran) for a keyboard; "" when anything else started it.
    /// Written by the app. The keyboard shows Listening and types the text only when this is its own session.
    public static var dictationSession: String {
        get { d.string(forKey: "session.dictation") ?? "" }
        set { d.set(newValue, forKey: "session.dictation") }
    }
    /// Written by the keyboard each time it appears. A keyboard without Allow Full Access cannot write to the
    /// App Group, so a fresh value here proves the keyboard is added AND has Full Access on this device.
    public static var keyboardSeen: Date? {
        get { d.object(forKey: "keyboard.seen") as? Date }
        set { d.set(newValue, forKey: "keyboard.seen") }
    }
    public static var keyboardFullAccess: Bool {
        get { d.bool(forKey: "keyboard.fullAccess") }
        set { d.set(newValue, forKey: "keyboard.fullAccess") }
    }
    /// Written by the keyboard when it appears (needs Full Access): whether it draws its own globe key on this device
    /// (iOS's needsInputModeSwitchKey). The layout previews draw the same keys. Nil until the keyboard has written it.
    public static var keyboardGlobe: Bool? {
        get { d.object(forKey: "keyboard.globe") as? Bool }
        set { d.set(newValue, forKey: "keyboard.globe") }
    }
    /// Set when the Dictate or Start session shortcut runs (Action Button, Back Tap, Control Center, Siri).
    public static var lastTrigger: Date? {
        get { d.object(forKey: "trigger.last") as? Date }
        set { d.set(newValue, forKey: "trigger.last") }
    }
    /// Written by the keyboard about twice a second while it is on screen, cleared when it goes away. Start/Stop
    /// Free Flow uses it to decide whether to wait for the keyboard to type the text or to copy it.
    /// When the current result (resultID) was ready: a keyboard waiting on a long dictation types it within 10 minutes
    /// of this, however long the dictation was (KeyboardAwait).
    public static var resultAt: Date? {
        get { d.object(forKey: "session.resultAt") as? Date }
        set { d.set(newValue, forKey: "session.resultAt") }
    }
    public static var keyboardUpAt: Date? {
        get { d.object(forKey: "keyboard.upAt") as? Date }
        set { d.set(newValue, forKey: "keyboard.upAt") }
    }
    /// The result id the keyboard last typed at the cursor.
    public static var insertedID: String {
        get { d.string(forKey: "keyboard.insertedID") ?? "" }
        set { d.set(newValue, forKey: "keyboard.insertedID") }
    }
    /// The one reading every surface uses: off, armed, recording or processing (see SessionTruth).
    public static var micState: MicState { SessionTruth.state(phase: phase, heartbeat: heartbeat) }
    /// Why the app last turned the mic off by itself (interruption, route change). Empty after a normal start.
    public static var offReason: String {
        get { d.string(forKey: "session.offReason") ?? "" }
        set { d.set(newValue, forKey: "session.offReason") }
    }
    /// Build 23 (the keyboard reopened the app and nobody could say why): why the last mic session ended,
    /// in plain words, and when. The app writes it at every end it sees, when it was paused with the mic on, and at the
    /// next launch when it was closed with the mic on. Settings > Session shows it; no popup.
    public static var lastEnd: String {
        get { d.string(forKey: "session.lastEnd") ?? "" }
        set { d.set(newValue, forKey: "session.lastEnd") }
    }
    public static var lastEndAt: Date? {
        get { d.object(forKey: "session.lastEndAt") as? Date }
        set { d.set(newValue, forKey: "session.lastEndAt") }
    }
    public static func noteEnd(_ why: String, at: Date = Date()) { lastEnd = why; lastEndAt = at }
    /// When the keyboard's mic was tapped, for the tap-to-capture measurement.
    public static var tapAt: Date? {
        get { d.object(forKey: "keyboard.tapAt") as? Date }
        set { d.set(newValue, forKey: "keyboard.tapAt") }
    }
    /// Milliseconds from the last tap or press to capture starting.
    public static var lastLatencyMs: Double {
        get { d.double(forKey: "latency.lastMs") }
        set { d.set(newValue, forKey: "latency.lastMs") }
    }
    /// Two-finger swipe on the keyboard: up starts, down finishes.
    public static var keyboardGestures: Bool {
        get { d.object(forKey: Key.gestures) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.gestures) }
    }
    /// Autocorrect on space in the Free Flow keyboard (Settings > Keyboard). On unless turned off.
    public static var keyboardAutocorrect: Bool {
        get { d.object(forKey: "keyboard.autocorrect") as? Bool ?? true }
        set { d.set(newValue, forKey: "keyboard.autocorrect") }
    }
    /// Haptic click on each key press: off, light, medium or strong (needs Allow Full Access).
    public static var keyHaptics: KeyTick.Level {
        get { KeyTick.Level(rawValue: d.object(forKey: "keyboard.haptics") as? Int ?? 2) ?? .medium }
        set { d.set(newValue.rawValue, forKey: "keyboard.haptics") }
    }
    /// Shaped clicks through Core Haptics (on) or the system's simple impact click (off). Apple does not document
    /// Core Haptics inside keyboards, so this lets the person switch if shaped clicks are silent on their device.
    public static var keyShapedClicks: Bool {
        get { d.object(forKey: "keyboard.shapedClicks") as? Bool ?? true }
        set { d.set(newValue, forKey: "keyboard.shapedClicks") }
    }
    /// Scale each tick with the finger's contact size (see KeyTick). Does nothing when the device reports one size.
    public static var keyFollowSize: Bool {
        get { d.object(forKey: "keyboard.followSize") as? Bool ?? true }
        set { d.set(newValue, forKey: "keyboard.followSize") }
    }
    /// The last contact sizes the keyboard saw, kept so scaling does not restart each time the keyboard loads.
    public static var keyContactSizes: [Double] {
        get { (d.array(forKey: "keyboard.contactSizes") as? [NSNumber])?.map(\.doubleValue) ?? [] }
        set { d.set(newValue.map { NSNumber(value: $0) }, forKey: "keyboard.contactSizes") }
    }
    /// What the keyboard measured the last time it was used, for Settings > Keyboard.
    public static var keyFeelReport: [String: Double] {
        get { (d.dictionary(forKey: "keyboard.feelReport") as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:] }
        set { d.set(newValue.mapValues { NSNumber(value: $0) }, forKey: "keyboard.feelReport") }
    }
}
