// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddHooks",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddHooks", targets: ["CoddHooks"]),
        // For the app's Xcode tool targets `codd-hook` and `codd-statusline` (Tools/…), which are
        // embedded in CODD.app like codd-holder; the SwiftPM executables below are the same programs.
        .library(name: "CoddHookClient", targets: ["CoddHookClient"]),
        .executable(name: "codd-hook", targets: ["codd-hook"]),
        // The status-line command (M3 D8); the app's Xcode tool target `codd-statusline`
        // (Tools/codd-statusline) is the same program.
        .executable(name: "codd-statusline", targets: ["codd-statusline"]),
    ],
    dependencies: [
        .package(path: "../CoddCore"),
    ],
    targets: [
        // Loopback HTTP/1.1 client, JSON scanner, and the codd-hook / codd-statusline command logic.
        // Standard library + Darwin only (no Foundation): codd-hook runs on every SessionStart and
        // codd-statusline on every status-line refresh, so their startup time is on Claude's
        // critical path. Shared with CoddHooks for the /health probe and the report decoder.
        .target(name: "CoddHookClient"),
        // Hook endpoint (NWListener), HTTP parser, config.json, registry watcher, state engine.
        .target(
            name: "CoddHooks",
            dependencies: [
                "CoddHookClient",
                .product(name: "CoddCore", package: "CoddCore"),
            ]
        ),
        // SessionStart command hook: stdin JSON → POST to the CODD endpoint, always exit 0, no stdout.
        // -dead_strip_dylibs drops the Foundation load command the toolchain adds to every Swift
        // executable (same as codd-holder), which keeps dyld work at startup minimal.
        .executableTarget(
            name: "codd-hook", dependencies: ["CoddHookClient"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]),
        // Status-line command: report rate_limits, run the user's chained status line (D8).
        .executableTarget(
            name: "codd-statusline", dependencies: ["CoddHookClient"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]),
        .testTarget(name: "CoddHookClientTests", dependencies: ["CoddHookClient"]),
        .testTarget(
            name: "CoddHooksTests",
            // codd-hook and codd-statusline are dependencies so `swift test` builds the binaries the
            // end-to-end tests run.
            dependencies: ["CoddHooks", "CoddHookClient", "codd-hook", "codd-statusline",
                           .product(name: "CoddCore", package: "CoddCore")]
        ),
    ]
)
