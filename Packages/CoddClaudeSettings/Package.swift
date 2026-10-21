// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddClaudeSettings",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddClaudeSettings", targets: ["CoddClaudeSettings"]),
    ],
    targets: [
        // Claude Code user settings: order-preserving JSON, inspection of CODD web leftovers and
        // foreign hooks, the global installer (plan, diff, backup, apply, restore) and the
        // status-line chain CODD sessions inherit. Foundation only: the app and tests link it.
        .target(name: "CoddClaudeSettings"),
        // Fixtures/ holds settings texts generated once with node's JSON.stringify (numbers.json
        // by hand): the byte-for-byte round-trip references. Tests copy them into temp dirs.
        .testTarget(
            name: "CoddClaudeSettingsTests",
            dependencies: ["CoddClaudeSettings"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
