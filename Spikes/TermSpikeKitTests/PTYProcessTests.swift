import Darwin
import Foundation
import Testing
import TermSpikeKit

@Suite("PTYProcess", .serialized)
struct PTYProcessTests {
    @Test("captures output and the exit status")
    func outputAndExit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let collector = OutputCollector()
        let process = try PTYProcess(
            spec: shellSpec("printf 'hello from pty'; exit 3", in: directory),
            onOutput: collector.onOutput,
            onExit: collector.onExit
        )
        #expect(await waitUntil { collector.exitStatus != nil && collector.text.contains("hello from pty") })
        #expect(WaitStatus.exitCode(collector.exitStatus ?? -1) == 3)
        _ = process
    }

    @Test("runs the child in the requested directory with exactly the given environment")
    func environmentAndDirectory() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let collector = OutputCollector()
        var spec = shellSpec("pwd -P; /usr/bin/env", in: directory)
        spec.environment["SPIKE_MARKER"] = "zhuyin-注音"
        let process = try PTYProcess(spec: spec, onOutput: collector.onOutput, onExit: collector.onExit)
        #expect(await waitUntil { collector.exitStatus != nil })
        let output = collector.text
        let resolved = directory.url.resolvingSymlinksInPath().path
        #expect(output.contains(resolved) || output.contains(directory.url.path))
        #expect(output.contains("SPIKE_MARKER=zhuyin-注音"))
        #expect(!output.contains("DYLD_"))
        #expect(!output.contains("XPC_SERVICE_NAME"))
        _ = process
    }

    @Test("echoes input back through the tty")
    func inputRoundTrip() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let collector = OutputCollector()
        let process = try PTYProcess(
            spec: shellSpec("exec /bin/cat", in: directory),
            onOutput: collector.onOutput,
            onExit: collector.onExit
        )
        process.write(Data("ping 注音\n".utf8))
        #expect(await waitUntil { collector.text.components(separatedBy: "ping 注音").count >= 3 })
        process.terminate()
        #expect(await waitUntil { collector.exitStatus != nil })
    }

    @Test("TIOCSWINSZ resize is visible to the child")
    func resize() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let collector = OutputCollector()
        let process = try PTYProcess(
            spec: shellSpec("stty size; read line; stty size", in: directory, size: PTYWindowSize(columns: 101, rows: 33)),
            onOutput: collector.onOutput,
            onExit: collector.onExit
        )
        #expect(await waitUntil { collector.text.contains("33 101") })
        process.resize(PTYWindowSize(columns: 132, rows: 43))
        process.write(Data("\n".utf8))
        #expect(await waitUntil { collector.text.contains("43 132") })
        #expect(await waitUntil { collector.exitStatus != nil })
    }

    @Test("does not leak inherited descriptors into the child")
    func descriptorsClosed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let devNull = open("/dev/null", O_RDONLY) // deliberately without O_CLOEXEC
        #expect(devNull >= 0)
        let leaked = dup2(devNull, 211)
        close(devNull)
        defer { close(leaked) }
        let collector = OutputCollector()
        let process = try PTYProcess(
            spec: shellSpec("ls /dev/fd | tr '\\n' ' '", in: directory),
            onOutput: collector.onOutput,
            onExit: collector.onExit
        )
        #expect(await waitUntil { collector.exitStatus != nil })
        let listed = collector.text.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\n" }).map(String.init)
        #expect(listed.contains("0"))
        #expect(!listed.contains("211"))
        _ = process
    }

    @Test("writes larger than the PTY input buffer arrive intact")
    func largeWrite() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let collector = OutputCollector()
        let process = try PTYProcess(
            spec: shellSpec("stty raw -echo; exec /bin/cat", in: directory),
            onOutput: collector.onOutput,
            onExit: collector.onExit
        )
        try await Task.sleep(for: .milliseconds(200)) // let stty apply before writing
        let payload = Data(repeating: UInt8(ascii: "x"), count: 256 * 1024)
        process.write(payload)
        #expect(await waitUntil(timeout: .seconds(10)) { collector.count >= payload.count })
        process.terminate()
        #expect(await waitUntil { collector.exitStatus != nil })
    }

    @Test("observes the exit of every short-lived child (NOTE_EXIT vs waitpid race)")
    func manyShortChildren() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        var running: [(PTYProcess, OutputCollector)] = []
        for _ in 0 ..< 40 {
            let collector = OutputCollector()
            let process = try PTYProcess(
                spec: shellSpec("exit 7", in: directory),
                onOutput: collector.onOutput,
                onExit: collector.onExit
            )
            running.append((process, collector))
        }
        #expect(await waitUntil(timeout: .seconds(10)) { running.allSatisfy { $0.1.exitStatus != nil } })
        #expect(running.allSatisfy { WaitStatus.exitCode($0.1.exitStatus ?? 0) == 7 })
    }

    @Test("rejects relative executables")
    func rejectsRelativeExecutable() throws {
        let spec = PTYLaunchSpec(executable: "sh", arguments: ["sh"], environment: [:])
        #expect(throws: PTYError.self) {
            _ = try PTYProcess(spec: spec, onOutput: { _ in }, onExit: { _ in })
        }
    }
}
