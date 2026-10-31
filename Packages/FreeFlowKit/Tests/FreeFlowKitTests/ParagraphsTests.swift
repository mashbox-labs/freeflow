import XCTest
@testable import FreeFlowKit

final class ParagraphsTests: XCTestCase {
    /// Times the words of `text` (split on spaces) as speech: `word` s per word, 0.1 s between words inside a
    /// sentence, and after the n-th sentence end the pause `pause(n)`.
    private func timed(_ text: String, word: Double = 0.4, pause: (Int) -> Double) -> [TimedWord] {
        var out: [TimedWord] = []
        var t = 0.0, sentence = 0
        for w in text.split(separator: " ") {
            out.append(TimedWord(String(w), start: t, end: t + word))
            t += word
            if Paragraphs.endsSentence(w) { t += pause(sentence); sentence += 1 } else { t += 0.1 }
        }
        return out
    }

    /// n plain sentences of 9 words each (about 4 s of speech each at 0.4 s a word).
    private func sentences(_ n: Int) -> String {
        (0..<n).map { "We looked at item \($0) and it seemed fine today." }.joined(separator: " ")
    }

    private func breakCount(_ s: String) -> Int { s.components(separatedBy: "\n\n").count - 1 }

    private func sentenceCount(_ s: String) -> Int {
        let words = s.split(whereSeparator: \.isWhitespace)
        guard let last = words.last else { return 0 }
        return words.filter { Paragraphs.endsSentence($0) }.count + (Paragraphs.endsSentence(last) ? 0 : 1)
    }

    // MARK: Adaptive threshold

    func testThresholdIsThisDictationsMedianSentencePause() throws {
        // Two speakers, the second pausing twice as long everywhere: each gets its own threshold.
        let a = [0.55, 0.6, 0.7, 0.8, 1.5]
        XCTAssertEqual(try XCTUnwrap(Paragraphs.threshold(pauses: a)), 0.7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Paragraphs.threshold(pauses: a.map { $0 * 2 })), 1.4, accuracy: 1e-9)
        // Even count: the mean of the middle two.
        XCTAssertEqual(try XCTUnwrap(Paragraphs.threshold(pauses: [0.9, 0.6, 1.2, 0.7])), 0.8, accuracy: 1e-9)
        // Never under the floor.
        XCTAssertEqual(try XCTUnwrap(Paragraphs.threshold(pauses: [0.1, 0.2, 0.2, 0.3])), 0.5, accuracy: 1e-9)
        // median + k x 1.4826 x MAD.
        let k1 = Paragraphs.Rule(k: 1, floor: 0)
        XCTAssertEqual(try XCTUnwrap(Paragraphs.threshold(pauses: [1, 2, 3, 4, 5], rule: k1)), 3 + 1.4826, accuracy: 1e-9)
        // Too few sentence ends to judge the speaker: no threshold.
        XCTAssertNil(Paragraphs.threshold(pauses: [1, 2, 3]))
        XCTAssertNil(Paragraphs.threshold(pauses: []))
    }

    func testLongPausesBreakAndShortOnesDoNot() {
        // Pauses under the 0.5 s floor except after sentences 4, 9 and 14.
        let text = sentences(20)
        let long: Set<Int> = [4, 9, 14]
        let words = timed(text) { long.contains($0) ? 1.5 : 0.25 + 0.05 * Double($0 % 5) }
        let got = Paragraphs.breaks(words)
        let ends = words.indices.filter { Paragraphs.endsSentence(words[$0].text) }
        XCTAssertEqual(got, long.sorted().map { ends[$0] })
        let out = Paragraphs.apply(text, words: words)
        XCTAssertEqual(breakCount(out), 3)
        XCTAssertEqual(out.replacingOccurrences(of: "\n\n", with: " "), text)
        XCTAssertTrue(out.contains("item 4 and it seemed fine today.\n\nWe looked at item 5"))
    }

    func testSlowerSpeakerSameBreaksWhereAFixedPauseWouldBreakEverywhere() {
        let text = sentences(20)
        let pause: (Int) -> Double = { [3, 8, 15].contains($0) ? 1.6 : 0.6 + 0.04 * Double($0 % 6) }
        let fast = timed(text, pause: pause)
        let slow = fast.map { TimedWord($0.text, start: $0.start * 2, end: $0.end * 2) }
        let ends = fast.indices.dropLast().filter { Paragraphs.endsSentence(fast[$0].text) }.count
        XCTAssertEqual(Paragraphs.breaks(slow), Paragraphs.breaks(fast))
        XCTAssertLessThan(Paragraphs.breaks(slow).count, ends)
        // A fixed 0.6 s rule (the earlier rule) breaks the slow speaker at every sentence end.
        let fixed = (0..<(slow.count - 1)).filter { Paragraphs.endsSentence(slow[$0].text) && slow[$0 + 1].start - slow[$0].end >= 0.6 }
        XCTAssertEqual(fixed.count, ends)
    }

    func testBreaksOnlyAtSentenceEnds() {
        // Long pauses in the middle of sentences (after "item") never break.
        let text = sentences(20)
        var words = timed(text) { $0 % 4 == 0 ? 1.5 : 0.3 }
        var shift = 0.0
        for i in words.indices {
            words[i].start += shift; words[i].end += shift
            if words[i].text == "item" { shift += 3 }
        }
        for b in Paragraphs.breaks(words) { XCTAssertTrue(Paragraphs.endsSentence(words[b].text)) }
        let out = Paragraphs.apply(text, words: words)
        for part in out.components(separatedBy: "\n\n").dropLast() {
            XCTAssertTrue(Paragraphs.endsSentence(part.split(separator: " ").last ?? ""))
        }
    }

    // MARK: Hard rules

    func testEmptyAndOneSentenceUnchanged() {
        XCTAssertEqual(Paragraphs.apply("", words: []), "")
        XCTAssertEqual(DictationText.finish(""), "")
        let one = "So this is one long sentence that goes on and on without ever really stopping"
        let w = timed(one) { _ in 2 }
        XCTAssertEqual(Paragraphs.apply(one, words: w), one)
        // One sentence spread over 80 s with long pauses inside it: still one paragraph.
        let spread = w.enumerated().map { TimedWord($1.text, start: $1.start + Double($0) * 5, end: $1.end + Double($0) * 5) }
        XCTAssertEqual(Paragraphs.apply(one + ".", words: spread), one + ".")
        XCTAssertEqual(Paragraphs.apply(DictationText.finish(one + "."), words: spread), one + ".")
        // Text but no timings (Whisper, C++): unchanged.
        XCTAssertEqual(Paragraphs.apply(sentences(20), words: []), sentences(20))
    }

    func testShortDictationStaysOneBlock() {
        // 10 sentences, about 50 s of speech: under the 60 s guard, so no breaks even with long pauses.
        let text = sentences(10)
        let words = timed(text, word: 0.3) { $0 % 2 == 0 ? 2.0 : 0.3 }
        XCTAssertLessThan(words.last!.end - words.first!.start, 60)
        XCTAssertEqual(Paragraphs.apply(text, words: words), text)
        // The same with the guard off does break.
        XCTAssertGreaterThan(breakCount(Paragraphs.apply(text, words: words, rule: Paragraphs.Rule(minSeconds: 0))), 0)
    }

    func testNeverMoreBreaksThanSentencesAndWordsByteIdentical() {
        // Seeded random dictations through the real formatter: fillers, stutters, questions, quotes, every style and
        // level. With timings the text may differ from without only where one space became a blank line.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let vocab = ["we", "should", "ship", "the", "build", "on", "Friday", "because", "it", "works", "now", "I", "think",
                     "Maya", "said", "that", "MASHBOX", "is", "ready", "maybe", "later", "okay", "so", "it's", "really"]
        let fillers = ["um", "uh", "like", "you know"]
        var totalBreaks = 0
        for trial in 0..<200 {
            var parts: [String] = []
            let n = 6 + rnd(40)
            for _ in 0..<n {
                var s: [String] = []
                for k in 0..<(3 + rnd(12)) {
                    if rnd(9) == 0 { s.append(fillers[rnd(fillers.count)] + ",") }
                    let w = vocab[rnd(vocab.count)]
                    s.append(k == 0 ? w.prefix(1).uppercased() + w.dropFirst() : w)
                    if rnd(12) == 0 { s.append(w) }                      // stutter
                }
                let mark = [".", ".", ".", "?", "!", ".\"", "..."][rnd(7)]
                s[s.count - 1] += mark
                if rnd(10) == 0 { s.append("um.") }                     // a filler that ends the sentence
                parts.append(s.joined(separator: " "))
            }
            let raw = parts.joined(separator: " ")
            let words = timed(raw, word: 0.3 + 0.05 * Double(rnd(4))) { _ in 0.1 + Double(rnd(30)) / 10 }
            let without = DictationText.finish(raw)
            let with = Paragraphs.apply(without, words: words)
            XCTAssertFalse(without.contains("\n"))
            XCTAssertEqual(with.replacingOccurrences(of: "\n\n", with: " "), without, "trial \(trial)")
            XCTAssertEqual(with.split(whereSeparator: \.isWhitespace), without.split(whereSeparator: \.isWhitespace))
            XCTAssertLessThanOrEqual(breakCount(with), max(0, sentenceCount(without) - 1), "trial \(trial)")
            XCTAssertLessThanOrEqual(breakCount(with), Paragraphs.breaks(words).count)
            totalBreaks += breakCount(with)
        }
        XCTAssertGreaterThan(totalBreaks, 0)  // the test exercises real breaks, not only the guards
    }

    func testBreakAfterAFillerKeepsTheFiller() {
        // Build 12 has no cleanup: "there um." stays whole, and the long pause after it still breaks there.
        var parts = (0..<20).map { "We looked at item \($0) and it seemed fine today." }
        parts[6] = "Then we can go there um."
        let raw = parts.joined(separator: " ")
        let words = timed(raw) { $0 == 6 ? 1.8 : 0.3 }
        let out = Paragraphs.apply(raw, words: words)
        XCTAssertTrue(out.contains("Then we can go there um.\n\nWe looked at item 7"), out)
        XCTAssertEqual(breakCount(out), 1)
    }

    // MARK: Cost

    /// A 5-minute-sized dictation (910 words, 70 sentences, about 330 s): paragraphs must add well under 100 ms.
    func testFiveMinuteDictationCost() {
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let text = (0..<70).map { "So we looked at part \($0) of the plan and it seemed mostly fine." }.joined(separator: " ")
        let words = timed(text, word: 0.18) { _ in 0.2 + Double(rnd(20)) / 10 }
        XCTAssertGreaterThan(words.last!.end, 280)
        let formatted = DictationText.finish(text)
        let n = 51
        var ms: [Double] = []
        var out = ""
        for _ in 0..<n {
            let t0 = DispatchTime.now().uptimeNanoseconds
            out = Paragraphs.apply(formatted, words: words)
            ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        ms.sort()
        let median = ms[n / 2]
        print("FFPARA cost words=\(words.count) seconds=\(Int(words.last!.end)) breaks=\(breakCount(out)) runs=\(n) median_ms=\(String(format: "%.3f", median)) max_ms=\(String(format: "%.3f", ms[n - 1]))")
        XCTAssertGreaterThan(breakCount(out), 0)
        XCTAssertLessThan(median, 100)
    }
}
