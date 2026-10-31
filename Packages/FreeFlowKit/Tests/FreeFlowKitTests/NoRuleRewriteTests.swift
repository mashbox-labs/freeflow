import XCTest
@testable import FreeFlowKit

/// Build 12 (2026-10-30, every manual cleanup rule removed): nothing rule-based
/// runs between speech recognition and insert. Each line is raw recognizer text that one of the old rules rewrote
/// (fillers, repeats and stutters, cued repairs, swears and apologies, spoken commands, style casing and full stops,
/// tidy spacing, Polished discourse markers). The finished text must be the recognizer's text exactly, trimmed.
final class NoRuleRewriteTests: XCTestCase {
    static let lines = [
        "Um, so I think we should, uh, go tomorrow.",                 // fillers
        "I I I think the the plan works.",                            // stutter, repeat
        "Let's meet at 3, no, sorry, at 4.",                          // cued repair
        "Oh shit, sorry, I'm late.",                                  // swear + apology (2f3ea64)
        "Oh shit, sorry, I am late.",                                 // swear + apology (2f3ea64)
        "Oh shit, sorry, I'm running late.",  // 2f3ea64 CleanupKeepsWordsTests
        "Oh shit, sorry, I forgot.",  // 2f3ea64 CleanupKeepsWordsTests
        "Oh, shit, sorry, I was on mute.",  // 2f3ea64 CleanupKeepsWordsTests
        "Shit, sorry, wrong chat.",  // 2f3ea64 CleanupKeepsWordsTests
        "Oh shit, sorry.",  // 2f3ea64 CleanupKeepsWordsTests
        "Oh shit sorry I'm late.",  // 2f3ea64 CleanupKeepsWordsTests
        "Damn, sorry, I missed it.",  // 2f3ea64 CleanupKeepsWordsTests
        "Oh no, sorry, I didn't see that.",  // 2f3ea64 CleanupKeepsWordsTests
        "Fuck, I forgot the keys, sorry about that.",                 // swear + apology
        "Sorry, I mean, damn it, the meeting moved.",                 // apology + cue + swear
        "First line new line second line new paragraph third",        // spoken commands
        "Send it now scratch that wait for Maya",                     // spoken command
        "i think so",                                                 // style: i -> I, full stop
        "hello there. how are you",                                   // style: sentence capitals
        "Wait , what ?",                                              // tidy: space before punctuation
        ", and then we left",                                         // tidy: leading comma
        "Well, basically, you know, it works.",                       // discourse markers
        "Tencent and Nvidia shipped it.",                             // dictionary-style names
        "We need, like, three, three things.",                        // filler + repeat
    ]

    func testFinishedTextIsTheRecognizersText() {
        var changed: [String] = []
        for raw in Self.lines {
            let out = DictationText.finish(raw)
            if out != raw { changed.append("\(raw) -> \(out)") }
        }
        XCTAssertEqual(changed, [], "rule rewrites ran:\n" + changed.joined(separator: "\n"))
    }

    func testEveryWordSurvives() {
        for raw in Self.lines {
            let words = raw.split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(DictationText.finish(raw).split(whereSeparator: \.isWhitespace), words, raw)
        }
    }

    func testOnlyTrimsTheEnds() {
        XCTAssertEqual(DictationText.finish("  Oh shit, sorry.  \n"), "Oh shit, sorry.")
        XCTAssertEqual(DictationText.finish("   "), "")
    }
}
