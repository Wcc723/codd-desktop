import CoddPosix
import Darwin

/// Command line for one holder (mirrors `codd-holder`'s CLI).
public struct HolderLaunch: Sendable, Equatable {
    public var holderExecutable: String
    public var session: String
    public var sessionDirectory: String
    public var socketPath: String
    public var cols: UInt16
    public var rows: UInt16
    public var cwd: String
    public var ringSize: Int?
    public var envFile: String?
    public var exitLingerMilliseconds: Int?
    public var logPath: String?
    /// `--flow-limit` (tests and measurements; the holder default is 1 MiB).
    public var flowControlLimit: Int?
    public var argv: [String]

    public init(
        holderExecutable: String, session: String, sessionDirectory: String, socketPath: String,
        cols: UInt16, rows: UInt16, cwd: String, ringSize: Int? = nil, envFile: String? = nil,
        exitLingerMilliseconds: Int? = nil, logPath: String? = nil, flowControlLimit: Int? = nil, argv: [String]
    ) {
        self.holderExecutable = holderExecutable
        self.session = session
        self.sessionDirectory = sessionDirectory
        self.socketPath = socketPath
        self.cols = cols
        self.rows = rows
        self.cwd = cwd
        self.ringSize = ringSize
        self.envFile = envFile
        self.exitLingerMilliseconds = exitLingerMilliseconds
        self.logPath = logPath
        self.flowControlLimit = flowControlLimit
        self.argv = argv
    }

    /// argv for posix_spawn, including argv[0].
    public var arguments: [String] {
        var result = [
            holderExecutable, "--session", session, "--dir", sessionDirectory, "--socket", socketPath,
            "--cols", String(cols), "--rows", String(rows), "--cwd", cwd,
        ]
        if let ringSize { result += ["--ring-size", String(ringSize)] }
        if let envFile { result += ["--env-file", envFile] }
        if let exitLingerMilliseconds { result += ["--exit-linger-ms", String(exitLingerMilliseconds)] }
        if let logPath { result += ["--log", logPath] }
        if let flowControlLimit { result += ["--flow-limit", String(flowControlLimit)] }
        return result + ["--"] + argv
    }
}

/// Starts holders so they outlive the spawner.
///
/// `posix_spawn` with `POSIX_SPAWN_SETSID` (own session and process group, so quitting or killing the
/// app's group does not take the holder along), `POSIX_SPAWN_CLOEXEC_DEFAULT` (no app descriptor leaks
/// into the holder, and from there into `claude`), default signal dispositions, an empty signal mask
/// and /dev/null as stdin/stdout/stderr.
///
/// The spawner is the holder's parent until it exits: a long-running spawner must reap the holder
/// (`waitpid`, e.g. from a process-exit dispatch source) to avoid zombies.
public enum HolderSpawner {
    public static func spawn(
        _ launch: HolderLaunch, environment: [String]? = nil, stderrPath: String? = nil
    ) throws(SystemError) -> pid_t {
        try spawn(executable: launch.holderExecutable, arguments: launch.arguments, environment: environment, stderrPath: stderrPath)
    }

    public static func spawn(
        executable: String, arguments: [String], environment: [String]? = nil, stderrPath: String? = nil
    ) throws(SystemError) -> pid_t {
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { throw .current("posix_spawnattr_init") }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw .current("posix_spawn_file_actions_init") }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        var status = posix_spawnattr_setflags(&attributes, Int16(flags))
        guard status == 0 else { throw SystemError("posix_spawnattr_setflags", code: status) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        if let stderrPath {
            posix_spawn_file_actions_addopen(&actions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }

        let argv = CStringArray(arguments)
        let envp = CStringArray(environment ?? ProcessQueries.environment())
        var pid: pid_t = 0
        status = argv.withUnsafePointer { argvPointer in
            envp.withUnsafePointer { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argvPointer), UnsafeMutablePointer(mutating: envPointer))
            }
        }
        guard status == 0 else { throw SystemError("posix_spawn(\(executable))", code: status) }
        return pid
    }

    /// Polls until `socketPath` accepts connections. Returns false on timeout or when `pid` exited
    /// first (the exit status is left for the caller to reap).
    public static func waitForSocket(_ socketPath: String, timeoutMilliseconds: Int, pid: pid_t? = nil) -> Bool {
        let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        while Clock.monotonicNanoseconds() < deadline {
            if UnixSocket.isLive(path: socketPath) { return true }
            if let pid, hasExited(pid) { return false }
            Clock.sleep(milliseconds: 2)
        }
        return UnixSocket.isLive(path: socketPath)
    }

    /// True if our child `pid` terminated (without reaping it).
    public static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return result == 0 && info.si_pid == pid
    }
}
