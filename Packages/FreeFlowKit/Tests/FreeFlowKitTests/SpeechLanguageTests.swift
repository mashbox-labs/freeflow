import XCTest
@testable import FreeFlowKit

final class SpeechLanguageTests: XCTestCase {
    private let whisper: Set<String> = ["en", "es", "ko", "fr", "de", "no", "zh", "ja", "jw"]

    /// The default is the device's language, pinned: never "guess per window".
    func testDefaultIsTheDeviceLanguage() {
        XCTAssertEqual(SpeechLanguage.resolve(stored: nil, preferred: ["en-US", "es-ES"], supported: whisper), "en")
        XCTAssertEqual(SpeechLanguage.resolve(stored: "", preferred: ["ko-KR"], supported: whisper), "ko")
    }

    func testAutomaticIsOptInOnly() {
        XCTAssertNil(SpeechLanguage.resolve(stored: "auto", preferred: ["en-US"], supported: whisper))
        XCTAssertNotNil(SpeechLanguage.resolve(stored: nil, preferred: ["en-US"], supported: whisper))
    }

    func testAChosenLanguageWins() {
        XCTAssertEqual(SpeechLanguage.resolve(stored: "es", preferred: ["en-US"], supported: whisper), "es")
        // A stored code the model doesn't know falls back to the device language.
        XCTAssertEqual(SpeechLanguage.resolve(stored: "xx", preferred: ["en-GB"], supported: whisper), "en")
    }

    func testDeviceCodesMapToWhisperCodes() {
        XCTAssertEqual(SpeechLanguage.code(of: "nb-NO"), "no")
        XCTAssertEqual(SpeechLanguage.code(of: "zh-Hans-CN"), "zh")
        XCTAssertEqual(SpeechLanguage.code(of: "jv"), "jw")
        XCTAssertEqual(SpeechLanguage.resolve(stored: nil, preferred: ["tlh", "fr-CA"], supported: whisper), "fr")
        XCTAssertNil(SpeechLanguage.resolve(stored: nil, preferred: ["tlh"], supported: whisper))
    }

    /// Build 26: what the decoder gets. Automatic only when chosen and only on a model with more than one language;
    /// a device language the model doesn't speak is English, never a guess.
    func testPinnedNeverGuessesUnlessChosen() {
        // 2026-11-03: nothing stored = Automatic where the engine can detect; on an engine that can't, the device's language.
        XCTAssertNil(SpeechLanguage.pinned(stored: nil, preferred: ["en-US"], supported: whisper))
        XCTAssertEqual(SpeechLanguage.pinned(stored: nil, preferred: ["en-US"], supported: whisper, automaticAllowed: false), "en")
        XCTAssertEqual(SpeechLanguage.pinned(stored: "", preferred: ["tlh"], supported: whisper), "en")
        XCTAssertEqual(SpeechLanguage.pinned(stored: "xx", preferred: ["tlh"], supported: whisper), "en")
        XCTAssertNil(SpeechLanguage.pinned(stored: "auto", preferred: ["en-US"], supported: whisper))
        // An English-only model is always English, even with Automatic stored from another model.
        XCTAssertEqual(SpeechLanguage.pinned(stored: "auto", preferred: ["ko-KR"], supported: ["en"]), "en")
        XCTAssertEqual(SpeechLanguage.pinned(stored: "ko", preferred: ["ko-KR"], supported: ["en"]), "en")
        // An engine that can't guess (Parakeet): Automatic stored from Whisper means the device's language.
        XCTAssertEqual(SpeechLanguage.pinned(stored: "auto", preferred: ["de-DE"], supported: ["en", "de"], automaticAllowed: false), "de")
        // A model without English pins to one of its own languages.
        XCTAssertEqual(SpeechLanguage.pinned(stored: "", preferred: ["tlh"], supported: ["fr", "de"]), "de")
    }

    /// English device, every way the setting can be left: the decoder is told English, so English audio can't be
    /// written as Korean, Spanish or Chinese (build 22's P0). The audio-level check is asrbench --langcheck on the Mac.
    func testEnglishDeviceAlwaysDecodesEnglish() {
        for stored in ["", "en", "xx", "zz-ZZ"] {     // nil = Automatic since 2026-11-03 (testPinnedNeverGuessesUnlessChosen)
            for preferred in [["en-US"], ["en-GB", "ko-KR"], ["en"], ["en-AU", "es-ES", "zh-Hans-CN"]] {
                XCTAssertEqual(SpeechLanguage.pinned(stored: stored, preferred: preferred, supported: whisper), "en",
                               "\(String(describing: stored)) \(preferred)")
            }
        }
    }
}
