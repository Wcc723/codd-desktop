// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddNotebookUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddNotebookUI", targets: ["CoddNotebookUI"]),
        .executable(name: "codd-notebook-demo", targets: ["codd-notebook-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The Notebook chrome of M4 (Notebook artboard, SPEC §7.8, and the Split artboard's notes
        // drawer, §7.2): lists column, note list, editor chrome with its popover menus, chips row,
        // annotation summary, info panel, doc status bar, prompt footer, notes drawer, history
        // compare sheet, link / tag pickers. Plain value models and closures only (no CoddCore,
        // CoddNotes or App types); the editor itself (C4) goes into an NSView slot.
        .target(name: "CoddNotebookUI", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-notebook-demo --fonts <dir> --snapshot <dir>` renders the SPEC §5 sample offscreen:
        // the Notebook composition at 1440 × 900 with the COPY REF menu open, the drawer, the
        // history sheet and the pickers.
        .executableTarget(name: "codd-notebook-demo", dependencies: [
            "CoddNotebookUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddNotebookUITests", dependencies: [
            "CoddNotebookUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
