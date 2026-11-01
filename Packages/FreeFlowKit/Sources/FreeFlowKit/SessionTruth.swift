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

/// Build 23 (security): on the Mac, how long the mic stays on after a fn dictation.
/// Build 26: "Keep mic ready" Always (while Free Flow runs, as on iPhone and iPad), 15, 5, 2 or Off, default Always;
/// and the mic is the Mac's built-in one by default. Measured 10-31: a cold press on a Bluetooth headset heard nothing
/// for 897-1035 ms (median 924, 5 presses) while the headset moved to call mode; the built-in mic cold 67-137 ms
/// (6 starts); any mic kept ready 2-4 ms. A headset's mic kept on plays music in call quality (a2dp 0, hfp 1, 24 kHz);
/// the built-in mic leaves the headset in music mode.
public enum MacMic {
    public static let key = "macMicMinutes"
    /// Minutes; `always` = for as long as Free Flow runs.
    public static let always = -1
    public static let choices = [always, 15, 5, 2, 0]
    public static let defaultMinutes = always
    public static func minutes(stored: Int?) -> Int { stored.flatMap { choices.contains($0) ? $0 : nil } ?? defaultMinutes }
    public static func releasesAfterDictation(stored: Int?) -> Bool { minutes(stored: stored) == 0 }
    public static func label(_ minutes: Int) -> String {
        switch minutes {
        case always: return "Always (while Free Flow runs)"
        case 0: return "Off right after each dictation"
        default: return "\(minutes) minutes"
        }
    }

    /// Build 26: the picked mic: `builtIn` (the default), `systemDefault` (follows Sound settings) or a CoreAudio uid.
    public static let deviceKey = "macMicDevice"
    public static let builtIn = "builtin"
    public static let systemDefault = "default"
    public static func picked(stored: String?) -> String { (stored?.isEmpty ?? true) ? builtIn : stored! }

    /// The uid the Mac app records from through its own input unit, or "" for the system default input through the
    /// audio session. A picked mic that is not connected (the built-in one with the lid closed, an unplugged one) falls
    /// back to the system default.
    public static func ownInput(picked: String, connected: [String], builtInUID: String?) -> String {
        switch picked {
        case systemDefault: return ""
        case builtIn: return builtInUID.flatMap { connected.contains($0) ? $0 : nil } ?? ""
        default: return connected.contains(picked) ? picked : ""
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
