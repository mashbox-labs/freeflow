import Foundation

/// What the microphone is really doing. The app is the only writer (phase + a heartbeat every second in the
/// App Group); the keyboard, the controls and the Live Activity only read it through `SessionTruth.state`.
///
///     off ──tap (opens the app once)──▶ armed ──tap──▶ recording ──tap──▶ processing ──▶ armed
///      ▲                                  │                │                                │
///      └── window ends / Stop / interruption / route loss / app gone (stale heartbeat) ◀────┘
///
/// Armed = the audio session is open (orange dot, Live Activity "Free Flow ready") but samples are dropped
/// in memory, never stored or transcribed (only recording writes a clip). Off = the mic is really off.
public enum MicState: String, Sendable { case off, armed, recording, processing }

public enum SessionTruth {
    /// The app beats every second; three missed beats and it is gone (suspended, killed or crashed).
    public static let staleAfter: TimeInterval = 3.5

    public static func state(phase: SessionPhase, heartbeat: Date?, now: Date = Date()) -> MicState {
        guard let heartbeat, now.timeIntervalSince(heartbeat) < staleAfter else { return .off }
        switch phase {
        case .off: return .off
        case .listening: return .recording
        case .transcribing: return .processing
        case .ready, .done, .error: return .armed
        }
    }

    /// The short status line the keyboard shows next to its mic.
    public static func label(_ state: MicState, endsAt: Date?, offReason: String, now: Date = Date()) -> String {
        switch state {
        case .off: return "Tap to turn on"
        case .recording: return "Listening"
        case .processing: return "Transcribing"
        case .armed:
            guard let endsAt else { return "Ready" }
            let minutes = max(1, Int((endsAt.timeIntervalSince(now) / 60).rounded(.up)))
            return "Ready · \(minutes) min"
        }
    }
}

/// How long the mic stays armed after it is turned on.
public enum ArmWindow {
    public static let choices = [5, 15, 60]
    public static let defaultMinutes = 15

    /// Older builds stored 8 hours or 0 ("until I end it"); the mic must always disarm by itself, so those become 60.
    public static func minutes(stored: Int?) -> Int {
        guard let stored else { return defaultMinutes }
        if choices.contains(stored) { return stored }
        return choices.last!
    }

    /// Seconds the session stays on after the text is ready, so every keyboard sees phase done before the mic turns off.
    public static let doneGrace: TimeInterval = 2

    /// The window ends by itself, but never cuts off a dictation in progress, and never in the same heartbeat as the
    /// text it held on for: a dictation that outlived the window used to go done -> off within one second, and a
    /// keyboard that missed the done phase never typed the text (gate 13, 2026-10-30, iPad Pro; KeyboardInsertRule).
    public static func shouldDisarm(endsAt: Date?, phase: SessionPhase, resultAt: Date? = nil, now: Date = Date()) -> Bool {
        guard let endsAt, now >= endsAt else { return false }
        if phase == .done, let resultAt, now.timeIntervalSince(resultAt) < doneGrace { return false }
        return phase != .listening && phase != .transcribing
    }
}

/// Build 23 (security): on the Mac, how long the mic stays on after a fn dictation. Build 22 kept it on for
/// the session window (15 minutes) after every fn press. Default 0: on at fn down, off as soon as the text is in. A cold
/// start measured 10-31 on the M5's built-in mic: AVAudioEngine.start 60-78 ms after the call, first buffer 166-184 ms
/// (6 runs); the other choices keep it on between dictations.
public enum MacMic {
    public static let key = "macMicMinutes"
    public static let choices = [0, 5, 15, 60]
    public static let defaultMinutes = 0
    public static func minutes(stored: Int?) -> Int { stored.flatMap { choices.contains($0) ? $0 : nil } ?? defaultMinutes }
    public static func releasesAfterDictation(stored: Int?) -> Bool { minutes(stored: stored) == 0 }
    public static func label(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off right after each dictation"
        case 60: return "1 hour"
        default: return "\(minutes) minutes"
        }
    }
}

public enum InterruptionStep: Equatable, Sendable { case nothing, tryResume, turnOff(String) }

/// A call, Siri, another app taking audio or a lost route stops the mic. Show Off at once; come back only if
/// iOS says to resume and it actually works (it does not from the background: Apple DTS, forums thread 793010).
public enum InterruptionRule {
    public static func began(phase: SessionPhase) -> InterruptionStep {
        phase == .off ? .nothing : .turnOff("Another app or a call took the microphone.")
    }

    public static func ended(shouldResume: Bool, wasArmed: Bool) -> InterruptionStep {
        shouldResume && wasArmed ? .tryResume : .nothing
    }

    public static let resumeFailed = InterruptionStep.turnOff("The microphone could not come back. Tap to turn on.")
    public static let routeLost = InterruptionStep.turnOff("The microphone changed. Tap to turn on.")
}
