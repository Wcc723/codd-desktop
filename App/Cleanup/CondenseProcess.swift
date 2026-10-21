import Darwin
import Foundation

/// The one-shot `claude -p` child of a condense run (D32), spawned with `posix_spawn` in a new
/// session (`POSIX_SPAWN_SETSID`: no controlling terminal and its own process group, so `取消` and
/// the timeout end claude and anything it started without touching CODD's own group).
///
/// stdin is a file in the run folder (the instruction and the notes' AI text, 0600), stdout and
/// stderr go to files there too: nothing to drain, so a chatty child can never block on a full
/// pipe. The run folder is the child's cwd. Every other descriptor is closed in the child
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`). The caller polls ``poll()`` (non-blocking `waitpid`).
final class CondenseProcess: @unchecked Sendable {
    enum SpawnError: Error, Equatable, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let text): text
            }
        }
    }

    let pid: pid_t
    private let lock = NSLock()
    private var reaped: Int32?

    /// Starts `executable` with exactly `arguments` and `environment`.
    init(executable: String, arguments: [String], environment: [String: String], directory: String,
         stdin: String, stdout: String, stderr: String) throws(SpawnError) {
        let argv = [executable] + arguments
        if argv.contains(where: { $0.utf8.contains(0) }) { throw .failed("NUL byte in argv") }
        let envp = environment.filter { !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw .failed("posix_spawn_file_actions_init") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw .failed("posix_spawnattr_init") }
        defer { posix_spawnattr_destroy(&attributes) }
        var rc = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, stdin, O_RDONLY, 0)
        if rc == 0 { rc = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        if rc == 0 { rc = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        if rc == 0 { rc = posix_spawn_file_actions_addchdir(&actions, directory) }
        guard rc == 0 else { throw .failed("file actions: \(String(cString: strerror(rc)))") }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else { throw .failed("posix_spawnattr_setflags") }
        var spawned: pid_t = 0
        let result = Self.withCStrings(argv) { cArgv in
            Self.withCStrings(envp) { cEnvp in
                posix_spawn(&spawned, executable, &actions, &attributes, cArgv, cEnvp)
            }
        }
        guard result == 0 else { throw .failed("posix_spawn: \(String(cString: strerror(result)))") }
        pid = spawned
    }

    /// The exit status once the child is gone (`128 + signal` for a signal), nil while it runs.
    func poll() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if let reaped { return reaped }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else {
            // ECHILD: someone else reaped it (never expected); report it as gone.
            if r < 0, errno == ECHILD { reaped = -1 }
            return reaped
        }
        let signal = status & 0x7F
        reaped = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
        return reaped
    }

    /// SIGTERM to the child's process group (it leads its own session), SIGKILL after `grace`.
    func terminate(grace: Duration = .seconds(2)) async {
        guard poll() == nil else { return }
        _ = killpg(pid, SIGTERM)
        let deadline = ContinuousClock.now + grace
        while poll() == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if poll() == nil {
            _ = killpg(pid, SIGKILL)
            while poll() == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for p in pointers { free(p) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
