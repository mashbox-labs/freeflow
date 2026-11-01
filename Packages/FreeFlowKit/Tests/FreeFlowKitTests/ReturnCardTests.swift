import XCTest
@testable import FreeFlowKit

/// The "Recording. Go back to your app" card (build 10, option A, 2026-10-30).
final class ReturnCardTests: XCTestCase {
    func testFreeFlowOpenedAnyOtherWayShowsNoCard() {
        let card = ReturnCard()
        for phase in [SessionPhase.off, .ready, .listening, .transcribing, .done, .error] {
            XCTAssertFalse(card.shows(phase: phase), "\(phase)")
        }
    }

    func testKeyboardOpenShowsItWhileStartingAndRecording() {
        var card = ReturnCard()
        card.openedByKeyboard()
        XCTAssertTrue(card.shows(phase: .off), "the link arrives before the mic starts")
        XCTAssertTrue(card.shows(phase: .ready))
        XCTAssertTrue(card.shows(phase: .listening))
    }

    func testLeavingTheAppEndsIt() {
        var card = ReturnCard()
        card.openedByKeyboard()
        card.leftApp()
        XCTAssertFalse(card.shows(phase: .listening), "coming back to Free Flow normally shows the app, not the card")
    }

    func testStayHereEndsIt() {
        var card = ReturnCard()
        card.openedByKeyboard()
        card.stay()
        XCTAssertFalse(card.shows(phase: .listening))
    }

    func testWritingDoneOrErrorEndsTheTrip() {
        for end in [SessionPhase.transcribing, .done, .error] {
            var card = ReturnCard()
            card.openedByKeyboard()
            card.phaseChanged(.listening)
            XCTAssertTrue(card.shows(phase: .listening))
            card.phaseChanged(end)
            XCTAssertFalse(card.shows(phase: end), "\(end): the result or the error must show")
            // A later dictation started in the app itself is not a trip from the keyboard.
            card.phaseChanged(.listening)
            XCTAssertFalse(card.shows(phase: .listening), "\(end) then listening")
        }
    }

    func testStartingPhasesKeepIt() {
        var card = ReturnCard()
        card.openedByKeyboard()
        card.phaseChanged(.ready)
        card.phaseChanged(.listening)
        XCTAssertTrue(card.shows(phase: .listening))
    }

    func testAnotherKeyboardTripShowsItAgain() {
        var card = ReturnCard()
        card.openedByKeyboard()
        card.leftApp()
        card.openedByKeyboard()
        XCTAssertTrue(card.shows(phase: .listening))
    }

    func testTitleSaysRecordingOnlyWhileRecording() {
        XCTAssertEqual(ReturnCard.title(.listening), "Recording")
        XCTAssertEqual(ReturnCard.title(.off), "Starting")
        // Build 26: armed and waiting for the trip back, never "Recording".
        XCTAssertEqual(ReturnCard.title(.ready), "Go back")
    }

    func testWordsArePlain() {
        let all = [ReturnCard.title(.listening), ReturnCard.title(.off), ReturnCard.Words.head, ReturnCard.Words.how,
                   ReturnCard.Words.finish, ReturnCard.Words.stay, ReturnCard.Words.spoken(.listening), ReturnCard.Words.spoken(.off),
                   ReturnCard.title(.ready), ReturnCard.Words.spoken(.ready), ColdStart.Words.keyboardStarting, ColdStart.Words.keyboardLive,
                   ColdStart.Words.opening, ColdStart.Words.openingHow, ColdStart.Words.didNotStart, ColdStart.Words.gaveUp(60)]
        for line in all {
            XCTAssertFalse(line.isEmpty)
            XCTAssertNil(line.range(of: "dictate", options: .caseInsensitive), line)
            XCTAssertNil(line.range(of: "ready", options: .caseInsensitive), line)
            for glyph in ["\u{2014}", "\u{2013}", "\u{00B7}", "\u{2192}"] { XCTAssertFalse(line.contains(glyph), line) }
        }
        XCTAssertTrue(ReturnCard.Words.how.contains("swipe right along the bottom edge"))
        XCTAssertTrue(ReturnCard.Words.spoken(.listening).hasPrefix("Recording. Go back to your app."))
    }
}
