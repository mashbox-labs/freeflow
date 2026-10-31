import Foundation

/// Autocorrect for the Free Flow keyboard: the build 10 research "careful config" (FINDINGS section A), ported from
/// the Python prototype `ac_proto.py` rule for rule.
///
/// - A word is never touched when it is under 3 letters, has anything but the letters a-z/A-Z (digits, `@ . / _ - # : '`,
///   accents), has a capital after its first letter (camelCase, ALL CAPS), or starts with a capital mid-sentence.
/// - A word in the word list, or in the allow-list (contacts and text replacements from UILexicon, the Free Flow
///   Dictionary, words put back with delete), is never touched.
/// - Otherwise the candidates are the listed words within 1 edit (words of up to 4 letters) or 2 edits (Damerau OSA,
///   unit costs, as SymSpell's lookup). Each gets a weighted cost (substitution and insertion 1, leaving out one letter
///   of a double 0.5, swapping two neighbours 0.6, no key-distance weighting) and a score log-frequency - 3 x cost
///   (costs over 1.5 dropped). The best one replaces the word only when its log-frequency is at least -13 and its score
///   beats the runner-up by 5 or more; anything closer leaves the word alone.
public struct AutocorrectConfig: Equatable, Sendable {
    /// Weight of the edit cost against log-frequency (prototype `lam`).
    public var costWeight: Double
    /// Score lead the best candidate needs over the runner-up.
    public var margin: Double
    /// Candidates with a weighted cost above this are dropped (prototype `cmax`).
    public var maxCost: Double
    /// The best candidate's natural-log frequency must be at least this (prototype `minlp`).
    public var minLogFrequency: Double

    public init(costWeight: Double, margin: Double, maxCost: Double, minLogFrequency: Double) {
        self.costWeight = costWeight
        self.margin = margin
        self.maxCost = maxCost
        self.minLogFrequency = minLogFrequency
    }

    /// Chosen on the dev split only (b10/results/ac_tune_dev.json): weight 3, margin 5, max cost 1.5, min log-frequency
    /// -13, no spatial weighting (adj 1.0).
    public static let careful = AutocorrectConfig(costWeight: 3, margin: 5, maxCost: 1.5, minLogFrequency: -13)
}

/// What the engine decided for one word.
public enum AutocorrectOutcome: Equatable, Sendable {
    /// Leave the word as typed.
    case keep
    /// Replace the word with this (already capitalised like the typed word).
    case replace(String)
    /// The time limit ran out before every candidate was seen: leave the word as typed.
    case timedOut
}

/// The word list: lowercase a-z words with a natural-log frequency each, held as a trie in flat arrays
/// (first child / next sibling) so lookups and the edit-distance walk touch no Swift objects.
///
/// File format (UTF-8): one `word<TAB>logfreq` per line, words a-z only. Other lines are skipped. A word listed twice
/// keeps its highest value, as the prototype's merge did.
public final class AutocorrectLexicon: @unchecked Sendable {
    let label: [UInt8]
    let firstChild: [Int32]
    let nextSibling: [Int32]
    let wordIndex: [Int32]
    let logFrequency: [Double]
    /// Longest word, in letters.
    let maxLength: Int
    /// The most frequent word's log-frequency.
    public let maxLogFrequency: Double

    public var wordCount: Int { logFrequency.count }
    public var nodeCount: Int { label.count }
    /// Bytes held by the arrays (what the keyboard pays in memory for the list).
    public var memoryBytes: Int { label.count * (1 + 4 + 4 + 4) + logFrequency.count * 8 }

    /// Resource name the keyboard looks for (Bundle.main first, then FreeFlowKit's resources).
    public static let resourceName = "autocorrect-en"
    public static let resourceExtension = "tsv"

    /// The word list shipped in this build, if any.
    public static var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
            ?? Bundle.module.url(forResource: resourceName, withExtension: resourceExtension)
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Reads the file in place (no copy) in two passes when its words are in ascending order, as the shipped list is:
    /// the first counts the trie nodes so every array is allocated once at its final size, the second builds the trie.
    /// The load then leaves only the arrays behind (memoryBytes), with no per-word allocations for malloc to keep.
    /// A file out of order is parsed into entries and sorted first.
    public convenience init(data: Data) {
        let built: TrieBuilder? = data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            var nodes = 0, words = 0, ordered = true
            var previous = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
            AutocorrectLexicon.forEachLine(buf) { w, _ in
                if words > 0 {
                    if w.lexicographicallyPrecedes(previous) { ordered = false; return false }
                    if w.elementsEqual(previous) { return true }
                }
                nodes += w.count - AutocorrectLexicon.commonPrefix(w, previous)
                words += 1
                previous = w
                return true
            }
            guard ordered else { return nil }
            var b = TrieBuilder(nodes: nodes, words: words)
            AutocorrectLexicon.forEachLine(buf) { w, value in
                if let v = AutocorrectLexicon.parseValue(value) { b.add(w, v) }
                return true
            }
            return b
        }
        if let built {
            self.init(built: built)
        } else {
            self.init(entries: AutocorrectLexicon.entries(in: data))
        }
    }

    /// Words (a-z only; anything else is skipped) with their natural-log frequencies.
    public convenience init(words: [(String, Double)]) {
        self.init(entries: words.compactMap { w, v in
            let b = Array(w.utf8)
            return !b.isEmpty && b.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) ? (b, v) : nil
        })
    }

    convenience init(entries unsorted: [([UInt8], Double)]) {
        var inOrder = true
        for k in unsorted.indices.dropFirst() where unsorted[k].0.lexicographicallyPrecedes(unsorted[k - 1].0) {
            inOrder = false; break
        }
        let entries = inOrder ? unsorted : unsorted.sorted { a, b in a.0.lexicographicallyPrecedes(b.0) }
        var nodes = 0
        for k in entries.indices where k == 0 || entries[k].0 != entries[k - 1].0 {
            nodes += entries[k].0.count - (k == 0 ? 0 : zip(entries[k].0, entries[k - 1].0).prefix { $0 == $1 }.count)
        }
        var b = TrieBuilder(nodes: nodes, words: entries.count)
        for (w, v) in entries { w.withUnsafeBufferPointer { b.add($0, v) } }
        self.init(built: b)
    }

    private init(built b: TrieBuilder) {
        self.label = b.label
        self.firstChild = b.first
        self.nextSibling = b.next
        self.wordIndex = b.word
        self.logFrequency = b.freq
        self.maxLength = b.longest
        self.maxLogFrequency = b.freq.max() ?? 0
    }

    /// Every `word<TAB>value` line whose word is a-z only and whose value is not empty; `body` returns false to stop.
    static func forEachLine(_ buf: UnsafeBufferPointer<UInt8>,
                            _ body: (_ word: UnsafeBufferPointer<UInt8>, _ value: UnsafeBufferPointer<UInt8>) -> Bool) {
        let n = buf.count
        var i = 0
        while i < n {
            let start = i
            var tab = -1
            while i < n, buf[i] != 0x0A {
                if tab < 0, buf[i] == 0x09 { tab = i }
                i += 1
            }
            let end = i   // the newline, or the end of a last line that has none
            i += 1
            guard tab > start, end > tab + 1 else { continue }
            var ok = true
            for k in start..<tab where !(buf[k] >= 0x61 && buf[k] <= 0x7A) { ok = false; break }
            guard ok else { continue }
            if !body(UnsafeBufferPointer(rebasing: buf[start..<tab]), UnsafeBufferPointer(rebasing: buf[(tab + 1)..<end])) { return }
        }
    }

    /// Swift's Double(String) reads '.' as the decimal point in every locale and rounds correctly, so a value written
    /// with Python's repr comes back as the same double.
    static func parseValue(_ value: UnsafeBufferPointer<UInt8>) -> Double? {
        Double(String(decoding: value, as: UTF8.self))
    }

    /// The file's valid lines as entries, in file order (the path for a file that is not sorted).
    static func entries(in data: Data) -> [([UInt8], Double)] {
        var entries: [([UInt8], Double)] = []
        data.withUnsafeBytes { raw in
            forEachLine(raw.bindMemory(to: UInt8.self)) { w, value in
                if let v = parseValue(value) { entries.append((Array(w), v)) }
                return true
            }
        }
        return entries
    }

    static func commonPrefix(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        var k = 0
        while k < a.count, k < b.count, a[k] == b[k] { k += 1 }
        return k
    }

    /// Builds the flat trie from words in ascending byte order; a word listed twice keeps its highest value, as the
    /// prototype's merge did. Arrays are reserved once from the node and word counts.
    struct TrieBuilder {
        var label: [UInt8] = [0], first: [Int32] = [-1], next: [Int32] = [-1], word: [Int32] = [-1]
        private var lastChild: [Int32] = [-1]
        var freq: [Double] = []
        private var path: [Int32] = [0]
        private var previous: [UInt8] = []
        var longest = 0

        init(nodes: Int, words: Int) {
            label.reserveCapacity(nodes + 1); first.reserveCapacity(nodes + 1)
            next.reserveCapacity(nodes + 1); word.reserveCapacity(nodes + 1)
            lastChild.reserveCapacity(nodes + 1); freq.reserveCapacity(words)
            path.reserveCapacity(64); previous.reserveCapacity(64)
        }

        mutating func add(_ w: UnsafeBufferPointer<UInt8>, _ v: Double) {
            if !freq.isEmpty, w.elementsEqual(previous) {   // listed twice: keep the higher value
                freq[freq.count - 1] = max(freq[freq.count - 1], v)
                return
            }
            var common = 0
            while common < w.count, common < previous.count, w[common] == previous[common] { common += 1 }
            path.removeLast(path.count - 1 - common)
            for k in common..<w.count {
                let parent = Int(path[path.count - 1])
                let node = Int32(label.count)
                label.append(w[k]); first.append(-1); next.append(-1); word.append(-1); lastChild.append(-1)
                if first[parent] < 0 { first[parent] = node } else { next[Int(lastChild[parent])] = node }
                lastChild[parent] = node
                path.append(node)
            }
            word[Int(path[path.count - 1])] = Int32(freq.count)
            freq.append(v)
            longest = max(longest, w.count)
            previous.removeAll(keepingCapacity: true)
            previous.append(contentsOf: w)
        }
    }

    /// The node for this exact a-z word (or prefix), nil when absent.
    func node(_ w: UnsafeBufferPointer<UInt8>) -> Int32? {
        var node: Int32 = 0
        for ch in w {
            var c = firstChild[Int(node)]
            while c >= 0, label[Int(c)] != ch { c = nextSibling[Int(c)] }
            if c < 0 { return nil }
            node = c
        }
        return node
    }

    /// Natural-log frequency of a lowercase a-z word, nil when it is not in the list.
    public func logFrequency(of word: String) -> Double? {
        let b = Array(word.utf8)
        return b.withUnsafeBufferPointer { buf in
            guard let n = node(buf), wordIndex[Int(n)] >= 0 else { return nil }
            return logFrequency[Int(wordIndex[Int(n)])]
        }
    }

    public func contains(_ word: String) -> Bool { logFrequency(of: word) != nil }

    /// Every listed word within `maxDistance` Damerau OSA edits (unit costs) of `t`, `t` itself left out. nil when the
    /// deadline (DispatchTime uptime nanoseconds) passed first: the list is then incomplete and must not be used.
    func candidates(_ t: [UInt8], maxDistance md: Int, deadline: UInt64? = nil) -> [(word: [UInt8], index: Int32)]? {
        let m = t.count
        guard m > 0, m - md <= maxLength else { return [] }
        let width = m + 1
        let depthMax = maxLength + 1
        var rows = [Int32](repeating: 0, count: width * (depthMax + 1))
        var prefix = [UInt8](repeating: 0, count: depthMax + 1)
        var out: [(word: [UInt8], index: Int32)] = []
        var visited = 0
        var aborted = false
        let limit = Int32(md)
        for j in 0...m { rows[j] = Int32(j) }
        t.withUnsafeBufferPointer { tb in
            rows.withUnsafeMutableBufferPointer { R in
                prefix.withUnsafeMutableBufferPointer { P in
                    label.withUnsafeBufferPointer { L in
                        firstChild.withUnsafeBufferPointer { F in
                            nextSibling.withUnsafeBufferPointer { N in
                                wordIndex.withUnsafeBufferPointer { W in
                                    // Iterative depth-first walk: stack[d] = the child being tried at depth d (1-based).
                                    var stack = [Int32](repeating: -1, count: depthMax + 2)
                                    var d = 1
                                    stack[1] = F[0]
                                    while d >= 1 {
                                        let node = stack[d]
                                        if node < 0 { d -= 1; if d >= 1 { stack[d] = N[Int(stack[d])] }; continue }
                                        visited += 1
                                        if visited & 511 == 0, let dl = deadline, DispatchTime.now().uptimeNanoseconds > dl {
                                            aborted = true; return
                                        }
                                        let ch = L[Int(node)]
                                        P[d - 1] = ch
                                        let cur = d * width, prev = (d - 1) * width
                                        R[cur] = Int32(d)
                                        var rowMin = R[cur]
                                        if m > 0 {
                                            for j in 1...m {
                                                let cost: Int32 = tb[j - 1] == ch ? 0 : 1
                                                var v = R[prev + j - 1] + cost
                                                let del = R[prev + j] + 1
                                                if del < v { v = del }
                                                let ins = R[cur + j - 1] + 1
                                                if ins < v { v = ins }
                                                if d > 1, j > 1, ch == tb[j - 2], P[d - 2] == tb[j - 1] {
                                                    let tr = R[(d - 2) * width + j - 2] + 1
                                                    if tr < v { v = tr }
                                                }
                                                R[cur + j] = v
                                                if v < rowMin { rowMin = v }
                                            }
                                        }
                                        let wi = W[Int(node)]
                                        if wi >= 0, R[cur + m] <= limit {
                                            let w = Array(P[0..<d])
                                            if w != t { out.append((w, wi)) }
                                        }
                                        // Every deeper row is at least this row's minimum (also through a swap),
                                        // so a row over the limit ends this branch.
                                        if rowMin <= limit, d < depthMax, F[Int(node)] >= 0 {
                                            d += 1
                                            stack[d] = F[Int(node)]
                                        } else {
                                            stack[d] = N[Int(node)]
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return aborted ? nil : out
    }
}

/// Autocorrect decisions. Immutable and safe to use from any thread.
public final class AutocorrectEngine: @unchecked Sendable {
    public let lexicon: AutocorrectLexicon
    public let config: AutocorrectConfig
    /// Set: the build 12 typing rule (AutocorrectTyping.swift). nil: the build 10 careful rule (`config`).
    public let typing: TypingModel?

    public init(lexicon: AutocorrectLexicon, config: AutocorrectConfig = .careful, typing: TypingModel? = nil) {
        self.lexicon = lexicon
        self.config = config
        self.typing = typing
    }

    /// True when the word must never be touched by its shape alone: under 3 letters, anything but a-z/A-Z, a capital
    /// after the first letter, or a capital first letter mid-sentence.
    public static func isGuarded(_ token: String, sentenceInitial: Bool) -> Bool {
        var count = 0
        var first = true
        var firstUpper = false
        for s in token.unicodeScalars {
            let v = s.value
            let upper = v >= 0x41 && v <= 0x5A
            let lower = v >= 0x61 && v <= 0x7A
            if !upper && !lower { return true }
            if first { firstUpper = upper; first = false } else if upper { return true }
            count += 1
        }
        if count < 3 { return true }
        if firstUpper && !sentenceInitial { return true }
        return false
    }

    /// Weighted edit cost of typing `t` for the intended word `w` (prototype `wdl`, adj 1.0): substitution 1,
    /// inserting a letter 1, leaving out a letter 1 (0.5 when it is the second of a double), swapping neighbours 0.6.
    static func weightedCost(typed t: [UInt8], intended w: [UInt8]) -> Double {
        let n = w.count, m = t.count
        let width = m + 1
        var D = [Double](repeating: 0, count: (n + 1) * width)
        if n >= 1 {
            for i in 1...n { D[i * width] = D[(i - 1) * width] + (i > 1 && w[i - 1] == w[i - 2] ? 0.5 : 1.0) }
        }
        if m >= 1 {
            for j in 1...m { D[j] = D[j - 1] + 1.0 }
        }
        guard n >= 1, m >= 1 else { return D[n * width + m] }
        for i in 1...n {
            let om = i > 1 && w[i - 1] == w[i - 2] ? 0.5 : 1.0
            for j in 1...m {
                let sub = w[i - 1] == t[j - 1] ? 0.0 : 1.0
                var v = D[(i - 1) * width + j - 1] + sub
                let a = D[(i - 1) * width + j] + om
                if a < v { v = a }
                let b = D[i * width + j - 1] + 1.0
                if b < v { v = b }
                if i > 1, j > 1, w[i - 1] == t[j - 2], w[i - 2] == t[j - 1] {
                    let tr = D[(i - 2) * width + j - 2] + 0.6
                    if tr < v { v = tr }
                }
                D[i * width + j] = v
            }
        }
        return D[n * width + m]
    }

    /// Whether `token` even reaches the candidate search: not guarded, not listed, not allowed.
    public func needsLookup(_ token: String, sentenceInitial: Bool, isAllowed: (String) -> Bool = { _ in false }) -> Bool {
        if let typing { return needsLookupTyping(token, sentenceInitial: sentenceInitial, isAllowed: isAllowed, typing) }
        if Self.isGuarded(token, sentenceInitial: sentenceInitial) { return false }
        let t = token.lowercased()
        return !(lexicon.contains(t) || isAllowed(t))
    }

    /// The decision for one typed word. `deadline` is a DispatchTime uptime in nanoseconds; when it passes during the
    /// search the answer is `.timedOut` (treat as keep), never a guess from a partial candidate list.
    public func correct(_ token: String, sentenceInitial: Bool = false, isAllowed: (String) -> Bool = { _ in false },
                        deadline: UInt64? = nil) -> AutocorrectOutcome {
        if let typing { return correctTyping(token, sentenceInitial: sentenceInitial, isAllowed: isAllowed, deadline: deadline, typing) }
        if Self.isGuarded(token, sentenceInitial: sentenceInitial) { return .keep }
        let lower = token.lowercased()
        if lexicon.contains(lower) || isAllowed(lower) { return .keep }
        let t = Array(lower.utf8)
        let md = t.count <= 4 ? 1 : 2
        guard let cands = lexicon.candidates(t, maxDistance: md, deadline: deadline) else { return .timedOut }
        var scored: [(score: Double, word: [UInt8], cost: Double, lp: Double)] = []
        scored.reserveCapacity(cands.count)
        for c in cands {
            let k = Self.weightedCost(typed: t, intended: c.word)
            guard k <= config.maxCost else { continue }
            let lp = lexicon.logFrequency[Int(c.index)]
            scored.append((lp - config.costWeight * k, c.word, k, lp))
        }
        // The prototype sorts (score, word, cost) tuples high to low; the same order here.
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.word != b.word { return b.word.lexicographicallyPrecedes(a.word) }
            return a.cost > b.cost
        }
        guard let best = scored.first, best.lp >= config.minLogFrequency else { return .keep }
        if scored.count > 1, best.score - scored[1].score < config.margin { return .keep }
        var out = best.word
        if let f = token.utf8.first, f >= 0x41, f <= 0x5A { out[0] -= 0x20 }   // capitalised like the typed word
        return .replace(String(decoding: out, as: UTF8.self))
    }

    /// The word to type: the replacement, or the token unchanged.
    public func corrected(_ token: String, sentenceInitial: Bool = false, isAllowed: (String) -> Bool = { _ in false }) -> String {
        if case .replace(let r) = correct(token, sentenceInitial: sentenceInitial, isAllowed: isAllowed) { return r }
        return token
    }
}
