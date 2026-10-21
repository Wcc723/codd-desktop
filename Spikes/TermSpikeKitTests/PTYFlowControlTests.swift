import Darwin
import Foundation
import Synchronization
import Testing
import TermSpikeKit

/// `pauseReading()` / `resumeReading()`: the flow control the app applies
/// while an engine (Ghostty) has too much output queued.
@Suite("PTYProcess flow control", .serialized)
struct PTYFlowControlTests {
    /// Output bytes and the byte count at the moment the exit arrived.
    final class Counter: Sendable {
        private let state = Mutex<(bytes: Int, atExit: Int?)>((0, nil))

        var onOutput: PTYProcess.OutputHandler {
            { [self] buffer in state.withLock { $0.bytes += buffer.count } }
        }

        var onExit: PTYProcess.ExitHandler {
            { [self] _ in state.withLock { $0.atExit = $0.bytes } }
        }

        var bytes: Int { state.withLock { $0.bytes } }
        var bytesAtExit: Int? { state.withLock { $0.atExit } }
    }

    @Test("a paused process delivers nothing until resumed, then everything")
    func pauseAndResume() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        // Large enough that the child is still writing when the pause lands
        // (the PTY moves ~150 MiB/s, so this takes ~200 ms unpaused).
        let total = 32 << 20
        let counter = Counter()
        let process = try PTYProcess(
            spec: shellSpec("stty raw -echo; head -c \(total) /dev/zero", in: directory),
            onOutput: counter.onOutput,
            onExit: counter.onExit
        )
        #expect(await waitUntil { counter.bytes > 0 })
        process.pauseReading()
        process.pauseReading() // idempotent
        try await Task.sleep(for: .milliseconds(200)) // a chunk already being read may still land
        let paused = counter.bytes
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.bytes == paused, "output kept arriving while paused")
        #expect(paused < total)
        #expect(counter.bytesAtExit == nil, "the child cannot finish while its output is not drained")

        process.resumeReading()
        #expect(await waitUntil(timeout: .seconds(20)) { counter.bytesAtExit != nil })
        #expect(counter.bytesAtExit == total)
    }

    @Test("resume after pause twice restarts reading (pause is not counted)")
    func pauseIsNotCounted() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let counter = Counter()
        let process = try PTYProcess(
            spec: shellSpec("stty raw -echo; head -c 500000 /dev/zero", in: directory),
            onOutput: counter.onOutput,
            onExit: counter.onExit
        )
        process.pauseReading()
        process.pauseReading()
        process.resumeReading()
        #expect(await waitUntil(timeout: .seconds(10)) { counter.bytesAtExit != nil })
        #expect(counter.bytesAtExit == 500_000)
    }

    @Test("a child exiting while reading is paused finishes once reading resumes, output first")
    func exitWhilePaused() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let counter = Counter()
        let process = try PTYProcess(
            spec: shellSpec("sleep 0.3; printf 0123456789", in: directory),
            onOutput: counter.onOutput,
            onExit: counter.onExit
        )
        process.pauseReading()
        // macOS drains a tty's output before the last close of the slave
        // completes, so the child cannot finish exiting while nobody reads.
        try await Task.sleep(for: .milliseconds(800))
        #expect(counter.bytesAtExit == nil)
        #expect(counter.bytes == 0)
        process.resumeReading()
        #expect(await waitUntil { counter.bytesAtExit != nil })
        #expect(counter.bytesAtExit == 10)
    }

    @Test("releasing a paused process closes its descriptor and reaps the child")
    func releaseWhilePaused() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let before = openDescriptorCount()
        var pids: [pid_t] = []
        do {
            var processes: [PTYProcess] = []
            for _ in 0 ..< 10 {
                let process = try PTYProcess(
                    spec: shellSpec("stty raw -echo; exec /bin/cat /dev/zero", in: directory),
                    onOutput: { _ in },
                    onExit: { _ in }
                )
                process.pauseReading()
                processes.append(process)
                pids.append(process.pid)
            }
            try await Task.sleep(for: .milliseconds(200))
            processes.removeAll()
        }
        #expect(await waitUntil(timeout: .seconds(5)) {
            pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
        })
        try await Task.sleep(for: .milliseconds(200))
        // Ten leaked masters would show; other suites may hold a few briefly.
        #expect(openDescriptorCount() <= before + 4)
    }

    private func openDescriptorCount() -> Int {
        (0 ..< 4096).reduce(0) { count, fd in fcntl(Int32(fd), F_GETFD) == -1 ? count : count + 1 }
    }
}
