import XCTest
@testable import FreeFlowKit

/// The Models page's data (every size and quantization of Parakeet, Whisper and Liquid AI's models
/// as options): its sections, what each card shows, and that every speed is a measured simulator number.
final class ModelsPageTests: XCTestCase {
    func testSectionsHoldEveryModelOnce() {
        let sections = ModelCatalog.sections()
        XCTAssertEqual(sections.map(\.id), ["parakeet", "bark"])
        XCTAssertEqual(sections[1].models.map(\.id), ["bark-3.0-clean", "bark-3-pro"])
        let ids = sections.flatMap { $0.models.map(\.id) }
        XCTAssertEqual(ids.count, ModelCatalog.all.count)
        XCTAssertEqual(Set(ids), Set(ModelCatalog.all.map(\.id)))
        // Smallest download first inside each section.
        for s in sections {  // Core ML first, then smallest first within each engine
            for cpp in [false, true] {
                let sizes = s.models.filter { $0.engine.isCpp == cpp }.map(\.downloadBytes)
                XCTAssertEqual(sizes, sizes.sorted(), s.id)
            }
        }
    }

    func testParakeetHasCoreMLAndThreeQuantizations() throws {
        let parakeet = try XCTUnwrap(ModelCatalog.sections().first { $0.id == "parakeet" })
        XCTAssertEqual(parakeet.models.map(\.id), ["parakeet-redux", "phonon-2", "parakeet-ultra",
                                                   "parakeet-gguf-q4_0", "parakeet-gguf-q4_k", "parakeet-gguf-q8_0"])
        XCTAssertEqual(parakeet.models.map(\.engineLabel), ["Core ML", "Core ML", "Core ML", "C++ (ggml)", "C++ (ggml)", "C++ (ggml)"])
        XCTAssertEqual(parakeet.models[0].downloadBytes, 220_304_193)
        XCTAssertEqual(parakeet.models[2].downloadBytes, 632_162_964)
        XCTAssertEqual(parakeet.models[3].downloadBytes, 355_615_679)
    }

    /// Build 23: the C++ backup is Parakeet v3, and its card says so (never a bigger or better model than Ultra).
    func testCppBackupCardsSayV3() {
        for m in ModelCatalog.all where m.engine.isCpp {
            XCTAssertEqual(ModelCatalog.backupLine(for: m),
                           "Parakeet TDT 0.6B v3, the model Parakeet Ultra was trained from: a backup for when the Neural Engine can't be used", m.id)
        }
    }

    /// Build 23: the Dictionary label only where its boost fixed a word in the Mac check (10-31): Phonon-2 and Bark 3.0
    /// Clean yes; Ultra, Redux and Bark 3.0 Pro no; the C++ engine has no boost.
    func testDictionaryOnlyWhereMeasured() {
        XCTAssertEqual(ModelCatalog.all.filter(\.usesDictionary).map(\.id), ["phonon-2", "bark-3.0-clean"])
        XCTAssertEqual(ModelCatalog.model("phonon-2")?.purpose, "Fastest · English")
    }

    /// Bark 3.0 Pro's card says its real size and that the first load takes longer, and claims no "most".
    func testBarkProCard() throws {
        let pro = try XCTUnwrap(ModelCatalog.model("bark-3-pro"))
        XCTAssertEqual(pro.downloadBytes, 1_234_585_331)
        XCTAssertEqual(pro.languageCodes, ["en"])
        XCTAssertTrue(pro.blurb.contains("The first load takes longer."))
        XCTAssertFalse((pro.blurb + (pro.purpose ?? "")).lowercased().contains("most"))
        XCTAssertFalse((pro.blurb + (pro.purpose ?? "")).lowercased().contains("largest"))
    }

    func testEveryCardHasItsFacts() {
        for m in ModelCatalog.all {
            XCTAssertNotNil(m.group, m.id)
            XCTAssertNotNil(m.quant, "\(m.id) has no quantization label")
            XCTAssertFalse(m.languages.isEmpty, m.id)
            XCTAssertGreaterThan(m.downloadBytes, 0, m.id)
        }
    }

    /// A speed on the page is always a measured simulator walk, said as such.
    func testSimSpeedLine() {
        let s = SimSpeed(audioSeconds: 15.4, processSeconds: 2.53, simulator: "iPhone Air", date: "2026-10-29")
        XCTAssertEqual(s.short, "6.1x real time")
        XCTAssertEqual(s.line, "6.1x real time on the iPhone Air simulator (15.4 s of audio in 2.53 s, 2026-10-29)")
        XCTAssertEqual(SimSpeed(audioSeconds: 13.6, processSeconds: 1.27, simulator: "iPad mini", date: "d").short, "11x real time")
        for m in ModelCatalog.all {
            guard let sim = m.simSpeed else { continue }
            XCTAssertGreaterThan(sim.audioSeconds, 5, m.id)
            XCTAssertGreaterThan(sim.processSeconds, 0, m.id)
            XCTAssertTrue(sim.line.contains("simulator"), m.id)
        }
    }

    func testUnknownGroupIsRefused() {
        let json = """
        {"groups": [{"id": "g", "name": "G", "maker": "M", "makerLogo": null, "blurb": "b"}],
         "models": [{"id": "a", "tier": "small", "name": "A", "maker": "M", "makerLogo": null, "parameters": "1M",
          "languages": "all", "languageCodes": null, "licence": "MIT", "runtime": "Core ML", "engine": "whisperkit",
          "downloadBytes": 1, "minMemoryGiB": 0, "recommendFromGiB": 0, "preference": 1, "blurb": "b", "quality": null,
          "group": "nope"}]}
        """
        XCTAssertThrowsError(try ModelCatalog.decode(Data(json.utf8)))
        XCTAssertNoThrow(try ModelCatalog.decode(Data(json.replacingOccurrences(of: "\"nope\"", with: "\"g\"").utf8)))
    }
}
