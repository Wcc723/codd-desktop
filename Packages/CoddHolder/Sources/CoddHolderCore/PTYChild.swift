import CCoddShim
import CoddPosix
import Darwin

/// The child process on the PTY.
struct PTYChild {
    let pid: pid_t
    /// PTY master: O_NONBLOCK, FD_CLOEXEC.
    let masterFD: Int32
    /// Set when chdir/execve failed in the child (the child has already exited with 126/127).
    let launchFailure: LaunchFailure?

    struct LaunchFailure: Equatable {
        var stage: Int32
        var code: Int32

        /// The working directory was the problem, not the program.
        var isDirectoryFailure: Bool { stage == Int32(CODD_SPAWN_STAGE_CHDIR) }

        var message: String {
            let step = switch stage {
            case Int32(CODD_SPAWN_STAGE_CHDIR): "chdir"
            case Int32(CODD_SPAWN_STAGE_TTY): "controlling tty setup"
            default: "exec"
            }
            return "\(step) failed: \(String(cString: strerror(code)))"
        }
    }

    /// forkpty-style spawn through the C shim (async-signal-safe child path, fds >= 3 closed,
    /// signals reset, PTY slave as controlling terminal).
    static func spawn(argv: [String], environment: [String], cwd: String, cols: UInt16, rows: UInt16) throws(SystemError) -> PTYChild {
        let executable = ChildEnvironment.resolveExecutable(argv[0], environment: environment)
        let arguments = CStringArray(argv)
        let variables = CStringArray(environment)
        var result = codd_pty_spawn_result()
        let status: Int32 = executable.withCString { path in
            cwd.withCString { directory in
                arguments.withUnsafePointer { argvPointer in
                    variables.withUnsafePointer { envPointer in
                        var request = codd_pty_spawn_request(
                            path: path, argv: argvPointer, envp: envPointer, cwd: directory, cols: cols, rows: rows)
                        return codd_pty_spawn(&request, &result)
                    }
                }
            }
        }
        guard status == 0 else { throw .current("forkpty") }
        do {
            try Descriptor.setNonBlocking(result.master_fd)
            try Descriptor.setCloseOnExec(result.master_fd)
        } catch {
            // The child is already running: do not leave it behind unobserved.
            Descriptor.closeQuietly(result.master_fd)
            kill(result.pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(result.pid, &status, 0)
            throw error
        }
        let failure = result.failed_stage == Int32(CODD_SPAWN_STAGE_NONE)
            ? nil
            : LaunchFailure(stage: result.failed_stage, code: result.failed_errno)
        return PTYChild(pid: result.pid, masterFD: result.master_fd, launchFailure: failure)
    }
}
