import XCTest
@testable import FreeFlowKit

/// Build 28: when the app hands a dictation to the keyboard's writer, and the App Group record of it.
final class KeyboardWritingTests: XCTestCase {
    func testHandOverOnlyForKeyboardDictationsInTheBackground() {
        XCTAssertTrue(KeyboardWriting.handOver(fromKeyboard: true, appActive: false, writerOn: true, appleAvailable: true, enabled: true))
        XCTAssertFalse(KeyboardWriting.handOver(fromKeyboard: false, appActive: false, writerOn: true, appleAvailable: true, enabled: true))
        XCTAssertFalse(KeyboardWriting.handOver(fromKeyboard: true, appActive: true, writerOn: true, appleAvailable: true, enabled: true))
        XCTAssertFalse(KeyboardWriting.handOver(fromKeyboard: true, appActive: false, writerOn: false, appleAvailable: true, enabled: true))
        XCTAssertFalse(KeyboardWriting.handOver(fromKeyboard: true, appActive: false, writerOn: true, appleAvailable: false, enabled: true))
        XCTAssertFalse(KeyboardWriting.handOver(fromKeyboard: true, appActive: false, writerOn: true, appleAvailable: true, enabled: false))
    }

    func testPendingAndDoneRoundTrip() {
        let keepP = KeyboardWriting.pending, keepD = KeyboardWriting.done
        defer { KeyboardWriting.pending = keepP; KeyboardWriting.done = keepD }
        KeyboardWriting.pending = .init(id: "R1", style: .casual, history: "H1")
        XCTAssertEqual(KeyboardWriting.pending, .init(id: "R1", style: .casual, history: "H1"))
        KeyboardWriting.pending = nil
        XCTAssertNil(KeyboardWriting.pending)
        KeyboardWriting.done = .init(id: "R1", text: "Hello.", history: "H1", used: 1, kept: 0, seconds: 1.2, wordsIn: 3, wordsOut: 1, reason: nil)
        XCTAssertEqual(KeyboardWriting.done?.text, "Hello.")
        XCTAssertTrue(KeyboardWriting.done!.readout.short.hasPrefix("Written by Apple Intelligence"))
        KeyboardWriting.done = nil
        XCTAssertNil(KeyboardWriting.done)
    }

    func testKeyboardTimeLimitIsTheAppsPlusOneSecond() {
        XCTAssertEqual(KeyboardWriting.seconds(words: 0), WritingBudget.seconds(words: 0) + 1)
        XCTAssertEqual(KeyboardWriting.seconds(words: 400), 16)
    }

    func testHistoryUpdateChangesOneItem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let a = HistoryItem(text: "as heard", raw: "as heard", style: .formal, model: "m", audioSeconds: 1, processSeconds: 1)
        let b = HistoryItem(text: "other", raw: "other", style: .formal, model: "m", audioSeconds: 1, processSeconds: 1)
        store.add(a); store.add(b)
        store.update(a.id) { $0.text = "Written."; $0.writer = "Written by Apple Intelligence · 1.0 s" }
        let again = HistoryStore(url: url)
        XCTAssertEqual(again.items.first { $0.id == a.id }?.text, "Written.")
        XCTAssertEqual(again.items.first { $0.id == b.id }?.text, "other")
    }

    /// an iPad, build 28: the card said "written by the keyboard" at 0.00 s with the heard text. A readout the
    /// keyboard did not write, or one where Apple's model wrote nothing, must say as heard and why.
    func testReadoutNeverClaimsWritingThatDidNotHappen() {
        let placeholder = KeyboardWriting.handedOverReadout(words: 15)
        XCTAssertEqual(placeholder.used, 0)
        XCTAssertFalse(placeholder.short.contains("Written"))
        XCTAssertFalse(placeholder.line.contains("written by"))
        let failed = KeyboardWriting.Done(id: "R", text: "as heard", history: "", used: 0, kept: 1, seconds: 0.01, wordsIn: 2,
                                          wordsOut: 2, reason: "Apple Intelligence rate-limited (iOS limits it in the background)").readout
        XCTAssertTrue(failed.short.hasPrefix("As heard"))
        XCTAssertTrue(failed.short.contains("rate-limited"))
        let unavailable = KeyboardWriting.Done(id: "R", text: "x", history: "", used: 0, kept: 1, seconds: 0, wordsIn: 1, wordsOut: 1,
                                               reason: "Apple Intelligence not available in the keyboard (Apple's model is still downloading)").readout
        XCTAssertTrue(unavailable.short.contains("not available in the keyboard"))
    }

    func testHandOverMarkIsInTheResultID() {
        let id = KeyboardWriting.resultID(style: .veryCasual)
        XCTAssertEqual(KeyboardWriting.style(ofResultID: id), .veryCasual)
        XCTAssertNil(KeyboardWriting.style(ofResultID: UUID().uuidString))
        XCTAssertNil(KeyboardWriting.style(ofResultID: ""))
    }
}
