// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReaperKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReaperFS", targets: ["ReaperFS"]),
        .library(name: "ReaperFSTesting", targets: ["ReaperFSTesting"]),
        .library(name: "ReaperRules", targets: ["ReaperRules"]),
        .library(name: "ReaperEngine", targets: ["ReaperEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "ReaperFS"),
        .target(name: "ReaperFSTesting", dependencies: ["ReaperFS"]),
        .target(name: "ReaperRules", dependencies: ["Yams"], resources: [.copy("Resources/BuiltinRules")]),
        .target(name: "ReaperEngine", dependencies: ["ReaperFS", "ReaperRules"]),
        .testTarget(name: "ReaperFSTests", dependencies: ["ReaperFS", "ReaperFSTesting"]),
        .testTarget(
            name: "ReaperRulesTests",
            // The engine supplies the checks rules are validated against.
            dependencies: ["ReaperRules", "ReaperEngine", "Yams"],
            resources: [.copy("Conformance")]
        ),
        .testTarget(name: "ReaperEngineTests", dependencies: ["ReaperEngine", "ReaperFSTesting", "ReaperRules"]),
    ]
)
