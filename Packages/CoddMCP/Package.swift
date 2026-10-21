// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddMCP",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddMCP", targets: ["CoddMCP"]),
    ],
    targets: [
        // The MCP server for CODD notes (M4 C2): JSON-RPC over one HTTP request, no transport.
        // Foundation only and no MCP SDK (the Swift SDK lags the spec, D16): the JSON reader and
        // writer are hand-written so key order, number text and unescaped CJK are under our control.
        .target(name: "CoddMCP"),
        // The golden responses live in Fixtures/ and are read through #filePath, so they are
        // excluded from the target (as resources they would need Bundle.module and a copy step).
        .testTarget(name: "CoddMCPTests", dependencies: ["CoddMCP"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
