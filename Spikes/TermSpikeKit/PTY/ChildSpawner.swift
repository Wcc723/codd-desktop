import Darwin

/// `forkpty` + `execve` with everything the child needs prepared before the fork.
///
/// Between `fork` and `execve` the child may only make async-signal-safe calls:
/// no allocation, no locks, no Swift runtime work beyond plain loops. All C
/// strings, the termios template and the descriptor limit are computed first.
enum ChildSpawner {
    static func forkExec(_ spec: PTYLaunchSpec) throws -> (pid: pid_t, master: Int32) {
        let argv = CStringArray(spec.arguments)
        let envp = CStringArray(spec.environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            argv.free()
            envp.free()
        }
        guard let executable = strdup(spec.executable) else {
            throw PTYError.invalidSpec("out of memory")
        }
        defer { Darwin.free(executable) }
        let directory = spec.workingDirectory.flatMap { strdup($0) }
        defer { if let directory { Darwin.free(directory) } }

        var size = winsize(
            ws_row: spec.size.rows,
            ws_col: spec.size.columns,
            ws_xpixel: spec.size.pixelWidth,
            ws_ypixel: spec.size.pixelHeight
        )
        var attributes = defaultTermios()
        let descriptorLimit = maxDescriptor()

        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        defaultAction.sa_flags = 0
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)

        var master: Int32 = -1
        let pid = forkpty(&master, nil, &attributes, &size)
        if pid < 0 {
            throw PTYError.forkFailed(errno: errno)
        }
        if pid == 0 {
            // Child. Reset dispositions inherited from the app (GCD and AppKit
            // ignore or block some signals), then unblock everything.
            var number: Int32 = 1
            while number < NSIG {
                if number != SIGKILL, number != SIGSTOP {
                    _ = sigaction(number, &defaultAction, nil)
                }
                number += 1
            }
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            if let directory {
                _ = chdir(directory)
            }
            var fd: Int32 = 3
            while fd < descriptorLimit {
                _ = close(fd)
                fd += 1
            }
            _ = execve(executable, argv.pointer, envp.pointer)
            _exit(127)
        }
        return (pid, master)
    }

    /// Kernel defaults for a new PTY plus `IUTF8`, so canonical-mode erase
    /// removes whole UTF-8 characters (zsh at a prompt, `cat`, `read`).
    static func defaultTermios() -> termios {
        var attributes = termios()
        var master: Int32 = -1
        var slave: Int32 = -1
        if openpty(&master, &slave, nil, nil, nil) == 0 {
            _ = tcgetattr(slave, &attributes)
            close(master)
            close(slave)
        }
        attributes.c_iflag |= tcflag_t(IUTF8)
        return attributes
    }

    /// Upper bound for the close loop; launchd's soft limit is 256, Xcode's 10240.
    static func maxDescriptor() -> Int32 {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 4096 }
        return Int32(clamping: min(limit.rlim_cur, 16_384))
    }
}

/// A NULL-terminated `char *[]` that owns its strings.
struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[strings.count] = nil
    }

    func free() {
        for index in 0 ..< count {
            Darwin.free(pointer[index])
        }
        pointer.deallocate()
    }
}
