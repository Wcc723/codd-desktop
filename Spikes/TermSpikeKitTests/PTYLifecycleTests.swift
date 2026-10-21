import Darwin
import Foundation
import Synchronization
import Testing
import TermSpikeKit

/// Lifecycle guarantees a holder port relies on: EXIT after the last OUTPUT,
/// no descriptor or zombie left behind.
@Suite("PTYProcess lifecycle", .serialized)
struct PTYLifecycleTests {
    /// Records how many output bytes had been delivered when the exit arrived.
    final class ExitOrderCollector: Sendable {
        private let state = Mutex<(bytes: Int, atExit: Int?)>((0, nil))

        var onOutput: PTYProcess.OutputHandler {
            { [self] buffer in state.withLock { $0.bytes += buffer.count } }
        }

        var onExit: PTYProcess.ExitHandler {
            { [self] _ in state.withLock { $0.atExit = $0.bytes } }
        }

        var bytesAtExit: Int? { state.withLock { $0.atExit } }
    }

    @Test("reports the exit only after the child's last output was delivered")
    func exitAfterLastOutput() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let expected = 200_000
        // The child fills the PTY buffer and exits while up to a buffer's worth
        // is still unread, so the exit event races the final reads.
        for _ in 0 ..< 12 {
            let collector = ExitOrderCollector()
            let process = try PTYProcess(
                spec: shellSpec("head -c \(expected) /dev/zero | tr '\\000' x; exit 0", in: directory),
                onOutput: collector.onOutput,
                onExit: collector.onExit
            )
            #expect(await waitUntil(timeout: .seconds(10)) { collector.bytesAtExit != nil })
            #expect(collector.bytesAtExit == expected)
            _ = process
        }
    }

    @Test("tiny output then exit: exit never overtakes the output")
    func tinyOutputExitOrder() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        var collectors: [ExitOrderCollector] = []
        var processes: [PTYProcess] = []
        for _ in 0 ..< 200 {
            let collector = ExitOrderCollector()
            processes.append(try PTYProcess(
                spec: shellSpec("printf 0123456789", in: directory),
                onOutput: collector.onOutput,
                onExit: collector.onExit
            ))
            collectors.append(collector)
        }
        #expect(await waitUntil(timeout: .seconds(20)) { collectors.allSatisfy { $0.bytesAtExit != nil } })
        let early = collectors.filter { ($0.bytesAtExit ?? 0) < 10 }.count
        #expect(early == 0, "\(early) of 200 exits were reported before their output")
        _ = processes
    }

    @Test("closes its master descriptor once the child is gone")
    func noDescriptorLeak() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let before = openDescriptorCount()
        do {
            var collectors: [OutputCollector] = []
            var processes: [PTYProcess] = []
            for _ in 0 ..< 30 {
                let collector = OutputCollector()
                processes.append(try PTYProcess(
                    spec: shellSpec("printf done", in: directory),
                    onOutput: collector.onOutput,
                    onExit: collector.onExit
                ))
                collectors.append(collector)
            }
            #expect(await waitUntil(timeout: .seconds(10)) { collectors.allSatisfy { $0.exitStatus != nil } })
            processes.removeAll()
        }
        try await Task.sleep(for: .milliseconds(200))
        // Other suites run in parallel and may hold a descriptor or two.
        #expect(openDescriptorCount() <= before + 4)
    }

    @Test("releasing a running PTYProcess hangs up and reaps its child")
    func deinitReapsChild() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        var process: PTYProcess? = try PTYProcess(
            spec: shellSpec("exec /bin/sleep 30", in: directory),
            onOutput: { _ in },
            onExit: { _ in }
        )
        let pid = try #require(process?.pid)
        try await Task.sleep(for: .milliseconds(100))
        process = nil
        // kill(pid, 0) still succeeds on a zombie; ESRCH means it was reaped.
        #expect(await waitUntil(timeout: .seconds(5)) { kill(pid, 0) == -1 && errno == ESRCH })
    }

    @Test("a child that ignores SIGHUP is killed after the grace period")
    func terminateEscalates() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let collector = OutputCollector()
        let process = try PTYProcess(
            spec: shellSpec("trap '' HUP; printf ready; while :; do sleep 1; done", in: directory),
            onOutput: collector.onOutput,
            onExit: collector.onExit
        )
        #expect(await waitUntil { collector.text.contains("ready") })
        process.terminate(grace: 0.3)
        #expect(await waitUntil(timeout: .seconds(5)) { collector.exitStatus != nil })
        #expect(WaitStatus.describe(collector.exitStatus ?? 0) == "signal 9")
    }

    /// Descriptors currently open in this process.
    private func openDescriptorCount() -> Int {
        (0 ..< 4096).reduce(0) { count, fd in fcntl(Int32(fd), F_GETFD) == -1 ? count : count + 1 }
    }
}
