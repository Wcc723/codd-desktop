// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddFiles",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddFiles", targets: ["CoddFiles"]),
        .library(name: "CoddFileEditorUI", targets: ["CoddFileEditorUI"]),
        .executable(name: "codd-files-demo", targets: ["codd-files-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The local file editor's model layer (M4 D24–D27): read-only git, the lazy tree, text
        // codecs, file / folder watching, the save rules, the open-tab state machine, line diffs and
        // the recent / AI-touch stores. Foundation + CoreServices (FSEvents) only, no AppKit.
        .target(name: "CoddFiles"),
        // The FileEditor artboard chrome (tree, tab strip, toolbar, disk banner, status items,
        // dirty-close sheet) over value models with closures; the code view is an NSView slot.
        .target(name: "CoddFileEditorUI", dependencies: [
            "CoddFiles", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        // `codd-files-demo --fonts <dir> --snapshot <dir>` renders the FileEditor composition
        // (1440 × 900, offscreen) to a PNG and exits.
        .executableTarget(name: "codd-files-demo", dependencies: [
            "CoddFiles", "CoddFileEditorUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddFilesTests", dependencies: ["CoddFiles"]),
        .testTarget(name: "CoddFileEditorUITests", dependencies: [
            "CoddFiles", "CoddFileEditorUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
