import Foundation
import XCTest
@testable import FreeFlowKit

/// Build 12 autocorrect bench (research b12ac/PREREG-AC12.md). Replays each typed sentence of the sealed set key by key
/// through AutocorrectTyper exactly as the keyboard calls it (KeyboardViewController.typeKey / typeSpace), then a
/// return, and writes what landed, one line per sentence ("\n" written as \n), to $FFAC12_OUT/<split>.out for
/// b12ac/scripts/ac12_score.py. Nothing is scored here. Opt-in:
///   FFAC12_DIR=<dir with ac12_<split>.typed.txt> FFAC12_OUT=<dir> FFAC12_SPLITS=dev swift test -c release -Xswiftc -enable-testing --filter AutocorrectBench12
final class AutocorrectBench12Tests: XCTestCase {
    func testReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FFAC12_DIR"], let out = env["FFAC12_OUT"] else { throw XCTSkip("FFAC12_DIR / FFAC12_OUT not set") }
        let lex = try AutocorrectLexicon(contentsOf: ACFixture.bundledList())
        for split in (env["FFAC12_SPLITS"] ?? "dev").split(separator: ",").map(String.init) {
            let lines = try String(contentsOfFile: "\(dir)/ac12_\(split).typed.txt", encoding: .utf8)
                .split(separator: "\n").map(String.init)
            // FFAC12_ENGINE=b10 replays the build 10 careful rule with build 10's keys (space only); default: what ships.
            let b10 = env["FFAC12_ENGINE"] == "b10"
            let typer = AutocorrectTyper(engine: b10 ? AutocorrectEngine(lexicon: lex) : AutocorrectEngine(lexicon: lex, typing: .build12))
            typer.syncBudgetMs = 10_000   // no time-outs here: the timing tests cover the budget
            var landed: [String] = []
            var field = ""   // one field for the whole split, as the UI bench types it
            for line in lines {
                let start = field.count
                Self.type(line + "\n", typer, into: &field, spaceOnly: b10)
                landed.append(String(field.dropFirst(start)).replacingOccurrences(of: "\n", with: "\\n"))
            }
            try (landed.joined(separator: "\n") + "\n").write(toFile: "\(out)/\(split).out", atomically: true, encoding: .utf8)
            print("FFAC12 \(split) \(lines.count) lines -> \(out)/\(split).out")
        }
    }

    /// The keyboard's key handling (KeyboardViewController.typeKey / typeSpace at e9587c8) for `text` typed into `buf`.
    static func type(_ text: String, _ typer: AutocorrectTyper, into buf: inout String, spaceOnly: Bool = false) {
        for c in text {
            if c == " " || (!spaceOnly && AutocorrectTyper.endsWord(String(c))) {
                let e = typer.wordBreak(String(c), contextBefore: buf)
                for _ in 0..<e.deleteCount where !buf.isEmpty { buf.removeLast() }
                buf += e.insert
                if c == "\n" { typer.reset() } else if c != " " { typer.didType(contextBefore: buf); typer.drainLookups() }
            } else if c == "\n" {
                buf.append(c); typer.reset()
            } else {
                buf.append(c); typer.didType(contextBefore: buf); typer.drainLookups()
            }
        }
    }
}
