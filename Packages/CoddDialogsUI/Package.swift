// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddDialogsUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddDialogsUI", targets: ["CoddDialogsUI"]),
        .executable(name: "codd-dialogs-demo", targets: ["codd-dialogs-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The four SPEC §7.7 dialogs (StatusDialogs artboard A–D) as content views over value
        // models with closures, plus the presenter (sheet for A / B / D, child panel for C).
        // No CoddCore or App types: integration maps the app's data into the models.
        .target(name: "CoddDialogsUI", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-dialogs-demo --fonts <dir> --snapshot <dir>` renders every dialog state to PNGs.
        .executableTarget(name: "codd-dialogs-demo", dependencies: [
            "CoddDialogsUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddDialogsUITests", dependencies: [
            "CoddDialogsUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
