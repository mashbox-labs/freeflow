import Foundation

/// Build 33: when Apple Intelligence cleanup is slow on this device (the cleanup step over 2 s on 3
/// dictations in a row), Free Flow asks once whether to turn it off. At most once every 12 hours, never while cleanup
/// is off. Kept in this device's own store (the App Group), so each device decides for itself: an iPad can be slow
/// while an iPhone is not. A dictation the keyboard cleaned counts too: the app records it when it collects the result.
public enum CleanupSpeed {
    public static let slowAfter: TimeInterval = 2
    public static let streakToAsk = 3
    public static let askAtMostEvery: TimeInterval = 12 * 3600
    public static let question = "Cleanup is taking a few seconds on this device. Turn it off for faster dictation?"

    /// The run of slow cleanups after one whose cleanup step took `seconds`.
    public static func streak(after old: Int, seconds: TimeInterval) -> Int { seconds > slowAfter ? old + 1 : 0 }

    public static func shouldAsk(streak: Int, lastAsked: Date?, cleanupOn: Bool, now: Date = Date()) -> Bool {
        guard cleanupOn, streak >= streakToAsk else { return false }
        guard let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= askAtMostEvery
    }

    private static var d: UserDefaults { FF.defaults }
    public static var slowStreak: Int {
        get { d.integer(forKey: "cleanup.slowStreak") }
        set { d.set(newValue, forKey: "cleanup.slowStreak") }
    }
    public static var lastAsked: Date? {
        get { d.object(forKey: "cleanup.askedAt") as? Date }
        set { d.set(newValue, forKey: "cleanup.askedAt") }
    }

    /// One cleanup finished: its step took `seconds`.
    public static func note(seconds: TimeInterval) { slowStreak = streak(after: slowStreak, seconds: seconds) }

    /// True when the question should show now; it then counts as shown (the cooldown starts, the run starts over).
    public static func takeAsk(cleanupOn: Bool, now: Date = Date()) -> Bool {
        guard shouldAsk(streak: slowStreak, lastAsked: lastAsked, cleanupOn: cleanupOn, now: now) else { return false }
        lastAsked = now
        slowStreak = 0
        return true
    }
}
