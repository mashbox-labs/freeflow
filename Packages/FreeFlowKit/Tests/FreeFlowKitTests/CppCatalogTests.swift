import XCTest
@testable import FreeFlowKit

/// The C++ engine's menu: families of quantizations, the per-device pick inside a family, and Core ML staying the
/// app's automatic pick.
final class CppCatalogTests: XCTestCase {
    private func bytes(_ gib: Double) -> UInt64 { UInt64(gib * 1_073_741_824) }

    func testBundledCppEntries() throws {
        let cpp = ModelCatalog.all.filter(\.engine.isCpp)
        XCTAssertEqual(cpp.map(\.id), ["parakeet-gguf-q4_0", "parakeet-gguf-q4_k", "parakeet-gguf-q8_0"])
        for m in cpp {
            XCTAssertNotNil(m.modelFile, m.id)
            XCTAssertNotNil(m.quant, m.id)
            XCTAssertNotNil(m.family, m.id)
            if m.engine == .ggmlAudioLLM {
                XCTAssertNotNil(m.projectorFile, m.id)
                // The model card prompt: LFM3-Audio "Perform ASR in <language>."
                XCTAssertEqual(m.systemPrompt, "Perform ASR in English.", m.id)
            } else {
                XCTAssertNil(m.projectorFile, m.id)
            }
        }
    }

    func testFamiliesGroupQuantizationsSmallestFirst() {
        let families = ModelCatalog.families()
        XCTAssertEqual(families.map(\.name), ["Parakeet TDT 0.6B v3"])
        XCTAssertEqual(families[0].models.compactMap(\.quant), ["Q4_0", "Q4_K", "Q8_0"])
    }

    func testCoreMLStaysTheAutomaticPick() {
        for gib in [3.7, 5.6, 7.5, 11.2] {
            for language in ["en", "de", "th"] {
                XCTAssertFalse(ModelCatalog.recommended(memoryBytes: bytes(gib), language: language).engine.isCpp, "\(gib) \(language)")
            }
        }
    }

    func testFamilyPickPerDevice() throws {
        let parakeet = try XCTUnwrap(ModelCatalog.families().first)
        XCTAssertEqual(ModelCatalog.familyPick(parakeet, memoryBytes: bytes(3.7))?.quant, "Q4_0")
        XCTAssertEqual(ModelCatalog.familyPick(parakeet, memoryBytes: bytes(5.6))?.quant, "Q4_0")
        XCTAssertEqual(ModelCatalog.familyPick(parakeet, memoryBytes: bytes(7.5))?.quant, "Q8_0")
        XCTAssertEqual(ModelCatalog.familyPick(parakeet, memoryBytes: bytes(11.2))?.quant, "Q8_0")
    }

    private func entry(_ id: String, engine: String, min: Double, from: Double?, peak: Int?, family: String? = nil) -> String {
        let f = family.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","tier":"small","name":"\(id)","maker":"M","makerLogo":null,"parameters":"1M","languages":"all",
        "languageCodes":null,"licence":"MIT","runtime":"x","engine":"\(engine)","downloadBytes":\(id.count),"minMemoryGiB":\(min),
        "recommendFromGiB":\(from.map { String($0) } ?? "null"),"preference":1,"blurb":"b","quality":null,
        "family":\(f),"quant":"Q4_0","peakMemoryMB":\(peak.map(String.init) ?? "null"),"systemPrompt":null}
        """
    }

    private func catalog(_ entries: [String]) throws -> [SpeechModel] {
        try ModelCatalog.decode(Data("{\"models\":[\(entries.joined(separator: ","))]}".utf8))
    }

    /// The fallback every device can run must be a Core ML model: a C++ entry never satisfies it.
    func testCatalogNeedsCoreMLFallback() {
        XCTAssertThrowsError(try catalog([entry("cpp", engine: "ggml-parakeet", min: 0, from: 0, peak: 700)]))
        XCTAssertNoThrow(try catalog([entry("cpp", engine: "ggml-parakeet", min: 0, from: 0, peak: 700),
                                      entry("coreml", engine: "whisperkit", min: 0, from: 0, peak: nil)]))
    }

    /// When no Core ML model fits, the automatic pick still falls back to Core ML, never to a C++ model listed first.
    func testFallbackIsNeverCpp() throws {
        let all = try catalog([entry("cpp", engine: "ggml-parakeet", min: 0, from: 0, peak: 700),
                               entry("coreml-small", engine: "whisperkit", min: 0, from: 0, peak: nil),
                               entry("coreml-big", engine: "whisperkit", min: 7, from: 7, peak: nil)])
        let onlyBig = all.filter { $0.id != "coreml-small" }
        XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(2), language: "en", in: onlyBig).id, "coreml-big")
    }

    /// A quantization without a measured peak memory is never the RECOMMENDED pick.
    func testFamilyPickNeedsMeasuredPeak() throws {
        let all = try catalog([entry("coreml", engine: "whisperkit", min: 0, from: 0, peak: nil),
                               entry("q-measured", engine: "ggml-parakeet", min: 0, from: 0, peak: 700, family: "F"),
                               entry("q-unmeasured-bigger", engine: "ggml-parakeet", min: 0, from: 0, peak: nil, family: "F")])
        let family = try XCTUnwrap(ModelCatalog.families(in: all).first)
        XCTAssertEqual(family.models.count, 2)
        XCTAssertEqual(ModelCatalog.familyPick(family, memoryBytes: bytes(11.2))?.id, "q-measured")
        let unmeasured = try XCTUnwrap(ModelCatalog.families(in: all.filter { $0.id != "q-measured" }).first)
        XCTAssertNil(ModelCatalog.familyPick(unmeasured, memoryBytes: bytes(11.2)))
    }

    /// Every bundled C++ entry has a measured peak, so each family has a RECOMMENDED pick on a 6 GB iPhone.
    func testBundledCppEntriesAreMeasured() {
        for m in ModelCatalog.all where m.engine.isCpp { XCTAssertNotNil(m.peakMemoryMB, m.id) }
        for f in ModelCatalog.families() { XCTAssertNotNil(ModelCatalog.familyPick(f, memoryBytes: bytes(5.6)), f.name) }
    }

    /// The peak memory line shows only a measured number.
    func testPeakMemoryLine() throws {
        let all = try catalog([entry("coreml", engine: "whisperkit", min: 0, from: 0, peak: nil),
                               entry("cpp", engine: "ggml-parakeet", min: 0, from: 0, peak: 698)])
        XCTAssertNil(all[0].peakMemoryLine)
        XCTAssertEqual(all[1].peakMemoryLine, "Peak memory 698 MB while transcribing (measured on a Mac CPU with the app's engine)")
    }
}
