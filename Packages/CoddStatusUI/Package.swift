// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddStatusUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddStatusUI", targets: ["CoddStatusUI"]),
        .executable(name: "codd-status-demo", targets: ["codd-status-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The STATUS page (Status artboard, SPEC §7.11 with R2–R8) and its 220 px sidebar, drawn
        // from plain value models with closures. No CoddCore or App types: the app maps its data
        // into `StatusPageModel` (integration step I2).
        .target(name: "CoddStatusUI", dependencies: [.product(name: "CoddUI", package: "CoddUI")]),
        // `codd-status-demo --fonts <dir> --snapshot <dir>` renders the SPEC §5 sample and the
        // other states to PNGs at 1440 × 1300 (sidebar 220 + page).
        .executableTarget(name: "codd-status-demo", dependencies: [
            "CoddStatusUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddStatusUITests", dependencies: [
            "CoddStatusUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
