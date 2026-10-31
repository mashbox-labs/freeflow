import XCTest
@testable import FreeFlowKit

/// Gate 13, 2026-10-30 (iPad Pro, Core ML, 25-minute dictation): the 15-minute window ran out during the dictation and
/// the app turned the mic off 190 ms after the text was ready. The window must not end in the same heartbeat.
final class ArmWindowDoneGraceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var expired: Date { now.addingTimeInterval(-600) }

    func testNotInTheSameBeatAsTheText() {
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: expired, phase: .done, resultAt: now.addingTimeInterval(-0.19), now: now))
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: expired, phase: .done, resultAt: now.addingTimeInterval(-1.9), now: now))
    }

    func testDisarmsOnceTheGraceHasPassed() {
        XCTAssertTrue(ArmWindow.shouldDisarm(endsAt: expired, phase: .done, resultAt: now.addingTimeInterval(-2.1), now: now))
        XCTAssertTrue(ArmWindow.shouldDisarm(endsAt: expired, phase: .done, resultAt: nil, now: now))
    }

    func testStillNeverCutsADictation() {
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: expired, phase: .listening, resultAt: nil, now: now))
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: expired, phase: .transcribing, resultAt: nil, now: now))
    }

    func testWindowNotOverYet() {
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: now.addingTimeInterval(60), phase: .done, resultAt: nil, now: now))
    }
}
