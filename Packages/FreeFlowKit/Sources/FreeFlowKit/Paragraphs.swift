import Foundation

/// One recognized word and when it was said, in seconds from the start of the recording.
/// Parakeet on Core ML gives these; Whisper (run without timestamps) and the C++ engine give text only.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(_ text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Smart paragraphs: a blank line after a sentence whose pause is at least this dictation's own median sentence-end
/// pause (and at least 0.5 s), so a slow speaker is judged against their own pauses, not a fixed number. Only whitespace
/// changes: one space between two sentences becomes a blank line. No word is added, dropped, moved or re-cased, and
/// there are never more breaks than sentence ends.
///
/// The rule was chosen on the dev half of a fixed long-dictation set (43 five-minute LibriVox windows, Gutenberg
/// paragraphs as the reference) and scored once on the held-out half: F1 0.410 (P 0.291, R 0.697) against 0.351 for a
/// fixed 0.6 s pause. It still makes more breaks than the books (468 vs 195). Those timings came from faster-whisper,
/// not Parakeet, and audiobook reading is not dictation.
public enum Paragraphs {
    public struct Rule: Equatable, Sendable {
        /// The pause needed for a break: this dictation's median sentence-end pause + k x its spread (1.4826 x MAD).
        public var k: Double
        /// Never break on a pause shorter than this, in seconds.
        public var floor: Double
        /// Sentences a paragraph needs before the next break (the last paragraph too).
        public var minSentences: Int
        /// Sentence-end pauses needed to judge this speaker at all; fewer gives no breaks.
        public var minPauses: Int
        /// Speech shorter than this (first word to last) gets no breaks: messages stay one block.
        public var minSeconds: Double

        public init(k: Double = 0, floor: Double = 0.5, minSentences: Int = 1, minPauses: Int = 4, minSeconds: Double = 60) {
            self.k = k
            self.floor = floor
            self.minSentences = minSentences
            self.minPauses = minPauses
            self.minSeconds = minSeconds
        }

        /// Dev-selected: k 0, floor 0.5 s, min 1 sentence, 4 pauses. minSeconds is a product guard, not tuned: every
        /// scored window had over 150 s of speech, so it changes none of the scored numbers.
        public static let standard = Rule()
    }

    static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}"]

    /// A word ends a sentence when its last . ! or ? is followed only by closing quotes or brackets ("him.", "go?\"").
    static func endsSentence<S: StringProtocol>(_ word: S) -> Bool {
        for ch in word.reversed() {
            if closers.contains(ch) { continue }
            return ch == "." || ch == "!" || ch == "?"
        }
        return false
    }

    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// The pause (seconds) a sentence end needs for a break in this dictation, from its own sentence-end pauses;
    /// nil when there are too few to judge.
    public static func threshold(pauses: [Double], rule: Rule = .standard) -> Double? {
        guard pauses.count >= max(1, rule.minPauses) else { return nil }
        let sorted = pauses.sorted()
        let centre = median(sorted)
        var thr = centre
        if rule.k != 0 {
            let mad = median(sorted.map { abs($0 - centre) }.sorted())
            thr += rule.k * max(1.4826 * mad, 0.02)
        }
        return max(thr, rule.floor)
    }

    /// Indices i into `words` where a paragraph ends after words[i] (each one a sentence end, in order).
    public static func breaks(_ words: [TimedWord], rule: Rule = .standard) -> [Int] {
        guard words.count > 1, words[words.count - 1].end - words[0].start >= rule.minSeconds else { return [] }
        let ends = (0..<(words.count - 1)).filter { endsSentence(words[$0].text) }
        let pauses = ends.map { words[$0 + 1].start - words[$0].end }
        guard let thr = threshold(pauses: pauses, rule: rule) else { return [] }
        var out: [(word: Int, end: Int)] = []
        var since = 0
        for (k, i) in ends.enumerated() {
            since += 1
            if pauses[k] >= thr && since >= rule.minSentences {
                out.append((i, k))
                since = 0
            }
        }
        // Sentences after a break: the sentence ends after it plus the closing sentence.
        while let last = out.last, ends.count - last.end < rule.minSentences { out.removeLast() }
        return out.map(\.word)
    }

    /// The finished text's words, matched to recognized words by letters and digits only (case and punctuation differ).
    static func key<S: StringProtocol>(_ s: S) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// How far ahead a finished word is looked for: the cleanup and "scratch that" delete words, so the finished words
    /// are the recognized ones minus some, in the same order.
    static let lookahead = 256

    /// Puts the paragraph breaks into finished (formatted) text. A break goes between two finished words only where
    /// the first ends a sentence, the two are joined by exactly one space, and a chosen pause lies between the
    /// recognized words they came from. Everything else is copied byte for byte.
    public static func apply(_ text: String, words: [TimedWord], rule: Rule = .standard) -> String {
        let after = breaks(words, rule: rule)
        guard !after.isEmpty, !text.isEmpty else { return text }
        let keys = words.map { key($0.text) }

        var spans: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            spans.append(i..<j)
            i = j
        }
        guard spans.count > 1 else { return text }

        // Finished word -> recognized word (leftmost match, in order).
        var source = [Int?](repeating: nil, count: spans.count)
        var p = 0
        for (n, span) in spans.enumerated() {
            let k = key(text[span])
            guard !k.isEmpty else { continue }
            var j = p
            let stop = min(keys.count, p + lookahead)
            while j < stop {
                if keys[j] == k { source[n] = j; p = j + 1; break }
                j += 1
            }
        }
        // The recognized word each finished word is followed by (the next matched one), or the end.
        var next = [Int](repeating: words.count, count: spans.count)
        var upcoming = words.count
        for n in stride(from: spans.count - 1, through: 0, by: -1) {
            next[n] = upcoming
            if let s = source[n] { upcoming = s }
        }

        var out = ""
        out.reserveCapacity(text.utf8.count + 2 * after.count)
        var cursor = text.startIndex
        var b = 0
        for n in 0..<(spans.count - 1) {
            guard let a = source[n] else { continue }
            let c = next[n]
            while b < after.count, after[b] < a { b += 1 }
            guard b < after.count, after[b] < c else { continue }
            while b < after.count, after[b] < c { b += 1 }
            let gap = spans[n].upperBound..<spans[n + 1].lowerBound
            guard text[gap] == " ", endsSentence(text[spans[n]]) else { continue }
            out += text[cursor..<gap.lowerBound]
            out += "\n\n"
            cursor = gap.upperBound
        }
        out += text[cursor...]
        return out
    }
}
