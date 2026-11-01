import XCTest
@testable import FreeFlowKit

/// The writer choice (build 18: Apple Intelligence or Off), the readout lines and the writing time limit.
final class WriterRouteTests: XCTestCase {
    func testReadoutLines() {
        let apple = WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: true,
                                   wordsIn: 14, wordsOut: 12, seconds: 0.96, keptRaw: 1)
        XCTAssertEqual(apple.line, "Apple on-device model · Apple Foundation Models · in the background · 14 → 12 words · 0.96 s · tok/s not reported · 1 part kept as heard")
        let raw = WritingReadout(model: "None", runtime: "raw text", background: false, wordsIn: 9, wordsOut: 9, seconds: 0,
                                 note: "Apple's on-device model is not available")
        XCTAssertEqual(raw.line, "None · raw text · in the foreground · 9 → 9 words · 0.00 s · Apple's on-device model is not available")
        XCTAssertEqual(WritingReadout.words(" one  two\nthree "), 3)
    }



    func testWritingBudget() {
        XCTAssertEqual(WritingBudget.seconds(words: 0), 3, accuracy: 1e-9)
        XCTAssertEqual(WritingBudget.seconds(words: 34), 4.7, accuracy: 1e-9)
        XCTAssertEqual(WritingBudget.seconds(words: 100), 8, accuracy: 1e-9)
        XCTAssertEqual(WritingBudget.seconds(words: 240), 15, accuracy: 1e-9)
        XCTAssertEqual(WritingBudget.seconds(words: 5000), 15, accuracy: 1e-9)
    }

    func testReadoutTimeLimitNote() {
        let r = WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: false, wordsIn: 34,
                               wordsOut: 34, seconds: 4.71, keptRaw: 1, note: "time limit 4.7 s")
        XCTAssertTrue(r.line.hasSuffix("1 part kept as heard · time limit 4.7 s"), r.line)
    }

    func testPiecesEndAtSentenceEnds() {
        func words(_ n: Int, _ w: String) -> String { Array(repeating: w, count: n).joined(separator: " ") }
        // 100 words, a sentence end, then 50 more: the first piece ends at the sentence end (word 100), not at word 120.
        let a = words(99, "go") + " end." + " " + words(49, "on") + " last."
        let p = WritingGuard.pieces(a).filter { $0.write }.map { $0.text }
        XCTAssertEqual(p.count, 2)
        XCTAssertTrue(p[0].hasSuffix("end."), p[0])
        XCTAssertEqual(p[0].split(separator: " ").count, 100)
        XCTAssertEqual(p[1].split(separator: " ").count, 50)
        XCTAssertEqual(WritingGuard.pieces(a).map { $0.text }.joined(), a)
        // A sentence end early (word 10) and none up to word 120: still the last sentence end at or before 120.
        let b = words(9, "go") + " end. " + words(140, "on")
        let q = WritingGuard.pieces(b).filter { $0.write }.map { $0.text }
        XCTAssertEqual(q[0].split(separator: " ").count, 10)
        XCTAssertEqual(WritingGuard.pieces(b).map { $0.text }.joined(), b)
        // No sentence end at all: cut at the word limit.
        let c = words(250, "on")
        let r = WritingGuard.pieces(c).filter { $0.write }.map { $0.text.split(separator: " ").count }
        XCTAssertEqual(r, [120, 120, 10])
        XCTAssertEqual(WritingGuard.pieces(c).map { $0.text }.joined(), c)
        // Short text: one piece.
        XCTAssertEqual(WritingGuard.pieces("Hello there. How are you?").filter { $0.write }.count, 1)
    }


    /// Build 18 (2026-10-30): Apple Intelligence, optional; where it can't run the line says why.
    /// Build 33: off unless turned on; a stored choice is kept.
    func testWriterChoice() {
        XCTAssertEqual(WriterChoice.resolved(raw: nil), .off, "a new install starts with cleanup off")
        XCTAssertEqual(WriterChoice.resolved(raw: ""), .off)
        XCTAssertEqual(WriterChoice.resolved(raw: "lfm3"), .off, "an old LFM3 pick reads as not picked")
        XCTAssertEqual(WriterChoice.resolved(raw: "off"), .off)
        XCTAssertEqual(WriterChoice.resolved(raw: "apple"), .apple, "someone who turned it on keeps it on")
        XCTAssertEqual(WriterChoice.allCases, [.apple, .off])
        XCTAssertEqual(WriterChoice.status(choice: .apple, appleAvailable: true).state, "On, on this device")
        XCTAssertEqual(WriterChoice.status(choice: .apple, appleAvailable: false, reason: "Apple Intelligence is off in Settings").state,
                       "Not available: Apple Intelligence is off in Settings. Text goes in as heard.")
        XCTAssertEqual(WriterChoice.status(choice: .off, appleAvailable: true).name, "Off")
        XCTAssertEqual(WriterChoice.status(choice: .off, appleAvailable: true).state, "Text as heard")
    }

    func testShortLineSaysWhoWrote() {
        let apple = WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: false,
                                   wordsIn: 10, wordsOut: 9, seconds: 1.24, used: 1)
        XCTAssertEqual(apple.short, "Written by Apple Intelligence · 1.2 s")
        let part = WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: true, wordsIn: 10,
                                  wordsOut: 9, seconds: 0.91, keptRaw: 1, used: 1)
        XCTAssertEqual(part.short, "Written by Apple Intelligence · 0.9 s · part as heard")
        var refused = part; refused.note = "Apple Intelligence refused"
        XCTAssertEqual(refused.short, "Written by Apple Intelligence · 0.9 s · part as heard: Apple Intelligence refused")
        refused.used = 0
        XCTAssertEqual(refused.short, "As heard · Apple Intelligence refused")
        let unavailable = WritingReadout(model: "None", runtime: "raw text", background: true, wordsIn: 4, wordsOut: 4, seconds: 0,
                                         note: "Apple Intelligence is off in the Settings app")
        XCTAssertEqual(unavailable.short, "As heard · Apple Intelligence is off in the Settings app")
        let limited = WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: false, wordsIn: 10,
                                     wordsOut: 10, seconds: 4.7, keptRaw: 1, note: "time limit 4.7 s")
        XCTAssertEqual(limited.short, "As heard · time limit 4.7 s")
        let off = WritingReadout(model: "None", runtime: "raw text", background: false, wordsIn: 3, wordsOut: 3, seconds: 0,
                                 note: "writing is off")
        XCTAssertEqual(off.short, "As heard · writing is off")
    }

    /// Build 33: the default changes only where nothing is stored; a stored choice, on or off, is kept as it is.
    func testDefaultOffKeepsAStoredChoice() {
        let saved = UserDefaults.standard.string(forKey: WriterChoice.key)
        defer { UserDefaults.standard.set(saved, forKey: WriterChoice.key) }
        UserDefaults.standard.removeObject(forKey: WriterChoice.key)
        XCTAssertNil(WriterChoice.stored)
        XCTAssertEqual(WriterChoice.resolved, .off)
        WriterChoice.stored = .apple
        XCTAssertEqual(WriterChoice.resolved, .apple)
        XCTAssertEqual(UserDefaults.standard.string(forKey: WriterChoice.key), "apple", "nothing overwrites it")
        WriterChoice.stored = .off
        XCTAssertEqual(WriterChoice.resolved, .off)
    }
}
