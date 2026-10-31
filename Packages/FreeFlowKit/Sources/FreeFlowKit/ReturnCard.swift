import Foundation

/// The "Recording. Go back to your app" card (build 10, option A, 2026-10-30).
///
/// A keyboard cannot use the microphone, so with no warm session the Free Flow keyboard's mic opens Free Flow with
/// freeflow://dictate and Free Flow records there. Apple gives no public way to send a person back to the app they were
/// typing in, so the app shows one full-screen card that points at iOS's own back button at the top left and names the
/// bottom-edge swipe. After that first trip the session is warm and the keyboard records in place (ArmWindow).
///
/// The card belongs to that trip only. It arms when the keyboard's link (or its pending start) opens Free Flow, and ends
/// when Free Flow leaves the screen, when the person taps Stay here, or when the dictation is written, done or failed.
/// Free Flow opened any other way never shows it, and coming back to Free Flow normally shows the app.
public struct ReturnCard: Equatable, Sendable {
    public private(set) var armed = false

    public init() {}

    /// freeflow://dictate, or the keyboard's pending start read when Free Flow becomes active.
    public mutating func openedByKeyboard() { armed = true }

    /// Free Flow went to the background: the person went back to their app, or anywhere else.
    public mutating func leftApp() { armed = false }

    /// Stay here: the person wants Free Flow itself (its own Finish and Cancel).
    public mutating func stay() { armed = false }

    /// Once the dictation is written, done or failed, the trip is over: the result or the error shows, and a later
    /// dictation started in the app itself brings no card back.
    public mutating func phaseChanged(_ phase: SessionPhase) {
        switch phase {
        case .transcribing, .done, .error: armed = false
        case .off, .ready, .listening: break
        }
    }

    /// Whether the card covers Free Flow now: while the mic starts and while it records.
    public func shows(phase: SessionPhase) -> Bool {
        guard armed else { return false }
        switch phase {
        case .off, .ready, .listening: return true
        case .transcribing, .done, .error: return false
        }
    }

    /// "Recording" only once the mic really records; the second or so before that says "Starting".
    public static func title(_ phase: SessionPhase) -> String { phase == .listening ? "Recording" : "Starting" }

    /// The card's words (no-ai-smell: short, plain, no dashes; never "Dictate" or "Ready").
    public enum Words {
        public static let head = "Go back to your app"
        public static let how = "Tap its name at the top left, or swipe right along the bottom edge."
        public static let finish = "Finish from the keyboard."
        public static let stay = "Stay here"
        /// What VoiceOver reads for the card.
        public static func spoken(_ phase: SessionPhase) -> String { "\(title(phase)). \(head). \(how) \(finish)" }
    }
}
