import Foundation

/// Whether a keyboard that asked for a dictation is still waiting for its text. The keyboard stores the result id
/// current at its mic tap (and the tap time) in the App Group, so the text still lands when iOS shows the keyboard
/// again, often as a new keyboard instance.
public enum KeyboardAwait {
    /// Ten minutes.
    public static let window: TimeInterval = 600

    /// Build 8 waited 10 minutes from the mic tap whatever the dictation was doing, so a keyboard shown again after a
    /// dictation over 10 minutes never typed it. Now: while Free Flow is still recording or writing, wait (any length);
    /// once text made after the tap is ready, type it if it was ready less than 10 minutes ago.
    public static func isLive(awaitAt: Date?, now: Date, phase: SessionPhase, resultAt: Date?) -> Bool {
        guard let awaitAt else { return false }
        if phase == .listening || phase == .transcribing { return true }
        if let resultAt, resultAt >= awaitAt { return now.timeIntervalSince(resultAt) < window }
        return now.timeIntervalSince(awaitAt) < window
    }
}
