// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TBTool",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-Foundation engine: model, JSON store, import, posting rules, consolidation, exports.
        .target(name: "TBCore", path: "Sources/TBCore"),
        // The Mac app.
        .executableTarget(name: "TBTool", dependencies: ["TBCore"], path: "Sources/TBTool"),
        // Command-line access to the same engine (scripting / automation).
        .executableTarget(name: "tbcli", dependencies: ["TBCore"], path: "Sources/tbcli"),
        // The fixtures are made-up trial balances the tests read straight from disk.
        .testTarget(name: "TBCoreTests", dependencies: ["TBCore"], path: "Tests/TBCoreTests", exclude: ["Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
