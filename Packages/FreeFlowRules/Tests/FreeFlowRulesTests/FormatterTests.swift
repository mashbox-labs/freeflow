import XCTest
@testable import FreeFlowRules
@testable import FreeFlowKit

final class FormatterTests: XCTestCase {
    func testFormalAddsPeriodAndCapitals() {
        XCTAssertEqual(TextFormatter.format("um so i think we should ship it", style: .formal), "So I think we should ship it.")
    }
    func testVeryCasualKeepsAcronymsAndDictionaryCase() {
        XCTAssertEqual(TextFormatter.format("Ship it with NASA and MASHBOX.", style: .veryCasual, keepAsWritten: ["MASHBOX"]),
                       "ship it with NASA and MASHBOX")
    }
    func testExcited() {
        XCTAssertEqual(TextFormatter.format("We won.", style: .excited), "We won!")
    }
    func testCommands() {
        XCTAssertEqual(TextFormatter.format("Hello there. Bad idea scratch that. Good one new line bye", style: .formal),
                       "Hello there. Good one\nBye.")
    }
    /// No hard replace. Words the model wrote stay exactly as written, dictionary or not.
    func testDictionaryNeverRewritesWords() {
        let words = ["MASHBOX", "FreeFlow", "Tencent"]
        for (raw, want) in [("I use free flow daily", "I use free flow daily."),
                            ("mash the potatoes in a box", "Mash the potatoes in a box."),
                            ("it costs ten cents", "It costs ten cents."),
                            ("free flowing water", "Free flowing water.")] {
            XCTAssertEqual(TextFormatter.format(raw, style: .formal, keepAsWritten: words), want)
        }
    }
    func testDictionaryEntryDecodesOldAndNewFiles() throws {
        let old = #"[{"id":"5B0C6C2E-8D3F-4E0A-9C61-6F1E2A3B4C5D","word":"MASHBOX","heardAs":["mash box"]}]"#
        let new = #"[{"id":"5B0C6C2E-8D3F-4E0A-9C61-6F1E2A3B4C5E","word":"Hy-Nomas"}]"#
        let a = try JSONDecoder().decode([DictionaryEntry].self, from: Data(old.utf8))
        let b = try JSONDecoder().decode([DictionaryEntry].self, from: Data(new.utf8))
        XCTAssertEqual(a.first?.heardAs, ["mash box"])
        XCTAssertEqual(b.first?.word, "Hy-Nomas")
        XCTAssertEqual(b.first?.heardAs, [])
    }
    func testDictionaryWordsTrimmedAndDeduped() {
        let e = [DictionaryEntry(word: " MASHBOX "), DictionaryEntry(word: "mashbox"), DictionaryEntry(word: " "),
                 DictionaryEntry(word: "Tencent")]
        XCTAssertEqual(DictionaryStore.words(e), ["MASHBOX", "Tencent"])
    }
    func testRecommendation() {
        let gib = 1_073_741_824.0
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: UInt64(3.7 * gib), language: "en").id, "small")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: UInt64(5.6 * gib), language: "en").id, "medium")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: UInt64(7.5 * gib), language: "en").id, "medium")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: UInt64(7.5 * gib), language: "th").id, "large")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: UInt64(5.6 * gib), language: "ja").id, "small")
    }
}
