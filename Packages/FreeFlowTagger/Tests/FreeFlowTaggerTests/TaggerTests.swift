import XCTest
import FreeFlowKit
import FreeFlowRules
@testable import FreeFlowTagger

final class TaggerTests: XCTestCase {
    func words(_ s: String) -> [String] { s.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) } }
    func isSubsequence(_ a: [String], of b: [String]) -> Bool { var it = b.makeIterator(); return a.allSatisfy { w in while let x = it.next() { if x == w { return true } }; return false } }

    func testLoadsAndScoresEveryWord() throws {
        XCTAssertTrue(DisfluencyTagger.shared.load())
        let s = try XCTUnwrap(DisfluencyTagger.shared.scores(words: ["I", "went", "to", "the,", "uh,", "the", "store."]))
        XCTAssertEqual(s.count, 7)
        for row in s { XCTAssertEqual(row.values.reduce(0, +), 1, accuracy: 0.01) }
        XCTAssertGreaterThan(s[4]["F"] ?? 0, 0.5)   // "uh,"
    }

    func testWordPieceMatchesBertBasicSplit() {
        XCTAssertEqual(WordPiece.basic("Don't,"), ["don", "'", "t", ","])
        XCTAssertEqual(WordPiece.basic("café"), ["cafe"])
    }

    func testTaggerOnlyDeletes() {
        let samples = ["So, I'm, I'm thinking we, um, we meet at 5, no wait, 6 and, you know, go from there.",
                       "I when I went to the the store they had no idea what I meant.",
                       "Can you send me the the report by Friday?", "Thank you. Thank you so much."]
        for text in samples {
            for level in [CleanupLevel.clean, .polished] {
                let out = Cleanup.apply(text, level: level, language: "en", scorer: DisfluencyTagger.shared)
                XCTAssertTrue(isSubsequence(words(out), of: words(text)), "\(level): \(out)")
                XCTAssertFalse(out.isEmpty)
            }
        }
    }

    func testFluentTextUnchanged() {
        let fluent = "Let's meet at six tomorrow and go from there."
        XCTAssertEqual(words(Cleanup.apply(fluent, level: .clean, language: "en", scorer: DisfluencyTagger.shared)), words(fluent))
    }

    func testOtherLanguagesSkipTheTagger() {
        let pt = "Eu comprei um carro novo ontem."
        XCTAssertEqual(Cleanup.apply(pt, level: .clean, language: "pt", scorer: DisfluencyTagger.shared), pt)
    }
}
