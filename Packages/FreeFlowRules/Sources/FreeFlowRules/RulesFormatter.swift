// Bench only (build 12): the rule formatter builds 1-11 ran on dictated text. The app does not link this package.
import Foundation
import FreeFlowKit

public struct FormatOptions: Sendable {
    /// How much the words change (Verbatim, Clean, Polished). Independent of the style.
    public var cleanup: CleanupLevel
    public var spokenCommands: Bool
    /// The dictation's language code when known ("en", "pt"); nil detects it on-device.
    public var language: String?
    /// The on-device disfluency tagger (app only). nil = rules only, as in the keyboard and widgets.
    public var scorer: DisfluencyScorer?
    /// Settings > Paragraphs from pauses (off by default). Off, the text is exactly what it was without paragraphs.
    public var paragraphs: Bool
    public init(cleanup: CleanupLevel = .clean, spokenCommands: Bool = true, language: String? = nil, scorer: DisfluencyScorer? = nil,
                paragraphs: Bool = false) {
        self.cleanup = cleanup
        self.spokenCommands = spokenCommands
        self.language = language
        self.scorer = scorer
        self.paragraphs = paragraphs
    }
}

/// Turns raw recognizer output into finished text. Pure and deterministic.
public enum TextFormatter {
    /// `keepAsWritten`: dictionary words the style pass must not re-case. Nothing here replaces words.
    /// `timings`: the recognized words with their times (Parakeet on Core ML). With them and `options.paragraphs` on, a
    /// long dictation gets blank lines at the speaker's longer sentence-end pauses (Paragraphs). Off, or without timings
    /// (Whisper, C++), nothing changes.
    public static func format(_ raw: String, style: DictationStyle, keepAsWritten: [String] = [],
                              options: FormatOptions = FormatOptions(), timings: [TimedWord] = []) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        // Commands first, so "new line" becomes a line break before the cleanup looks at the words.
        if options.spokenCommands { text = applyCommands(text) }
        text = Cleanup.apply(text, level: options.cleanup, language: options.language, scorer: options.scorer)
        text = applyStyle(text, style, protected: keepAsWritten)
        // Paragraphs last, on the finished text: only spaces between sentences can become blank lines.
        let finished = tidy(text)
        return options.paragraphs ? Paragraphs.apply(finished, words: timings) : finished
    }

    static func applyCommands(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "(?i)[,.]?\\s*new paragraph[,.]?\\s*", with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)[,.]?\\s*new line[,.]?\\s*", with: "\n", options: .regularExpression)
        // "scratch that" removes the sentence or clause before it.
        while let range = t.range(of: "(?i)[,.]?\\s*scratch that[,.!]?", options: .regularExpression) {
            let before = t[..<range.lowerBound]
            let cut = before.lastIndex(where: { ".!?\n".contains($0) }).map { before.index(after: $0) } ?? before.startIndex
            t = String(t[..<cut]) + String(t[range.upperBound...])
        }
        return t
    }

    static func applyStyle(_ text: String, _ style: DictationStyle, protected: [String]) -> String {
        var t = text
        // Standalone "i" is always "I".
        t = t.replacingOccurrences(of: "(?<![\\w'])i(?=[\\s'.,!?]|$)", with: "I", options: .regularExpression)
        switch style {
        case .formal:
            t = capitaliseSentences(t)
            t = endSentence(t, with: ".")
        case .casual:
            t = capitaliseSentences(t)
            t = dropFinalPeriod(t)
        case .veryCasual:
            t = lowercaseSentenceStarts(t, protected: protected)
            t = dropFinalPeriod(t)
        case .excited:
            t = capitaliseSentences(t)
            t = dropFinalPeriod(t)
            if let last = t.last, !"!?".contains(last) { t += "!" }
        }
        return t
    }

    static func capitaliseSentences(_ text: String) -> String {
        var out = ""
        var capNext = true
        for ch in text {
            if capNext, ch.isLetter { out += ch.uppercased(); capNext = false; continue }
            out.append(ch)
            if ".!?\n".contains(ch) { capNext = true } else if !ch.isWhitespace && !"\"'(".contains(ch) { capNext = false }
        }
        return out
    }

    static func lowercaseSentenceStarts(_ text: String, protected: [String]) -> String {
        let keep = Set(protected.map { $0.lowercased() })
        var words = text.components(separatedBy: " ")
        for (i, w) in words.enumerated() {
            let core = w.trimmingCharacters(in: .punctuationCharacters)
            if core == "I" || core.hasPrefix("I'") || keep.contains(core.lowercased()) { continue }
            // Only lowercase words that are merely capitalised (keep acronyms such as NASA).
            if let f = core.first, f.isUppercase, core.dropFirst().allSatisfy({ !$0.isUppercase }) {
                words[i] = w.replacingOccurrences(of: core, with: core.lowercased())
            }
        }
        return words.joined(separator: " ")
    }

    static func endSentence(_ text: String, with mark: Character) -> String {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return text }
        return ".!?:;\n".contains(last) ? text : text + String(mark)
    }

    static func dropFinalPeriod(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast() }
        return t
    }

    static func tidy(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[,.;:]\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n ", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
