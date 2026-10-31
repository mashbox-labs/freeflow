import XCTest
@testable import FreeFlowKit

/// Seen in run r10 (2026-10-29): an 11 s host stall made both simulators' apps miss heartbeats while they kept
/// recording. The keyboard switched to "Free Flow stopped listening" and never came back, so the Finish key was gone
/// for the rest of a 25-minute dictation. A stall must come back by itself; only a real Off is final.
final class KeyboardLiveRuleTests: XCTestCase {
    func testAQuietAppStillRecordingIsAStallNotAStop() {
        XCTAssertEqual(KeyboardLiveRule.step(shown: .listening, stalled: false, truth: .off, phase: .listening, offReason: ""), .stalled)
        XCTAssertEqual(KeyboardLiveRule.step(shown: .writing, stalled: false, truth: .off, phase: .transcribing, offReason: ""), .stalled)
    }

    func testTheLiveViewComesBackWhenTheAppBeatsAgain() {
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .recording, phase: .listening, offReason: ""), .resume(.listening))
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .processing, phase: .transcribing, offReason: ""), .resume(.writing))
    }

    func testAResultMadeDuringTheStallStillGetsTyped() {
        // the app finished while the keyboard thought it was gone: back to Writing so the done step types the text
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .armed, phase: .done, offReason: ""), .resume(.writing))
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .armed, phase: .error, offReason: ""), .resume(.writing))
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .armed, phase: .ready, offReason: ""), .idle)
    }

    func testARealOffIsFinal() {
        // the app wrote why (call, route lost, window ended): say it, do not wait
        XCTAssertEqual(KeyboardLiveRule.step(shown: .listening, stalled: false, truth: .off, phase: .off, offReason: "Another app or a call took the microphone."),
                       .stopped("Another app or a call took the microphone."))
        // the app's phase is no longer live and it gave no reason
        XCTAssertEqual(KeyboardLiveRule.step(shown: .listening, stalled: false, truth: .off, phase: .off, offReason: ""), .stopped(KeyboardLiveRule.stoppedText))
        // a stall that turns into a real Off
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .off, phase: .off, offReason: "iOS restarted its audio. Tap to turn on."),
                       .stopped("iOS restarted its audio. Tap to turn on."))
    }

    func testNothingChangesWhenNothingIsLive() {
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: false, truth: .off, phase: .off, offReason: ""), .keep)
        XCTAssertEqual(KeyboardLiveRule.step(shown: .listening, stalled: false, truth: .recording, phase: .listening, offReason: ""), .keep)
        XCTAssertEqual(KeyboardLiveRule.step(shown: nil, stalled: true, truth: .off, phase: .listening, offReason: ""), .keep)
    }
}
