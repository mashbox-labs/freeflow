import XCTest
@testable import FreeFlowKit

/// One source of truth for the mic: what every surface (keyboard, controls, Live Activity) is allowed to show.
final class SessionTruthTests: XCTestCase {
    let now = Date()

    func testFreshHeartbeatMapsPhases() {
        let beat = now.addingTimeInterval(-1)
        XCTAssertEqual(SessionTruth.state(phase: .ready, heartbeat: beat, now: now), .armed)
        XCTAssertEqual(SessionTruth.state(phase: .done, heartbeat: beat, now: now), .armed)
        XCTAssertEqual(SessionTruth.state(phase: .error, heartbeat: beat, now: now), .armed)
        XCTAssertEqual(SessionTruth.state(phase: .listening, heartbeat: beat, now: now), .recording)
        XCTAssertEqual(SessionTruth.state(phase: .transcribing, heartbeat: beat, now: now), .processing)
        XCTAssertEqual(SessionTruth.state(phase: .off, heartbeat: beat, now: now), .off)
    }

    /// "Maybe recording" must be impossible: a stale or missing heartbeat is Off, whatever the last phase said.
    func testStaleHeartbeatIsAlwaysOff() {
        for phase in [SessionPhase.ready, .listening, .transcribing, .done, .error, .off] {
            XCTAssertEqual(SessionTruth.state(phase: phase, heartbeat: now.addingTimeInterval(-10), now: now), .off, "\(phase)")
            XCTAssertEqual(SessionTruth.state(phase: phase, heartbeat: nil, now: now), .off, "\(phase)")
        }
    }

    func testKeyboardNeverShowsALiveMicWhenOff() {
        let label = SessionTruth.label(.off, endsAt: nil, offReason: "", now: now)
        XCTAssertEqual(label, "Tap to turn on")
        XCTAssertEqual(SessionTruth.label(.off, endsAt: nil, offReason: "A call took the microphone.", now: now),
                       "Tap to turn on")
    }

    func testArmedLabelShowsTimeLeft() {
        XCTAssertEqual(SessionTruth.label(.armed, endsAt: now.addingTimeInterval(12 * 60 + 5), offReason: "", now: now), "Ready · 13 min")
        XCTAssertEqual(SessionTruth.label(.armed, endsAt: now.addingTimeInterval(40), offReason: "", now: now), "Ready · 1 min")
        XCTAssertEqual(SessionTruth.label(.recording, endsAt: nil, offReason: "", now: now), "Listening")
        XCTAssertEqual(SessionTruth.label(.processing, endsAt: nil, offReason: "", now: now), "Transcribing")
    }

    // MARK: The armed window

    func testWindowIsFiveFifteenOrSixtyDefaultFifteen() {
        XCTAssertEqual(ArmWindow.choices, [5, 15, 60])
        XCTAssertEqual(ArmWindow.minutes(stored: nil), 15)
        XCTAssertEqual(ArmWindow.minutes(stored: 5), 5)
        XCTAssertEqual(ArmWindow.minutes(stored: 60), 60)
        // Older builds offered 8 hours and "until I end it"; the mic must still disarm by itself.
        XCTAssertEqual(ArmWindow.minutes(stored: 480), 60)
        XCTAssertEqual(ArmWindow.minutes(stored: 0), 60)
    }

    func testWindowEndsByItselfButNotMidDictation() {
        let ends = now.addingTimeInterval(-1)
        XCTAssertTrue(ArmWindow.shouldDisarm(endsAt: ends, phase: .ready, now: now))
        XCTAssertTrue(ArmWindow.shouldDisarm(endsAt: ends, phase: .done, now: now))
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: ends, phase: .listening, now: now))
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: ends, phase: .transcribing, now: now))
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: now.addingTimeInterval(60), phase: .ready, now: now))
        XCTAssertFalse(ArmWindow.shouldDisarm(endsAt: nil, phase: .ready, now: now))
    }

    // MARK: Interruptions (call, Siri, another app, route change)

    func testInterruptionBeganTurnsOffAtOnce() {
        XCTAssertEqual(InterruptionRule.began(phase: .ready), .turnOff("Another app or a call took the microphone."))
        XCTAssertEqual(InterruptionRule.began(phase: .listening), .turnOff("Another app or a call took the microphone."))
        XCTAssertEqual(InterruptionRule.began(phase: .off), .nothing)
    }

    func testInterruptionEndedResumesOnlyWhenIOSSaysSoAndItWorks() {
        XCTAssertEqual(InterruptionRule.ended(shouldResume: true, wasArmed: true), .tryResume)
        XCTAssertEqual(InterruptionRule.ended(shouldResume: false, wasArmed: true), .nothing)
        XCTAssertEqual(InterruptionRule.ended(shouldResume: true, wasArmed: false), .nothing)
        XCTAssertEqual(InterruptionRule.resumeFailed, .turnOff("The microphone could not come back. Tap to turn on."))
    }
}
