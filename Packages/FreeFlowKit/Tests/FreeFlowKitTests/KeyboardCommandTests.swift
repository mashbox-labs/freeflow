import FreeFlowKit
import XCTest

/// Build 23 (security): the app acts on a keyboard command only with the keyboard's fresh, unused nonce, and a finish
/// or cancel only for the dictation that keyboard started.
final class KeyboardCommandTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func command(_ name: DarwinName, nonce: String = "n1", session: String? = nil, age: TimeInterval = 0.2) -> KeyboardCommand {
        KeyboardCommand(name: name.rawValue, nonce: nonce, session: session ?? nonce, at: now.addingTimeInterval(-age))
    }

    func testFreshStartOpensItsOwnSession() {
        XCTAssertTrue(KeyboardCommand.accepts(command(.start), name: .start, lastNonce: nil, currentSession: nil, now: now))
        XCTAssertFalse(KeyboardCommand.accepts(command(.start, session: "other"), name: .start, lastNonce: nil, currentSession: nil, now: now))
    }

    func testNothingWrittenOrUsedOrOldIsRefused() {
        XCTAssertFalse(KeyboardCommand.accepts(nil, name: .start, lastNonce: nil, currentSession: nil, now: now), "a bare notification")
        XCTAssertFalse(KeyboardCommand.accepts(command(.start), name: .start, lastNonce: "n1", currentSession: nil, now: now), "used once")
        XCTAssertFalse(KeyboardCommand.accepts(command(.start, age: 2.5), name: .start, lastNonce: nil, currentSession: nil, now: now), "older than 2 s")
        XCTAssertFalse(KeyboardCommand.accepts(command(.finish), name: .start, lastNonce: nil, currentSession: nil, now: now), "written for another name")
        XCTAssertFalse(KeyboardCommand.accepts(command(.start, nonce: ""), name: .start, lastNonce: nil, currentSession: nil, now: now))
    }

    func testFinishAndCancelOnlyForTheKeyboardsDictation() {
        for name in [DarwinName.finish, .cancel] {
            let c = command(name, nonce: "n2", session: "s1")
            XCTAssertTrue(KeyboardCommand.accepts(c, name: name, lastNonce: "n1", currentSession: "s1", now: now))
            XCTAssertFalse(KeyboardCommand.accepts(c, name: name, lastNonce: nil, currentSession: "s9", now: now), "another dictation")
            XCTAssertFalse(KeyboardCommand.accepts(c, name: name, lastNonce: nil, currentSession: nil, now: now), "not the keyboard's dictation")
            XCTAssertFalse(KeyboardCommand.accepts(c, name: name, lastNonce: nil, currentSession: "", now: now))
        }
    }

    func testTheOpenAndStartWindowIsLonger() {
        let c = command(.start, age: 8)
        XCTAssertFalse(KeyboardCommand.accepts(c, name: .start, lastNonce: nil, currentSession: nil, now: now))
        XCTAssertTrue(KeyboardCommand.accepts(c, name: .start, lastNonce: nil, currentSession: nil,
                                              fresh: KeyboardCommand.openFreshFor, now: now))
    }

    /// Security (Mac, build 32): with no keyboard extension, even a well-formed, fresh, unused command is refused.
    func testNoKeyboardOnThisPlatformRefusesEveryCommand() {
        XCTAssertFalse(KeyboardCommand.accepts(command(.start), name: .start, lastNonce: nil, currentSession: nil, now: now, keyboard: false))
        XCTAssertFalse(KeyboardCommand.accepts(command(.start), name: .start, lastNonce: nil, currentSession: nil,
                                               fresh: KeyboardCommand.openFreshFor, now: now, keyboard: false))
        XCTAssertFalse(KeyboardCommand.accepts(command(.finish, session: "s"), name: .finish, lastNonce: nil, currentSession: "s", now: now, keyboard: false))
    }

    /// Security (Mac, build 32): with no keyboard to read it, a finished dictation's text is never stored.
    func testResultTextIsStoredOnlyWhereAKeyboardReadsIt() {
        XCTAssertEqual(SharedSession.storedResultText("private words", keyboard: true), "private words")
        XCTAssertNil(SharedSession.storedResultText("private words", keyboard: false))
    }
}
