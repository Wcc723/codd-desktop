// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddOnboarding",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddOnboarding", targets: ["CoddOnboarding"]),
        .library(name: "CoddOnboardingUI", targets: ["CoddOnboardingUI"]),
        .executable(name: "codd-onboarding-demo", targets: ["codd-onboarding-demo"]),
    ],
    dependencies: [
        .package(path: "../CoddUI"),
    ],
    targets: [
        // The first-launch wizard's data (docs/M5-PLAN.md §2.3–§2.5): steps and flow, the boot log,
        // the read-only project catalog of `~/.claude.json`, group suggestions, the import plan, the
        // gate and `onboarding.json`. Foundation only: no CoddCore, no App types.
        .target(name: "CoddOnboarding"),
        // The views of the frozen Onboarding artboard, drawn from `OnboardingViewModel` with
        // `OnboardingActions` closures; the views never read the disk (the App fills the model, I2).
        .target(name: "CoddOnboardingUI", dependencies: [
            "CoddOnboarding", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        // `codd-onboarding-demo --fonts <dir> --snapshot <dir>` renders every step and state offscreen.
        .executableTarget(name: "codd-onboarding-demo", dependencies: [
            "CoddOnboarding", "CoddOnboardingUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
        .testTarget(name: "CoddOnboardingTests", dependencies: ["CoddOnboarding"]),
        .testTarget(name: "CoddOnboardingUITests", dependencies: [
            "CoddOnboarding", "CoddOnboardingUI", .product(name: "CoddUI", package: "CoddUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
