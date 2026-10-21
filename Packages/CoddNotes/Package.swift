// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddNotes",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddNotes", targets: ["CoddNotes"]),
    ],
    dependencies: [
        // The notes index (D5). Pinned exactly: the index schema and the FTS5 raw SQL were verified
        // against this release with the system SQLite (3.54, FTS5 with the trigram tokenizer).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        // Notes storage (Markdown files + frontmatter), the derived SQLite index and CJK search,
        // the FSEvents watcher, history snapshots, image assets and annotations, retention, AI text.
        // No AppKit: the MCP backend calls this off the main actor.
        .target(
            name: "CoddNotes",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .testTarget(name: "CoddNotesTests", dependencies: ["CoddNotes"]),
    ],
    swiftLanguageModes: [.v6]
)
