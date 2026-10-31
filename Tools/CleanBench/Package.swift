// swift-tools-version: 6.0
import PackageDescription

// Mac-only bench for the cleanup work (not part of the app). asrbench runs the app's three speech
// models on a folder of clips; cleanbench runs the cleanup levels on text.
let package = Package(
    name: "CleanBench",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../../Packages/FluidAudio"),
        .package(path: "../../Packages/WhisperKit"),
        .package(path: "../../Packages/FreeFlowKit"),
        .package(path: "../../Packages/FreeFlowTagger"),
        .package(path: "../../Packages/FreeFlowRules"),
    ],
    targets: [
        .executableTarget(name: "asrbench", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .executableTarget(name: "cleanbench", dependencies: [
            .product(name: "FreeFlowKit", package: "FreeFlowKit"),
            .product(name: "FreeFlowTagger", package: "FreeFlowTagger"),
            .product(name: "FreeFlowRules", package: "FreeFlowRules"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
