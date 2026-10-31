import Foundation

/// When Free Flow suggests a smaller speech model (builds 23-24): it measures the wait after the user
/// stops talking (the transcription itself, without the model's load). A long recording takes longer and that is not
/// slow, so the limit grows with the recording (the aim: catch a model too slow for this device, not Whisper large on
/// a fast Mac). Every number of the rule is here, to tune in one place.
/// - slow: a wait over max(`waitSeconds`, `perRecordingSecond` x the recording's length) on `needed` of the model's
///   last `window` dictations on this device;
/// - asked at most once per `quietHours`, never by itself (the user taps Switch), never during the first-prepare screen;
/// - "Not now" `declinesToStop` times for one model: never again for that model (the user chose it).
public struct SlowRule: Codable, Equatable, Sendable {
    public static let waitSeconds = 1.5
    /// PROVISIONAL until the Mac bench (set from Whisper large on the M5 at 10 s and 30 s).
    public static let perRecordingSecond = 0.25
    public static let window = 5
    public static let needed = 3
    public static let quietHours = 24.0
    public static let declinesToStop = 2

    /// One dictation: its wait after speech and the recording's length, in seconds.
    public struct Wait: Codable, Equatable, Sendable {
        public let wait: Double
        public let audio: Double
        public var isSlow: Bool { wait > SlowRule.limit(audioSeconds: audio) }
    }
    /// The wait above which a dictation of this length counts as slow.
    public static func limit(audioSeconds: Double) -> Double { max(waitSeconds, perRecordingSecond * audioSeconds) }

    /// Model id -> its last `window` dictations on this device, newest last.
    public private(set) var recent: [String: [Wait]] = [:]
    public private(set) var lastAsked: Date?
    public private(set) var declines: [String: Int] = [:]

    public init() {}

    public mutating func record(model: String, wait: Double, audio: Double) {
        recent[model] = Array((recent[model, default: []] + [Wait(wait: wait, audio: audio)]).suffix(Self.window))
    }

    public func isSlow(_ model: String) -> Bool {
        (recent[model] ?? []).filter(\.isSlow).count >= Self.needed
    }

    /// Whether to ask now about `model` (the caller also checks that a smaller Neural Engine model exists).
    public func mayAsk(_ model: String, now: Date) -> Bool {
        guard declines[model, default: 0] < Self.declinesToStop, isSlow(model) else { return false }
        if let lastAsked, now.timeIntervalSince(lastAsked) < Self.quietHours * 3600 { return false }
        return true
    }

    public mutating func asked(now: Date) { lastAsked = now }
    public mutating func notNow(_ model: String) { declines[model, default: 0] += 1 }
    /// Switched away: that model's waits no longer describe what the user runs.
    public mutating func switched(from model: String) { recent[model] = nil }
}
