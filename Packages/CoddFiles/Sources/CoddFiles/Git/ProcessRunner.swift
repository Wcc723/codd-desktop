import Darwin
import Dispatch
import Foundation

/// The outcome of one child process.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Why a child process run failed (its exit status is not a failure here; callers judge it).
public enum ProcessRunError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case outputTooLarge(Int)
    case cancelled
}

/// A `posix_spawn(2)` runner in the style of CoddCore's `ProcessCommandRunner` (copied, not
/// depended on: CoddFiles has no CoddCore dependency).
///
/// - The child gets a new session (`POSIX_SPAWN_SETSID`): no controlling terminal, its own process
///   group, so a timeout can stop it and any helper it started (git runs `xcrun` shims and may spawn
///   sub-gits for submodules).
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`: only stdin (`/dev/null`), stdout and stderr reach the child.
/// - stdout and stderr are drained concurrently on the job's serial queue (a full pipe would
///   otherwise deadlock the child).
/// - At the timeout or on task cancellation the child's process group gets SIGTERM, then SIGKILL
///   after `terminationGrace`.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], environment: [String: String], timeout: Duration,
                    maxOutputBytes: Int, terminationGrace: Duration = .milliseconds(500)) async throws -> ProcessResult {
        let job = SpawnJob(executable: executable, arguments: arguments, environment: environment, timeout: timeout,
                           maxOutputBytes: maxOutputBytes, terminationGrace: terminationGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(continuation)
            }
        } onCancel: {
            job.abort(.cancelled)
        }
    }
}

/// One child process run. Every mutable property is touched only on `queue` (a serial queue that
/// also runs all dispatch-source handlers), so no lock is needed; `start` and `abort` hop onto it.
/// The continuation is resumed exactly once.
private final class SpawnJob: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: Duration
    private let maxOutputBytes: Int
    private let terminationGrace: Duration
    private let pipeDrainGrace = Duration.milliseconds(250)
    private let queue = DispatchQueue(label: "codd.files.process")

    private var continuation: CheckedContinuation<ProcessResult, any Error>?
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
    private var drainExpired = false
    private var discardOutput = false
    private var failure: ProcessRunError?
    private var finished = false

    init(executable: String, arguments: [String], environment: [String: String], timeout: Duration, maxOutputBytes: Int,
         terminationGrace: Duration) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.terminationGrace = terminationGrace
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
        queue.async { self.launch(continuation) }
    }

    func abort(_ reason: ProcessRunError) {
        queue.async { self.handleAbort(reason) }
    }

    // MARK: - Everything below runs on `queue`

    private func launch(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
        self.continuation = continuation
        guard failure == nil else { // cancelled before it started
            exited = true
            finishIfReady()
            return
        }
        do {
            try spawn()
        } catch let error as ProcessRunError {
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
        schedule(after: timeout) { [self] in handleAbort(.timedOut) }
    }

    private func handleAbort(_ reason: ProcessRunError) {
        guard !finished, failure == nil else { return }
        failure = reason
        if pid > 0, !exited { terminateChild() }
    }

    private func spawn() throws {
        let argv = [executable] + arguments
        if let index = argv.firstIndex(where: { $0.utf8.contains(0) }) {
            throw ProcessRunError.launchFailed("NUL byte in argv[\(index)]")
        }
        if let key = environment.first(where: { $0.key.utf8.contains(0) || $0.value.utf8.contains(0) })?.key {
            throw ProcessRunError.launchFailed("NUL byte in environment variable \(key.prefix(64))")
        }
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }

        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { throw ProcessRunError.launchFailed("pipe: \(Self.errnoText())") }
        guard pipe(&errFDs) == 0 else {
            let text = Self.errnoText()
            outFDs.forEach { close($0) }
            throw ProcessRunError.launchFailed("pipe: \(text)")
        }
        for fd in outFDs + errFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var spawned: pid_t = 0
        let rc: Int32
        do {
            rc = try withSpawnConfiguration(stdoutWrite: outFDs[1], stderrWrite: errFDs[1]) { actions, attributes in
                withCStringArray(argv) { cArgv in
                    withCStringArray(envp) { cEnvp in
                        posix_spawn(&spawned, executable, &actions, &attributes, cArgv, cEnvp)
                    }
                }
            }
        } catch {
            (outFDs + errFDs).forEach { close($0) }
            throw error
        }
        close(outFDs[1])
        close(errFDs[1])
        guard rc == 0 else {
            close(outFDs[0])
            close(errFDs[0])
            throw ProcessRunError.launchFailed("posix_spawn \(executable): \(String(cString: strerror(rc)))")
        }
        pid = spawned
        readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        stdoutOpen = true
        stderrOpen = true
        stdoutSource = makeReader(fd: outFDs[0], isStdout: true)
        stderrSource = makeReader(fd: errFDs[0], isStdout: false)

        let source = DispatchSource.makeProcessSource(identifier: spawned, eventMask: .exit, queue: queue)
        // NOTE_EXIT can arrive before the child is waitable: the handler waits for it (CoddCore M1 finding).
        source.setEventHandler { [self] in reap(exitReported: true) }
        processSource = source
        source.activate()
        reap(exitReported: false)
    }

    private func withSpawnConfiguration(stdoutWrite: Int32, stderrWrite: Int32,
                                        _ body: (inout posix_spawn_file_actions_t?, inout posix_spawnattr_t?) -> Int32) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions), "file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO), "stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO), "stderr")

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
        if rc != 0 { throw ProcessRunError.launchFailed("posix_spawn \(what): \(String(cString: strerror(rc)))") }
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

    private func drain(fd: Int32, isStdout: Bool) {
        while true {
            let n = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                append(readBuffer.prefix(n), isStdout: isStdout)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            (isStdout ? stdoutSource : stderrSource)?.cancel()
            return
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>, isStdout: Bool) {
        guard !discardOutput else { return }
        if isStdout { stdout.append(contentsOf: bytes) } else { stderr.append(contentsOf: bytes) }
        if stdout.count > maxOutputBytes || stderr.count > maxOutputBytes {
            discardOutput = true
            stdout = Data()
            stderr = Data()
            handleAbort(.outputTooLarge(maxOutputBytes))
        }
    }

    private func reap(exitReported: Bool) {
        guard !exited, pid > 0 else { return }
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r == -1 && errno == EINTR
        if r == 0, exitReported {
            repeat { r = waitpid(pid, &status, 0) } while r == -1 && errno == EINTR
        }
        if r == 0 { return }
        if r == pid {
            let low = status & 0x7F
            exitStatus = low == 0 ? (status >> 8) & 0xFF : 128 + low
        } else {
            exitStatus = -1
        }
        exited = true
        processSource?.cancel()
        schedule(after: pipeDrainGrace) { [self] in
            drainExpired = true
            finishIfReady()
        }
        finishIfReady()
    }

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
        let c = delay.components
        timer.schedule(deadline: .now() + TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18)
        timer.setEventHandler(handler: handler)
        timers.append(timer)
        timer.activate()
    }

    private func finishIfReady() {
        guard !finished, exited, (!stdoutOpen && !stderrOpen) || drainExpired, let continuation else { return }
        finished = true
        self.continuation = nil
        let outcome: Result<ProcessResult, any Error> = failure.map { .failure($0) }
            ?? .success(ProcessResult(status: exitStatus, stdout: stdout, stderr: stderr))
        stdoutSource?.cancel()
        stderrSource?.cancel()
        processSource?.cancel()
        timers.forEach { $0.cancel() }
        timers = []
        stdout = Data()
        stderr = Data()
        readBuffer = []
        continuation.resume(with: outcome)
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}

/// Calls `body` with a NULL-terminated C string array (freed afterwards).
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
