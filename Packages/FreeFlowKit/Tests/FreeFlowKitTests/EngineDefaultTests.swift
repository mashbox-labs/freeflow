import XCTest
@testable import FreeFlowKit

/// Build 9 (2026-10-29): Core ML is the default engine; C++ Parakeet v3 Q4_0 is the fallback when Core ML
/// can't load on a device, and a manual pick. Nobody is moved between engines.
final class EngineDefaultTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testFreshInstallDefaultIsTheCoreMLRecommendationOnEveryMemorySize() {
        for memory in [3.5, 4.0, 5.6, 7.5, 11.2, 15.0] {
            let bytes = UInt64(memory * Double(gib))
            let m = EngineDefault.model(memoryBytes: bytes, language: "en")
            XCTAssertFalse(m.engine.isCpp, "\(memory) GiB")
            XCTAssertEqual(m.id, ModelCatalog.recommended(memoryBytes: bytes, language: "en").id, "\(memory) GiB")
        }
        XCTAssertFalse(EngineDefault.model(memoryBytes: 8 * gib, language: "ja").engine.isCpp)
    }

    func testCoreMLLoadFailureFallsBackToCppWhenItsFileIsOnTheDevice() {
        let m = EngineDefault.fallback(after: "parakeet-ultra", readyIDs: ["parakeet-ultra", "parakeet-gguf-q4_0"], memoryBytes: 8 * gib, language: "en")
        XCTAssertEqual(m?.id, "parakeet-gguf-q4_0")
        XCTAssertEqual(m?.engine.isCpp, true)
    }

    func testNoFallbackWithoutTheCppFile() {
        XCTAssertNil(EngineDefault.fallback(after: "parakeet-ultra", readyIDs: ["parakeet-ultra"], memoryBytes: 8 * gib, language: "en"))
    }

    func testAFailedCppModelNeverFallsBackHere() {
        XCTAssertNil(EngineDefault.fallback(after: "parakeet-gguf-q8_0", readyIDs: ["parakeet-gguf-q8_0", "parakeet-gguf-q4_0"],
                                            memoryBytes: 8 * gib, language: "en"))
    }

    func testNoFallbackForALanguageParakeetDoesNotCover() {
        XCTAssertNil(EngineDefault.fallback(after: "parakeet-ultra", readyIDs: ["parakeet-ultra", "parakeet-gguf-q4_0"], memoryBytes: 8 * gib, language: "ja"))
    }

    func testUnknownModelHasNoFallback() {
        XCTAssertNil(EngineDefault.fallback(after: "nope", readyIDs: ["parakeet-gguf-q4_0"], memoryBytes: 8 * gib, language: "en"))
    }

    func testNoticeNamesBothModels() {
        let cpp = ModelCatalog.model("parakeet-gguf-q4_0")!
        let line = EngineDefault.fallbackNotice(failed: "Parakeet TDT 0.6B v3", to: cpp)
        XCTAssertTrue(line.contains("Parakeet TDT 0.6B v3"))
        XCTAssertTrue(line.contains(cpp.name))
        XCTAssertTrue(line.contains("C++"))
    }

    /// Build 23 (FluidAudio #828: an int8 encoder like Ultra's did not load on an A16 iPhone, on any compute unit): a
    /// Core ML model on the device first, else the recommendation without the models that failed here.
    func testCoreMLFallbackAfterUltraFailsToLoad() {
        let ready = EngineDefault.coreMLFallback(after: "parakeet-ultra", failedIDs: [], readyIDs: ["parakeet-ultra", "phonon-2"],
                                                 memoryBytes: 8 * gib, language: "en")
        XCTAssertEqual(ready?.id, "phonon-2", "on the device: dictation works at once")
        XCTAssertEqual(EngineDefault.coreMLFallback(after: "parakeet-ultra", failedIDs: [], readyIDs: ["parakeet-ultra", "phonon-2"],
                                                    memoryBytes: 8 * gib, language: "de")?.id, "whisper-turbo-ane",
                       "Phonon-2 is English only: a German speaker on 8 GB gets the recommendation, our Whisper (build 39)")
        XCTAssertEqual(EngineDefault.coreMLFallback(after: "parakeet-ultra", failedIDs: [], readyIDs: ["parakeet-ultra"],
                                                    memoryBytes: 8 * gib, language: "en")?.id, "whisper-turbo-ane")
        // Below 7 GiB Whisper large doesn't fit: Redux, as before.
        XCTAssertEqual(EngineDefault.coreMLFallback(after: "parakeet-ultra", failedIDs: [], readyIDs: ["parakeet-ultra"],
                                                    memoryBytes: 6 * gib, language: "de")?.id, "parakeet-redux")
        let everyCoreML = Set(ModelCatalog.all.filter { !$0.engine.isCpp }.map(\.id))
        XCTAssertNil(EngineDefault.coreMLFallback(after: "parakeet-redux", failedIDs: everyCoreML, readyIDs: [],
                                                  memoryBytes: 8 * gib, language: "en"), "nothing left: the error stands")
        let redux = ModelCatalog.model("parakeet-redux")!
        XCTAssertEqual(EngineDefault.coreMLFallbackNotice(failed: "Parakeet Ultra", to: redux, downloaded: false, device: "iPhone"),
                       "Core ML could not load Parakeet Ultra on this iPhone, so Free Flow now uses Parakeet Redux. Download it in Models (220 MB).")
    }
}
