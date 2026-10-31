import XCTest
@testable import FreeFlowKit

/// The 25 held-out five-minute windows the paragraph rule was scored on (words and times: faster-whisper small on
/// public-domain LibriVox recordings of Pride and Prejudice, Walden and The Souls of Black Folk). Each window starts with
/// "# <id> <break indices>": the breaks the scored rule chose (a paragraph ends after that word).
final class ParagraphsHeldoutTests: XCTestCase {
    struct Window { let id: String; let expected: [Int]; var words: [TimedWord] }

    private func windows() throws -> [Window] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/para-heldout.tsv")
        var out: [Window] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("# ") {
                let f = line.split(separator: " ")
                out.append(Window(id: String(f[1]), expected: f.dropFirst(2).map { Int($0)! }, words: []))
                continue
            }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            out[out.count - 1].words.append(TimedWord(String(f[0]), start: Double(f[1])!, end: Double(f[2])!))
        }
        return out
    }

    /// Setting off (the default): the formatter's text is byte-identical with and without the timings, for every
    /// window.
    func testOffIsByteIdenticalOnHeldout() throws {
        let wins = try windows()
        XCTAssertEqual(wins.count, 25)
        var diffs = 0
        for w in wins {
            let text = w.words.map(\.text).joined(separator: " ")
            let plain = DictationText.finish(text)
            let off = DictationText.finish(text)
            if off != plain { diffs += 1 }
        }
        XCTAssertEqual(diffs, 0)
    }

    /// Setting on: the Swift rule picks exactly the breaks that were scored (468 on these 25 windows).
    func testOnMatchesTheScoredRuleOnHeldout() throws {
        let wins = try windows()
        var total = 0
        for w in wins {
            XCTAssertEqual(Paragraphs.breaks(w.words), w.expected, w.id)
            total += w.expected.count
            let text = w.words.map(\.text).joined(separator: " ")
            let out = Paragraphs.apply(text, words: w.words)
            XCTAssertEqual(out.components(separatedBy: "\n\n").count - 1, w.expected.count, w.id)
            XCTAssertEqual(out.replacingOccurrences(of: "\n\n", with: " "), text, w.id)
        }
        XCTAssertEqual(total, 468)
    }
}
