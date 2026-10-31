import FreeFlowKit
import XCTest

/// Build 23 (F2): the Mac's mic after a fn dictation. Off right after by default; the window choices stay as they were.
final class MacMicTests: XCTestCase {
    func testDefaultReleasesRightAfter() {
        XCTAssertEqual(MacMic.minutes(stored: nil), 0)
        XCTAssertTrue(MacMic.releasesAfterDictation(stored: nil))
        XCTAssertTrue(MacMic.releasesAfterDictation(stored: 0))
    }

    func testChoicesKeepTheMicOn() {
        for m in [5, 15, 60] {
            XCTAssertEqual(MacMic.minutes(stored: m), m)
            XCTAssertFalse(MacMic.releasesAfterDictation(stored: m))
        }
        XCTAssertEqual(MacMic.minutes(stored: 480), 0, "an unknown value is the default")
        XCTAssertEqual(MacMic.choices.map(MacMic.label), ["Off right after each dictation", "5 minutes", "15 minutes", "1 hour"])
    }
}
