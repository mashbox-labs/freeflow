// swift-tools-version: 6.0
import PackageDescription

// Shared code for the Free Flow app, its keyboard and its widgets.
let package = Package(
    name: "FreeFlowKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FreeFlowKit", targets: ["FreeFlowKit"])],
    targets: [
        .target(name: "FreeFlowKit", resources: [.process("Resources")]),
        .testTarget(name: "FreeFlowKitTests", dependencies: ["FreeFlowKit"]),
    ],
    swiftLanguageModes: [.v5]
)
