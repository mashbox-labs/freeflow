import XCTest
@testable import FreeFlowKit

/// The Swift port against the Python prototype (ac_proto.py, careful config chosen on dev only).
/// Dev: item-by-item port check (outputs and candidate sets). Held-out: the preregistered set scored with the Swift
/// code, side by side with the prototype's numbers. Nothing here feeds back into the config; a difference is a finding.
final class AutocorrectHeldoutTests: XCTestCase {
    func testDevPortMatchesPrototypeItemByItem() throws {
        let fx = try ACFixture.load()
        try check(fx, split: "dev", report: "ffac_swift_dev_parity.json")
    }

    func testHeldoutRescore() throws {
        let fx = try ACFixture.load()
        try check(fx, split: "heldout", report: "ffac_swift_heldout.json")
    }

    private func check(_ fx: ACFixture, split: String, report: String) throws {
        let e = fx.engine
        let ty = try fx.typos(split), ms = try fx.stays(split)
        let typoOut = ty.map { e.corrected($0.typo) }
        let stayOut = ms.map { e.corrected($0.token) }
        let swift = ACScore(typos: ty, typoOut: typoOut, stays: ms, stayOut: stayOut)

        // The prototype's own outputs for the same rows, in the same order.
        let py = try fx.python(split)
        XCTAssertEqual(py.count, ty.count + ms.count)
        let pyTypo = Array(py.prefix(ty.count)), pyStay = Array(py.dropFirst(ty.count))
        XCTAssertEqual(pyTypo.map(\.token), ty.map(\.typo))
        XCTAssertEqual(pyStay.map(\.token), ms.map(\.token))
        let python = ACScore(typos: ty, typoOut: pyTypo.map(\.output), stays: ms, stayOut: pyStay.map(\.output))

        var diffs: [String] = []
        for (r, (s, p)) in zip(py, zip(typoOut + stayOut, py.map(\.output))) where s != p {
            diffs.append("\(r.kind) \(r.token): swift \(s), python \(p)")
        }

        // Candidate sets: the trie walk against SymSpell's lookup, for every token that reached the candidate step.
        let pyCands = try fx.pythonCandidates(split)
        var candDiffs: [String] = []
        var reached = 0
        for tok in Set(ty.map(\.typo) + ms.map(\.token)) where e.needsLookup(tok, sentenceInitial: false) {
            reached += 1
            let t = Array(tok.lowercased().utf8)
            let mine = Set(e.lexicon.candidates(t, maxDistance: t.count <= 4 ? 1 : 2)!.map { String(decoding: $0.word, as: UTF8.self) })
            guard let theirs = pyCands[tok] else { candDiffs.append("\(tok): not in the prototype's list"); continue }
            if mine != theirs {
                candDiffs.append("\(tok): swift-only \(mine.subtracting(theirs).sorted()) python-only \(theirs.subtracting(mine).sorted())")
            }
        }

        // Names two more ways, as the prototype: capitalised mid-sentence, and with the names as contacts.
        let names = ms.filter { $0.category == "name" }.map(\.token)
        let nameSet = Set(names)
        let capChanged = names.filter { n in let c = n.prefix(1).uppercased() + n.dropFirst(); return e.corrected(c) != c }.count
        let contactsChanged = names.filter { e.corrected($0, isAllowed: { nameSet.contains($0) }) != $0 }.count

        let label = split.uppercased()
        print("FFAC-\(label) swift:  \(swift.line)")
        print("FFAC-\(label) python: \(python.line)")
        print("FFAC-\(label) item differences \(diffs.count) of \(py.count); candidate-set differences \(candDiffs.count) of \(reached) looked-up tokens (python list has \(pyCands.count))")
        print("FFAC-\(label) names capitalised changed \(capChanged)/\(names.count); with names as contacts changed \(contactsChanged)/\(names.count)")
        for d in diffs.prefix(25) { print("FFAC-\(label) diff \(d)") }
        for d in candDiffs.prefix(25) { print("FFAC-\(label) cand \(d)") }
        fx.write(report, [
            "split": split, "swift": swift.json, "python_from_its_outputs": python.json,
            "item_differences": diffs.count, "items": py.count, "item_difference_examples": Array(diffs.prefix(50)),
            "candidate_set_differences": candDiffs.count, "looked_up_tokens": reached,
            "candidate_difference_examples": Array(candDiffs.prefix(50)),
            "names_capitalised_changed": [capChanged, names.count], "names_with_contacts_changed": [contactsChanged, names.count],
            "config": ["weight": e.config.costWeight, "margin": e.config.margin, "max_cost": e.config.maxCost,
                       "min_log_frequency": e.config.minLogFrequency, "spatial": false],
        ])
        XCTAssertEqual(swift, python, "Swift and the prototype score differently on \(split)")
        XCTAssertEqual(diffs.count, 0, "item differences on \(split)")
        XCTAssertEqual(candDiffs.count, 0, "candidate-set differences on \(split)")
        XCTAssertEqual(reached, pyCands.count)
    }
}
