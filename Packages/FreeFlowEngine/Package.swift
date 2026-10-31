// swift-tools-version:5.9
// FreeFlowEngine: on-device speech-to-text over llama.cpp + whisper.cpp Parakeet on ONE ggml, behind a small Swift API.
// FreeFlowSpeech.xcframework (static, iOS / iOS Simulator / macOS) is built by scripts/build-engine.sh from pinned
// sources and Engine/ff_engine.cpp.
import PackageDescription

let package = Package(
    name: "FreeFlowEngine",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "FreeFlowEngine", targets: ["FreeFlowEngine"])],
    targets: [
        .binaryTarget(name: "FreeFlowSpeech", path: "FreeFlowSpeech.xcframework"),
        .target(name: "FreeFlowEngine", dependencies: ["FreeFlowSpeech"]),
        .testTarget(name: "FreeFlowEngineTests", dependencies: ["FreeFlowEngine"]),
    ]
)
