import FreeFlowKit
import XCTest

/// Build 26: the Mac's mic is the built-in one by default and stays ready while Free Flow runs.
final class MacMicTests: XCTestCase {
    func testDefaultKeepsTheMicReadyAlways() {
        XCTAssertEqual(MacMic.minutes(stored: nil), MacMic.always)
        XCTAssertFalse(MacMic.releasesAfterDictation(stored: nil))
        XCTAssertTrue(MacMic.releasesAfterDictation(stored: 0))
    }

    func testChoices() {
        for m in [15, 5, 2] {
            XCTAssertEqual(MacMic.minutes(stored: m), m)
            XCTAssertFalse(MacMic.releasesAfterDictation(stored: m))
        }
        XCTAssertEqual(MacMic.minutes(stored: 60), MacMic.always, "build 23's 1 hour is no longer a choice: the default")
        XCTAssertEqual(MacMic.choices.map(MacMic.label),
                       ["Always (while Free Flow runs)", "15 minutes", "5 minutes", "2 minutes", "Off right after each dictation"])
    }

    func testPickedDefaultsToBuiltIn() {
        XCTAssertEqual(MacMic.picked(stored: nil), MacMic.builtIn)
        XCTAssertEqual(MacMic.picked(stored: ""), MacMic.builtIn)
        XCTAssertEqual(MacMic.picked(stored: "usb-uid"), "usb-uid")
    }

    func testOwnInput() {
        let all = ["BuiltInMicrophoneDevice", "headset-uid", "usb-uid"]
        XCTAssertEqual(MacMic.ownInput(picked: MacMic.builtIn, connected: all, builtInUID: "BuiltInMicrophoneDevice"), "BuiltInMicrophoneDevice")
        XCTAssertEqual(MacMic.ownInput(picked: MacMic.builtIn, connected: ["headset-uid"], builtInUID: nil), "", "lid closed: the default")
        XCTAssertEqual(MacMic.ownInput(picked: MacMic.systemDefault, connected: all, builtInUID: "BuiltInMicrophoneDevice"), "")
        XCTAssertEqual(MacMic.ownInput(picked: "headset-uid", connected: all, builtInUID: "BuiltInMicrophoneDevice"), "headset-uid")
        XCTAssertEqual(MacMic.ownInput(picked: "usb-uid", connected: ["BuiltInMicrophoneDevice"], builtInUID: "BuiltInMicrophoneDevice"), "",
                       "unplugged: the default records")
    }
}
