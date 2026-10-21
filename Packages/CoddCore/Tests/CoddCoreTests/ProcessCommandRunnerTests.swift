import Foundation
import Testing
@testable import CoddCore

/// Real child processes, limited to /bin/sh, /usr/bin/env and /usr/bin/yes.
@Suite("ProcessCommandRunner", .serialized)
struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner(terminationGrace: .milliseconds(500), pipeDrainGrace: .milliseconds(200))

    func sh(_ script: String, env: [String: String] = ["PATH": "/usr/bin:/bin"], timeout: Duration = .seconds(10),
            maxOutput: Int = 8 << 20) -> CommandInvocation {
        CommandInvocation(executable: "/bin/sh", arguments: ["-c", script], environment: env, timeout: timeout,
                          maxOutputBytes: maxOutput)
    }

    @Test func capturesStdoutStderrAndStatus() async throws {
        let r = try await runner.run(sh("printf 'out'; printf 'err' >&2; exit 3"))
        #expect(r.status == 3)
        #expect(!r.terminatedBySignal)
        #expect(r.stdoutText == "out")
        #expect(r.stderrText == "err")
        #expect(!r.succeeded)
    }

    @Test func environmentIsExact() async throws {
        let r = try await runner.run(CommandInvocation(
            executable: "/usr/bin/env", arguments: [], environment: ["ONLY": "this", "LANG": "en_US.UTF-8"], timeout: .seconds(5)))
        let lines = Set(r.stdoutText.split(separator: "\n").map(String.init))
        #expect(lines == ["ONLY=this", "LANG=en_US.UTF-8"])
    }

    @Test func currentDirectory() async throws {
        let tmp = try TempDir("codd-runner-cwd")
        defer { tmp.remove() }
        var inv = sh("pwd -P")
        inv.currentDirectory = tmp.url.path
        let r = try await runner.run(inv)
        let printed = r.stdoutText.trimmingCharacters(in: .newlines)
        #expect(printed.hasPrefix("/"))
        #expect(printed.hasSuffix("/" + tmp.url.lastPathComponent))
    }

    @Test func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        // 1 MB to stdout and 256 KB to stderr, far beyond the 64 KB pipe buffer.
        let r = try await runner.run(sh("i=0; while [ $i -lt 4 ]; do head -c 65536 /dev/zero >&2; i=$((i+1)); done; head -c 1048576 /dev/zero"))
        #expect(r.status == 0)
        #expect(r.stdout.count == 1_048_576)
        #expect(r.stderr.count == 262_144)
    }

    @Test func timeoutKillsTheChild() async throws {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(300))) {
            try await runner.run(sh("sleep 30", timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func timeoutEscalatesToSigkill() async throws {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(200))) {
            try await runner.run(sh("trap '' TERM; while :; do sleep 0.05; done", timeout: .milliseconds(200)))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func grandchildHoldingThePipeDoesNotHang() async throws {
        let start = ContinuousClock.now
        let r = try await runner.run(sh("(sleep 5 &) ; echo done"))
        #expect(r.stdoutText == "done\n")
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// critique H3: a listening socket (or any fd) of the app must never leak into children, or an
    /// orphaned grandchild keeps the hook port bound. POSIX_SPAWN_CLOEXEC_DEFAULT closes inherited fds;
    /// this guards that assumption.
    @Test func parentFileDescriptorsDoNotLeakIntoTheChild() async throws {
        let tmp = try TempDir("codd-runner-fd")
        defer { tmp.remove() }
        let path = tmp.file("secret.txt").path
        FileManager.default.createFile(atPath: path, contents: Data("LEAKED".utf8))
        let fd = open(path, O_RDONLY) // deliberately without O_CLOEXEC
        #expect(fd >= 3)
        defer { close(fd) }
        let r = try await runner.run(sh("cat <&\(fd) 2>/dev/null || echo CLEAN"))
        #expect(r.stdoutText == "CLEAN\n")
    }

    /// A grandchild that keeps writing after the child exited: the run must finish after the drain
    /// grace without hanging or crashing (pipe handles are closed while data still arrives).
    @Test func grandchildWritingAfterExitDoesNotHangOrCrash() async throws {
        let fast = ProcessCommandRunner(terminationGrace: .milliseconds(200), pipeDrainGrace: .milliseconds(1))
        let start = ContinuousClock.now
        for _ in 0..<50 {
            let r = try await fast.run(sh("(i=0; while [ $i -lt 100000 ]; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done) & echo done"))
            #expect(r.stdoutText.contains("done\n"))
        }
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func outputCapAborts() async throws {
        await #expect(throws: CommandRunnerError.outputTooLarge(10_000)) {
            try await runner.run(CommandInvocation(executable: "/usr/bin/yes", arguments: [], environment: [:],
                                                   timeout: .seconds(10), maxOutputBytes: 10_000))
        }
    }

    @Test func launchFailure() async throws {
        await #expect {
            try await runner.run(CommandInvocation(executable: "/nonexistent/codd-tool", arguments: [], environment: [:], timeout: .seconds(1)))
        } throws: { error in
            if case CommandRunnerError.launchFailed = error { return true }
            return false
        }
    }

    @Test func cancellationStopsTheChild() async throws {
        let start = ContinuousClock.now
        let task = Task { try await runner.run(sh("sleep 30")) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CommandRunnerError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// Regression: NOTE_EXIT can be delivered before the child is waitable; reaping with WNOHANG
    /// only then loses the exit and the run never finishes (~2 % of very short children).
    @Test(.timeLimit(.minutes(1)))
    func manyShortChildrenAllComplete() async throws {
        let quick = ProcessCommandRunner(terminationGrace: .milliseconds(200), pipeDrainGrace: .milliseconds(50))
        let invocation = CommandInvocation(executable: "/usr/bin/true", arguments: [], environment: [:], timeout: .seconds(20))
        for _ in 0..<50 {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for _ in 0..<64 { group.addTask { try await quick.run(invocation).status } }
                for try await status in group { #expect(status == 0) }
            }
        }
    }

    /// The child is a session leader without a controlling terminal (an interactive login shell
    /// must not be able to grab CODD's terminal for job control and get stopped by SIGTTIN).
    @Test func childRunsInItsOwnSession() async throws {
        let tmp = try TempDir("codd-runner-sid")
        defer { tmp.remove() }
        let pidFile = tmp.file("pid").path
        let task = Task {
            try await runner.run(CommandInvocation(
                executable: "/bin/sh", arguments: ["-c", #"echo $$ > "$1"; sleep 1"#, "sh", pidFile],
                environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10)))
        }
        var childPid: pid_t?
        for _ in 0..<200 where childPid == nil {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let p = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { childPid = p } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let pid = try #require(childPid)
        #expect(getsid(pid) == pid)
        #expect(getpgid(pid) == pid)
        #expect(getsid(pid) != getsid(0))
        #expect(try await task.value.status == 0)
    }

    /// On timeout the whole process group is signalled, so a grandchild does not outlive the run.
    @Test func timeoutAlsoStopsGrandchildren() async throws {
        let tmp = try TempDir("codd-runner-pgrp")
        defer { tmp.remove() }
        let pidFile = tmp.file("grandchild").path
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(300))) {
            try await runner.run(CommandInvocation(
                executable: "/bin/sh", arguments: ["-c", #"sleep 30 & echo $! > "$1"; wait"#, "sh", pidFile],
                environment: ["PATH": "/usr/bin:/bin"], timeout: .milliseconds(300)))
        }
        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let grandchild = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<300 where !gone {
            gone = kill(grandchild, 0) != 0 && errno == ESRCH
            if !gone { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(gone, "grandchild \(grandchild) survived the timeout")
    }

    /// Ignored signals are reset to their defaults in the child (an app ignoring SIGPIPE must not
    /// hand that to cswap or the login shell).
    @Test func signalDispositionsAreReset() async throws {
        signal(SIGUSR2, SIG_IGN)
        defer { signal(SIGUSR2, SIG_DFL) }
        let r = try await runner.run(sh("kill -USR2 $$; echo survived"))
        #expect(r.terminatedBySignal)
        #expect(r.status == SIGUSR2)
        #expect(r.stdoutText.isEmpty)
    }

    @Test func missingWorkingDirectoryIsALaunchFailure() async throws {
        var inv = sh("pwd")
        inv.currentDirectory = "/nonexistent/codd-cwd"
        await #expect {
            try await runner.run(inv)
        } throws: { error in
            if case CommandRunnerError.launchFailed = error { return true }
            return false
        }
    }

    @Test func nulBytesAreRejectedWithoutEchoingValues() async throws {
        await #expect(throws: CommandRunnerError.launchFailed("NUL byte in argv[2]")) {
            try await runner.run(sh("echo a\0b"))
        }
        await #expect(throws: CommandRunnerError.launchFailed("NUL byte in environment variable TOKEN")) {
            try await runner.run(sh("true", env: ["TOKEN": "secret\0value"]))
        }
    }

    /// No descriptor leaks on success, launch failure, a bad cwd or a timeout (each leak would be 2–4
    /// fds per run; other suites running in parallel add only a little noise).
    @Test func noDescriptorLeaks() async throws {
        func openDescriptors() -> Int {
            (0..<Int32(min(getdtablesize(), 4096))).reduce(0) { $0 + (fcntl($1, F_GETFD) != -1 ? 1 : 0) }
        }
        let before = openDescriptors()
        for i in 0..<60 {
            var inv: CommandInvocation
            switch i % 4 {
            case 0: inv = sh("echo ok")
            case 1: inv = CommandInvocation(executable: "/nonexistent/codd-tool", arguments: [], environment: [:], timeout: .seconds(1))
            case 2: inv = sh("pwd"); inv.currentDirectory = "/nonexistent/codd-cwd"
            default: inv = sh("sleep 5", timeout: .milliseconds(20))
            }
            _ = try? await runner.run(inv)
        }
        try await Task.sleep(for: .milliseconds(100)) // let cancelled sources run their cancel handlers
        let after = openDescriptors()
        #expect(after - before < 20, "fds before \(before), after \(after)")
    }

    @Test func manyConcurrentRuns() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<16 { group.addTask { try await runner.run(sh("echo \(i)")).stdoutText } }
            var outputs = Set<String>()
            for try await out in group { outputs.insert(out) }
            #expect(outputs.count == 16)
        }
    }
}
