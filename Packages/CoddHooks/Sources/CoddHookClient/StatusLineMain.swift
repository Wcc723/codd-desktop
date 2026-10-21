import Darwin

/// The chain's process group for the signal handlers (0 = none). Written only while the forwarded
/// signals are blocked, so a handler never runs between the spawn and this record.
nonisolated(unsafe) private var chainProcessGroup: pid_t = 0

/// SIGTERM / SIGINT / SIGHUP: Claude cancels a status-line run that a newer one superseded. The
/// chain runs in its own process group (so a timeout can kill its whole tree), which also means
/// nobody else would stop it: forward the signal, then leave. A process the chain forks while the
/// group is being signalled can miss it (measured: a `sleep` survived as an orphan), so the
/// signal is sent again 20 ms later if the group is still there; then up to 200 ms are given for
/// the group to go (no SIGKILL: a plain Claude would not escalate either). Only async-signal-safe
/// calls (kill, nanosleep, _exit).
private func forwardSignalAndExit(_ signal: Int32) {
    let group = chainProcessGroup
    if group > 0 {
        _ = kill(-group, signal)
        var pause = timespec(tv_sec: 0, tv_nsec: 20_000_000)
        for attempt in 0..<10 {
            _ = nanosleep(&pause, nil)
            guard kill(-group, 0) == 0 else { break }
            if attempt == 0 { _ = kill(-group, signal) }
        }
    }
    _exit(1)
}

/// The backstop timer: something blocked outside the budgets below. Kill the chain, exit 0.
private func backstopExpired(_: Int32) {
    let group = chainProcessGroup
    if group > 0 { _ = kill(-group, SIGKILL) }
    _exit(0)
}

/// Process-level behaviour of `codd-statusline` (M3 D8).
///
/// 1. Read stdin to EOF (at most 1 MiB, 1000 ms).
/// 2. With a chain: `posix_spawn` `/bin/sh -c <chain>` in its own process group, stdout / stderr
///    and the environment inherited, stdin a pipe that gets the same bytes (written non-blocking
///    within 500 ms, then closed). It starts before the report so the user's line is not delayed.
/// 3. POST the report within 300 ms in total (skipped without an endpoint, never retried).
/// 4. Wait for the chain at most ``StatusLineCommand/chainTimeoutMilliseconds`` from its start;
///    then SIGTERM to its group (once more 20 ms later) and SIGKILL 1 s later if any of it is left.
/// 5. Exit with the chain's status (a signal n gives 128 + n), or 0 without a chain or on any own
///    failure.
///
/// CODD itself never writes to stdout (that is the status line Claude draws): without a chain
/// nothing is printed at all. Diagnostics go to stderr only with `CODD_HOOK_DEBUG=1`. SIGPIPE is
/// ignored here and restored to the default for the chain, whose signal mask is the inherited one.
/// The chain inherits the environment except `CODD_STATUSLINE_CHAIN` (see
/// `StatusLineProcess.chainEnvironment()`).
public enum StatusLineMain {
    public enum Outcome: Sendable, Equatable {
        case posted(status: Int)
        case skipped(StatusLineCommand.Skip)
        case failed(LoopbackHTTPError)
    }

    public static func main() -> Never {
        chainProcessGroup = 0 // initialise the global before any handler can read it
        StatusLineProcess.ensureStandardDescriptors()
        signal(SIGPIPE, SIG_IGN)
        for s in [SIGTERM, SIGINT, SIGHUP] { signal(s, forwardSignalAndExit) }

        let environment: (String) -> String? = { name in getenv(name).map { String(cString: $0) } }
        let command = StatusLineCommand(arguments: CommandLine.arguments, environment: environment)
        armBackstop(chainTimeout: command.chainTimeoutMilliseconds)

        let input = StatusLineProcess.readInput(fd: STDIN_FILENO, limit: StatusLineCommand.maxStdinBytes,
                                                deadline: .after(milliseconds: StatusLineCommand.stdinBudgetMilliseconds))
        var child: StatusLineProcess.Child?
        var spawnError: Int32?
        if let chain = command.chain {
            switch StatusLineProcess.spawnChain(chain) {
            case .success(let c):
                child = c
                StatusLineProcess.feed(c.stdin, input.bytes,
                                       deadline: .after(milliseconds: StatusLineCommand.chainStdinBudgetMilliseconds))
            case .failure(let e):
                spawnError = e.errno
            }
        }

        let outcome: Outcome
        switch command.request(stdin: input.bytes, readFile: { StatusLineConfigFile.read($0) }) {
        case .failure(let skip):
            outcome = .skipped(skip)
        case .success(let request):
            let deadline = MonotonicDeadline.after(milliseconds: StatusLineCommand.postBudgetMilliseconds)
            switch LoopbackHTTPClient.send(request.bytes, port: request.port, deadline: deadline) {
            case .success(let response): outcome = .posted(status: response.status)
            case .failure(let error): outcome = .failed(error)
            }
        }

        var exitStatus: Int32 = 0
        var chainNote: String
        if let child {
            let deadline = MonotonicDeadline(
                nanoseconds: child.startedAt + UInt64(command.chainTimeoutMilliseconds) * 1_000_000)
            if let status = StatusLineProcess.waitForExit(child.pid, deadline: deadline) {
                exitStatus = StatusLineProcess.exitCode(status)
                chainNote = "chain exited \(exitStatus)"
            } else {
                exitStatus = StatusLineProcess.exitCode(StatusLineProcess.terminate(group: child.pid))
                chainNote = "chain timed out after \(command.chainTimeoutMilliseconds) ms, killed (\(exitStatus))"
            }
        } else if let spawnError {
            chainNote = "chain not started (errno \(spawnError))"
        } else {
            chainNote = command.chain == nil ? "no chain" : "chain not started"
        }
        if !input.complete { chainNote += "; stdin incomplete" }
        if command.debug { debugLog(outcome: outcome, chain: chainNote) }
        exit(exitStatus)
    }

    /// A SIGALRM backstop past every budget (stdin, stdin to the chain, report, chain timeout, the
    /// kill grace and the final wait), in case something blocks outside poll(2) / kevent(2).
    static func armBackstop(chainTimeout: Int) {
        signal(SIGALRM, backstopExpired)
        let ms = StatusLineCommand.stdinBudgetMilliseconds + StatusLineCommand.chainStdinBudgetMilliseconds
            + StatusLineCommand.postBudgetMilliseconds + chainTimeout + 2 * StatusLineCommand.killGraceMilliseconds + 500
        var timer = itimerval(it_interval: timeval(tv_sec: 0, tv_usec: 0),
                              it_value: timeval(tv_sec: ms / 1000, tv_usec: Int32(ms % 1000) * 1000))
        _ = setitimer(ITIMER_REAL, &timer, nil)
    }

    static func debugLog(outcome: Outcome, chain: String) {
        let report: String
        switch outcome {
        case .posted(let status) where status == 204: report = "report delivered"
        case .posted(let status): report = "endpoint answered \(status)"
        case .skipped(let skip): report = "report not sent: \(skip.rawValue)"
        case .failed(let error): report = "report failed: \(error)"
        }
        var bytes = Array("codd-statusline: \(report); \(chain)\n".utf8)
        _ = bytes.withUnsafeMutableBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
}

/// The process mechanics of ``StatusLineMain`` (Darwin only).
enum StatusLineProcess {
    struct Child {
        var pid: pid_t
        /// Write end of the chain's stdin pipe (non-blocking).
        var stdin: Int32
        /// `MonotonicDeadline.now()` at the spawn.
        var startedAt: UInt64
    }

    /// Opens /dev/null on any of fd 0–2 that is closed, so a later pipe or socket can never land
    /// on a standard descriptor (and be handed to the chain as its stdout).
    static func ensureStandardDescriptors() {
        for fd: Int32 in 0...2 where fcntl(fd, F_GETFD) == -1 {
            let n = open("/dev/null", fd == 0 ? O_RDONLY : O_WRONLY)
            if n >= 0, n != fd {
                _ = dup2(n, fd)
                close(n)
            }
        }
    }

    /// Reads `fd` to EOF within `deadline`, keeping what arrived when it stops early (over `limit`
    /// or out of time): the chain still gets those bytes.
    static func readInput(fd: Int32, limit: Int, deadline: MonotonicDeadline) -> (bytes: [UInt8], complete: Bool) {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, deadline.pollTimeout)
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { return (out, false) }
            if ready < 0 || p.revents & Int16(POLLNVAL) != 0 { return (out, true) }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
                if out.count > limit { return (out, false) }
            } else if n == 0 {
                return (out, true)
            } else if errno != EINTR, errno != EAGAIN {
                return (out, true)
            }
        }
    }

    struct SpawnError: Error {
        var errno: Int32
    }

    /// `/bin/sh -c <command>` in a new process group (pgid = its pid) with only fds 0–2: 0 is a
    /// fresh pipe, 1 and 2 are ours.
    static func spawnChain(_ command: String) -> Result<Child, SpawnError> {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return .failure(SpawnError(errno: errno)) }
        let readEnd = fds[0], writeEnd = fds[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFL, fcntl(writeEnd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        var forwarded = sigset_t()
        _ = sigemptyset(&forwarded)
        for s in [SIGTERM, SIGINT, SIGHUP] { _ = sigaddset(&forwarded, s) }
        var inherited = sigset_t()
        _ = sigprocmask(SIG_BLOCK, &forwarded, &inherited)
        defer { _ = sigprocmask(SIG_SETMASK, &inherited, nil) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        for fd in [STDOUT_FILENO, STDERR_FILENO] where fcntl(fd, F_GETFD) != -1 {
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                                        | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Ignored dispositions survive exec: SIGPIPE (ignored here) must be the default again, or
        // `… | head` in the user's command would see EPIPE errors instead of a quiet exit.
        var defaults = sigset_t()
        _ = sigemptyset(&defaults)
        for s in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGALRM] { _ = sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &inherited)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { for p in argv { free(p) } }
        let envp = chainEnvironment()
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        close(readEnd)
        guard rc == 0 else {
            close(writeEnd)
            return .failure(SpawnError(errno: rc))
        }
        chainProcessGroup = pid
        return .success(Child(pid: pid, stdin: writeEnd, startedAt: MonotonicDeadline.now()))
    }

    /// Our environment without `CODD_STATUSLINE_CHAIN` (pointers into `environ`, valid for the
    /// spawn). A chained command that itself runs `codd-statusline` must not find the variable and
    /// run the same chain again, recursively; nothing else uses it (CODD web's wrapper takes its
    /// chain from argv).
    static func chainEnvironment() -> [UnsafeMutablePointer<CChar>?] {
        let prefix = Array((StatusLineWireNames.chainEnvironment + "=").utf8CString.dropLast())
        var out: [UnsafeMutablePointer<CChar>?] = []
        var p = environ
        while let entry = p.pointee {
            if strncmp(entry, prefix, prefix.count) != 0 { out.append(entry) }
            p += 1
        }
        out.append(nil)
        return out
    }

    /// Writes `bytes` to the chain's stdin until done, the chain stops reading (EPIPE) or the
    /// deadline, then closes it so the chain sees EOF.
    static func feed(_ fd: Int32, _ bytes: [UInt8], deadline: MonotonicDeadline) {
        defer { close(fd) }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR { continue }
            guard n < 0, errno == EAGAIN else { return }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&p, 1, deadline.pollTimeout)
            if ready == 0 { return }
            if ready < 0, errno != EINTR { return }
        }
    }

    /// The wait status once `pid` exits, or `nil` when `deadline` passes first. Uses a kqueue
    /// NOTE_EXIT wait (no polling latency on the status line), polling only as a fallback.
    static func waitForExit(_ pid: pid_t, deadline: MonotonicDeadline) -> Int32? {
        if let status = reap(pid) { return status }
        let kq = kqueue()
        if kq >= 0 {
            defer { close(kq) }
            var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                                fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            if kevent(kq, &change, 1, nil, 0, nil) == 0 {
                while true {
                    // Also covers an exit between the first reap and the registration.
                    if let status = reap(pid) { return status }
                    let now = MonotonicDeadline.now()
                    guard deadline.nanoseconds > now else { return nil }
                    let left = deadline.nanoseconds - now
                    var timeout = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
                    var event = kevent()
                    let n = kevent(kq, nil, 0, &event, 1, &timeout)
                    if n > 0 { return reapBlocking(pid) }
                    if n == 0 { return reap(pid) }
                    if errno != EINTR { break }
                }
            } else if errno == ESRCH {
                return reapBlocking(pid)
            }
        }
        while true {
            if let status = reap(pid) { return status }
            if deadline.hasPassed { return nil }
            usleep(2000)
        }
    }

    static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return status }
            if r == 0 { return nil }
            if errno == EINTR { continue }
            return 0 // ECHILD: not ours to wait for any more; nothing better to report
        }
    }

    static func reapBlocking(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return 0 }
        }
        return status
    }

    /// The timeout path: SIGTERM to the group, SIGKILL after the grace when the leader or any other
    /// member (a background job that ignores SIGTERM and would keep Claude's stdout open) is still
    /// there. Returns the leader's wait status.
    static func terminate(group pid: pid_t) -> Int32 {
        signalGroup(pid, SIGTERM)
        let grace = MonotonicDeadline.after(milliseconds: StatusLineCommand.killGraceMilliseconds)
        // Once more for a member forked while the group was being signalled (see forwardSignalAndExit).
        var status = waitForExit(pid, deadline: .after(milliseconds: 20))
        if groupExists(pid) { _ = kill(-pid, SIGTERM) }
        if status == nil { status = waitForExit(pid, deadline: grace) }
        while status != nil, groupExists(pid), !grace.hasPassed { usleep(10_000) }
        if status == nil || groupExists(pid) { signalGroup(pid, SIGKILL) }
        if status == nil {
            status = waitForExit(pid, deadline: .after(milliseconds: StatusLineCommand.killGraceMilliseconds))
        }
        return status ?? SIGKILL // the raw wait status of "killed by SIGKILL"
    }

    static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        if kill(-pid, signal) != 0 { _ = kill(pid, signal) }
    }

    static func groupExists(_ pid: pid_t) -> Bool {
        kill(-pid, 0) == 0 || errno == EPERM
    }

    /// The shell convention: the exit code, or 128 + n for a death by signal n.
    static func exitCode(_ status: Int32) -> Int32 {
        let low = status & 0x7F
        if low == 0 { return (status >> 8) & 0xFF }
        if low != 0x7F { return 128 + low }
        return 1
    }
}
