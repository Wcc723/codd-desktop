// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoddHolder",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoddProtocol", targets: ["CoddProtocol"]),
        .library(name: "CoddHolderCore", targets: ["CoddHolderCore"]),
        .library(name: "CoddHolderClient", targets: ["CoddHolderClient"]),
        .executable(name: "codd-holder", targets: ["codd-holder"]),
        .executable(name: "codd-holderctl", targets: ["codd-holderctl"]),
    ],
    targets: [
        // Wire protocol v1 (framing, typed messages, minimal JSON, meta.json and ring layouts).
        // Pure Swift standard library: no Foundation, no Darwin. Shared by holder and app.
        .target(name: "CoddProtocol"),
        // fork/exec PTY child, TIOCSWINSZ, shared-memory atomics, libproc helpers (things Swift cannot do safely).
        .target(name: "CCoddShim"),
        // Thin Darwin wrappers shared by the holder and its clients (errors, fds, unix sockets, files, clock).
        .target(name: "CoddPosix", dependencies: ["CCoddShim"]),
        // The holder: PTY, single kqueue loop, mmap ring, socket server, output scanner, flow control.
        .target(name: "CoddHolderCore", dependencies: ["CoddProtocol", "CoddPosix"]),
        // Blocking client + spawner (posix_spawn SETSID | CLOEXEC_DEFAULT). Used by codd-holderctl and tests.
        .target(name: "CoddHolderClient", dependencies: ["CoddProtocol", "CoddPosix"]),
        // -dead_strip_dylibs drops the Foundation load command the toolchain adds to every Swift
        // executable by default; the holder does not use Foundation. Measured idle holder (release,
        // child /bin/sh): rss 2.4 MB / phys_footprint 1.5 MB with the flag, rss 6.2 MB / footprint
        // 2.0 MB without (budget 2.5 MB). The Xcode `codd-holder` tool target (project.yml) needs
        // the same flag in OTHER_LDFLAGS.
        .executableTarget(
            name: "codd-holder", dependencies: ["CoddHolderCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]),
        // Debug/test client: spawn, attach, send, tail, list, kill.
        .executableTarget(name: "codd-holderctl", dependencies: ["CoddHolderClient"]),
        // Child-side probes for integration tests (open fds, input timestamps). Not shipped.
        .executableTarget(name: "codd-holder-testhelper", dependencies: ["CoddPosix"]),
        // The current client against holders built from older commits (scripts/m5-compat.sh,
        // docs/M5-PLAN.md D19 / §2.9). Only the client modules it checks; not shipped.
        .executableTarget(name: "codd-holder-compat", dependencies: ["CoddHolderClient", "CoddProtocol"]),
        .testTarget(name: "CoddProtocolTests", dependencies: ["CoddProtocol"]),
        .testTarget(
            name: "CoddHolderTests",
            dependencies: ["CoddHolderCore", "CoddHolderClient", "CoddProtocol", "CoddPosix"]
        ),
    ]
)
