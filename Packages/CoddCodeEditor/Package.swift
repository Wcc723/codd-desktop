// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddCodeEditor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddCodeEditor", targets: ["CoddCodeEditor"]),
        .executable(name: "codd-code-demo", targets: ["codd-code-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The file editor's code view (M4 D11 / D27 / D28): a TextKit 1 text view with the
        // FileEditor artboard's gutter, native per-language lexers applied as temporary attributes,
        // the find / replace widget, inline AI diff hunks as block decorations and the overview
        // ruler. No CoddCore / CoddFiles / App types: the app maps its data in (integration I3).
        .target(name: "CoddCodeEditor", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-code-demo --fonts <dir> --snapshot <dir>` renders the artboard's punch.vue view and
        // TypeScript / JSON / Python samples offscreen; without `--snapshot` it opens a window.
        .executableTarget(name: "codd-code-demo", dependencies: [
            "CoddCodeEditor", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddCodeEditorTests", dependencies: [
            "CoddCodeEditor", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
