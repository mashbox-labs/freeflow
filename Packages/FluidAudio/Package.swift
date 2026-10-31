// swift-tools-version: 6.2
import PackageDescription

// FluidAudio v0.18.0 (github.com/FluidInference/FluidAudio, commit b6a8b391), Apache-2.0.
// Vendored as source: SwiftPM's full clone of the repository (~295 MB of history) stalls
// builds on a slow link. Only the library is kept (no CLI, tests or docs), built as upstream's
// ASR/VAD-only configuration (no `TTS` or `Diarizer` trait, so no LuxTTS G2P resources), and the
// optional NemoTextProcessing binary (used by ITN, not Parakeet) is left out; the sources guard
// it with `#if canImport(CNemoTextProcessing)`.
// Free Flow changes on top (marked "Free Flow" in the source): ChunkPacer.swift, TdtVocabularyBias.swift,
// and their hooks in AsrManager.swift, ChunkProcessor.swift and TdtDecoderV3.swift.
let package = Package(
    name: "FluidAudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FluidAudio", targets: ["FluidAudio"]),
    ],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
            path: "Sources/FluidAudio",
            exclude: ["ASR/Parakeet/Unified/benchmark.md"]
        ),
        .target(name: "FastClusterWrapper", path: "Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "Sources/MachTaskSelfWrapper", publicHeadersPath: "include"),
    ],
    cxxLanguageStandard: .cxx17
)
