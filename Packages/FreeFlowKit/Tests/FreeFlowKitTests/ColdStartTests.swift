import XCTest
@testable import FreeFlowKit

/// Build 26: the keyboard's cold start records in the app you type in (ColdStart).
final class ColdStartTests: XCTestCase {
    let rate = 16_000.0
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: pre-roll

    func testPreRollKeepsFromBeforeTheAskUpToNow() {
        // The ask took 0.1 s to arrive: 0.4 s before it plus the 0.1 s it travelled.
        let n = ColdStart.preRollSamples(signalAt: t0, now: t0.addingTimeInterval(0.1), rate: rate, buffered: 32_000)
        XCTAssertEqual(n, 8_000)
    }

    func testPreRollIsAtLeastPointThreeAndAtMostPointFiveForAFastAsk() {
        let n = ColdStart.preRollSamples(signalAt: t0, now: t0, rate: rate, buffered: 32_000)
        XCTAssertGreaterThanOrEqual(Double(n) / rate, 0.3)
        XCTAssertLessThanOrEqual(Double(n) / rate, 0.5)
    }

    func testPreRollNeverReachesPastTheRing() {
        let n = ColdStart.preRollSamples(signalAt: t0, now: t0.addingTimeInterval(9), rate: rate, buffered: 32_000)
        XCTAssertEqual(n, Int(ColdStart.ringSeconds * rate))
    }

    func testPreRollNeverMoreThanBuffered() {
        // The mic turned on 0.1 s ago: only what it heard.
        XCTAssertEqual(ColdStart.preRollSamples(signalAt: t0, now: t0, rate: rate, buffered: 1_600), 1_600)
        XCTAssertEqual(ColdStart.preRollSamples(signalAt: t0, now: t0, rate: rate, buffered: 0), 0)
    }

    func testAnAskFromTheFutureKeepsJustThePreRoll() {
        let n = ColdStart.preRollSamples(signalAt: t0.addingTimeInterval(5), now: t0, rate: rate, buffered: 32_000)
        XCTAssertEqual(n, Int(ColdStart.preRoll * rate))
    }

    // MARK: the ring

    func testRingDropsWhatWasSaidBeforeTheWindow() {
        // 3 s said in Free Flow (1.0), then 0.5 s as the keyboard comes up (2.0): only the last 2 s survive, and a
        // 0.5 s pre-roll holds only the keyboard-time samples.
        var ring = PreRollRing(capacity: Int(2 * rate))
        ring.write([Float](repeating: 1, count: Int(3 * rate)))
        ring.write([Float](repeating: 2, count: Int(0.5 * rate)))
        XCTAssertEqual(ring.count, Int(2 * rate))
        let pre = ring.last(Int(0.5 * rate))
        XCTAssertEqual(pre.count, 8_000)
        XCTAssertTrue(pre.allSatisfy { $0 == 2 }, "nothing said in Free Flow is in the pre-roll")
        let all = ring.last(Int(9 * rate))
        XCTAssertEqual(all.count, Int(2 * rate))
        XCTAssertEqual(all.first, 1); XCTAssertEqual(all.last, 2)
    }

    func testRingKeepsOrderAcrossTheWrap() {
        var ring = PreRollRing(capacity: 5)
        for v in 1...7 { ring.write([Float(v)]) }
        XCTAssertEqual(ring.last(5), [3, 4, 5, 6, 7])
        XCTAssertEqual(ring.last(2), [6, 7])
        ring.write([8, 9, 10])
        XCTAssertEqual(ring.last(5), [6, 7, 8, 9, 10])
    }

    func testRingTakesTheTailOfAChunkLongerThanItself() {
        var ring = PreRollRing(capacity: 4)
        ring.write([1, 2])
        ring.write([3, 4, 5, 6, 7, 8])
        XCTAssertEqual(ring.last(4), [5, 6, 7, 8])
    }

    func testRingResetForgetsEverything() {
        var ring = PreRollRing(capacity: 4)
        ring.write([1, 2, 3])
        ring.reset()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.last(4), [])
    }

    // MARK: the keyboard's ask

    func testKeyboardAsksOncePerArming() {
        let h = Handoff(session: "s", armedAt: t0)
        XCTAssertTrue(ColdStart.keyboardShouldStart(handoff: h, claimed: nil, truth: .armed, now: t0.addingTimeInterval(3)))
        XCTAssertFalse(ColdStart.keyboardShouldStart(handoff: h, claimed: t0, truth: .armed, now: t0.addingTimeInterval(3)),
                       "a second keyboard (or a second appear) must not start a second dictation")
        let again = Handoff(session: "s2", armedAt: t0.addingTimeInterval(100))
        XCTAssertTrue(ColdStart.keyboardShouldStart(handoff: again, claimed: t0, truth: .armed, now: t0.addingTimeInterval(101)))
    }

    func testKeyboardDoesNotAskWithoutAnArmedIdleMic() {
        let h = Handoff(session: "s", armedAt: t0)
        for truth in [MicState.off, .recording, .processing] {
            XCTAssertFalse(ColdStart.keyboardShouldStart(handoff: h, claimed: nil, truth: truth, now: t0), "\(truth)")
        }
        XCTAssertFalse(ColdStart.keyboardShouldStart(handoff: nil, claimed: nil, truth: .armed, now: t0))
    }

    func testKeyboardDoesNotAskAfterTheWait() {
        let h = Handoff(session: "s", armedAt: t0)
        XCTAssertFalse(ColdStart.keyboardShouldStart(handoff: h, claimed: nil, truth: .armed, now: t0.addingTimeInterval(ColdStart.waitForReturn)))
        XCTAssertTrue(ColdStart.expired(armedAt: t0, now: t0.addingTimeInterval(ColdStart.waitForReturn)))
        XCTAssertFalse(ColdStart.expired(armedAt: t0, now: t0.addingTimeInterval(ColdStart.waitForReturn - 1)))
    }

    func testWaitOverrideIsForTestsOnly() {
        XCTAssertEqual(ColdStart.wait(environment: [:]), ColdStart.waitForReturn)
        XCTAssertEqual(ColdStart.wait(environment: ["FF_HANDOFF_WAIT": "8"]), 8)
        XCTAssertEqual(ColdStart.wait(environment: ["FF_HANDOFF_WAIT": "nope"]), ColdStart.waitForReturn)
    }

    func testHandoffRoundTripsThroughTheAppGroup() {
        let h = Handoff(session: "abc", armedAt: t0)
        SharedSession.handoff = h
        XCTAssertEqual(SharedSession.handoff, h)
        SharedSession.handoff = nil
        XCTAssertNil(SharedSession.handoff)
    }
}
