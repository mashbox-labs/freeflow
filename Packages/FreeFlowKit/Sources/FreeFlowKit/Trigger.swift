import Foundation

/// What one press of Start/Stop Free Flow does. The press can come from the Action Button, a Control Center or
/// Lock Screen control, Siri, or a shortcut (Back Tap runs a shortcut).
public enum TriggerStep: Equatable, Sendable {
    /// Start listening where we are: the mic session is already warm, or the app is open.
    case start
    /// Stop listening and write the text.
    case stop
    /// Open Free Flow first. iOS does not let an app turn the microphone on from the background
    /// (Apple DTS, developer.apple.com/forums/thread/816408), so a press with no warm session has to bring the app forward once.
    case openApp
    /// Still writing the last one; ignore the press.
    case busy
}

public enum TriggerPlanner {
    public static func step(phase: SessionPhase, sessionLive: Bool, appActive: Bool) -> TriggerStep {
        switch phase {
        case .listening: return .stop
        case .transcribing: return .busy
        case .off, .ready, .done, .error: return sessionLive || appActive ? .start : .openApp
        }
    }
}

/// Where the text went.
public enum TriggerDelivery: String, Equatable, Sendable {
    /// The Free Flow keyboard was up and typed it at the cursor.
    case typed
    /// No keyboard took it, so it is on the clipboard.
    case copied
    /// Nothing to deliver.
    case nothing
}

public enum TriggerRouting {
    /// The keyboard writes a heartbeat to the App Group while it is on screen.
    public static let keyboardFresh: TimeInterval = 2
    /// How long to wait for the keyboard to confirm it typed the text before copying it instead.
    public static let insertWait: TimeInterval = 1.5

    public static func keyboardUp(seenAt: Date?, now: Date = Date()) -> Bool {
        guard let seenAt else { return false }
        return now.timeIntervalSince(seenAt) < keyboardFresh
    }

    /// The keyboard types any result that arrives while it is up and writes back the result id it typed.
    /// If it is up, wait (up to `timeout`) for that; otherwise, or if it stays silent, copy the text.
    @MainActor
    public static func deliver(text: String, id: String, keyboardSeenAt: () -> Date?, insertedID: () -> String,
                               timeout: TimeInterval = insertWait, copy: (String) -> Void) async -> TriggerDelivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        if keyboardUp(seenAt: keyboardSeenAt()) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if insertedID() == id { return .typed }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if insertedID() == id { return .typed }
        }
        copy(text)
        return .copied
    }
}

/// The result of one press, as Siri, Shortcuts and the notice report it.
public enum TriggerOutcome: Equatable, Sendable {
    case listening
    case finished(TriggerDelivery, text: String)
    case busy
    case needsApp
    case failed(String)

    public var dialog: String {
        switch self {
        case .listening: return "Listening. Press again to stop."
        case .finished(.typed, _): return "Typed at your cursor."
        case .finished(.copied, _): return "Copied. Touch and hold where you want it, then Paste."
        case .finished(.nothing, _): return "Nothing was heard."
        case .busy: return "Still writing the last one."
        case .needsApp: return "Open Free Flow once to turn the microphone on, then press again."
        case .failed(let message): return message
        }
    }

    /// What a shortcut gets back: the text, or nothing.
    public var value: String {
        if case .finished(_, let text) = self { return text }
        return ""
    }
}

/// The small notification after a press when Free Flow is in the background. It says where the text went and
/// how many words; it never shows the words themselves.
public enum TriggerNotice {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    public static func content(for outcome: TriggerOutcome) -> Content? {
        switch outcome {
        case .finished(.copied, let text):
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return Content(title: "Copied", body: "\(words) \(words == 1 ? "word" : "words") on the clipboard. Touch and hold where you want it, then Paste.")
        case .failed(let message):
            return Content(title: "Free Flow", body: message)
        case .finished(.nothing, _):
            return Content(title: "Free Flow", body: "Nothing was heard.")
        default:
            return nil
        }
    }
}
