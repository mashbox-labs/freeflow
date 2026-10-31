import XCTest
@testable import FreeFlowKit

final class KeyboardInsertRuleTests: XCTestCase {
    private func owed(_ phase: SessionPhase, id: String = "b", last: String = "a", inserted: String = "a",
                      visible: Bool = true, waiting: Bool = false, awaitLive: Bool = true) -> Bool {
        KeyboardInsertRule.owed(phase: phase, resultID: id, lastResult: last, insertedID: inserted,
                                visible: visible, waiting: waiting, awaitLive: awaitLive)
    }

    /// Gate 13 iPad Pro: the session window ran out during the dictation, so the app went done -> off in the same
    /// second; the keyboard shown again after Finish must still type the text.
    func testSessionEndedRightAfterTheTextStillTypes() {
        XCTAssertTrue(owed(.off))
    }

    /// The keyboard that tapped Finish (showing Writing) must type it too, not say "stopped listening".
    func testWritingKeyboardTypesWhenTheSessionEnds() {
        XCTAssertTrue(owed(.off, waiting: true, awaitLive: false))
    }

    func testDoneTypes() {
        XCTAssertTrue(owed(.done))
        XCTAssertTrue(owed(.done, waiting: true, awaitLive: false))
    }

    func testTypedOnceOnly() {
        XCTAssertFalse(owed(.off, inserted: "b"))
        XCTAssertFalse(owed(.done, last: "b"))
    }

    func testNothingNew() {
        XCTAssertFalse(owed(.off, id: "a"))
        XCTAssertFalse(owed(.done, id: ""))
    }

    func testHiddenKeyboardWaits() {
        XCTAssertFalse(owed(.off, visible: false))
    }

    func testNotOwedWhenNobodyIsWaiting() {
        XCTAssertFalse(owed(.off, waiting: false, awaitLive: false))
        XCTAssertFalse(owed(.done, waiting: false, awaitLive: false))
    }

    func testNotWhileStillRecordingOrWriting() {
        for p in [SessionPhase.listening, .transcribing, .ready, .error] { XCTAssertFalse(owed(p), "\(p)") }
    }
}
