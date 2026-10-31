import XCTest
@testable import FreeFlowKit

/// Autocorrect rules on small hand-made word lists (no outside data). The held-out re-score and the timing are in
/// AutocorrectHeldoutTests and AutocorrectTimingTests.
final class AutocorrectTests: XCTestCase {
    /// Made-up frequencies (natural log), chosen only to exercise the rules.
    private func engine(_ words: [(String, Double)]) -> AutocorrectEngine {
        AutocorrectEngine(lexicon: AutocorrectLexicon(words: words))
    }

    private let small: [(String, Double)] = [
        ("the", -3.0), ("tea", -10.0), ("tomorrow", -9.0), ("receive", -10.0), ("i", -4.0), ("saw", -8.0),
        ("files", -10.0), ("cat", -9.0), ("cut", -9.2), ("rare", -14.0), ("weird", -10.0), ("wired", -10.2),
    ]

    func testGuardsMatchThePrototype() {
        let g = AutocorrectEngine.isGuarded
        XCTAssertTrue(g("ok", false))            // under 3 letters
        XCTAssertTrue(g("a1b", false))           // digit
        for t in ["foo.bar", "it's", "a_b", "a-b", "#tag", "a:b", "x/y", "me@x", "café"] { XCTAssertTrue(g(t, false), t) }
        XCTAssertTrue(g("getUserById", false))   // camelCase
        XCTAssertTrue(g("NASA", false))          // ALL CAPS
        XCTAssertTrue(g("Jaxon", false))         // capital mid-sentence
        XCTAssertFalse(g("Jaxon", true))         // sentence start
        XCTAssertFalse(g("teh", false))
    }

    func testWeightedCost() {
        func k(_ t: String, _ w: String) -> Double { AutocorrectEngine.weightedCost(typed: Array(t.utf8), intended: Array(w.utf8)) }
        XCTAssertEqual(k("teh", "the"), 0.6, accuracy: 1e-12)          // swap
        XCTAssertEqual(k("tomorow", "tomorrow"), 0.5, accuracy: 1e-12) // one letter of a double left out
        XCTAssertEqual(k("recieve", "receive"), 0.6, accuracy: 1e-12)
        XCTAssertEqual(k("abd", "abc"), 1.0, accuracy: 1e-12)          // substitution
        XCTAssertEqual(k("thhe", "the"), 1.0, accuracy: 1e-12)         // insertion (no spatial discount)
        XCTAssertEqual(k("abc", "abc"), 0.0)
        XCTAssertEqual(k("", "ab"), 2.0)
    }

    /// The trie walk must return exactly the words within the edit limit (unit-cost Damerau OSA), checked against a
    /// plain dynamic program over every word, on dense random lists where neighbours are common.
    func testCandidatesEqualBruteForceOSA() {
        var rng = SplitMix(seed: 20261030)
        let alphabet = Array("abcd".utf8)
        var words = Set<[UInt8]>()
        while words.count < 1500 {
            let n = 1 + Int(rng.next() % 8)
            words.insert((0..<n).map { _ in alphabet[Int(rng.next() % 4)] })
        }
        let list = Array(words)
        let lex = AutocorrectLexicon(entries: list.map { ($0, -5.0) })
        XCTAssertEqual(lex.wordCount, list.count)
        for _ in 0..<150 {
            let n = 1 + Int(rng.next() % 9)
            let q = (0..<n).map { _ in alphabet[Int(rng.next() % 4)] }
            for md in 1...2 {
                let got = Set(lex.candidates(q, maxDistance: md)!.map { $0.word })
                let want = Set(list.filter { $0 != q && osa($0, q) <= md })
                XCTAssertEqual(got, want, "query \(String(decoding: q, as: UTF8.self)) md \(md)")
            }
        }
    }

    func testMarginFrequencyFloorAndCapitals() {
        let e = engine(small)
        XCTAssertEqual(e.correct("teh"), .replace("the"))
        XCTAssertEqual(e.correct("Teh", sentenceInitial: true), .replace("The"))
        XCTAssertEqual(e.correct("Teh"), .keep)                      // capital mid-sentence: guarded
        XCTAssertEqual(e.correct("tomorow"), .replace("tomorrow"))
        XCTAssertEqual(e.correct("wierd"), .keep)                    // weird vs wired: too close to call
        XCTAssertEqual(e.correct("rarw"), .keep)                     // only candidate under the -13 floor
        XCTAssertEqual(e.correct("cxt"), .keep)                      // cat vs cut within the margin
        XCTAssertEqual(e.correct("the"), .keep)                      // listed
        XCTAssertEqual(e.correct("teh", isAllowed: { $0 == "teh" }), .keep)
    }

    func testDeadlineGivesTimedOutNeverAGuess() {
        var rng = SplitMix(seed: 7)
        let alphabet = Array("etaoinshr".utf8)
        var words: [(String, Double)] = []
        for i in 0..<20000 {
            let n = 4 + Int(rng.next() % 6)
            words.append((String(decoding: (0..<n).map { _ in alphabet[Int(rng.next() % 9)] }, as: UTF8.self), -5 - Double(i % 7)))
        }
        let e = engine(words)
        XCTAssertEqual(e.correct("etaoinsh", deadline: 0), .timedOut)
        XCTAssertNotEqual(e.correct("etaoinsh"), .timedOut)
    }

    func testFileFormatRoundTripsExactly() throws {
        let text = "the\t-3.9132529025071245\nteh\t-12.5\nBad\t-1\nx y\t-2\nthe\t-20\ncat\tnope\n\nzebra\t-11.000000000000002"
        let lex = AutocorrectLexicon(data: Data(text.utf8))
        XCTAssertEqual(lex.wordCount, 3)                             // the, teh, zebra (bad lines skipped)
        XCTAssertEqual(lex.logFrequency(of: "the"), -3.9132529025071245)   // highest of the two kept
        XCTAssertEqual(lex.logFrequency(of: "zebra"), -11.000000000000002) // last line without a newline
        XCTAssertNil(lex.logFrequency(of: "th"))
    }

    private func assertSameTrie(_ a: AutocorrectLexicon, _ b: AutocorrectLexicon, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.label, b.label, file: file, line: line)
        XCTAssertEqual(a.firstChild, b.firstChild, file: file, line: line)
        XCTAssertEqual(a.nextSibling, b.nextSibling, file: file, line: line)
        XCTAssertEqual(a.wordIndex, b.wordIndex, file: file, line: line)
        XCTAssertEqual(a.logFrequency, b.logFrequency, file: file, line: line)
        XCTAssertEqual(a.maxLength, b.maxLength, file: file, line: line)
    }

    /// A sorted file takes the in-place two-pass build; it must give the same trie as parsing to entries first.
    func testSortedFileBuildsTheSameTrieAsEntries() {
        let text = "ape\t-9\napex\t-10.25\nBad\t-1\napt\t-8\napt\t-7.5\nbe\t-4\nbee\tnope\nbeer\t-6\n\nx y\t-2\nzebra\t-11.000000000000002"
        let data = Data(text.utf8)
        let lex = AutocorrectLexicon(data: data)
        XCTAssertEqual(lex.wordCount, 6)                                     // ape apex apt be beer zebra
        XCTAssertEqual(lex.logFrequency(of: "apt"), -7.5)                    // highest of the two kept
        XCTAssertEqual(lex.logFrequency(of: "zebra"), -11.000000000000002)   // last line without a newline
        XCTAssertNil(lex.logFrequency(of: "bee"))
        assertSameTrie(lex, AutocorrectLexicon(entries: AutocorrectLexicon.entries(in: data).reversed()))
    }

    /// The shipped list: the in-place build equals the entries build (fed in reverse, so it is sorted first).
    func testBundledListInPlaceBuildEqualsSortedEntries() throws {
        let data = try Data(contentsOf: ACFixture.bundledList(), options: .mappedIfSafe)
        let lex = AutocorrectLexicon(data: data)
        XCTAssertEqual(lex.wordCount, 92_404)
        assertSameTrie(lex, AutocorrectLexicon(entries: AutocorrectLexicon.entries(in: data).reversed()))
        XCTAssertLessThan(Double(lex.firstChild.capacity), Double(lex.firstChild.count) * 1.05, "arrays are allocated once at their final size")
    }

    // MARK: keyboard side

    private func typer() -> AutocorrectTyper { AutocorrectTyper(engine: engine(small)) }

    func testWordAtCursorAndSentenceRule() {
        let w = AutocorrectTyper.wordAtCursor
        XCTAssertEqual(w("i saw teh"), .init(word: "teh", punct: "", sentenceInitial: false))
        XCTAssertEqual(w("teh"), .init(word: "teh", punct: "", sentenceInitial: true))
        XCTAssertEqual(w("ok. Teh,"), .init(word: "Teh", punct: ",", sentenceInitial: true))
        XCTAssertEqual(w("ok?! Teh"), .init(word: "Teh", punct: "", sentenceInitial: false))   // prototype: exactly . ! ?
        XCTAssertEqual(w("see https://x.com/teh"), .init(word: "https://x.com/teh", punct: "", sentenceInitial: false))
        XCTAssertNil(w("teh "))
        XCTAssertNil(w(""))
    }

    func testSpaceCorrectsAndDeletePutsTheWordBack() {
        let t = typer()
        XCTAssertEqual(t.space(contextBefore: "i saw teh"), .init(deleteCount: 3, insert: "the "))
        XCTAssertTrue(t.canUndo)
        XCTAssertEqual(t.delete(contextBefore: "i saw the "), .init(deleteCount: 4, insert: "teh"))
        XCTAssertFalse(t.canUndo)
        // Put back: the same word is not corrected again this session.
        XCTAssertEqual(t.space(contextBefore: "i saw teh"), .space)
        XCTAssertEqual(t.lastSpace?.path, .known)
    }

    func testPunctuationStaysAndUndoKeepsIt() {
        let t = typer()
        XCTAssertEqual(t.space(contextBefore: "i saw teh,"), .init(deleteCount: 4, insert: "the, "))
        XCTAssertEqual(t.delete(contextBefore: "i saw the, "), .init(deleteCount: 5, insert: "teh,"))
    }

    func testUndoOnlyRightAfterTheCorrection() {
        let t = typer()
        _ = t.space(contextBefore: "teh")
        t.didType(contextBefore: "the c")          // another key
        XCTAssertNil(t.delete(contextBefore: "the c"))
        _ = t.space(contextBefore: "teh")
        XCTAssertNil(t.delete(contextBefore: "something else "))   // text changed under us: plain delete
    }

    func testNothingChangesWhenOffOrGuardedOrAllowed() {
        let t = typer()
        XCTAssertEqual(t.space(contextBefore: "see https://x.com/teh"), .space)
        XCTAssertEqual(t.lastSpace?.path, .guarded)
        XCTAssertEqual(t.space(contextBefore: "ping Teh"), .space)
        t.enabled = false
        XCTAssertEqual(t.space(contextBefore: "teh"), .space)
        XCTAssertEqual(t.lastSpace?.path, .off)
        t.enabled = true; t.fieldAllows = false
        XCTAssertEqual(t.space(contextBefore: "teh"), .space)
        t.fieldAllows = true
        t.allow.setSystemLexicon([(userInput: "Teh", documentText: "Teh")])
        XCTAssertEqual(t.space(contextBefore: "teh"), .space)
        let d = typer()
        d.allow.setDictionary(["MASHBOX Teh"])
        XCTAssertEqual(d.space(contextBefore: "teh"), .space)
        XCTAssertEqual(AutocorrectTyper().space(contextBefore: "teh"), .space)   // no word list
    }

    func testLookupWhileTypingIsUsedOnSpace() {
        let t = typer()
        t.didType(contextBefore: "i saw teh")
        t.drainLookups()
        XCTAssertEqual(t.space(contextBefore: "i saw teh"), .init(deleteCount: 3, insert: "the "))
        XCTAssertEqual(t.lastSpace?.path, .cached)
        let u = typer()
        XCTAssertEqual(u.space(contextBefore: "i saw teh"), .init(deleteCount: 3, insert: "the "))
        XCTAssertEqual(u.lastSpace?.path, .sync)
    }

    func testAllowListWords() {
        XCTAssertEqual(AutocorrectAllowList.words("MASHBOX Labs"), ["mashbox labs", "mashbox", "labs"])
        XCTAssertEqual(AutocorrectAllowList.words("  "), [])
    }
}

/// Unit-cost optimal string alignment distance (plain dynamic program), the reference for the trie walk.
func osa(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let n = a.count, m = b.count, w = m + 1
    if n == 0 || m == 0 { return max(n, m) }
    var d = [Int](repeating: 0, count: (n + 1) * w)
    for i in 0...n { d[i * w] = i }
    for j in 0...m { d[j] = j }
    for i in 1...n {
        for j in 1...m {
            let c = a[i - 1] == b[j - 1] ? 0 : 1
            var v = min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1, d[(i - 1) * w + j - 1] + c)
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, d[(i - 2) * w + j - 2] + 1) }
            d[i * w + j] = v
        }
    }
    return d[n * w + m]
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
