// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddCleanupUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddCleanupUI", targets: ["CoddCleanupUI"]),
        .executable(name: "codd-cleanup-demo", targets: ["codd-cleanup-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The Cleanup page (Cleanup artboard, SPEC §7.10, M4 D29–D32): crumb, title, NOTES / SESSIONS /
        // FILES tabs, the review table with its sticky bulk bar, the CONDENSE card and the POLICY card,
        // drawn from plain value models with closures. No CoddCore, CoddNotes or App types: the app
        // maps its candidates into `CleanupPageModel` (integration step I4a).
        .target(name: "CoddCleanupUI", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-cleanup-demo --fonts <dir> --snapshot <dir>` renders the artboard composition at
        // 1368 × 900 (the window minus the rail), the SESSIONS and FILES tabs and the condense states.
        .executableTarget(name: "codd-cleanup-demo", dependencies: [
            "CoddCleanupUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddCleanupUITests", dependencies: [
            "CoddCleanupUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
