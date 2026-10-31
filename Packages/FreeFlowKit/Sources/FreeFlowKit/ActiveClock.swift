import Foundation

/// Build 24 (seen on an iPad: "Preparing … · 1862 s"): time Free Flow spent in front. iOS suspends an app soon after
/// it leaves the screen, and a Neural Engine prepare does not move while it is suspended, so the prepare's clock and its
/// time limit count only time in front. The app tells it when it leaves and comes back (ModelManager).
public final class ActiveClock: @unchecked Sendable {
    public static let shared = ActiveClock()
    private let lock = NSLock()
    private var pausedTotal: TimeInterval = 0
    private var backgroundSince: Date?
    /// How long the last stay in the background lasted (0 before the first one).
    public private(set) var lastBackground: TimeInterval = 0

    public init() {}

    public func enteredBackground(_ now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if backgroundSince == nil { backgroundSince = now }
    }

    public func enteredForeground(_ now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let since = backgroundSince else { return }
        let away = max(0, now.timeIntervalSince(since))
        pausedTotal += away
        lastBackground = away
        backgroundSince = nil
    }

    /// Seconds spent in the background so far, the current stay included.
    public func paused(_ now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return pausedTotal + (backgroundSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

/// A stretch of time measured on an ActiveClock: wall time minus the time Free Flow spent in the background.
public struct ActiveSpan: Sendable, Equatable {
    public let began: Date
    public let pausedAtStart: TimeInterval

    public init(began: Date = Date(), clock: ActiveClock = .shared) {
        self.began = began
        pausedAtStart = clock.paused(began)
    }

    public func seconds(_ now: Date = Date(), clock: ActiveClock = .shared) -> TimeInterval {
        max(0, now.timeIntervalSince(began) - (clock.paused(now) - pausedAtStart))
    }

    /// True when Free Flow spent more than a second in the background during this span.
    public func wasPaused(_ now: Date = Date(), clock: ActiveClock = .shared) -> Bool {
        clock.paused(now) - pausedAtStart > 1
    }
}

/// A time limit on active time that starts at its first check (a load waiting its turn behind another is not timed).
public final class ActiveLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var span: ActiveSpan?
    public let seconds: TimeInterval
    private let clock: ActiveClock

    public init(seconds: TimeInterval, clock: ActiveClock = .shared) {
        self.seconds = seconds
        self.clock = clock
    }

    /// True once `seconds` of active time have passed since the first call.
    public func expired(_ now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if span == nil { span = ActiveSpan(began: now, clock: clock) }
        return span!.seconds(now, clock: clock) >= seconds
    }
}
