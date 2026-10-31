import XCTest
@testable import FreeFlowKit

/// The crash-loop guard: a GGUF model that kills Free Flow while it loads or runs must not kill it again at every
/// launch. The marker the dead process leaves behind sends the next launch back to Core ML, once, with one line.
final class CppCrashGuardTests: XCTestCase {
    private var dir: URL!
    private var guardUnderTest: CppCrashGuard { CppCrashGuard(url: dir.appendingPathComponent("cpp-in-progress.json")) }
    private let gib: UInt64 = 1 << 30

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("crashguard-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A load that never returned (the process died inside it) is found at the next launch, and only once.
    func testMarkerLeftByADeadLoadIsFoundOnceAtLaunch() {
        guardUnderTest.begin("parakeet-gguf-q4_0", .load)
        XCTAssertEqual(guardUnderTest.takeCrash(), CppCrashGuard.Marker(modelID: "parakeet-gguf-q4_0", phase: .load))
        XCTAssertNil(guardUnderTest.takeCrash(), "the fallback must happen once per crash, not at every launch")
    }

    func testMarkerLeftByADeadRunIsFound() {
        guardUnderTest.begin("lfm3-audio-q4_0", .run)
        XCTAssertEqual(guardUnderTest.takeCrash(), CppCrashGuard.Marker(modelID: "lfm3-audio-q4_0", phase: .run))
    }

    /// A load or run that returned (with text or with an error) leaves nothing behind.
    func testFinishedCallLeavesNoMarker() {
        guardUnderTest.begin("parakeet-gguf-q4_0", .load)
        guardUnderTest.end()
        guardUnderTest.begin("parakeet-gguf-q4_0", .run)
        guardUnderTest.end()
        XCTAssertNil(guardUnderTest.takeCrash())
    }

    /// A marker cut off mid-write still means the process died inside the engine.
    func testUnreadableMarkerStillCountsAsACrash() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"modelID\":\"parak".utf8).write(to: guardUnderTest.url)
        XCTAssertEqual(guardUnderTest.takeCrash(), CppCrashGuard.Marker(modelID: nil, phase: nil))
    }

    /// The on-disk format the gate plants by hand (scripts write this exact JSON into the app's container).
    func testPlantedMarkerFormatIsRead() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"modelID\":\"parakeet-gguf-q4_0\",\"phase\":\"load\"}".utf8).write(to: guardUnderTest.url)
        XCTAssertEqual(guardUnderTest.takeCrash(), CppCrashGuard.Marker(modelID: "parakeet-gguf-q4_0", phase: .load))
    }

    /// A C++ pick moves to a Core ML model that is already on the device, so the keyboard keeps working at once.
    func testFallbackMovesACppPickToACoreMLModelOnTheDevice() {
        let id = CppCrashGuard.fallback(activeID: "parakeet-gguf-q4_0", readyIDs: ["parakeet-redux", "parakeet-gguf-q4_0"],
                                        memoryBytes: 12 * gib)
        XCTAssertEqual(id, "parakeet-redux")
        XCTAssertEqual(CppCrashGuard.fallback(activeID: "parakeet-gguf-q8_0", readyIDs: ["parakeet-ultra", "parakeet-redux", "parakeet-gguf-q8_0"],
                                              memoryBytes: 6 * gib), "parakeet-ultra", "the device's recommendation comes first")
    }

    /// No Core ML model on the device yet: the recommendation, which then asks for its download (as on a first run).
    func testFallbackWithNoCoreMLModelOnTheDeviceIsTheRecommendation() {
        let id = CppCrashGuard.fallback(activeID: "parakeet-gguf-q4_0", readyIDs: ["parakeet-gguf-q4_0"], memoryBytes: 6 * gib)
        XCTAssertEqual(id, ModelCatalog.recommended(memoryBytes: 6 * gib).id)
        XCTAssertFalse(ModelCatalog.model(id)!.engine.isCpp)
    }

    /// A Core ML pick stays (a C++ model run once, e.g. from Retry, crashed; the pick itself is fine).
    func testFallbackKeepsACoreMLPick() {
        XCTAssertEqual(CppCrashGuard.fallback(activeID: "phonon-2", readyIDs: ["phonon-2"], memoryBytes: 12 * gib), "phonon-2")
    }

    /// One plain line that names the model and says where dictation went.
    func testNoticeIsOnePlainLine() {
        let named = CppCrashGuard.notice(for: .init(modelID: "parakeet-gguf-q4_0", phase: .load), fallbackName: "Whisper small")
        XCTAssertEqual(named, "Free Flow closed while loading Parakeet TDT 0.6B v3 Q4_0, so dictation is back on Core ML (Whisper small).")
        let unknown = CppCrashGuard.notice(for: .init(modelID: nil, phase: nil), fallbackName: "Parakeet TDT 0.6B v3")
        XCTAssertEqual(unknown, "Free Flow closed while running a C++ model, so dictation is back on Core ML (Parakeet TDT 0.6B v3).")
        XCTAssertFalse(named.contains("\n"))
    }
}
