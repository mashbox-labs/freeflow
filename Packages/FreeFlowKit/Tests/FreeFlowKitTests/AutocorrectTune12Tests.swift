import Foundation
import XCTest
@testable import FreeFlowKit

/// Build 12 typing-rule costs, chosen on DEV ONLY (research b12ac/PREREG-AC12.md): the dev half of the sealed slip set
/// plus build 10's dev must-stay words (names, slang, profanity, brands, code, ordinary; lowercase, mid-sentence) and
/// build 10's dev spelling mistakes for information. Candidates are found once per word; every grid point then runs
/// the engine's own decision (AutocorrectEngine.decideTyping). Held-out is never read here.
/// Opt-in: FFAC12_DIR=<dir with ac12_dev.jsonl> FFAC_DATA=<build 10 data> FFAC12_OUT=<dir> swift test -c release -Xswiftc -enable-testing --filter AutocorrectTune12
final class AutocorrectTune12Tests: XCTestCase {
    struct Tok { let typed: String; let t: [UInt8]; let lp: Double?; let cands: [(word: [UInt8], logFrequency: Double)]; let guarded: Bool }

    func testDevGrid() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FFAC12_DIR"], let out = env["FFAC12_OUT"] else { throw XCTSkip("FFAC12_DIR / FFAC12_OUT not set") }
        let lex = try AutocorrectLexicon(contentsOf: ACFixture.bundledList())
        let engine = AutocorrectEngine(lexicon: lex)
        var cache: [String: Tok] = [:]
        func tok(_ s: String) -> Tok {
            if let t = cache[s] { return t }
            let lower = s.lowercased(), b = Array(lower.utf8)
            let guarded = AutocorrectEngine.isGuardedTyping(s, sentenceInitial: false)
            let cands = guarded ? [] : (lex.candidates(b, maxDistance: b.count <= 4 ? 1 : 2) ?? [])
                .map { (word: $0.word, logFrequency: lex.logFrequency[Int($0.index)]) }
            let r = Tok(typed: s, t: b, lp: lex.logFrequency(of: lower), cands: cands, guarded: guarded)
            cache[s] = r
            return r
        }
        // Sealed dev slips and ordinary words.
        var slips: [(Tok, String)] = [], ordinary: [Tok] = []
        for line in try String(contentsOfFile: "\(dir)/ac12_dev.jsonl", encoding: .utf8).split(separator: "\n") {
            let rec = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let words = (rec["intended"] as! String).split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.?")) }
            let typos = rec["typos"] as! [[String: Any]]
            let at = Set(typos.map { $0["index"] as! Int })
            for t in typos { slips.append((tok(t["typo"] as! String), t["intended"] as! String)) }
            for (i, w) in words.enumerated() where !at.contains(i) { ordinary.append(tok(w)) }
        }
        // Build 10's dev data (already looked at in build 10: information and a guard, not the bar).
        let fx = try ACFixture.load()
        let stays = try fx.stays("dev").map { (tok($0.token.lowercased()), $0.category) }
        let spell = try fx.typos("dev").map { (tok($0.typo), $0.intended) }
        print("FFTUNE dev slips \(slips.count) ordinary \(ordinary.count) b10 stays \(stays.count) b10 misspellings \(spell.count) unique \(cache.count)")

        func decide(_ k: Tok, _ m: TypingModel) -> String? {
            if k.guarded { return nil }
            let keep = k.lp.map { $0 + m.knownBonus } ?? m.unknownLogFrequency
            return AutocorrectEngine.decideTyping(typed: k.t, keep: keep, candidates: k.cands, m).map { String(decoding: $0, as: UTF8.self) }
        }
        struct Row { let m: TypingModel; let fixed: Int; let wrong: Int; let changed: Int; let stayChanged: Int; let stayByCat: [String: Int]; let spellFixed: Int }
        func eval(_ m: TypingModel) -> Row {
            var fixed = 0, wrong = 0, changed = 0, sc = 0, sp = 0
            var byCat: [String: Int] = [:]
            for (k, want) in slips { if let r = decide(k, m) { if r == want { fixed += 1 } else { wrong += 1 } } }
            for k in ordinary where decide(k, m) != nil { changed += 1 }
            for (k, c) in stays where decide(k, m) != nil { sc += 1; byCat[c, default: 0] += 1 }
            for (k, want) in spell where decide(k, m) == want.lowercased() { sp += 1 }
            return Row(m: m, fixed: fixed, wrong: wrong, changed: changed, stayChanged: sc, stayByCat: byCat, spellFixed: sp)
        }
        var grid: [TypingModel] = []
        let wide = env["FFAC12_GRID"] == "wide"
        if wide {
            for sb in [1.5, 2.5, 3.5] { for sp in [1.0, 2.0, 3.0] { for idb in [1.5, 2.5] { for ia in [2.5, 3.5] { for ins in [4.0, 5.5] {
            for dd in [1.0, 2.0] { for de in [2.5, 3.5, 4.5] { for sw in [1.5, 2.5, 3.5] { for kb in [6.0, 8.0, 10.0, 12.0] { for u in [-20.0, -17.0, -14.0] {
                grid.append(TypingModel(subBase: sb, subPerPitch2: sp, insertDouble: idb, insertAdjacent: ia, insert: ins, deleteDouble: dd,
                                        delete: de, swap: sw, knownBonus: kb, unknownLogFrequency: u, minLogFrequency: -16, maxCost: 9))
            } } } } } } } } } }
        } else {
            for sb in [1.0, 1.5, 2.0] { for sp in [0.5, 1.0, 1.5] { for sw in [2.0, 2.5, 3.0] { for ins in [5.5, 7.0] {
            for kb in [4.0, 5.0, 6.0, 7.0, 8.0] { for u in [-15.0, -14.0, -13.0, -12.0, -11.0] { for mlf in [-16.0, -14.0, -12.0] {
                grid.append(TypingModel(subBase: sb, subPerPitch2: sp, insertDouble: 2.5, insertAdjacent: 3.5, insert: ins, deleteDouble: 1.0,
                                        delete: 3.5, swap: sw, knownBonus: kb, unknownLogFrequency: u, minLogFrequency: mlf, maxCost: 9))
            } } } } } } }
        }
        var rows = [Row?](repeating: nil, count: grid.count)
        let lock = NSLock()
        let t0 = Date()
        DispatchQueue.concurrentPerform(iterations: grid.count) { i in
            let r = eval(grid[i]); lock.lock(); rows[i] = r; lock.unlock()
        }
        let all = rows.compactMap { $0 }
        // Build 10's preregistered limits (preregistration rule 4) on its dev must-stay words: names + slang +
        // profanity + brands + code <= 2.0% changed, ordinary running text <= 0.5%. Plus 0 sealed-set ordinary words.
        let runN = stays.filter { $0.1 == "common_running_text" }.count, otherN = stays.count - runN
        func withinB10(_ r: Row) -> Bool {
            let run = r.stayByCat["common_running_text"] ?? 0
            return Double(r.stayChanged - run) <= 0.02 * Double(otherN) && Double(run) <= 0.005 * Double(runN)
        }
        print("FFTUNE b10 limits: others <= \(0.02 * Double(otherN)) of \(otherN), running text <= \(0.005 * Double(runN)) of \(runN)")
        let zero = all.filter { $0.changed == 0 && (env["FFAC12_B10LIMITS"] != "1" || withinB10($0)) }
        let ranked = zero.sorted { a, b in
            if a.fixed != b.fixed { return a.fixed > b.fixed }
            if a.stayChanged != b.stayChanged { return a.stayChanged < b.stayChanged }
            return a.wrong < b.wrong
        }
        print(String(format: "FFTUNE grid %d points in %.1f s; %d with 0 ordinary words changed", all.count, Date().timeIntervalSince(t0), zero.count))
        func line(_ r: Row) -> String {
            let m = r.m
            return String(format: "fixed %d/%d wrong %d changed %d/%d b10stays %d/%d %@ b10spell %d/%d | sub %.1f+%.1fd2 insD %.1f insA %.1f ins %.1f delD %.1f del %.1f swap %.1f known +%.0f unknown %.0f",
                          r.fixed, slips.count, r.wrong, r.changed, ordinary.count, r.stayChanged, stays.count,
                          r.stayByCat.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), r.spellFixed, spell.count,
                          m.subBase, m.subPerPitch2, m.insertDouble, m.insertAdjacent, m.insert, m.deleteDouble, m.delete, m.swap, m.knownBonus, m.unknownLogFrequency)
        }
        for r in ranked.prefix(5) { print("FFTUNE top " + line(r)) }
        // The trade-off: most dev slips fixed for each budget of build 10 must-stay words changed.
        var front: [Row] = []
        for budget in [0, 5, 10, 14, 20, 30, 45, 60, 90] {
            if let r = ranked.first(where: { $0.stayChanged <= budget }) { front.append(r); print("FFTUNE front <=\(budget) " + line(r)) }
        }
        if let pick = env["FFAC12_SHOW"].flatMap(Int.init), let r = ranked.first(where: { $0.stayChanged <= pick }) {
            print("FFTUNE PICK " + line(r))
            let changedStays = stays.compactMap { k, c in decide(k, r.m).map { "\(c):\(k.typed)>\($0)" } }
            print("FFTUNE stays changed at <=\(pick): " + changedStays.joined(separator: " "))
            let misses = slips.compactMap { k, want in decide(k, r.m) == want ? nil : "\(k.typed)>\(decide(k, r.m) ?? "=")(\(want))" }
            print("FFTUNE dev slips missed at <=\(pick): " + misses.joined(separator: " "))
        }
        let b10 = AutocorrectEngine(lexicon: lex, config: .careful)
        let b10fixed = slips.filter { b10.corrected($0.0.typed) == $0.1 }.count
        let b10stay = stays.filter { b10.corrected($0.0.typed) != $0.0.typed }.count
        print("FFTUNE build10 careful: fixed \(b10fixed)/\(slips.count) b10stays changed \(b10stay)/\(stays.count)")
        let lines = ranked.prefix(200).map(line)
        try (lines.joined(separator: "\n") + "\n").write(toFile: "\(out)/tune12-dev.txt", atomically: true, encoding: .utf8)
        _ = engine
    }
}
