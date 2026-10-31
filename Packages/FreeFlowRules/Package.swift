// swift-tools-version: 6.0
import PackageDescription

// Bench only: the rule-based cleanup and style formatter that builds 1-11 ran on dictated text. The app, keyboard
// and widgets do not link it (build 12, 2026-10-30: no rule-based rewrites). CleanBench and the tagger bench
// use it as a comparison arm.
let package = Package(
    name: "FreeFlowRules",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FreeFlowRules", targets: ["FreeFlowRules"])],
    dependencies: [.package(path: "../FreeFlowKit")],
    targets: [
        .target(name: "FreeFlowRules", dependencies: [.product(name: "FreeFlowKit", package: "FreeFlowKit")]),
        .testTarget(name: "FreeFlowRulesTests", dependencies: ["FreeFlowRules", .product(name: "FreeFlowKit", package: "FreeFlowKit")]),
    ],
    swiftLanguageModes: [.v5]
)
