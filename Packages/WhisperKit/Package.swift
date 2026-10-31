// swift-tools-version: 5.10
import PackageDescription

// WhisperKit from argmax-oss-swift v1.1.1 (github.com/argmaxinc/argmax-oss-swift), MIT (see LICENSE).
// Vendored as source from the release tarball: only the WhisperKit and ArgmaxCore library targets.
// The upstream manifest also declares CLI and server dependencies (Vapor, OpenAPI) that the app never links.
let package = Package(
    name: "WhisperKit",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "WhisperKit", targets: ["WhisperKit"])],
    targets: [
        .target(name: "ArgmaxCore", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "WhisperKit", dependencies: ["ArgmaxCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
    ]
)
