// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddTextKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddTextKit", targets: ["CoddTextKit"]),
        .executable(name: "codd-markdown-demo", targets: ["codd-markdown-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The notebook's Markdown editor (M4 D11): an NSTextView forced into TextKit 1 with a live
        // preview (marks hidden off the caret paragraph by glyph generation, block decorations by
        // line-fragment heights), IME-safe editing commands, the block parser, a read-only renderer
        // and a small fenced-code highlighter. AppKit + CoddUI only; no CoddNotes or App types.
        .target(name: "CoddTextKit", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-markdown-demo --fonts <dir> --snapshot <dir>` renders the SPEC §5 n1 note (live
        // preview and source mode) offscreen; without `--snapshot` it opens a window for a manual
        // 注音 try (a manual tool only, never run by automation).
        .executableTarget(name: "codd-markdown-demo", dependencies: [
            "CoddTextKit", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddTextKitTests", dependencies: [
            "CoddTextKit", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
