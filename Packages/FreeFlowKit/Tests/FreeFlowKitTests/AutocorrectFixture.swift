import CryptoKit
import Foundation
import XCTest
@testable import FreeFlowKit

/// The build 10 research data for the autocorrect re-score and timing, kept outside the repo: the preregistered test
/// set and the prototype's own per-item outputs. The word list is the one
/// the keyboard ships, ThirdParty/WordList/autocorrect-en.tsv in this repo (SymSpell frequency_dictionary_en_82_765 +
/// FrequencyWords en_50k, merged exactly as ac_proto.py does; scripts/make-wordlist.py rebuilds it).
///
/// Opt-in, because a debug build takes minutes over the full set:
///   FFAC_DATA=~/Developer/freeflow-ac-data swift test -c release -Xswiftc -enable-testing --filter Autocorrect
/// (iOS simulator: TEST_RUNNER_FFAC_DATA=<dir> xcodebuild test ...). Unset: these tests skip. Results go to $FFAC_OUT,
/// else the data folder. Every file is checked against the sha256 recorded when it was made, so the set cannot drift.
struct ACFixture {
    /// The shipped word list: byte for byte the prototype's ffac_lexicon_proto.tsv that the dev and held-out scores used.
    static let bundledListSHA256 = "1ad1341a43f41c79e8b4ca80d9ce6081641bd0d19753dac6f2b96b4403dabaa7"

    /// ThirdParty/WordList/autocorrect-en.tsv in this checkout ($FFAC_LIST overrides), checked against its sha256.
    static func bundledList() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let url: URL
        if let p = env["FFAC_LIST"] ?? env["TEST_RUNNER_FFAC_LIST"], !p.isEmpty {
            url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            var root = URL(fileURLWithPath: #filePath)   // <repo>/Packages/FreeFlowKit/Tests/FreeFlowKitTests/this file
            for _ in 0..<5 { root.deleteLastPathComponent() }
            url = root.appendingPathComponent("ThirdParty/WordList/\(AutocorrectLexicon.resourceName).\(AutocorrectLexicon.resourceExtension)")
        }
        let got = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard got == bundledListSHA256 else {
            throw NSError(domain: "ACFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) sha256 \(got) is not the shipped \(bundledListSHA256)"])
        }
        return url
    }

    static let sha256: [String: String] = [
        "typos.tsv": "6f6666cf3ac9b52ce929f90e1a9443d57bf82087c99bd575ddd988155eaeb106",       // PREREG-AC.md
        "muststay.tsv": "8b1b7559b1adbb2de4da52cea7f6776095769d2ac9fb11e82af61b009c5d1e5a",    // PREREG-AC.md
        "py_out_dev.tsv": "c36057c8db97d30dd9e6e15d82edb5d2d2eee0efde1d4245b0dbeb979c7346fc",
        "py_out_heldout.tsv": "c3896f91187a57ac143673e69ed5239daf0dc5cb387655156ad686703699f511",
        "py_cands_dev.tsv": "7dc2f22c5c45dcc55d2dbf46cff4fc3bfd21d4b557b7ce3aeac8df217033c024",
        "py_cands_heldout.tsv": "6d7aca4c1da866f40febac5b532bc179900fb50e9a90d7dfe5d75281a9ed6ab4",
    ]

    struct Typo { let typo: String; let intended: String; let source: String }
    struct Stay { let token: String; let category: String }
    struct PyRow { let kind: String; let token: String; let output: String }

    let dir: URL
    let lexiconURL: URL
    let engine: AutocorrectEngine
    let loadMs: Double

    static func dataDir() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["FFAC_DATA"] ?? env["TEST_RUNNER_FFAC_DATA"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        throw XCTSkip("Opt-in: set FFAC_DATA to the autocorrect data folder (kept outside the repo, see ACFixture)")
    }

    static var outDir: URL {
        if let p = ProcessInfo.processInfo.environment["FFAC_OUT"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return (try? dataDir()) ?? FileManager.default.temporaryDirectory
    }

    private static var cached: ACFixture?
    private static let lock = NSLock()

    static func load() throws -> ACFixture {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let dir = try dataDir()
        for (name, want) in sha256 {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == want else { throw XCTSkip("\(name) sha256 \(got) is not the recorded \(want)") }
        }
        let url = try bundledList()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let lex = try AutocorrectLexicon(contentsOf: url)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let f = ACFixture(dir: dir, lexiconURL: url, engine: AutocorrectEngine(lexicon: lex, config: .careful), loadMs: ms)
        cached = f
        return f
    }

    func tsv(_ name: String) throws -> [[String: String]] {
        let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let head = lines.removeFirst().components(separatedBy: "\t")
        return lines.map { line in
            let cols = line.components(separatedBy: "\t")
            var r: [String: String] = [:]
            for (i, h) in head.enumerated() where i < cols.count { r[h] = cols[i] }
            return r
        }
    }

    func typos(_ split: String) throws -> [Typo] {
        try tsv("typos.tsv").filter { $0["split"] == split }.map { Typo(typo: $0["typo"]!, intended: $0["intended"]!, source: $0["source"]!) }
    }

    func stays(_ split: String) throws -> [Stay] {
        try tsv("muststay.tsv").filter { $0["split"] == split }.map { Stay(token: $0["token"]!, category: $0["category"]!) }
    }

    func python(_ split: String) throws -> [PyRow] {
        try tsv("py_out_\(split).tsv").map { PyRow(kind: $0["kind"]!, token: $0["token"]!, output: $0["output"] ?? "") }
    }

    /// token -> the prototype's candidate words (SymSpell lookup, Verbosity.ALL), for every token that reached it.
    func pythonCandidates(_ split: String) throws -> [String: Set<String>] {
        let text = try String(contentsOf: dir.appendingPathComponent("py_cands_\(split).tsv"), encoding: .utf8)
        var out: [String: Set<String>] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let words = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            out[String(parts[0])] = Set(words)
        }
        return out
    }

    func write(_ name: String, _ object: Any) { Self.write(name, object) }

    static func write(_ name: String, _ object: Any) {
        let dir = outDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name))
        }
    }
}

/// The prototype's scoring (ac_proto.py score): FIXED = output equals the intended word (case-insensitive), LEFT =
/// output equals the typo, WRONG = anything else; must-stay = changed / all, per category.
struct ACScore: Equatable {
    var typos = 0, fixed = 0, wrong = 0, left = 0
    var falseBy: [String: [Int]] = [:]

    init(typos t: [ACFixture.Typo], typoOut: [String], stays s: [ACFixture.Stay], stayOut: [String]) {
        typos = t.count
        for (r, o) in zip(t, typoOut) {
            if o.lowercased() == r.intended { fixed += 1 } else if o.lowercased() == r.typo { left += 1 }
        }
        wrong = typos - fixed - left
        for (r, o) in zip(s, stayOut) {
            var v = falseBy[r.category] ?? [0, 0]
            v[0] += o != r.token ? 1 : 0
            v[1] += 1
            falseBy[r.category] = v
        }
    }

    var json: [String: Any] {
        var j: [String: Any] = ["typos_n": typos, "fixed": fixed, "wrong": wrong, "left": left,
                                "fix_rate": Double(fixed) / Double(max(1, typos))]
        for (k, v) in falseBy { j["false_\(k)"] = v }
        return j
    }

    var line: String {
        let cats = falseBy.keys.sorted().map { "\($0) \(falseBy[$0]![0])/\(falseBy[$0]![1])" }.joined(separator: ", ")
        return "typos \(typos): fixed \(fixed) (\(String(format: "%.1f", 100 * Double(fixed) / Double(max(1, typos))))%), wrong \(wrong), left \(left); \(cats)"
    }
}
