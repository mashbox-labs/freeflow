import FreeFlowKit
import XCTest

/// The model picker's data and rules: the bundled catalog, the automatic pick, the order, too big, extra small,
/// and the speeds measured on the device.
final class ModelCatalogTests: XCTestCase {
    private let gib = 1_073_741_824.0
    private func bytes(_ g: Double) -> UInt64 { UInt64(g * gib) }

    /// A catalog with an extra-small entry, the way a new model would arrive: data only.
    private let fixture = """
    {"models": [
      {"id": "small", "tier": "small", "name": "Whisper small", "maker": "OpenAI", "makerLogo": "logo-openai", "parameters": "244M",
       "languages": "99 languages", "languageCodes": null, "licence": "MIT", "runtime": "Core ML", "engine": "whisperkit",
       "downloadBytes": 220113912, "minMemoryGiB": 0, "recommendFromGiB": 0, "preference": 1, "blurb": "b", "quality": null},
      {"id": "medium", "tier": "medium", "name": "Parakeet", "maker": "NVIDIA", "makerLogo": "logo-nvidia", "parameters": "600M",
       "languages": "25", "languageCodes": ["en", "de"], "licence": "CC-BY-4.0", "runtime": "Core ML", "engine": "parakeet-v3",
       "downloadBytes": 483105645, "minMemoryGiB": 0, "recommendFromGiB": 5.0, "preference": 3, "blurb": "b", "quality": null},
      {"id": "large", "tier": "large", "name": "Whisper large-v3-turbo", "maker": "OpenAI", "makerLogo": "logo-openai", "parameters": "809M",
       "languages": "99 languages", "languageCodes": null, "licence": "MIT", "runtime": "Core ML", "engine": "whisperkit",
       "downloadBytes": 648662093, "minMemoryGiB": 7.0, "recommendFromGiB": 7.0, "preference": 2, "blurb": "b", "quality": null},
      {"id": "tiny-q", "tier": "xsmall", "name": "Our quantized model", "maker": "MASHBOX Labs", "makerLogo": null, "parameters": "100M",
       "languages": "25", "languageCodes": ["en", "de"], "licence": "Apache-2.0", "runtime": "Core ML", "engine": "parakeet-v3",
       "downloadBytes": 90000000, "minMemoryGiB": 0, "recommendFromGiB": null, "preference": 0, "blurb": "b",
       "quality": {"werPercent": 2.5, "testSet": "LibriSpeech test-clean", "measuredBy": "MASHBOX Labs", "date": "2026-10-29"}}
    ]}
    """

    private func fixtureModels() throws -> [SpeechModel] { try ModelCatalog.decode(Data(fixture.utf8)) }

    func testBundledCatalogLoads() {
        // Core ML models; the C++ entries are checked in CppCatalogTests.
        let ids = ModelCatalog.all.filter { !$0.engine.isCpp }.map(\.id)
        // Build 23: Parakeet Ultra, Phonon-2, Parakeet Redux, and the C++ backup, plus Underdog Bark 3.0 Clean and Pro
        // (Conway Research). Nemotron Unified dropped: without live words it adds nothing Ultra does not.
        XCTAssertEqual(ids, ["parakeet-ultra", "phonon-2", "parakeet-redux", "bark-3.0-clean", "bark-3-pro"])
        for id in ids { XCTAssertEqual(ModelCatalog.model(id)?.engine, .parakeetV3, id) }
        XCTAssertNil(ModelCatalog.model("nemotron-unified"))
        // Never the automatic pick: only Ultra (and Redux below 5 GB) are.
        for id in ["phonon-2", "bark-3.0-clean", "bark-3-pro"] { XCTAssertNil(ModelCatalog.model(id)?.recommendFromGiB, id) }
        XCTAssertFalse(ModelCatalog.all.contains { $0.engine == .whisperKit || $0.engine == .ggmlAudioLLM })
        XCTAssertEqual(ModelCatalog.parakeetLanguages.count, 25)
        XCTAssertEqual(ModelCatalog.model("phonon-2")?.languageCodes, ["en"])
        XCTAssertNil(ModelCatalog.extraSmall())
        for id in ModelCatalog.removed.keys { XCTAssertNil(ModelCatalog.model(id), id) }
    }

    /// The catalog's download sizes are the manifest's: model files plus tokenizer.
    func testDownloadBytesMatchManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("App/Resources/model-manifest.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        for model in ModelCatalog.all {
            let parts = [json[model.id], json[model.id + ".tokenizer"]].compactMap { $0?["bytes"] as? NSNumber }
            XCTAssertFalse(parts.isEmpty, "\(model.id) has no manifest entry")
            XCTAssertEqual(parts.reduce(Int64(0)) { $0 + $1.int64Value }, model.downloadBytes, model.id)
        }
    }

    /// Build 23: Parakeet Ultra from 5 GB (as v3 was), for every language (one it doesn't cover transcribes in English
    /// until its model comes); Parakeet Redux, the smallest, below that. Phonon-2 is never the automatic pick.
    func testRecommendation() {
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(3.7), language: "en").id, "parakeet-redux")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(5.6), language: "en").id, "parakeet-ultra")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(7.5), language: "en").id, "parakeet-ultra")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(11.2), language: "en").id, "parakeet-ultra")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(7.5), language: "th").id, "parakeet-ultra")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(5.6), language: "ja").id, "parakeet-ultra")
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(3.7), language: "ja").id, "parakeet-redux")
        XCTAssertEqual(ModelCatalog.defaultPick, "parakeet-ultra")
    }

    /// A pick that left the catalog moves with one plain line.
    func testMovedLine() {
        let ultra = ModelCatalog.model("parakeet-ultra")!
        XCTAssertEqual(ModelCatalog.movedLine(from: "whisper-small-f16", to: ultra, downloaded: true),
                       "Whisper small 16-bit is no longer offered, so Free Flow now uses Parakeet Ultra.")
        XCTAssertEqual(ModelCatalog.movedLine(from: "medium", to: ultra, downloaded: false),
                       "Parakeet TDT 0.6B v3 is no longer offered, so Free Flow now uses Parakeet Ultra. Download it in Models (632 MB).")
    }

    func testRecommendedFirstThenBiggestFirst() throws {
        let models = try fixtureModels()
        let rec = ModelCatalog.recommended(memoryBytes: bytes(5.6), language: "en", in: models)
        XCTAssertEqual(rec.id, "medium")
        XCTAssertEqual(ModelCatalog.pickerOrder(recommended: rec, in: models).map(\.id), ["medium", "large", "small", "tiny-q"])
        let small = ModelCatalog.recommended(memoryBytes: bytes(3.7), language: "en", in: models)
        XCTAssertEqual(ModelCatalog.pickerOrder(recommended: small, in: models).map(\.id), ["small", "large", "medium", "tiny-q"])
        // The bundled catalog: every model listed once.
        let shipped = ModelCatalog.pickerOrder(recommended: ModelCatalog.recommended(memoryBytes: bytes(11.2), language: "en"))
        XCTAssertEqual(shipped.map(\.id), ["parakeet-ultra", "bark-3-pro", "bark-3.0-clean", "phonon-2", "parakeet-redux"])
    }

    func testTooBigByMemory() throws {
        let large = try XCTUnwrap(fixtureModels().first { $0.id == "large" })
        XCTAssertFalse(large.fits(memoryBytes: bytes(5.6)))
        XCTAssertTrue(large.fits(memoryBytes: bytes(7.5)))
        XCTAssertEqual(ModelCatalog.tooBigReason(large, memoryBytes: bytes(5.6), device: "iPhone"),
                       "Needs 8 GB of memory. This iPhone has 6 GB.")
        XCTAssertEqual(ModelCatalog.tooBigReason(large, memoryBytes: bytes(3.7), device: "iPad"),
                       "Needs 8 GB of memory. This iPad has 4 GB.")
        XCTAssertNil(ModelCatalog.tooBigReason(large, memoryBytes: bytes(7.5), device: "iPhone"))
        // Every model in the catalog stays pickable on 4 GB devices (Ultra is not recommended there, but it fits).
        for m in ModelCatalog.all where !m.engine.isCpp { XCTAssertTrue(m.fits(memoryBytes: bytes(3.7)), m.id) }
    }

    func testExtraSmallSlotsInFromData() throws {
        let models = try fixtureModels()
        let xs = try XCTUnwrap(ModelCatalog.extraSmall(in: models))
        XCTAssertEqual(xs.id, "tiny-q")
        XCTAssertEqual(xs.tier.title, "Extra small")
        // Never the automatic pick (recommendFromGiB null), on any memory or language.
        for g in [3.7, 5.6, 7.5, 15.6] {
            for lang in ["en", "de", "th"] {
                XCTAssertNotEqual(ModelCatalog.recommended(memoryBytes: bytes(g), language: lang, in: models).id, "tiny-q")
            }
        }
        XCTAssertEqual(xs.quality?.line, "2.5% word errors on LibriSpeech test-clean (measured by MASHBOX Labs, 2026-10-29)")
    }

    func testReasonLine() {
        XCTAssertEqual(ModelCatalog.reason(for: ModelCatalog.model("parakeet-ultra")!, memoryBytes: bytes(11.2), language: "en", device: "iPhone"),
                       "Picked for this iPhone's 12 GB of memory and your language, English.")
        XCTAssertEqual(ModelCatalog.reason(for: ModelCatalog.model("parakeet-redux")!, memoryBytes: bytes(3.7), language: "de", device: "iPhone"),
                       "Picked for this iPhone's 4 GB of memory and your language, German.")
        // A language the model doesn't speak is never named as the reason.
        XCTAssertEqual(ModelCatalog.reason(for: ModelCatalog.model("parakeet-ultra")!, memoryBytes: bytes(7.5), language: "th", device: "iPad"),
                       "Picked for this iPad's 8 GB of memory.")
    }

    func testMarketingMemory() {
        XCTAssertEqual(DeviceProfile.marketingGB(memoryBytes: bytes(3.7)), 4)
        XCTAssertEqual(DeviceProfile.marketingGB(memoryBytes: bytes(5.6)), 6)
        XCTAssertEqual(DeviceProfile.marketingGB(memoryBytes: bytes(7.5)), 8)
        XCTAssertEqual(DeviceProfile.marketingGB(memoryBytes: bytes(11.2)), 12)
        XCTAssertEqual(DeviceProfile.marketingGB(memoryBytes: bytes(15.6)), 16)
        XCTAssertEqual(DeviceProfile.marketingGB(gib: 7.0), 8)
    }

    func testCatalogChecks() {
        XCTAssertThrowsError(try ModelCatalog.decode(Data(#"{"models": []}"#.utf8)))
        let dup = fixture.replacingOccurrences(of: #""id": "large""#, with: #""id": "small""#)
        XCTAssertThrowsError(try ModelCatalog.decode(Data(dup.utf8)))
        let noFallback = fixture.replacingOccurrences(of: #""recommendFromGiB": 0,"#, with: #""recommendFromGiB": 1,"#)
        XCTAssertThrowsError(try ModelCatalog.decode(Data(noFallback.utf8)))
    }

    func testMeasuredSpeed() {
        var m = MeasuredSpeed()
        XCTAssertNil(m.line(device: "iPhone"))
        XCTAssertFalse(m.add(audioSeconds: 0.5, processSeconds: 0.1), "clips under 1 s are not counted")
        XCTAssertFalse(m.add(audioSeconds: 5, processSeconds: 0))
        XCTAssertTrue(m.add(audioSeconds: 14.0, processSeconds: 1.58))   // 8.86x
        XCTAssertEqual(m.line(device: "iPhone"), "Measured on this iPhone: 8.9x real time, median of 1 dictation")
        m.add(audioSeconds: 10, processSeconds: 0.5)   // 20x
        m.add(audioSeconds: 10, processSeconds: 1.0)   // 10x
        XCTAssertEqual(m.median, 10)
        XCTAssertEqual(m.line(device: "iPad"), "Measured on this iPad: 10x real time, median of 3 dictations")
        for _ in 0..<30 { m.add(audioSeconds: 3, processSeconds: 1) }
        XCTAssertEqual(m.count, MeasuredSpeed.keep)
        XCTAssertEqual(m.median, 3)
        let round = try? JSONDecoder().decode(MeasuredSpeed.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(round, m)
    }
}
