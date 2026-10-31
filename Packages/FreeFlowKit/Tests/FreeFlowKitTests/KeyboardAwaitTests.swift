import XCTest
@testable import FreeFlowKit

/// Suspected cause of a missed dictation (2026-10-29): the keyboard's awaited result expired 600 s after the mic
/// tap, so a keyboard shown again after a dictation over 10 minutes never typed its text. Any length must land.
final class KeyboardAwaitTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testA25MinuteDictationStillLandsWhenTheKeyboardComesBackRightAfter() {
        // tapped at t0, 25 min of recording, text ready at t0+1530, keyboard shown again 5 s later
        XCTAssertTrue(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 1535, phase: .done, resultAt: t0 + 1530))
    }

    func testStillWaitingWhileFreeFlowRecordsOrWritesAnyLength() {
        XCTAssertTrue(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 3600, phase: .listening, resultAt: nil))
        XCTAssertTrue(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 3700, phase: .transcribing, resultAt: t0 - 50))
    }

    func testTextReadyTenMinutesAgoIsNoLongerTyped() {
        XCTAssertFalse(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 1530 + 601, phase: .done, resultAt: t0 + 1530))
    }

    func testAShortDictationKeepsBuild8Behaviour() {
        XCTAssertTrue(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 30, phase: .done, resultAt: t0 + 20))
        XCTAssertTrue(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 5, phase: .ready, resultAt: nil))
    }

    func testAnOlderResultDoesNotKeepAnOldTapAlive() {
        // the current result is from before the tap, the tap was 11 minutes ago and nothing is running: give up
        XCTAssertFalse(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 660, phase: .ready, resultAt: t0 - 10))
        XCTAssertFalse(KeyboardAwait.isLive(awaitAt: t0, now: t0 + 660, phase: .error, resultAt: nil))
    }

    func testNothingAwaited() {
        XCTAssertFalse(KeyboardAwait.isLive(awaitAt: nil, now: t0, phase: .listening, resultAt: nil))
    }
}
