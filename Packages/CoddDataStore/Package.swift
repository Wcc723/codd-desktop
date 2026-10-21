// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddDataStore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddDataStore", targets: ["CoddDataStore"]),
    ],
    targets: [
        // M5 D14 / D2: the data root's file inventory with each file's version rules, the migration
        // registry (backup first), the launch preflight with its banner issues, the write guard for
        // newer files and the one-time UserDefaults domain copy. Foundation only, no dependency:
        // it mirrors the stores' rules instead of importing them, so it can run before any of them.
        .target(name: "CoddDataStore"),
        .testTarget(name: "CoddDataStoreTests", dependencies: ["CoddDataStore"]),
    ],
    swiftLanguageModes: [.v6]
)
