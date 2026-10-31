import Foundation

/// What the keyboard shows during a dictation when the app's heartbeat goes quiet.
///
/// 2026-10-29: an 11 s host stall made both simulators' apps miss heartbeats while they kept
/// recording. The keyboard had switched to "Free Flow stopped listening" for good (that message never cleared when the
/// beat came back), so the Finish key was gone for the rest of a 25-minute dictation. A quiet heartbeat with no off
/// reason while the app's last phase is still listening or writing is a stall: say so, keep the recording, and go back
/// to the live view when the app beats again. Only a real Off (a reason from the app, or a phase that is no longer
/// live) is final.
public enum KeyboardLiveRule {
    public enum Live: Equatable, Sendable { case listening, writing }
    public enum Step: Equatable, Sendable { case keep, stalled, stopped(String), resume(Live), idle }
    public static let stalledText = "Free Flow is not answering. Your recording is kept."
    public static let stoppedText = "Free Flow stopped listening. Tap the mic to turn it on."

    /// - shown: the live view on screen (nil when the keyboard is not showing Listening or Writing)
    /// - stalled: the keyboard is showing the stall message
    /// - truth: `SessionTruth.state` of the App Group; phase/offReason: the app's last written values
    public static func step(shown: Live?, stalled: Bool, truth: MicState, phase: SessionPhase, offReason: String) -> Step {
        if truth == .off {
            guard shown != nil || stalled else { return .keep }
            if offReason.isEmpty, phase == .listening || phase == .transcribing { return stalled ? .keep : .stalled }
            return .stopped(offReason.isEmpty ? stoppedText : offReason)
        }
        guard stalled else { return .keep }
        switch truth {
        case .recording: return .resume(.listening)
        case .processing: return .resume(.writing)
        case .armed, .off: return phase == .done || phase == .error ? .resume(.writing) : .idle
        }
    }
}
