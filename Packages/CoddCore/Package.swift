// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddCore", targets: ["CoddCore"]),
    ],
    targets: [
        // Models (groups/projects/sessions/accounts), hook event → state machine (port of status-writer.js),
        // Claude registry reader, cswap JSON client, title-glyph parsing, launch argv/env builder.
        .target(name: "CoddCore"),
        .testTarget(
            name: "CoddCoreTests",
            dependencies: ["CoddCore"],
            // Fixtures/gen holds the node harness that regenerates the golden files; it is not a resource.
            exclude: ["Fixtures/gen"],
            resources: [
                .copy("Fixtures/hooks"),
                .copy("Fixtures/registry"),
                .copy("Fixtures/cswap"),
            ]
        ),
    ]
)
