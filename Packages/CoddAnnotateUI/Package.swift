// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddAnnotateUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddAnnotateUI", targets: ["CoddAnnotateUI"]),
        .executable(name: "codd-annotate-demo", targets: ["codd-annotate-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The ImageAnnotate screen (ImageAnnotate artboard, SPEC §8 R6, M4 D10): tool strip, canvas,
        // annotation list, send options and the AI preview, edited in ORIGINAL image pixels on plain
        // value drafts. No CoddNotes or App types: the app maps its `ImageAnnotations` to
        // `AnnotationDocument` and passes the CoddNotes formatter and codec as closures.
        .target(name: "CoddAnnotateUI", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-annotate-demo --fonts <dir> --snapshot <dir>` draws a made-up 750 × 1334 placeholder
        // with the three R6 annotations and renders the screen at 1368 × 876 (Fit and 200 %).
        .executableTarget(name: "codd-annotate-demo", dependencies: [
            "CoddAnnotateUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddAnnotateUITests", dependencies: [
            "CoddAnnotateUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
