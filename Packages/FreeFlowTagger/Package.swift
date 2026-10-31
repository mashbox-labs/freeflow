// swift-tools-version: 6.0
import PackageDescription

// The on-device disfluency tagger behind the Clean and Polished levels: a small token classifier
// (Core ML) that marks words to delete. It never writes a word. App target only (not the keyboard).
let package = Package(
    name: "FreeFlowTagger",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FreeFlowTagger", targets: ["FreeFlowTagger"])],
    dependencies: [.package(path: "../FreeFlowKit"), .package(path: "../FreeFlowRules")],
    targets: [
        .target(name: "FreeFlowTagger", dependencies: [.product(name: "FreeFlowKit", package: "FreeFlowKit"), .product(name: "FreeFlowRules", package: "FreeFlowRules")],
                resources: [.copy("Resources/DisfluencyTagger.mlmodelc"), .copy("Resources/vocab.txt"), .copy("Resources/tagger.json")]),
        .testTarget(name: "FreeFlowTaggerTests", dependencies: ["FreeFlowTagger"]),
    ],
    swiftLanguageModes: [.v5]
)
