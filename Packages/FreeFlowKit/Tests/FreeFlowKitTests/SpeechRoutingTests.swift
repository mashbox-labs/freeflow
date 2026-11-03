import XCTest
@testable import FreeFlowKit

/// 2026-11-02: English and Parakeet's 24 other languages stay on Parakeet; Whisper only for the languages
/// Parakeet lacks; Automatic only on Whisper.
final class SpeechRoutingTests: XCTestCase {
    private let parakeet: Set<String> = ["en", "de", "fr", "es", "it", "nl", "pl", "pt", "ru", "uk", "sv", "da", "fi", "no",
                                         "cs", "sk", "sl", "hr", "bg", "ro", "hu", "et", "lv", "lt", "el", "mt"]

    func testParakeetLanguagesStayOnParakeet() {
        for code in ["en", "de", "fr", "ru", "mt"] {
            XCTAssertEqual(SpeechRouting.modelID(language: code, parakeet: "parakeet-ultra", whisper: "large", parakeetLanguages: parakeet),
                           "parakeet-ultra", code)
        }
    }

    func testOtherLanguagesGoToWhisper() {
        for code in ["th", "ko", "ja", "zh", "ar", "hi", "vi"] {
            XCTAssertEqual(SpeechRouting.modelID(language: code, parakeet: "parakeet-ultra", whisper: "large", parakeetLanguages: parakeet),
                           "large", code)
        }
    }

    func testAutomaticIsWhisperOnly() {
        XCTAssertEqual(SpeechRouting.modelID(language: nil, parakeet: "parakeet-ultra", whisper: "large", parakeetLanguages: parakeet), "large")
        // No Whisper on this device: Parakeet, which pins an unknown language to English.
        XCTAssertEqual(SpeechRouting.modelID(language: nil, parakeet: "parakeet-ultra", whisper: nil, parakeetLanguages: parakeet), "parakeet-ultra")
        XCTAssertEqual(SpeechRouting.modelID(language: "th", parakeet: "parakeet-ultra", whisper: nil, parakeetLanguages: parakeet), "parakeet-ultra")
    }

    func testTheRealCatalogRoutesThaiToWhisperAndEnglishToParakeet() throws {
        let whisper = try XCTUnwrap(ModelCatalog.all.first { $0.engine.isWhisper }, "a Whisper model in the catalog")
        let langs = ModelCatalog.parakeetLanguages
        XCTAssertTrue(langs.contains("en")); XCTAssertFalse(langs.contains("th"))
        XCTAssertEqual(SpeechRouting.modelID(language: "en", parakeet: ModelCatalog.defaultPick, whisper: whisper.id, parakeetLanguages: langs),
                       ModelCatalog.defaultPick)
        XCTAssertEqual(SpeechRouting.modelID(language: "th", parakeet: ModelCatalog.defaultPick, whisper: whisper.id, parakeetLanguages: langs),
                       whisper.id)
        XCTAssertNil(whisper.languageCodes, "Whisper lists no codes: its full set is the app's constant")
    }

    func testSettingsListsBothSets() {
        let all = SpeechRouting.languages(parakeet: parakeet, whisper: ["en", "th", "ko"])
        XCTAssertTrue(all.isSuperset(of: parakeet)); XCTAssertTrue(all.contains("th"))
        XCTAssertEqual(SpeechRouting.languages(parakeet: parakeet, whisper: nil), parakeet)
        XCTAssertEqual(SpeechRouting.engine(for: "th", parakeetLanguages: parakeet, hasWhisper: true), .whisperKit)
        XCTAssertEqual(SpeechRouting.engine(for: "en", parakeetLanguages: parakeet, hasWhisper: true), .parakeetV3)
        XCTAssertEqual(SpeechRouting.engine(for: nil, parakeetLanguages: parakeet, hasWhisper: true), .whisperKit)
        XCTAssertEqual(SpeechRouting.engine(for: "th", parakeetLanguages: parakeet, hasWhisper: false), .parakeetV3)
    }
}
