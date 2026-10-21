// swift-tools-version: 6.2
import PackageDescription

// The upcoming features libghostty-spm enables on its own targets. The vendored wrapper keeps them so it
// compiles exactly as upstream does (isolation inference and `nonisolated` semantics depend on them).
let wrapperSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CoddTerminal",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddTerminal", targets: ["CoddTerminal"]),
        .executable(name: "codd-term-demo", targets: ["codd-term-demo"]),
    ],
    dependencies: [
        // libghostty (prebuilt XCFramework + C header). Only the `GhosttyKit` product is used; the Swift
        // wrapper is vendored below (see README.md "Why the wrapper is vendored").
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026101301"),
        // The vendored wrapper's frame pacing. Same version libghostty-spm 2.2.2026101301 resolves.
        .package(url: "https://github.com/Lakr233/DisplayLink.git", exact: "3.0.1"),
    ],
    targets: [
        // libghostty-spm's GhosttyTerminal wrapper (MIT, @Lakr233), macOS subset, vendored at upstream
        // commit d403978 with CODD patches marked `CODD:` (replay entry point, no resource bundle).
        .target(
            name: "GhosttyWrapper",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "DisplayLink", package: "DisplayLink"),
            ],
            swiftSettings: wrapperSwiftSettings
        ),
        // CODD's terminal engine: one TerminalEngine per PTY, configuration, key-equivalent policy,
        // DA1 detector and the visible / hot / cold surface pool.
        .target(name: "CoddTerminal", dependencies: ["GhosttyWrapper"]),
        // Manual test app: one window, one terminal on a local PTY (`zsh -f`). Not used by tests.
        .executableTarget(name: "codd-term-demo", dependencies: ["CoddTerminal"]),
        .testTarget(name: "CoddTerminalTests", dependencies: ["CoddTerminal"]),
    ]
)
