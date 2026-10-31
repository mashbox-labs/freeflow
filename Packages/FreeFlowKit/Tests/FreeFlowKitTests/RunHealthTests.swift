import XCTest
@testable import FreeFlowKit

/// "Won't run well on this device": memory from os_proc_available_memory() against the measured peak, then the
/// on-device speed probe. Only measured inputs decide.
final class RunHealthTests: XCTestCase {
    private func model(peakMB: Int?) throws -> SpeechModel {
        let peak = peakMB.map(String.init) ?? "null"
        let json = """
        {"models":[{"id":"fallback","tier":"small","name":"S","maker":"M","makerLogo":null,"parameters":"1M","languages":"all",
        "languageCodes":null,"licence":"MIT","runtime":"Core ML","engine":"whisperkit","downloadBytes":1,"minMemoryGiB":0,
        "recommendFromGiB":0,"preference":1,"blurb":"b","quality":null},
        {"id":"x","tier":"xsmall","name":"X","maker":"M","makerLogo":null,"parameters":"1M","languages":"all",
        "languageCodes":null,"licence":"MIT","runtime":"C++","engine":"ggml-parakeet","downloadBytes":1,"minMemoryGiB":0,
        "recommendFromGiB":0,"preference":1,"blurb":"b","quality":{"werPercent":1.5,"testSet":"t","measuredBy":"Liquid AI",
        "date":"2026-10-29","source":"vendor"},"family":"f","quant":"Q4_0","peakMemoryMB":\(peak),"systemPrompt":null}]}
        """
        return try XCTUnwrap(ModelCatalog.decode(Data(json.utf8)).first { $0.id == "x" })
    }

    func testDecodesCppFields() throws {
        let m = try model(peakMB: 700)
        XCTAssertEqual(m.engine, .ggmlParakeet)
        XCTAssertTrue(m.engine.isCpp)
        XCTAssertEqual(m.quant, "Q4_0")
        XCTAssertEqual(m.family, "f")
        XCTAssertEqual(m.quality?.label, "VENDOR")
        XCTAssertTrue(m.quality?.line.contains("published by Liquid AI") ?? false)
    }

    func testOldCatalogEntriesStillDecode() {
        XCTAssertFalse(ModelCatalog.all.isEmpty)
        // Core ML entries carry only numbers measured on their exact files; VENDOR numbers appear only on C++ entries.
        XCTAssertTrue(ModelCatalog.all.filter { !$0.engine.isCpp }.allSatisfy { ($0.quality?.label ?? "MEASURED") == "MEASURED" })
    }

    func testTooLittleMemoryWontRunWell() throws {
        let m = try model(peakMB: 1000)
        guard case .wontRunWell = ModelCatalog.runHealth(m, availableBytes: 900 * 1_048_576, probeSpeed: 30) else {
            return XCTFail("900 MB free for a 1000 MB peak must not pass")
        }
    }

    func testSlowerThanRealTimeWontRunWell() throws {
        let m = try model(peakMB: 100)
        guard case .wontRunWell = ModelCatalog.runHealth(m, availableBytes: 4_000 * 1_048_576, probeSpeed: 0.8) else {
            return XCTFail("0.8x real time must not pass")
        }
    }

    func testGoodAndNotProbed() throws {
        let m = try model(peakMB: 100)
        XCTAssertEqual(ModelCatalog.runHealth(m, availableBytes: 4_000 * 1_048_576, probeSpeed: 12), .good)
        XCTAssertEqual(ModelCatalog.runHealth(m, availableBytes: 4_000 * 1_048_576, probeSpeed: nil), .notProbed)
        XCTAssertEqual(ModelCatalog.runHealth(m, availableBytes: nil, probeSpeed: 12), .good)
    }

    /// The loaded model's own memory counts as free: switching models unloads it first, so a 1000 MB model is not
    /// flagged just because a 700 MB one is loaded right now.
    func testLoadedModelCountsAsFree() throws {
        let m = try model(peakMB: 1000)
        let mb: UInt64 = 1_048_576
        guard case .wontRunWell = ModelCatalog.runHealth(m, availableBytes: 900 * mb, probeSpeed: 30) else {
            return XCTFail("900 MB free, nothing loaded, 1000 MB peak must not pass")
        }
        XCTAssertEqual(ModelCatalog.runHealth(m, availableBytes: 900 * mb, loadedBytes: 700 * mb, probeSpeed: 30), .good)
        // Without a device reading (simulator) the loaded bytes alone never decide.
        XCTAssertEqual(ModelCatalog.runHealth(m, availableBytes: nil, loadedBytes: 700 * mb, probeSpeed: 30), .good)
    }
}
