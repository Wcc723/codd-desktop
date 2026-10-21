// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddComposer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddComposer", targets: ["CoddComposer"]),
        .executable(name: "codd-composer-demo", targets: ["codd-composer-demo"]),
    ],
    targets: [
        // The prompt composer under the terminal: IME-safe text view, scroll/grow field, history,
        // drafts, the PTY payload encoder and Terminal.app-style path escaping. No theme of its own:
        // the app passes its tokens as a `ComposerStyle`.
        .target(name: "CoddComposer"),
        // Manual test app (注音 check): one window, one composer; Enter prints the payload to stdout.
        .executableTarget(name: "codd-composer-demo", dependencies: ["CoddComposer"]),
        .testTarget(name: "CoddComposerTests", dependencies: ["CoddComposer"]),
    ],
    swiftLanguageModes: [.v6]
)
