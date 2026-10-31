import XCTest
@testable import FreeFlowKit

/// Start/Stop Free Flow (Action Button, Control Center, Lock Screen, Siri, Back Tap): what one press does,
/// and where the text goes.
final class TriggerTests: XCTestCase {
    // MARK: What a press does

    func testPressWhileListeningStops() {
        for live in [true, false] {
            for active in [true, false] {
                XCTAssertEqual(TriggerPlanner.step(phase: .listening, sessionLive: live, appActive: active), .stop)
            }
        }
    }

    func testPressWhileWritingWaits() {
        XCTAssertEqual(TriggerPlanner.step(phase: .transcribing, sessionLive: true, appActive: false), .busy)
    }

    func testWarmSessionStartsWithoutOpeningTheApp() {
        for phase in [SessionPhase.ready, .done, .error] {
            XCTAssertEqual(TriggerPlanner.step(phase: phase, sessionLive: true, appActive: false), .start)
        }
    }

    /// Apple DTS: a recording session cannot be activated from the background, so a cold press opens the app.
    func testColdPressInTheBackgroundOpensTheApp() {
        for phase in [SessionPhase.off, .ready, .done, .error] {
            XCTAssertEqual(TriggerPlanner.step(phase: phase, sessionLive: false, appActive: false), .openApp)
        }
    }

    func testColdPressWithTheAppOpenStartsHere() {
        XCTAssertEqual(TriggerPlanner.step(phase: .off, sessionLive: false, appActive: true), .start)
    }

    // MARK: Where the text goes

    func testKeyboardUpOnlyWhileItsHeartbeatIsFresh() {
        let now = Date()
        XCTAssertTrue(TriggerRouting.keyboardUp(seenAt: now.addingTimeInterval(-0.5), now: now))
        XCTAssertFalse(TriggerRouting.keyboardUp(seenAt: now.addingTimeInterval(-5), now: now))
        XCTAssertFalse(TriggerRouting.keyboardUp(seenAt: nil, now: now))
    }

    func testKeyboardThatTypedTheResultMeansNoClipboard() async {
        var copied: String?
        var inserted = ""
        let task = Task { @MainActor in
            await TriggerRouting.deliver(text: "hello there", id: "r1", keyboardSeenAt: { Date() }, insertedID: { inserted },
                                         timeout: 2, copy: { copied = $0 })
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run { inserted = "r1" }
        let result = await task.value
        XCTAssertEqual(result, .typed)
        XCTAssertNil(copied)
    }

    func testKeyboardUpButSilentFallsBackToClipboard() async {
        var copied: String?
        let start = Date()
        let result = await TriggerRouting.deliver(text: "hello there", id: "r2", keyboardSeenAt: { Date() }, insertedID: { "older" },
                                                  timeout: 0.4, copy: { copied = $0 })
        XCTAssertEqual(result, .copied)
        XCTAssertEqual(copied, "hello there")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.35)
    }

    func testNoKeyboardCopiesAtOnce() async {
        var copied: String?
        let start = Date()
        let result = await TriggerRouting.deliver(text: "hi", id: "r3", keyboardSeenAt: { nil }, insertedID: { "" },
                                                  timeout: 5, copy: { copied = $0 })
        XCTAssertEqual(result, .copied)
        XCTAssertEqual(copied, "hi")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testEmptyTextGoesNowhere() async {
        var copied: String?
        let result = await TriggerRouting.deliver(text: "  ", id: "r4", keyboardSeenAt: { nil }, insertedID: { "" },
                                                  timeout: 1, copy: { copied = $0 })
        XCTAssertEqual(result, .nothing)
        XCTAssertNil(copied)
    }

    // MARK: What it says

    func testDialogsSayWhereTheTextWent() {
        XCTAssertTrue(TriggerOutcome.finished(.typed, text: "a b").dialog.contains("cursor"))
        XCTAssertTrue(TriggerOutcome.finished(.copied, text: "a b").dialog.contains("Copied"))
        XCTAssertTrue(TriggerOutcome.listening.dialog.contains("again"))
        XCTAssertEqual(TriggerOutcome.failed("Didn't catch that.").dialog, "Didn't catch that.")
        XCTAssertEqual(TriggerOutcome.finished(.copied, text: "one two three").value, "one two three")
        XCTAssertEqual(TriggerOutcome.listening.value, "")
    }

    /// The notice is small and private: it says where the text went and how many words, never the words.
    func testCopiedNoticeNeverShowsTheText() throws {
        let notice = try XCTUnwrap(TriggerNotice.content(for: .finished(.copied, text: "my secret plan for tomorrow")))
        XCTAssertTrue(notice.body.contains("5 words"))
        XCTAssertFalse(notice.body.contains("secret"))
        XCTAssertFalse(notice.title.contains("secret"))
    }

    func testNoNoticeWhenTypedOrListening() {
        XCTAssertNil(TriggerNotice.content(for: .finished(.typed, text: "a")))
        XCTAssertNil(TriggerNotice.content(for: .listening))
        XCTAssertNil(TriggerNotice.content(for: .busy))
    }

    func testFailureGetsANotice() {
        XCTAssertEqual(TriggerNotice.content(for: .failed("Didn't catch that. Try again."))?.body, "Didn't catch that. Try again.")
    }
}
