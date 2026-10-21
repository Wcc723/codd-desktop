import Foundation
import Synchronization
import TermSpikeKit

/// Collects PTY output and the exit status across threads.
final class OutputCollector: Sendable {
    private let bytes = Mutex<[UInt8]>([])
    private let status = Mutex<Int32?>(nil)

    var onOutput: PTYProcess.OutputHandler {
        { [self] buffer in bytes.withLock { $0.append(contentsOf: buffer) } }
    }

    var onExit: PTYProcess.ExitHandler {
        { [self] value in status.withLock { $0 = value } }
    }

    var text: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
    var count: Int { bytes.withLock { $0.count } }
    var exitStatus: Int32? { status.withLock { $0 } }
}

/// Polls `condition` every 10 ms until it holds or `timeout` elapses.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A fresh directory under the system temp dir, removed by `cleanup()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermSpikeKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Launch spec for a `/bin/sh -c` script in `directory` with a tiny environment.
func shellSpec(_ script: String, in directory: TemporaryDirectory, size: PTYWindowSize = .fallback) -> PTYLaunchSpec {
    PTYLaunchSpec(
        executable: "/bin/sh",
        arguments: ["sh", "-c", script],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"],
        workingDirectory: directory.url.path,
        size: size
    )
}
