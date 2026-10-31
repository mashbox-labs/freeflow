import FreeFlowKit
import XCTest

/// Build 24 (seen on an iPad: "· 1862 s" after about 30 min with another app in front): the prepare clock counts only time
/// with Free Flow in front, and its time limit too.
final class ActiveClockTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testBackgroundTimeIsLeftOut() {
        let clock = ActiveClock()
        let span = ActiveSpan(began: t0, clock: clock)
        clock.enteredBackground(t0.addingTimeInterval(20))
        XCTAssertEqual(span.seconds(t0.addingTimeInterval(1800), clock: clock), 20, accuracy: 0.001, "counted while in the background")
        clock.enteredForeground(t0.addingTimeInterval(1850))
        XCTAssertEqual(span.seconds(t0.addingTimeInterval(1862), clock: clock), 32, accuracy: 0.001)
        XCTAssertTrue(span.wasPaused(t0.addingTimeInterval(1862), clock: clock))
        XCTAssertEqual(clock.lastBackground, 1830, accuracy: 0.001)
    }

    func testASpanThatStartsLaterIgnoresEarlierBackgroundTime() {
        let clock = ActiveClock()
        clock.enteredBackground(t0); clock.enteredForeground(t0.addingTimeInterval(100))
        let span = ActiveSpan(began: t0.addingTimeInterval(110), clock: clock)
        XCTAssertEqual(span.seconds(t0.addingTimeInterval(140), clock: clock), 30, accuracy: 0.001)
        XCTAssertFalse(span.wasPaused(t0.addingTimeInterval(140), clock: clock))
    }

    func testLimitStartsAtItsFirstCheckAndSkipsBackground() {
        let clock = ActiveClock()
        let limit = ActiveLimit(seconds: 60, clock: clock)
        XCTAssertFalse(limit.expired(t0))                                   // starts here
        clock.enteredBackground(t0.addingTimeInterval(30))
        XCTAssertFalse(limit.expired(t0.addingTimeInterval(600)), "background time ran the limit out")
        clock.enteredForeground(t0.addingTimeInterval(600))
        XCTAssertFalse(limit.expired(t0.addingTimeInterval(629)))
        XCTAssertTrue(limit.expired(t0.addingTimeInterval(630)))
    }
}
