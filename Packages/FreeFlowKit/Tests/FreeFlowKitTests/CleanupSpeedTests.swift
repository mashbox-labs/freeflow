import FreeFlowKit
import XCTest

/// Build 33: the slow-cleanup question (over 2 s on 3 dictations in a row, at most once every 12 hours, never when off).
final class CleanupSpeedTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testThreeSlowInARowAsks() {
        var s = 0
        for t in [2.4, 3.1, 2.01] { s = CleanupSpeed.streak(after: s, seconds: t) }
        XCTAssertEqual(s, 3)
        XCTAssertTrue(CleanupSpeed.shouldAsk(streak: s, lastAsked: nil, cleanupOn: true, now: now))
    }

    func testAFastOneStartsTheRunOver() {
        var s = 0
        for t in [2.5, 2.5, 1.2, 2.5, 2.5] { s = CleanupSpeed.streak(after: s, seconds: t) }
        XCTAssertEqual(s, 2)
        XCTAssertFalse(CleanupSpeed.shouldAsk(streak: s, lastAsked: nil, cleanupOn: true, now: now))
        XCTAssertEqual(CleanupSpeed.streak(after: 2, seconds: 2.0), 0, "exactly 2 s is not slow")
    }

    func testAtMostOnceEvery12Hours() {
        XCTAssertFalse(CleanupSpeed.shouldAsk(streak: 5, lastAsked: now.addingTimeInterval(-11.9 * 3600), cleanupOn: true, now: now))
        XCTAssertTrue(CleanupSpeed.shouldAsk(streak: 5, lastAsked: now.addingTimeInterval(-12 * 3600), cleanupOn: true, now: now))
    }

    func testNeverWhenCleanupIsOff() {
        XCTAssertFalse(CleanupSpeed.shouldAsk(streak: 9, lastAsked: nil, cleanupOn: false, now: now))
    }

    func testTakingTheAskStartsTheCooldownAndTheRunOver() {
        CleanupSpeed.slowStreak = 0; CleanupSpeed.lastAsked = nil
        defer { CleanupSpeed.slowStreak = 0; CleanupSpeed.lastAsked = nil }
        for _ in 0..<3 { CleanupSpeed.note(seconds: 2.6) }
        XCTAssertTrue(CleanupSpeed.takeAsk(cleanupOn: true, now: now))
        XCTAssertEqual(CleanupSpeed.slowStreak, 0)
        for _ in 0..<3 { CleanupSpeed.note(seconds: 2.6) }
        XCTAssertFalse(CleanupSpeed.takeAsk(cleanupOn: true, now: now.addingTimeInterval(3600)), "within 12 hours")
        XCTAssertTrue(CleanupSpeed.takeAsk(cleanupOn: true, now: now.addingTimeInterval(12 * 3600)))
    }
}
