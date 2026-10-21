// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddSettingsUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddSettingsUI", targets: ["CoddSettingsUI"]),
        .executable(name: "codd-settings-demo", targets: ["codd-settings-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
        .package(path: "../CoddPreferences"),
    ],
    targets: [
        // Every section of the v3 Settings artboard (SPEC §7.12 with R5 / R8, M3 D13–D22, D28,
        // D29, D34) bound to `CoddPreferences`, the search field, the hotkey recorder and the
        // exclusive Carbon global hotkey. Facts come in as `SettingsInfo` values and edits leave
        // through `SettingsModel.onChange` / `SettingsActions`: no CoddCore or App types.
        .target(
            name: "CoddSettingsUI",
            dependencies: [
                .product(name: "CoddUI", package: "CoddUI"),
                .product(name: "CoddPreferences", package: "CoddPreferences"),
            ],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        // `codd-settings-demo --fonts <dir> --snapshot <dir>` renders all 13 sections with the
        // SPEC §5 sample at 1040 × 720 (the app's Settings window) and 1440 × 900; without
        // `--snapshot` it opens the page in a window.
        .executableTarget(name: "codd-settings-demo", dependencies: [
            "CoddSettingsUI",
            .product(name: "CoddUI", package: "CoddUI"),
            .product(name: "CoddPreferences", package: "CoddPreferences"),
        ]),
        .testTarget(name: "CoddSettingsUITests", dependencies: [
            "CoddSettingsUI",
            .product(name: "CoddUI", package: "CoddUI"),
            .product(name: "CoddPreferences", package: "CoddPreferences"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
