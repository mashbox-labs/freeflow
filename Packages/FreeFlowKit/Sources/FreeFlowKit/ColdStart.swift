import Foundation

/// Build 26: the keyboard's cold start records in the app you type in, not in Free Flow.
///
/// A keyboard cannot use the microphone (Apple's App Extension Programming Guide, Custom Keyboard: no access to the
/// device microphone), so with no warm session the keyboard's mic opens Free Flow, which starts
/// its audio session in the foreground and keeps it running in the background (UIBackgroundModes audio). Build 25 also
/// started the dictation there, so people talked into Free Flow's screen or waited and lost words on the way back.
///
/// Now Free Flow only arms: the mic is on, nothing is kept but the last `ringSeconds` in memory (PreRollRing), and the
/// return card says to go back. When a Free Flow keyboard shows again in another app, it asks for the start at once
/// (the same nonce-checked start as a warm tap). The dictation keeps `preRoll` seconds from before the keyboard's ask,
/// plus whatever the mic heard while the ask travelled, so a first word said as the keyboard slides up is not clipped.
/// Anything said earlier, while Free Flow was in front, is dropped: it was said to the wrong screen, and the person
/// will say it again once the keyboard says it is listening.
///
/// Nobody goes back within `waitForReturn`: the mic turns off by itself (no orange dot left on).
public enum ColdStart {
    /// Seconds kept from before the keyboard's start (0.3 to 0.5 s).
    public static let preRoll: TimeInterval = 0.4
    /// Seconds the armed mic keeps in memory, the most a pre-roll can reach back including the ask's travel time.
    public static let ringSeconds: TimeInterval = 2
    /// Seconds Free Flow waits, armed, for a keyboard to show again before it turns the mic off.
    public static let waitForReturn: TimeInterval = 60

    /// UI tests set FF_HANDOFF_WAIT (simulator launchd) so the give-up case runs in seconds. iOS apps get no
    /// environment from people, so this changes nothing outside a test.
    public static func wait(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        guard let s = environment["FF_HANDOFF_WAIT"], let v = Double(s), v > 0 else { return waitForReturn }
        return v
    }

    /// How many buffered samples start the dictation: from `preRoll` seconds before the keyboard's ask up to now, never
    /// more than the ring holds. An ask stamped in the future (clock change) keeps just the pre-roll.
    public static func preRollSamples(signalAt: Date, now: Date, rate: Double, buffered: Int) -> Int {
        let travel = max(0, now.timeIntervalSince(signalAt))
        let want = Int(((travel + preRoll) * rate).rounded())
        return max(0, min(want, buffered, Int(ringSeconds * rate)))
    }

    public static func expired(armedAt: Date, now: Date, wait: TimeInterval = waitForReturn) -> Bool {
        now.timeIntervalSince(armedAt) >= wait
    }

    /// The keyboard on screen asks for the start once per arming: Free Flow is armed for a trip (fresh), its mic is on and
    /// idle, and no keyboard has claimed this arming yet.
    public static func keyboardShouldStart(handoff: Handoff?, claimed: Date?, truth: MicState, now: Date = Date(),
                                           wait: TimeInterval = waitForReturn) -> Bool {
        guard let handoff, truth == .armed, claimed != handoff.armedAt else { return false }
        let age = now.timeIntervalSince(handoff.armedAt)
        return age >= -1 && age < wait
    }

    /// What the screens say (no-ai-smell: short, plain, no dashes).
    public enum Words {
        /// The keyboard's title while the start is on its way (tens of milliseconds; the pre-roll covers it).
        public static let keyboardStarting = "Starting"
        /// The keyboard's title once Free Flow really records, after a trip.
        public static let keyboardLive = "Listening, speak now"
        /// The keyboard while Free Flow opens.
        public static let opening = "Opening Free Flow"
        public static let openingHow = "Then come back here. Free Flow listens once you are back."
        /// The keyboard asked and Free Flow did not start within `keyboardGiveUp`.
        public static let didNotStart = "Free Flow did not start listening. Tap the mic to try again."
        /// Why the mic turned off when nobody went back.
        public static func gaveUp(_ seconds: TimeInterval) -> String {
            "Free Flow waited \(Int(seconds.rounded())) s for you to go back to your app, so it turned the mic off."
        }
    }

    /// Seconds the keyboard shows Starting before it says the start did not happen.
    public static let keyboardGiveUp: TimeInterval = 3
}

/// Free Flow is armed for one keyboard's trip back (App Group, written by the app only).
public struct Handoff: Codable, Equatable, Sendable {
    /// The keyboard session that opened Free Flow (KeyboardCommand nonce).
    public let session: String
    public let armedAt: Date
    public init(session: String, armedAt: Date) { self.session = session; self.armedAt = armedAt }
}

/// The armed mic's last seconds, in memory only. Not thread safe: the owner holds its own lock.
public struct PreRollRing {
    private var buffer: [Float]
    private var next = 0
    public private(set) var count = 0
    public var capacity: Int { buffer.count }

    public init(capacity: Int) { buffer = [Float](repeating: 0, count: max(1, capacity)) }

    public mutating func write(_ chunk: UnsafeBufferPointer<Float>) {
        let cap = buffer.count
        var src = chunk
        // Only the tail can survive a chunk longer than the ring.
        if src.count > cap { src = UnsafeBufferPointer(rebasing: src[(src.count - cap)...]) }
        buffer.withUnsafeMutableBufferPointer { dst in
            var i = 0
            while i < src.count {
                let n = min(src.count - i, cap - next)
                (dst.baseAddress! + next).update(from: src.baseAddress! + i, count: n)
                next = (next + n) % cap
                i += n
            }
        }
        count = min(cap, count + src.count)
    }

    public mutating func write(_ samples: [Float]) { samples.withUnsafeBufferPointer { write($0) } }

    /// The newest `n` samples, oldest first.
    public func last(_ n: Int) -> [Float] {
        let k = max(0, min(n, count))
        guard k > 0 else { return [] }
        let start = (next - k + buffer.count) % buffer.count
        if start + k <= buffer.count { return Array(buffer[start..<(start + k)]) }
        return Array(buffer[start...]) + Array(buffer[..<(k - (buffer.count - start))])
    }

    public mutating func reset() { next = 0; count = 0 }
}
