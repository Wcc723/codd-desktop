// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddHost",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddHost", targets: ["CoddHost"]),
    ],
    targets: [
        // Host metrics for the STATUS page and the footer one-liner (M3 D26 / D36): mach host
        // statistics, sysctl, volume capacity, IOPowerSources, proc_pid_rusage, and the main-thread
        // latency probe. Darwin + Foundation + IOKit only; no AppKit, no CoddCore.
        .target(name: "CoddHost", linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "CoddHostTests", dependencies: ["CoddHost"]),
    ],
    swiftLanguageModes: [.v6]
)
