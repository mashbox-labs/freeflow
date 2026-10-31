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
}
