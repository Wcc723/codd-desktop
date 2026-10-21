// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddPreferences",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddPreferences", targets: ["CoddPreferences"]),
    ],
    targets: [
        // The Settings model (`CoddPreferences`, every row of the v3 Settings artboard with its
        // default) and `<dataRoot>/preferences.json` (M3 D14). Foundation only, no dependency, so the
        // Settings UI package and the app can both use it without pulling in CoddCore.
        .target(name: "CoddPreferences"),
        .testTarget(name: "CoddPreferencesTests", dependencies: ["CoddPreferences"]),
    ],
    swiftLanguageModes: [.v6]
)
