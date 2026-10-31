import XCTest
@testable import FreeFlowKit

/// Build 12 (2026-10-30): anything that can use Core ML should, falling back to C++.
/// Core ML is the default and the recommended choice; a C++ form of the same model stays on the Models page,
/// labelled as the fallback, and is never marked recommended.
final class CoreMLFirstTests: XCTestCase {
    static let gibs: [Double] = [2, 3, 4, 5, 6, 7, 8, 12, 16]
    /// (C++ form, its Core ML twin) for every C++ model that has one.
    var twins: [(SpeechModel, SpeechModel)] { ModelCatalog.all.compactMap { m in ModelCatalog.coreMLTwin(of: m).map { (m, $0) } } }

    func testEveryCppFormWithACoreMLTwinFindsIt() {
        XCTAssertEqual(Set(twins.map(\.0.id)), ["parakeet-gguf-q4_0", "parakeet-gguf-q4_k", "parakeet-gguf-q8_0"])
        for (cpp, core) in twins { XCTAssertEqual(core.id, "parakeet-ultra", cpp.id); XCTAssertFalse(core.engine.isCpp) }
        for m in ModelCatalog.all where !m.engine.isCpp { XCTAssertNil(ModelCatalog.coreMLTwin(of: m), m.id) }
    }

    /// Every model with both forms resolves to Core ML on a supported device: the automatic pick is never C++, and
    /// wherever a C++ twin fits, its Core ML form fits too.
    func testBothFormsResolveToCoreMLOnASupportedDevice() {
        for g in Self.gibs {
            let bytes = UInt64(g * ModelCatalog.gib)
            for lang in ["en", "de", "pt", "ja"] {
                XCTAssertFalse(EngineDefault.model(memoryBytes: bytes, language: lang).engine.isCpp, "\(g) GiB \(lang)")
                XCTAssertFalse(ModelCatalog.recommended(memoryBytes: bytes, language: lang).engine.isCpp, "\(g) GiB \(lang)")
            }
            for (cpp, core) in twins where cpp.fits(memoryBytes: bytes) {
                XCTAssertTrue(core.fits(memoryBytes: bytes), "\(g) GiB: \(cpp.id) fits, \(core.id) doesn't")
            }
        }
    }

    func testCardsSayTheirBackendAndCppTwinsAreNeverRecommended() {
        for (cpp, _) in twins {
            XCTAssertEqual(ModelCatalog.backendLabel(for: cpp), "C++, for when Core ML isn't available", cpp.id)
            for g in Self.gibs {
                XCTAssertFalse(ModelCatalog.showsRecommendedFile(cpp, memoryBytes: UInt64(g * ModelCatalog.gib)), "\(cpp.id) \(g) GiB")
            }
        }
        for m in ModelCatalog.all where !m.engine.isCpp { XCTAssertEqual(ModelCatalog.backendLabel(for: m), "Core ML", m.id) }
    }

    /// In each Models page section the Core ML forms come before any C++ form (the 356 MB C++ Q4_0 card used to
    /// come first in Parakeet, above the 483 MB Core ML card).
    func testCoreMLComesFirstInEverySection() {
        for s in ModelCatalog.sections() {
            let cpp = s.models.map(\.engine.isCpp)
            XCTAssertEqual(cpp, cpp.sorted { !$0 && $1 }, s.id)
        }
        XCTAssertEqual(ModelCatalog.sections().first { $0.id == "parakeet" }?.models.first?.id, "parakeet-redux")
    }
}
