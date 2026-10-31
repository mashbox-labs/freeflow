import XCTest
@testable import FreeFlowRules
@testable import FreeFlowKit

/// Build 11, iPad, Parakeet (10-30): a speaker said "oh shit sorry" twice and "shit" and "sorry" never came
/// through. Free Flow filters no content: an apology or an exclamation is never taken for a correction, and the
/// cleanup never removes a word unless it is a filler sound (um, uh), the same word said again, or a correction
/// whose new words match what they replace.
final class CleanupKeepsWordsTests: XCTestCase {
    /// Exactly what each level gives for the sentences Parakeet writes for "oh shit sorry ...".
    func testOhShitSorryKeepsEveryWord() {
        let lines = [
            "Oh shit, sorry, I'm running late.",
            "Oh shit, sorry, I forgot.",
            "Oh, shit, sorry, I was on mute.",
            "Shit, sorry, wrong chat.",
            "Oh shit, sorry.",
            "Oh shit sorry I'm late.",
            "Damn, sorry, I missed it.",
            "Oh no, sorry, I didn't see that.",
        ]
        for level in [CleanupLevel.clean, .polished] {
            for s in lines {
                let out = Cleanup.apply(s, level: level, language: "en")
                print("FFKEEP \(level) \(s.debugDescription) -> \(out.debugDescription)")
                let polishedOh = level == .polished && s.hasPrefix("Oh, ")   // Polished drops a comma-set opening "oh" by design
                if !polishedOh { XCTAssertEqual(words(out), words(s), "\(level): \(s)") }
            }
        }
    }

    /// Filler sounds still go, and a correction whose new words match the old still works.
    func testFillersAndMatchedCorrectionsStillGo() {
        XCTAssertEqual(Cleanup.apply("So, um, I think so.", level: .clean, language: "en"), "So, I think so.")
        XCTAssertEqual(words(Cleanup.apply("Let's meet at 5, sorry, 6.", level: .clean, language: "en")), words("Let's meet at 6."))
    }

    private func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0 == " " }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }
}
