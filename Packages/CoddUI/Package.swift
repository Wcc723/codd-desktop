// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddUI", targets: ["CoddUI"]),
        .executable(name: "codd-ui-gallery", targets: ["codd-ui-gallery"]),
    ],
    targets: [
        // The Phosphor Console design system (D30): the app's tokens, fonts, drawing helpers and
        // controls copied verbatim from App/ with `public` / `open` added (see MIGRATION.md), plus
        // the M3 primitives the STATUS, Settings and dialog packages build on. AppKit only.
        .target(name: "CoddUI", exclude: ["MIGRATION.md"]),
        // `codd-ui-gallery --fonts <dir> --snapshot <dir>` renders specimen boards of every control
        // and primitive (all states) to PNGs and exits; without `--snapshot` it opens a window.
        .executableTarget(name: "codd-ui-gallery", dependencies: ["CoddUI"]),
        .testTarget(name: "CoddUITests", dependencies: ["CoddUI"]),
    ],
    swiftLanguageModes: [.v6]
)
