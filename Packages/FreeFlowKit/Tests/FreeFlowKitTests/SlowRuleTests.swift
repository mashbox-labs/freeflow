import XCTest
@testable import FreeFlowKit

final class SlowRuleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testThreeSlowOfTheLastFiveAsks() {
        var r = SlowRule()
        for w in [0.4, 2.0, 0.5, 1.6] { r.record(model: "large", wait: w, audio: 2) }
        XCTAssertFalse(r.mayAsk("large", now: t0), "2 slow of 4")
        r.record(model: "large", wait: 3.0, audio: 2)
        XCTAssertTrue(r.mayAsk("large", now: t0), "3 slow of 5")
    }

    func testExactlyTheLimitIsNotSlowAndOnlyTheLastFiveCount() {
        var r = SlowRule()
        for _ in 0..<5 { r.record(model: "large", wait: SlowRule.waitSeconds, audio: 2) }
        XCTAssertFalse(r.isSlow("large"), "over 1.5 s, not at it")
        var s = SlowRule()
        for w in [9.0, 9.0, 9.0, 0.2, 0.2, 0.2, 0.2, 0.2] { s.record(model: "large", wait: w, audio: 2) }
        XCTAssertFalse(s.isSlow("large"), "the old slow ones fell out of the window")
        XCTAssertEqual(s.recent["large"]?.count, SlowRule.window)
    }

    func testOncePerDay() {
        var r = SlowRule()
        for _ in 0..<5 { r.record(model: "large", wait: 4, audio: 2) }
        r.asked(now: t0)
        XCTAssertFalse(r.mayAsk("large", now: t0.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(r.mayAsk("large", now: t0.addingTimeInterval(24 * 3600)))
    }

    func testNotNowTwiceStopsForThatModelOnly() {
        var r = SlowRule()
        for _ in 0..<5 { r.record(model: "large", wait: 4, audio: 2); r.record(model: "small", wait: 4, audio: 2) }
        r.notNow("large")
        XCTAssertTrue(r.mayAsk("large", now: t0))
        r.notNow("large")
        XCTAssertFalse(r.mayAsk("large", now: t0.addingTimeInterval(30 * 86400)), "they chose it")
        XCTAssertTrue(r.mayAsk("small", now: t0))
    }

    func testSwitchingForgetsTheOldModelsWaits() {
        var r = SlowRule()
        for _ in 0..<5 { r.record(model: "large", wait: 4, audio: 2) }
        r.switched(from: "large")
        XCTAssertFalse(r.isSlow("large"))
    }

    /// The limit grows with the recording, so a long dictation is not "slow" for taking longer.
    func testTheLimitGrowsWithTheRecording() {
        XCTAssertEqual(SlowRule.limit(audioSeconds: 2), SlowRule.waitSeconds, "short: the floor")
        let long = 30.0, limit = SlowRule.limit(audioSeconds: long)
        XCTAssertEqual(limit, SlowRule.perRecordingSecond * long, accuracy: 1e-9)
        var r = SlowRule()
        for _ in 0..<5 { r.record(model: "large", wait: limit - 0.01, audio: long) }
        XCTAssertFalse(r.isSlow("large"), "just under k x 30 s is not slow")
        for _ in 0..<3 { r.record(model: "large", wait: limit + 0.01, audio: long) }
        XCTAssertTrue(r.isSlow("large"))
    }

    func testRoundTripsThroughJSON() throws {
        var r = SlowRule()
        r.record(model: "large", wait: 2, audio: 2); r.notNow("large"); r.asked(now: t0)
        let back = try JSONDecoder().decode(SlowRule.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }
}
