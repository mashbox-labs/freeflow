import Foundation

/// Build 28: a keyboard dictation that finishes while Free Flow is in the background is written by Apple's model
/// IN THE KEYBOARD, not in the app. Apple rate-limits Foundation Models requests from a process in the background
/// (LanguageModelSession.GenerationError.rateLimited: "only ... if your app is running in the background"); the
/// keyboard on screen runs inside the foreground app's session. Measured elsewhere on iOS 26.6 (getdictus/dictus-ios
/// #315, #357, #361): the backgrounded app is refused after about 12 calls until its process restarts, while the
/// keyboard ran 20 of 20 calls during that refusal, for about +7-9 MB.
///
/// The app writes the heard text as the result as before (so the worst case stays "typed as heard") and marks it here
/// with the style to write it in. The keyboard on screen writes it, then types it. The keyboard reports what it typed
/// back here, and the app copies that into History when it next runs in the foreground.
public enum KeyboardWriting {
    private enum Key {
        static let enabled = "kbwrite.enabled", pendingID = "kbwrite.pending.id", pendingStyle = "kbwrite.pending.style"
        static let pendingHistory = "kbwrite.pending.history"
        static let doneID = "kbwrite.done.v2"
    }
    private static var d: UserDefaults { FF.defaults }

    /// On unless turned off (the app's -ffAppWrites launch argument turns it off for a side-by-side test).
    public static var enabled: Bool {
        get { d.object(forKey: Key.enabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.enabled) }
    }

    /// Whether the app hands this dictation to the keyboard: started from the keyboard, the app not in the foreground,
    /// writing on and Apple's model available.
    public static func handOver(fromKeyboard: Bool, appActive: Bool, writerOn: Bool, appleAvailable: Bool, enabled: Bool) -> Bool {
        fromKeyboard && !appActive && writerOn && appleAvailable && enabled
    }

    /// The result still to be written by the keyboard: its SharedSession.resultID, the style, and the History item.
    public struct Pending: Equatable, Sendable {
        public var id: String, style: DictationStyle, history: String
        public init(id: String, style: DictationStyle, history: String) { self.id = id; self.style = style; self.history = history }
    }
    public static var pending: Pending? {
        get {
            guard let id = d.string(forKey: Key.pendingID), !id.isEmpty,
                  let style = DictationStyle(rawValue: d.string(forKey: Key.pendingStyle) ?? "") else { return nil }
            return Pending(id: id, style: style, history: d.string(forKey: Key.pendingHistory) ?? "")
        }
        set {
            d.set(newValue?.id ?? "", forKey: Key.pendingID)
            d.set(newValue?.style.rawValue ?? "", forKey: Key.pendingStyle)
            d.set(newValue?.history ?? "", forKey: Key.pendingHistory)
        }
    }

    /// What the keyboard did with a pending result: the text it typed (or holds) and its readout, including why any
    /// part went in as heard. `used` 0 means Apple's model wrote none of it.
    public struct Done: Codable, Equatable, Sendable {
        public var id: String, text: String, history: String
        public var used: Int, kept: Int, seconds: Double, wordsIn: Int, wordsOut: Int
        /// Why Apple's model did not write it (or part of it); nil when it wrote all of it.
        public var reason: String?
        public init(id: String, text: String, history: String, used: Int, kept: Int, seconds: Double, wordsIn: Int, wordsOut: Int,
                    reason: String?) {
            self.id = id; self.text = text; self.history = history; self.used = used; self.kept = kept
            self.seconds = seconds; self.wordsIn = wordsIn; self.wordsOut = wordsOut; self.reason = reason
        }
        public var readout: WritingReadout {
            WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models in the keyboard", background: false,
                           wordsIn: wordsIn, wordsOut: wordsOut, seconds: seconds, keptRaw: kept, note: reason, used: used)
        }
    }
    public static var done: Done? {
        get {
            guard let data = d.data(forKey: Key.doneID) else { return nil }
            return try? JSONDecoder().decode(Done.self, from: data)
        }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.doneID) }
    }

    /// What the app shows while the keyboard writes: nothing written yet, and why. Never says written.
    public static func handedOverReadout(words: Int) -> WritingReadout {
        WritingReadout(model: "Apple on-device model", runtime: "handed to the keyboard", background: true, wordsIn: words,
                       wordsOut: words, seconds: 0, note: "the keyboard has not reported yet")
    }

    /// The result ID of a handed-over dictation carries the mark itself ("kbw.<style>.<uuid>"), so the keyboard never
    /// sees the new result without the mark (two App Group keys can reach another process in either order).
    public static func resultID(style: DictationStyle) -> String { "kbw.\(style.rawValue).\(UUID().uuidString)" }
    /// The style a handed-over result is to be written in, or nil for a result that is already final.
    public static func style(ofResultID id: String) -> DictationStyle? {
        let parts = id.split(separator: ".", maxSplits: 2)
        guard parts.count == 3, parts[0] == "kbw" else { return nil }
        return DictationStyle(rawValue: String(parts[1]))
    }

    /// The keyboard's time limit for writing: the app's (WritingBudget) plus 1 s for the first request's model load.
    public static func seconds(words: Int) -> Double { WritingBudget.seconds(words: words) + 1 }
}
