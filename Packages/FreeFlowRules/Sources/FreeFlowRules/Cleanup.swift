import FreeFlowKit
import Foundation
import NaturalLanguage

/// How much Free Flow changes your words. The style (Formal, Casual...) sets only the look; the cleanup
/// level sets which words stay. Every style works with every level.
public enum CleanupLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case verbatim, clean, polished
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .polished: return "Polished"
        }
    }
    public var summary: String {
        switch self {
        case .verbatim: return "Every word as heard, stutters included."
        case .clean: return "Drops stutters, repeats, um and uh, and the words you corrected. Never adds or changes a word."
        case .polished: return "Clean, and drops filler phrases such as \"you know\" and \"like\"."
        }
    }
    /// The sentence the settings preview runs through the real cleaner at each level.
    public static let sample = "So, I'm, I'm thinking we, um, we meet at 5, no wait, 6 and, you know, go from there."
}

/// One word of dictated text with the punctuation around it.
struct Token: Equatable {
    var lead: String      // opening quotes or brackets
    var core: String      // the word as written
    var trail: String     // punctuation after it
    var key: String       // lowercased, straight apostrophes, no cut-off hyphen
    var isFragment: Bool  // a cut-off word such as "th-"

    var endsSentence: Bool { trail.contains { ".!?".contains($0) } }
    var text: String { lead + core + trail }
}

enum Tokenizer {
    static let leadSet = Set("\"“‘([{")
    static let trailSet = Set(".,!?;:\"”’)]}…")

    static func split(_ line: String) -> [Token] {
        var out: [Token] = []
        for piece in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            var s = Substring(piece)
            var lead = "", trail = ""
            while let f = s.first, leadSet.contains(f) { lead.append(f); s = s.dropFirst() }
            while let l = s.last, trailSet.contains(l) { trail.insert(l, at: trail.startIndex); s = s.dropLast() }
            var core = String(s)
            let isFragment = core.count > 1 && core.hasSuffix("-") && !core.hasSuffix("--")
            if core.isEmpty || core.allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                // Punctuation on its own ("--", "-"): keep it on the word before.
                if !out.isEmpty { out[out.count - 1].trail += " " + lead + core + trail; continue }
                core = lead + core + trail; lead = ""; trail = ""
            }
            var key = core.lowercased().replacingOccurrences(of: "’", with: "'")
            if isFragment { key.removeLast() }
            out.append(Token(lead: lead, core: core, trail: trail, key: key, isFragment: isFragment))
        }
        return out
    }

    static func join(_ tokens: [Token]) -> String { tokens.map(\.text).joined(separator: " ") }
}

/// The deterministic cleanup rules. Pure, instant, on-device. At the Clean level they only delete words
/// (stutters, immediate repeats, filler sounds, words the speaker explicitly corrected) and fix the commas
/// around what they deleted. They never add, change or reorder a word.
public enum Cleanup {
    /// `language` is a language code such as "en" or "pt" when the caller knows it; nil detects it on-device.
    public static func apply(_ text: String, level: CleanupLevel, language: String? = nil, scorer: DisfluencyScorer? = nil) -> String {
        guard level != .verbatim else { return text }
        let english = usesEnglishRules(text, language: language)
        return text.components(separatedBy: "\n").map { line in
            var t = Tokenizer.split(line)
            dropFragments(&t)
            guard english else {
                // The word lists below are English: "um" is a word in Portuguese, "er" in German, and
                // "nous nous" is grammatical French. Other languages get only cut-off words and a word said
                // three or more times in a row.
                dropRuns(&t)
                return Tokenizer.join(t)
            }
            // The tagger reads the words as spoken (before any rule) and removes only what it is very sure of,
            // mostly abandoned starts the rules cannot see; the rules then do repeats, fillers and cued corrections.
            if let scorer { applyTagger(&t, scorer, level) }
            dropRepeats(&t)
            dropFillers(&t)
            dropRepeats(&t)
            applyCorrections(&t)
            dropRepeats(&t)
            if level == .polished { dropDiscourseMarkers(&t) }
            return Tokenizer.join(t)
        }.joined(separator: "\n")
    }

    /// True when the English word lists may run: the text reads as English, or the on-device guess is
    /// unsure and the device language is English.
    public static func usesEnglishRules(_ text: String, language: String? = nil) -> Bool {
        if let language { return language.lowercased().hasPrefix("en") }
        // Judge the language on the words only: filler sounds ("um", "uh") would pull the guess away from English.
        let words = Tokenizer.split(text.replacingOccurrences(of: "\n", with: " ")).filter { !fillers.contains($0.key) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words.map(\.core).joined(separator: " "))
        if let (top, p) = recognizer.languageHypotheses(withMaximum: 1).first {
            if top == .english { return true }
            if p >= 0.6 { return false }
        }
        return (Locale.current.language.languageCode?.identifier ?? "en") == "en"
    }

    /// Words said three or more times on purpose in many languages ("no no no", "ja ja ja", "ha ha ha").
    static let meantRuns: Set<String> = ["no", "non", "nein", "nee", "ne", "nie", "ja", "jo", "si", "sí", "oui", "da", "ok", "okay",
                                         "ha", "haha", "he", "hi", "la", "na", "yes", "yeah", "bye"]

    /// Any language: one word said three or more times in a row ("je je je pense") keeps one copy.
    static func dropRuns(_ t: inout [Token]) {
        var i = 0
        while i < t.count {
            let key = t[i].key
            var j = i + 1
            while j < t.count, t[j].key == key, !t[j - 1].endsSentence { j += 1 }
            if j - i >= 3, !key.isEmpty, !key.contains(where: \.isNumber), !meantRuns.contains(key) { removeRange(&t, i, j - 1) }
            i += 1
        }
    }

    // MARK: Word lists

    /// Sounds, not words. "uh-huh" and "mm-hmm" mean yes and are kept.
    static let fillers: Set<String> = ["um", "umm", "ummm", "uhm", "uh", "uhh", "uhhh", "er", "erm", "err", "hmm", "hm", "hmmm", "mm", "mmm"]
    /// Words a comma almost never follows; a comma left between one of these and a removed filler goes too.
    static let noPause: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "from", "by", "my", "your", "his",
                                       "her", "its", "our", "their", "this", "is", "was", "are", "were", "be", "been", "am", "have", "has",
                                       "had", "will", "would", "can", "could", "should", "do", "does", "did", "i", "we", "you", "they",
                                       "he", "she", "not", "very", "really", "and", "or", "but", "because", "if", "than", "as", "about",
                                       "into", "i'm", "we're", "you're", "they're", "it's", "there's", "that's", "some", "any", "more"]
    /// Words people double on purpose ("very very", "bye bye", "no no").
    static let meantDoubles: Set<String> = ["very", "really", "so", "much", "many", "far", "long", "way", "no", "yes", "yeah", "yep",
                                            "nope", "bye", "ha", "haha", "hey", "go", "knock", "blah", "bla", "la", "na", "ho", "oh",
                                            "ah", "now", "there", "well", "more", "again", "same", "tick", "choo", "chop", "tut", "boo",
                                            "pretty", "super", "too", "hip", "wow", "yay", "please", "come", "over", "on", "night",
                                            "little", "big", "bigger", "better", "faster", "harder", "louder", "closer", "ever", "uh-huh",
                                            "mm-hmm", "bang", "quick", "slowly", "round", "hush", "ding", "dong", "boom", "beep", "tsk"]
    /// Grammatical doubles ("I know that that works", "had had"): removed only after a pause mark.
    static let pauseOnlyDoubles: Set<String> = ["that", "had", "is", "do", "does", "did", "was"]
    static let numberWords: Set<String> = ["zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                           "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                                           "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
                                           "hundred", "thousand", "million", "billion", "noon", "midnight", "half", "quarter"]
    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
                                        "tonight", "yesterday"]
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                                      "november", "december"]
    static let whWords: Set<String> = ["what", "who", "whom", "whose", "which", "when", "where", "why", "how"]
    static let colours: Set<String> = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "black", "white", "grey", "gray",
                                       "brown", "silver", "gold"]
    /// Short phrases between two copies of a repeat or before a correction: "the, you know, the".
    static let interregna: [[String]] = [["you", "know"], ["i", "mean"], ["like"], ["sorry"], ["well"], ["or"]]

    struct Cue { let words: [String]; let strong: Bool }
    /// Self-correction cues, longest first. Strong cues signal a correction almost always; weak ones only
    /// when the repair matches a word just before them (same word, or same kind: a number, a day, a name).
    static let cues: [Cue] = [
        Cue(words: ["no", "no", "wait"], strong: true), Cue(words: ["sorry", "i", "mean"], strong: true),
        Cue(words: ["no", "i", "mean"], strong: true), Cue(words: ["no", "make", "that"], strong: true),
        Cue(words: ["no", "wait"], strong: true), Cue(words: ["wait", "no"], strong: true), Cue(words: ["oh", "wait"], strong: true),
        Cue(words: ["or", "wait"], strong: true), Cue(words: ["no", "sorry"], strong: true), Cue(words: ["sorry", "no"], strong: true),
        Cue(words: ["or", "sorry"], strong: true), Cue(words: ["or", "rather"], strong: true), Cue(words: ["make", "that"], strong: false),
        Cue(words: ["actually", "no"], strong: true), Cue(words: ["no", "actually"], strong: true), Cue(words: ["or", "no"], strong: true),
        Cue(words: ["i", "mean"], strong: false), Cue(words: ["sorry"], strong: false), Cue(words: ["wait"], strong: false),
        Cue(words: ["no"], strong: false), Cue(words: ["rather"], strong: false),
    ]
    static let notCueAfterNo: Set<String> = ["one", "way", "idea", "problem", "matter", "longer", "more", "less", "doubt", "thanks",
                                             "worries", "need", "big", "time", "chance", "reason", "sense", "point", "clue", "other", "body"]
    static let notCueBeforeSorry: Set<String> = ["i'm", "im", "am", "so", "very", "really", "be", "feel", "felt", "was", "were", "is", "are",
                                                 "say", "said", "sound", "sounds", "look", "looks", "too", "how", "i", "we're", "you're",
                                                 "they're", "he's", "she's", "not", "being", "terribly", "truly", "awfully", "we", "they"]
    static let notCueAfterSorry: Set<String> = ["for", "about", "to", "that", "if", "but"]
    static let notCueBeforeWait: Set<String> = ["can't", "cannot", "to", "will", "would", "please", "just", "i'll", "we'll", "gonna",
                                                "not", "don't", "didn't", "won't", "couldn't", "could", "should", "must", "and", "i", "we",
                                                "you", "they", "let's", "lets"]
    static let notCueAfterWait: Set<String> = ["for", "to", "a", "until", "till", "up", "here", "there", "and", "outside", "in", "on",
                                               "your", "my", "his", "her", "their", "our", "it", "until"]

    // MARK: Tagger

    /// Deletes the words the on-device tagger marks as disfluent with high confidence (abandoned or corrected words,
    /// filler sounds, editing terms; at Polished also discourse markers). Runs before the rules. Delete-only: it never adds, changes or reorders a word,
    /// and it never empties a line. English only (it was trained on English).
    static func applyTagger(_ t: inout [Token], _ scorer: DisfluencyScorer, _ level: CleanupLevel) {
        guard !t.isEmpty, let s = scorer.scores(words: t.map(\.text)), s.count == t.count else { return }
        let classes = level == .polished ? ["R", "F", "E", "D"] : ["R", "F", "E"]
        let threshold = scorer.threshold(for: level)
        let drop = s.indices.filter { i in classes.reduce(Float(0)) { $0 + (s[i][$1] ?? 0) } >= threshold }
        guard !drop.isEmpty, drop.count < t.count else { return }
        for i in drop.reversed() { remove(&t, at: i) }
    }

    // MARK: Rules

    static func isFiller(_ t: Token) -> Bool {
        fillers.contains(t.key) && !(t.core.count > 1 && t.core == t.core.uppercased() && t.key == "er")
    }

    /// Removes the token at index i, keeping sentence-final punctuation and dropping commas that only framed it.
    static func remove(_ t: inout [Token], at i: Int) {
        let gone = t[i]
        if i > 0 {
            if gone.endsSentence, !t[i - 1].endsSentence {
                let mark = gone.trail.filter { ".!?".contains($0) }
                t[i - 1].trail = t[i - 1].trail.replacingOccurrences(of: ",", with: "") + mark
            } else if t[i - 1].trail == ",", noPause.contains(t[i - 1].key) {
                t[i - 1].trail = ""
            }
        }
        if !gone.lead.isEmpty, i + 1 < t.count { t[i + 1].lead = gone.lead + t[i + 1].lead }
        t.remove(at: i)
    }

    /// Removes t[from..<to] (a reparandum and its cue), moving any opening quote forward.
    static func removeRange(_ t: inout [Token], _ from: Int, _ to: Int) {
        let lead = t[from].lead
        t.removeSubrange(from..<to)
        if !lead.isEmpty, from < t.count { t[from].lead = lead + t[from].lead }
    }

    static func dropFragments(_ t: inout [Token]) {
        var i = 0
        while i + 1 < t.count {
            if t[i].isFragment, !t[i].key.isEmpty, t[i + 1].key.hasPrefix(t[i].key) { remove(&t, at: i) } else { i += 1 }
        }
    }

    static func dropFillers(_ t: inout [Token]) {
        var i = 0
        while i < t.count { if isFiller(t[i]) { remove(&t, at: i) } else { i += 1 } }
    }

    static func sentenceStart(_ t: [Token], _ i: Int) -> Bool { i == 0 || t[i - 1].endsSentence }

    static func isNumberish(_ key: String) -> Bool { key.contains(where: \.isNumber) || numberWords.contains(key) }

    static func isNameLike(_ t: [Token], _ i: Int) -> Bool {
        guard let f = t[i].core.first, f.isUppercase else { return false }
        return t[i].key != "i" && !t[i].key.hasPrefix("i'") && !sentenceStart(t, i)
    }

    static func canCollapse(_ t: [Token], first i: Int, length n: Int, second j: Int) -> Bool {
        // "Thank you. Thank you." is meant; "they. they went" (a stuttered function word) is not.
        if t[j - 1].endsSentence && !(n == 1 && j == i + 1 && noPause.contains(t[i].key) && !meantDoubles.contains(t[i].key)) { return false }
        for k in 0..<n {
            let key = t[i + k].key
            if key.isEmpty || isNumberish(key) { return false }
        }
        if (0..<n).allSatisfy({ meantDoubles.contains(t[i + $0].key) }) { return false }
        if n == 1, isNameLike(t, i), isNameLike(t, j), !t[i].trail.contains(",") { return false }  // "Walla Walla", "New York, New York"
        // "and so on and so on", "tries and tries": a coordinated repeat is meant unless a pause comma splits it.
        if n > 1, ["and", "or"].contains(t[i].key) || ["and", "or"].contains(t[i + n - 1].key), !t[i + n - 1].trail.contains(",") { return false }
        if n == 1 {
            let key = t[i].key
            if key.count == 1 && key != "a" && key != "i" { return false }  // spelled letters: "C N N"
            if pauseOnlyDoubles.contains(key) {
                let paused = t[i].trail.contains(where: { ",-…".contains($0) }) || j > i + 1
                if !paused { return false }
            }
        }
        return true
    }

    /// The gap between two copies: filler sounds and editing phrases only ("uh", "you know", "uh, well").
    static func isInterregnum(_ t: [Token], _ from: Int, _ to: Int) -> Bool {
        if t[to - 1].endsSentence { return false }
        var k = from
        while k < to {
            if isFiller(t[k]) { k += 1; continue }
            guard let p = interregna.first(where: { k + $0.count <= to && t[k..<(k + $0.count)].map(\.key) == $0 }) else { return false }
            k += p.count
        }
        return true
    }
    static func hasFiller(_ t: [Token], _ from: Int, _ to: Int) -> Bool { t[from..<to].contains(where: isFiller) }

    static func dropRepeats(_ t: inout [Token]) {
        var i = 0
        while i < t.count {
            var removed = false
            outer: for n in stride(from: min(5, (t.count - i) / 2), through: 1, by: -1) {
                for gap in 0...3 {
                    let j = i + n + gap
                    guard j + n <= t.count else { continue }
                    // A one-word interregnum ("the, sorry, the") needs the pause comma; "I'm sorry I'm late" is meant.
                    if gap > 0 {
                        guard isInterregnum(t, i + n, j) else { continue }
                        // A one-word editing term ("the, sorry, the") needs a pause mark; "I'm sorry I'm late" is meant.
                        if gap == 1 && !hasFiller(t, i + n, j) && !t[i + n - 1].trail.contains(",") { continue }
                    }
                    guard (0..<n).allSatisfy({ t[i + $0].key == t[j + $0].key }) else { continue }
                    guard canCollapse(t, first: i, length: n, second: j) else { continue }
                    removeRange(&t, i, j)
                    removed = true
                    break outer
                }
            }
            if !removed { i += 1 }
        }
    }

    enum Kind { case number, day, month, wh, colour, name }
    static func kind(_ t: [Token], _ i: Int) -> Kind? {
        let key = t[i].key
        if isNumberish(key) { return .number }
        if weekdays.contains(key) { return .day }
        if months.contains(key) { return .month }
        if whWords.contains(key) { return .wh }
        if colours.contains(key) { return .colour }
        if isNameLike(t, i) { return .name }
        return nil
    }

    static func cueApplies(_ cue: Cue, _ t: [Token], at i: Int) -> Bool {
        let n = cue.words.count
        guard i > 0, i + n < t.count else { return false }
        guard (0..<n).allSatisfy({ t[i + $0].key == cue.words[$0] }) else { return false }
        let prev = t[i - 1].key, next = t[i + n].key
        switch cue.words {
        case ["no"]: return !notCueAfterNo.contains(next) && !t[i - 1].endsSentence
        case ["sorry"]: return !notCueBeforeSorry.contains(prev) && !notCueAfterSorry.contains(next)
        case ["wait"]: return !notCueBeforeWait.contains(prev) && !notCueAfterWait.contains(next)
        case ["rather"]: return !["would", "i'd", "we'd", "you'd", "they'd", "he'd", "she'd", "had"].contains(prev) && next != "than"
        case ["i", "mean"]: return !t[i - 1].endsSentence && !["what", "you", "do", "i"].contains(next)
        default: return true
        }
    }

    /// Weak cues that read as corrections from their surroundings: ", sorry," set off by commas mid-sentence,
    /// and "I mean" straight after a word with no pause ("the projects I mean the costs").
    static func promoted(_ cue: Cue, _ t: [Token], at i: Int) -> Bool {
        let n = cue.words.count
        if cue.words == ["sorry"] { return t[i - 1].trail == "," && t[i].trail == "," }
        if cue.words == ["i", "mean"] {
            return t[i - 1].trail.isEmpty && !noPause.contains(t[i - 1].key) && !["what", "know", "that's", "you"].contains(t[i - 1].key)
                && t[i + n - 1].trail.isEmpty && !["is", "by", "it", "that", "to", "what", "you", "i", "we", "they", "he", "she"].contains(t[i + n].key)
        }
        return false
    }

    /// "at 5, no wait, 6" -> "at 6". The repair's first word is matched to a word just before the cue
    /// (the same word, or the same kind); everything from there to the end of the cue goes.
    static func applyCorrections(_ t: inout [Token]) {
        var i = 1
        while i < t.count {
            guard let cue = cues.first(where: { cueApplies($0, t, at: i) }) else { i += 1; continue }
            let r = i + cue.words.count
            if cue.words.contains(t[r].key) { i += 1; continue }  // "no no no" is not a correction
            let strong = cue.strong || promoted(cue, t, at: i)
            let maxBack = strong ? 6 : 4
            var start: Int?
            var j = i - 1
            while j >= max(0, i - maxBack) {
                if j < i - 1 && t[j].endsSentence { break }
                if t[j].key == t[r].key || (kind(t, j) != nil && kind(t, j) == kind(t, r)) { start = j; break }
                j -= 1
            }
            // No match, no deletion: build 11 then deleted the word before a strong cue anyway, so "Oh shit, sorry, I'm
            // late" lost "shit" and "sorry" (10-30). A word goes only when the new words match what they replace.
            guard let s = start else { i += 1; continue }
            removeRange(&t, s, r)
            i = max(1, s)
        }
    }

    /// Polished only: "you know", "I mean", "like" and sentence-opening "so" or "well" when set off by commas.
    static func dropDiscourseMarkers(_ t: inout [Token]) {
        let phrases: [[String]] = [["you", "know"], ["i", "mean"], ["like"], ["so"], ["well"], ["oh"], ["basically"], ["okay", "so"]]
        var i = 0
        while i < t.count {
            var hit = false
            for p in phrases {
                let end = i + p.count
                guard end <= t.count, t[i..<end].map(\.key) == p else { continue }
                let opening = sentenceStart(t, i)
                let commaAfter = t[end - 1].trail == "," || (end == t.count) || t[end - 1].endsSentence
                let commaBefore = i > 0 && t[i - 1].trail.hasSuffix(",")
                let sentenceOnly = p == ["so"] || p == ["well"] || p == ["okay", "so"] || p == ["basically"]
                guard commaAfter, opening || (commaBefore && !sentenceOnly), end < t.count || !opening else { continue }
                if p == ["like"], !opening, !commaBefore { continue }
                let mark = t[end - 1].endsSentence ? t[end - 1].trail.filter { ".!?".contains($0) } : ""
                let lead = t[i].lead
                t.removeSubrange(i..<end)
                if i > 0 {
                    if !mark.isEmpty { t[i - 1].trail = t[i - 1].trail.replacingOccurrences(of: ",", with: "") + mark }
                    else if noPause.contains(t[i - 1].key) { t[i - 1].trail = t[i - 1].trail.replacingOccurrences(of: ",", with: "") }
                }
                if !lead.isEmpty, i < t.count { t[i].lead = lead + t[i].lead }
                hit = true
                break
            }
            if !hit { i += 1 }
        }
    }
}
