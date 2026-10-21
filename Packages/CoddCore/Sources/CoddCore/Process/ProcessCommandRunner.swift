import Darwin
import Dispatch
import Foundation

/// ``CommandRunner`` on `posix_spawn(2)`.
///
/// - The child starts in a NEW SESSION (`POSIX_SPAWN_SETSID`): it has no controlling terminal and
///   leads its own process group. Without this, an interactive login shell (`$SHELL -l -i -c`, used
///   by ``LoginShellEnvironmentCapture``) spawned while CODD itself has a controlling terminal (run
///   from a terminal or from inside a CODD session) opens `/dev/tty`, tries to take the terminal for
///   job control from a background process group, is stopped by `SIGTTIN`/`SIGTTOU` and hangs until
///   the timeout (reproduced with Foundation `Process` under `script(1)`).
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`: only stdin (`/dev/null`), stdout and stderr reach the child, no
///   matter which descriptors the app has open without `FD_CLOEXEC` (critique H3).
/// - Signal dispositions are reset to the defaults and the signal mask is cleared (an app that
///   ignores `SIGPIPE` must not pass that on).
/// - stdout and stderr are drained concurrently on the job's serial queue (a full 64 KB pipe would
///   otherwise deadlock the child).
/// - On timeout or task cancellation the child's whole process group gets SIGTERM, then SIGKILL after
///   ``terminationGrace`` (grandchildren such as cswap's `security` helpers are stopped too).
/// - After the child exits, pipes get ``pipeDrainGrace`` to reach EOF; a grandchild that keeps the
///   pipe open cannot hang the call.
public struct ProcessCommandRunner: CommandRunner {
    public var terminationGrace: Duration
    public var pipeDrainGrace: Duration

    public init(terminationGrace: Duration = .seconds(2), pipeDrainGrace: Duration = .milliseconds(250)) {
        self.terminationGrace = terminationGrace
        self.pipeDrainGrace = pipeDrainGrace
    }

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        let job = SpawnJob(invocation: invocation, terminationGrace: terminationGrace, pipeDrainGrace: pipeDrainGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(continuation)
            }
        } onCancel: {
            job.abort(.cancelled)
        }
    }
}

/// One child process run.
///
/// Thread safety: every mutable property is read and written ONLY on `queue` (a serial queue that
/// also runs all dispatch-source handlers), so no lock is needed; the public entry points
/// (``start(_:)`` and ``abort(_:)``) hop onto it. The continuation is resumed exactly once.
private final class SpawnJob: @unchecked Sendable {
    private let invocation: CommandInvocation
    private let terminationGrace: Duration
    private let pipeDrainGrace: Duration
    private let queue = DispatchQueue(label: "codd.command-runner.job")

    private var continuation: CheckedContinuation<CommandResult, any Error>?
    private var pid: pid_t = 0
    private var stdout = Data()
    private var stderr = Data()
    private var readBuffer = [UInt8]()
    private var stdoutOpen = false
    private var stderrOpen = false
    private var stdoutSource: (any DispatchSourceRead)?
    private var stderrSource: (any DispatchSourceRead)?
    private var processSource: (any DispatchSourceProcess)?
    private var timers: [any DispatchSourceTimer] = []
    private var exited = false
    private var exitStatus: Int32 = 0
    private var signaled = false
    private var drainExpired = false
    /// Output beyond the cap is read and dropped so the child never blocks on a full pipe.
    private var discardOutput = false
    private var failure: CommandRunnerError?
    private var finished = false

    init(invocation: CommandInvocation, terminationGrace: Duration, pipeDrainGrace: Duration) {
        self.invocation = invocation
        self.terminationGrace = terminationGrace
        self.pipeDrainGrace = pipeDrainGrace
    }

    func start(_ continuation: CheckedContinuation<CommandResult, any Error>) {
        queue.async { self.launch(continuation) }
    }

    /// Records `reason` (the first one wins) and stops the child. Safe from any thread, also before
    /// ``start(_:)`` (then nothing is spawned).
    func abort(_ reason: CommandRunnerError) {
        queue.async { self.handleAbort(reason) }
    }

    // MARK: - Everything below runs on `queue`

    private func launch(_ continuation: CheckedContinuation<CommandResult, any Error>) {
        self.continuation = continuation
        guard failure == nil else { // cancelled before it started
            exited = true
            finishIfReady()
            return
        }
        do {
            try spawn()
        } catch let error as CommandRunnerError {
            failure = error
            exited = true
            finishIfReady()
            return
        } catch {
            failure = .launchFailed(String(describing: error))
            exited = true
            finishIfReady()
            return
        }
        schedule(after: invocation.timeout) { [self] in handleAbort(.timedOut(invocation.timeout)) }
    }

    private func handleAbort(_ reason: CommandRunnerError) {
        guard !finished, failure == nil else { return }
        failure = reason
        if pid > 0, !exited { terminateChild() }
    }

    private func spawn() throws {
        let argv = [invocation.executable] + invocation.arguments
        // C strings end at NUL: such a value would be silently truncated. (Values are not echoed in
        // the error; they may be secrets.)
        if let index = argv.firstIndex(where: { $0.utf8.contains(0) }) {
            throw CommandRunnerError.launchFailed("NUL byte in argv[\(index)]")
        }
        if let key = invocation.environment.first(where: { $0.key.utf8.contains(0) || $0.value.utf8.contains(0) })?.key {
            throw CommandRunnerError.launchFailed("NUL byte in environment variable \(key.prefix(64))")
        }
        let envp = invocation.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }

        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { throw CommandRunnerError.launchFailed("pipe: \(Self.errnoText())") }
        guard pipe(&errFDs) == 0 else {
            let text = Self.errnoText()
            outFDs.forEach { close($0) }
            throw CommandRunnerError.launchFailed("pipe: \(text)")
        }
        // Parent ends must not leak into processes other code spawns concurrently.
        for fd in outFDs + errFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var spawned: pid_t = 0
        let rc: Int32
        do {
            rc = try withSpawnConfiguration(stdoutWrite: outFDs[1], stderrWrite: errFDs[1]) { actions, attributes in
                withCStringArray(argv) { cArgv in
                    withCStringArray(envp) { cEnvp in
                        posix_spawn(&spawned, invocation.executable, &actions, &attributes, cArgv, cEnvp)
                    }
                }
            }
        } catch {
            (outFDs + errFDs).forEach { close($0) }
            throw error
        }
        // The child has its own copies; the parent keeps only the read ends.
        close(outFDs[1])
        close(errFDs[1])
        guard rc == 0 else {
            close(outFDs[0])
            close(errFDs[0])
            throw CommandRunnerError.launchFailed("posix_spawn \(invocation.executable): \(String(cString: strerror(rc)))")
        }
        pid = spawned
        readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        stdoutOpen = true
        stderrOpen = true
        stdoutSource = makeReader(fd: outFDs[0], isStdout: true)
        stderrSource = makeReader(fd: errFDs[0], isStdout: false)

        let source = DispatchSource.makeProcessSource(identifier: spawned, eventMask: .exit, queue: queue)
        // NOTE_EXIT can arrive before the child is waitable (measured: ~2 % of very short children
        // returned 0 from waitpid(WNOHANG) in the handler, and no second event ever comes), so the
        // handler waits for the exiting child instead of polling.
        source.setEventHandler { [self] in reap(exitReported: true) }
        processSource = source
        source.activate()
        reap(exitReported: false) // the child may already be gone (a zombie) before the source is armed
    }

    /// File actions (stdin `/dev/null`, stdout/stderr pipes, cwd) and attributes (new session,
    /// close-on-exec by default, default signal dispositions, empty mask) for `posix_spawn`.
    private func withSpawnConfiguration(
        stdoutWrite: Int32, stderrWrite: Int32,
        _ body: (inout posix_spawn_file_actions_t?, inout posix_spawnattr_t?) -> Int32
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions), "file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO), "stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO), "stderr")
        if let cwd = invocation.currentDirectory {
            try check(posix_spawn_file_actions_addchdir(&actions, cwd), "chdir")
        }

        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "sigdefault")
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "sigmask")
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "setflags")
        return body(&actions, &attributes)
    }

    private func check(_ rc: Int32, _ what: String) throws {
        if rc != 0 { throw CommandRunnerError.launchFailed("posix_spawn \(what): \(String(cString: strerror(rc)))") }
    }

    private func makeReader(fd: Int32, isStdout: Bool) -> any DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain(fd: fd, isStdout: isStdout) }
        source.setCancelHandler { [self] in
            close(fd)
            if isStdout { stdoutOpen = false } else { stderrOpen = false }
            finishIfReady()
        }
        source.activate()
        return source
    }

    /// Reads until the pipe is empty; EOF or a read error cancels the source (which closes the fd).
    private func drain(fd: Int32, isStdout: Bool) {
        while true {
            let n = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                append(readBuffer.prefix(n), isStdout: isStdout)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            (isStdout ? stdoutSource : stderrSource)?.cancel() // EOF (0) or a hard error
            return
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>, isStdout: Bool) {
        guard !discardOutput else { return }
        if isStdout { stdout.append(contentsOf: bytes) } else { stderr.append(contentsOf: bytes) }
        if stdout.count > invocation.maxOutputBytes || stderr.count > invocation.maxOutputBytes {
            discardOutput = true
            stdout = Data()
            stderr = Data()
            handleAbort(.outputTooLarge(invocation.maxOutputBytes))
        }
    }

    /// Collects the exit status if the child has exited. `exitReported`: the kernel reported the
    /// exit (NOTE_EXIT), so a child that is not waitable yet is about to be and is waited for.
    private func reap(exitReported: Bool) {
        guard !exited, pid > 0 else { return }
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r == -1 && errno == EINTR
        if r == 0, exitReported {
            repeat { r = waitpid(pid, &status, 0) } while r == -1 && errno == EINTR
        }
        if r == 0 { return } // still running
        if r == pid {
            let low = status & 0x7F
            if low == 0 {
                exitStatus = (status >> 8) & 0xFF
            } else {
                exitStatus = low
                signaled = true
            }
        } else {
            exitStatus = -1 // ECHILD: reaped elsewhere (e.g. SIGCHLD set to SIG_IGN); status unknown
        }
        exited = true
        processSource?.cancel()
        schedule(after: pipeDrainGrace) { [self] in
            drainExpired = true
            finishIfReady()
        }
        finishIfReady()
    }

    /// SIGTERM to the child's process group (it is the session and group leader), SIGKILL later.
    private func terminateChild() {
        let target = pid
        kill(-target, SIGTERM)
        kill(target, SIGTERM)
        schedule(after: terminationGrace) { [self] in
            reap(exitReported: false)
            guard !exited else { return }
            kill(-target, SIGKILL)
            kill(target, SIGKILL)
        }
    }

    private func schedule(after delay: Duration, _ handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.timeInterval)
        timer.setEventHandler(handler: handler)
        timers.append(timer)
        timer.activate()
    }

    private func finishIfReady() {
        guard !finished, exited, (!stdoutOpen && !stderrOpen) || drainExpired, let continuation else { return }
        finished = true
        self.continuation = nil
        let outcome: Result<CommandResult, any Error> = failure.map { .failure($0) }
            ?? .success(CommandResult(status: exitStatus, terminatedBySignal: signaled, stdout: stdout, stderr: stderr))
        // A grandchild may still hold a pipe open: stop reading (the cancel handlers close the fds).
        stdoutSource?.cancel()
        stderrSource?.cancel()
        processSource?.cancel()
        // Cancelling releases the handlers, which breaks the job ↔ source reference cycles.
        timers.forEach { $0.cancel() }
        timers = []
        stdout = Data()
        stderr = Data()
        readBuffer = []
        continuation.resume(with: outcome)
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

/// Calls `body` with a NULL-terminated C string array (memory freed afterwards).
private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (i, s) in strings.enumerated() { (array + i).initialize(to: strdup(s)) }
    (array + strings.count).initialize(to: nil)
    defer {
        for i in 0..<strings.count { free(array[i]) }
        array.deinitialize(count: strings.count + 1)
        array.deallocate()
    }
    return body(UnsafePointer(array))
}

extension Duration {
    /// Seconds as `TimeInterval`.
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
