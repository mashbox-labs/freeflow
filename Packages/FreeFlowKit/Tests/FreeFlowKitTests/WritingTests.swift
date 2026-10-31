import CryptoKit
import XCTest
@testable import FreeFlowKit

final class WritingTests: XCTestCase {
    /// Formal is the bake-off's prompt_v1.txt (sha256 74bfa80d...) less one sentence, "Write numbers, times and amounts
    /// as digits." (build 18: it made Apple's model change facts, e.g. "Monday" -> "1"), byte for byte.
    func testFormalIsTheMeasuredPrompt() {
        let sha = SHA256.hash(data: Data(WritingPrompt.instructions(for: .formal).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, "6920c560708d42d527d50ba0889cd32def8fc41dafce56f72ee24ca213b1f23e")
        XCTAssertFalse(WritingPrompt.instructions(for: .formal).contains("as digits"))
        for s in DictationStyle.allCases where s != .formal {
            let p = WritingPrompt.instructions(for: s)
            XCTAssertNotEqual(p, WritingPrompt.instructions(for: .formal), s.rawValue)
            XCTAssertTrue(p.contains("Keep swear words, slang and apologies exactly as spoken."), s.rawValue)
        }
        XCTAssertEqual(WritingPrompt.message("oh shit sorry"), "Transcript: oh shit sorry")
    }

    /// Build 18: the style sentences measured on the 87 dev lines (10-30). "in a ... style" for very casual and excited
    /// made Apple's input check refuse most lines; they name only the form. Casual is unchanged.
    func testStyleSentencesAreTheMeasuredOnes() {
        let f = "in a formal style: correct capitalisation, full punctuation, complete sentences."
        let base = WritingPrompt.instructions(for: .formal)
        XCTAssertEqual(WritingPrompt.instructions(for: .casual), base.replacingOccurrences(of: f, with: "in a casual style: capitals and light punctuation, no full stop at the very end."))
        XCTAssertEqual(WritingPrompt.instructions(for: .veryCasual), base.replacingOccurrences(of: f, with: "with correct spelling and complete sentences, written in lowercase except names and I, with commas only where needed and no full stop at the very end."))
        XCTAssertEqual(WritingPrompt.instructions(for: .excited), base.replacingOccurrences(of: f, with: "with correct capitalisation, full punctuation and complete sentences, and an exclamation mark at the very end."))
    }

    /// Nothing about words is hard-coded. The guard refuses only an empty answer; no word, phrase or count
    /// rule decides whether the model's text is used.
    func testGuardOnlyRefusesAnEmptyAnswer() {
        XCTAssertNil(WritingGuard.reject(raw: "Um, so I I think we should, uh, go tomorrow.", written: "I think we should go tomorrow."))
        XCTAssertNil(WritingGuard.reject(raw: "What is the capital of France?", written: "The capital of France is Paris."))
        XCTAssertNotNil(WritingGuard.reject(raw: "Send it now.", written: ""))
        XCTAssertNotNil(WritingGuard.reject(raw: "Send it now.", written: " \n "))
    }

    func testPiecesJoinBackToTheText() {
        let long = (0..<40).map { "This is sentence \($0) of a long dictation." }.joined(separator: " ")
        for text in ["One short line.", long, "Para one here.\n\nPara two here.", long + "\n\n" + long] {
            let p = WritingGuard.pieces(text)
            XCTAssertEqual(p.map(\.text).joined(), text)
            for piece in p where piece.write { XCTAssertLessThanOrEqual(piece.text.split(separator: " ").count, 120) }
        }
        XCTAssertGreaterThan(WritingGuard.pieces(long).filter(\.write).count, 1)
    }
}
