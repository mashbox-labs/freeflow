import Foundation

/// Build 12 autocorrect: the typing rule. For a typed word t, every listed word w within 1 edit (words of up to 4
/// letters) or 2 edits gets the score  log-frequency(w) - cost(t | w),  where cost is what it takes a thumb to turn w
/// into t, in nats: a substitution costs more the further apart the two keys are on the keyboard, a letter typed
/// twice, a dropped letter and two swapped neighbours each have their own cost. Keeping t is scored too: its own
/// log-frequency plus `knownBonus` when it is listed, `unknownLogFrequency` when it is not. The best score wins.
/// Words of 2 letters are looked at (build 10 skipped words under 3), never 1-letter candidates. Capitals after the
/// first letter, a capital first letter mid-sentence and anything but a-z/A-Z still leave the word alone, as do the
/// allow-list words (contacts, text replacements, the Free Flow Dictionary, words put back with delete).
/// No word is special-cased; the only inputs are the word list, the key positions and the costs below.
public struct TypingModel: Equatable, Sendable {
    /// Substitution: base + perPitch2 x (distance between the two key centres in key widths)^2.
    public var subBase: Double
    public var subPerPitch2: Double
    /// A letter typed that w does not have: the same letter twice, a key next to a neighbouring letter, any other.
    public var insertDouble: Double
    public var insertAdjacent: Double
    public var insert: Double
    /// A letter of w not typed: the second of a double, any other.
    public var deleteDouble: Double
    public var delete: Double
    /// Two neighbouring letters typed in the wrong order.
    public var swap: Double
    /// Keeping a listed typed word scores its log-frequency plus this.
    public var knownBonus: Double
    /// Keeping a typed word that is not listed scores this.
    public var unknownLogFrequency: Double
    /// Candidates rarer than this are never suggested.
    public var minLogFrequency: Double
    /// Candidates costing more than this are never suggested.
    public var maxCost: Double

    public init(subBase: Double, subPerPitch2: Double, insertDouble: Double, insertAdjacent: Double, insert: Double,
                deleteDouble: Double, delete: Double, swap: Double, knownBonus: Double, unknownLogFrequency: Double,
                minLogFrequency: Double, maxCost: Double) {
        self.subBase = subBase; self.subPerPitch2 = subPerPitch2
        self.insertDouble = insertDouble; self.insertAdjacent = insertAdjacent; self.insert = insert
        self.deleteDouble = deleteDouble; self.delete = delete; self.swap = swap
        self.knownBonus = knownBonus; self.unknownLogFrequency = unknownLogFrequency
        self.minLogFrequency = minLogFrequency; self.maxCost = maxCost
    }

    /// Chosen on the dev half only (AutocorrectTune12Tests, 4,050-point grid): most dev
    /// slips fixed (185/229) with 0 of 1,208 dev ordinary words changed and within build 10's preregistered limits on
    /// its dev must-stay words (16/1369 changed). minLogFrequency -16/-14/-12 tied in the printout; -16 kept.
    public static let build12 = TypingModel(subBase: 1.5, subPerPitch2: 1.0, insertDouble: 2.5, insertAdjacent: 3.5, insert: 7.0,
                                            deleteDouble: 1.0, delete: 3.5, swap: 2.5, knownBonus: 6,
                                            unknownLogFrequency: -13, minLogFrequency: -16, maxCost: 9)

    /// The cheapest single edit: no candidate can score above (most frequent word) - this.
    var cheapestEdit: Double {
        min(subBase + subPerPitch2 * TypingKeys.minPitch2, insertDouble, insertAdjacent, insert, deleteDouble, delete, swap)
    }
}

/// Letter key centres in key widths, from Apple's iPhone Air keyboard as measured (AppleKeyboardUITests.apple; Free
/// Flow's Comfort letters sit within 1 pt of them, testA1). Rows 56 pt apart, keys 41.33 pt apart.
enum TypingKeys {
    private static let pitch = 41.333
    private static let rows: [(y: Double, xs: [Double], letters: String)] = [
        (641.5, [24.17, 65.33, 106.67, 148.0, 189.33, 230.67, 272.0, 313.33, 354.67, 396.0], "qwertyuiop"),
        (697.5, [44.67, 86.0, 127.33, 168.67, 210.0, 251.33, 292.67, 334.0, 375.33], "asdfghjkl"),
        (753.5, [86.0, 127.33, 168.67, 210.0, 251.33, 292.67, 334.0], "zxcvbnm"),
    ]
    /// Squared distance between letter keys a-z (index = letter - 'a'), in key widths.
    static let pitch2: [Double] = {
        var c = [(Double, Double)](repeating: (0, 0), count: 26)
        for r in rows {
            for (x, l) in zip(r.xs, r.letters.utf8) { c[Int(l) - 0x61] = (x / pitch, r.y / pitch) }
        }
        var d = [Double](repeating: 0, count: 26 * 26)
        for i in 0..<26 { for j in 0..<26 { d[i * 26 + j] = pow(c[i].0 - c[j].0, 2) + pow(c[i].1 - c[j].1, 2) } }
        return d
    }()
    static let minPitch2: Double = pitch2.enumerated().filter { $0.offset % 27 != 0 }.map(\.element).min() ?? 1
    @inline(__always) static func distance2(_ a: UInt8, _ b: UInt8) -> Double {
        guard a >= 0x61, a <= 0x7A, b >= 0x61, b <= 0x7A else { return 25 }
        return pitch2[Int(a - 0x61) * 26 + Int(b - 0x61)]
    }
    /// Neighbouring keys: centres within 1.5 key widths (the same row next door, the row above or below beside it).
    @inline(__always) static func adjacent(_ a: UInt8, _ b: UInt8) -> Bool { a != b && distance2(a, b) <= 2.25 }
}

extension AutocorrectEngine {
    /// Cost in nats of typing `t` when `w` was meant (weighted Damerau OSA under the typing model).
    static func typingCost(typed t: [UInt8], intended w: [UInt8], _ m: TypingModel) -> Double {
        let n = w.count, k = t.count, width = k + 1
        var D = [Double](repeating: 0, count: (n + 1) * width)
        func ins(_ j: Int) -> Double {   // the typed letter t[j-1] is extra
            let x = t[j - 1]
            if j > 1, t[j - 2] == x { return m.insertDouble }
            if (j > 1 && TypingKeys.adjacent(t[j - 2], x)) || (j < k && TypingKeys.adjacent(t[j], x)) { return m.insertAdjacent }
            return m.insert
        }
        func del(_ i: Int) -> Double { i > 1 && w[i - 1] == w[i - 2] ? m.deleteDouble : m.delete }
        if n >= 1 { for i in 1...n { D[i * width] = D[(i - 1) * width] + del(i) } }
        if k >= 1 { for j in 1...k { D[j] = D[j - 1] + ins(j) } }
        guard n >= 1, k >= 1 else { return D[n * width + k] }
        for i in 1...n {
            for j in 1...k {
                let a = w[i - 1], b = t[j - 1]
                var v = D[(i - 1) * width + j - 1] + (a == b ? 0 : m.subBase + m.subPerPitch2 * TypingKeys.distance2(a, b))
                let dv = D[(i - 1) * width + j] + del(i)
                if dv < v { v = dv }
                let iv = D[i * width + j - 1] + ins(j)
                if iv < v { v = iv }
                if i > 1, j > 1, a == t[j - 2], w[i - 2] == b, a != b {
                    let sv = D[(i - 2) * width + j - 2] + m.swap
                    if sv < v { v = sv }
                }
                D[i * width + j] = v
            }
        }
        return D[n * width + k]
    }

    /// The typing rule's shape guard: 1 letter, anything but a-z/A-Z, a capital after the first letter, or a capital
    /// first letter mid-sentence.
    static func isGuardedTyping(_ token: String, sentenceInitial: Bool) -> Bool {
        var count = 0, first = true, firstUpper = false
        for s in token.unicodeScalars {
            let v = s.value
            let upper = v >= 0x41 && v <= 0x5A, lower = v >= 0x61 && v <= 0x7A
            if !upper && !lower { return true }
            if first { firstUpper = upper; first = false } else if upper { return true }
            count += 1
        }
        return count < 2 || (firstUpper && !sentenceInitial)
    }

    /// Typing rule: whether the word is worth a candidate search at all.
    func needsLookupTyping(_ token: String, sentenceInitial: Bool, isAllowed: (String) -> Bool, _ m: TypingModel) -> Bool {
        if Self.isGuardedTyping(token, sentenceInitial: sentenceInitial) { return false }
        let t = token.lowercased()
        if isAllowed(t) { return false }
        if let lp = lexicon.logFrequency(of: t), lp + m.knownBonus >= lexicon.maxLogFrequency - m.cheapestEdit { return false }
        return true
    }

    func correctTyping(_ token: String, sentenceInitial: Bool, isAllowed: (String) -> Bool, deadline: UInt64?,
                       _ m: TypingModel) -> AutocorrectOutcome {
        guard needsLookupTyping(token, sentenceInitial: sentenceInitial, isAllowed: isAllowed, m) else { return .keep }
        let lower = token.lowercased()
        let t = Array(lower.utf8)
        let keep = keepScore(lower, m)
        guard let cands = lexicon.candidates(t, maxDistance: t.count <= 4 ? 1 : 2, deadline: deadline) else { return .timedOut }
        let scored = cands.map { (word: $0.word, logFrequency: lexicon.logFrequency[Int($0.index)]) }
        let best = Self.decideTyping(typed: t, keep: keep, candidates: scored, m)
        guard var out = best else { return .keep }
        if let f = token.utf8.first, f >= 0x41, f <= 0x5A { out[0] -= 0x20 }
        return .replace(String(decoding: out, as: UTF8.self))
    }

    /// The decision: the best-scoring candidate when it beats keeping the word (`keep`), else nil. Ties go to the
    /// alphabetically first word.
    static func decideTyping(typed t: [UInt8], keep: Double, candidates: [(word: [UInt8], logFrequency: Double)],
                             _ m: TypingModel) -> [UInt8]? {
        var best: [UInt8]? = nil
        var bestScore = -Double.infinity
        for c in candidates where c.word.count >= 2 && c.logFrequency >= m.minLogFrequency {
            let cost = typingCost(typed: t, intended: c.word, m)
            guard cost <= m.maxCost else { continue }
            let s = c.logFrequency - cost
            if s > bestScore || (s == bestScore && best.map { c.word.lexicographicallyPrecedes($0) } == true) {
                bestScore = s; best = c.word
            }
        }
        return bestScore > keep ? best : nil
    }

    /// Keeping the typed word scores this (lowercase a-z).
    func keepScore(_ lower: String, _ m: TypingModel) -> Double {
        lexicon.logFrequency(of: lower).map { $0 + m.knownBonus } ?? m.unknownLogFrequency
    }
}
