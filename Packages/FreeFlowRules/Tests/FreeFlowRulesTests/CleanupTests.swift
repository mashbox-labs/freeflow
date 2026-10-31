import XCTest
@testable import FreeFlowRules
@testable import FreeFlowKit

/// Behaviour of the cleanup levels. Hand-written cases; the measured numbers come from Tools/CleanBench.
final class CleanupTests: XCTestCase {
    private func clean(_ s: String, _ level: CleanupLevel = .clean) -> String { Cleanup.apply(s, level: level) }

    func testStutterAndRepeats() {
        XCTAssertEqual(clean("I'm I'm going home"), "I'm going home")
        XCTAssertEqual(clean("I'm, I'm going home"), "I'm going home")
        XCTAssertEqual(clean("I I I think so"), "I think so")
        XCTAssertEqual(clean("we should we should ship it"), "we should ship it")
        XCTAssertEqual(clean("abandon the, you know, the written word"), "abandon the written word")
        XCTAssertEqual(clean("th- the plan works"), "the plan works")
    }
    func testMeantRepeatsStay() {
        for s in ["it was very very good", "I know that that works", "call 5 5 5 1 2 1 2", "we went to Walla Walla",
                  "bye bye", "Thank you. Thank you.", "Did you see the C N N show", "no no no", "it had had an effect"] {
            XCTAssertEqual(clean(s), s, s)
        }
        XCTAssertEqual(clean("I know that, that works"), "I know that works")
    }
    func testFillers() {
        XCTAssertEqual(clean("I think the, uh, attitude is better"), "I think the attitude is better")
        XCTAssertEqual(clean("Yes, uh, I think so"), "Yes, I think so")
        XCTAssertEqual(clean("Um, so we ship it, um."), "so we ship it.")
        XCTAssertEqual(clean("uh-huh, sounds good"), "uh-huh, sounds good")
        XCTAssertEqual(clean("Take him to the ER now"), "Take him to the ER now")
    }
    func testSelfCorrections() {
        XCTAssertEqual(clean("let's meet at 5, no wait, 6 tomorrow"), "let's meet at 6 tomorrow")
        XCTAssertEqual(clean("send it to John, no wait, Mary"), "send it to Mary")
        XCTAssertEqual(clean("I want to go to Paris, no wait, to Rome"), "I want to go to Rome")
        XCTAssertEqual(clean("meet on Tuesday sorry Wednesday"), "meet on Wednesday")
        XCTAssertEqual(clean("pick the red one, I mean the blue one"), "pick the blue one")
    }
    func testNotCorrections() {
        for s in ["I have no idea", "I'm sorry I'm late", "wait for me", "I can't wait to see it", "There is no way",
                  "No, I don't think so", "I mean, it's fine", "I'd rather stay", "Sorry, I missed that", "no one knows",
                  "What didn't European chemists make that could be used?"] {
            XCTAssertEqual(clean(s), s, s)
        }
    }
    func testVerbatimIsUntouched() {
        let s = "So, I'm, I'm, um, at 5, no wait, 6."
        XCTAssertEqual(clean(s, .verbatim), s)
    }
    func testPolishedDropsDiscourseMarkers() {
        XCTAssertEqual(clean("So, you know, it was, like, huge.", .polished), "it was huge.")
        XCTAssertEqual(clean("It was big, you know, really big.", .polished), "It was big, really big.")
    }
    func testLevelsWithStyles() {
        let raw = CleanupLevel.sample
        XCTAssertEqual(TextFormatter.format(raw, style: .formal, options: FormatOptions(cleanup: .clean)),
                       "So, I'm thinking we meet at 6 and, you know, go from there.")
        XCTAssertEqual(TextFormatter.format(raw, style: .veryCasual, options: FormatOptions(cleanup: .clean)),
                       "so, I'm thinking we meet at 6 and, you know, go from there")
        XCTAssertEqual(TextFormatter.format(raw, style: .formal, options: FormatOptions(cleanup: .polished)),
                       "I'm thinking we meet at 6 and go from there.")
        XCTAssertEqual(TextFormatter.format(raw, style: .formal, options: FormatOptions(cleanup: .verbatim)),
                       raw)
    }

    /// "um" (Portuguese), "er" (German) and "nous nous" (French) are words, not stutters.
    func testOtherLanguagesKeepTheirWords() {
        for s in ["Ele comprou um carro novo e depois foi para casa com um amigo",
                  "Er ist heute nicht zu Hause, aber er kommt morgen wieder zurück",
                  "Nous nous sommes vus hier soir au cinéma avec nos amis",
                  "Ik denk dat die die het weten niets zullen zeggen"] {
            XCTAssertFalse(Cleanup.usesEnglishRules(s), s)
            XCTAssertEqual(clean(s), s, s)
            XCTAssertEqual(clean(s, .polished), s, s)
        }
        XCTAssertEqual(clean("Ich ich ich weiß es wirklich nicht genau, ehrlich gesagt"), "ich weiß es wirklich nicht genau, ehrlich gesagt")
        XCTAssertEqual(clean("Non non non, je ne veux pas y aller ce soir"), "Non non non, je ne veux pas y aller ce soir")
        XCTAssertEqual(Cleanup.apply("um, I think so", level: .clean, language: "pt"), "um, I think so")
        XCTAssertEqual(Cleanup.apply("um, I think so", level: .clean, language: "en"), "I think so")
    }
    /// The Clean promise: words are only ever deleted, never added, changed or reordered.
    func testCleanOnlyDeletes() {
        func words(_ s: String) -> [String] {
            s.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        }
        for s in ["So, Im, Im thinking we, um, we meet at 5, no wait, 6 and, you know, go from there.",
                  "I I I uh think the the plan, sorry, the budget is is fine", "th- the, uh, the red one, I mean the blue one",
                  "we should we should, um, ship it on Monday no wait Tuesday", "Yeah. Yeah. Um, okay so, like, it works"] {
            let out = words(clean(s))
            var it = words(s).makeIterator()
            XCTAssertTrue(out.allSatisfy { w in while let x = it.next() { if x == w { return true } }; return false }, s)
        }
    }
}

