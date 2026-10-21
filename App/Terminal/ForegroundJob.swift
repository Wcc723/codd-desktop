import Darwin

/// Asks whether a shell tab runs a foreground job right now (closing a terminal asks first when
/// one does). `TerminalHub` reads the tab's process group fresh; a factory without it (mock mode)
/// leaves the pane to the running lamp it already shows (`ShellState.runningTabs`).
@MainActor
protocol ShellTabJobProbe {
    func runsForegroundJob(tabID: String) -> Bool
}

/// D25: whether a shell runs a foreground job (`npm run dev`, `sleep 30`), from its `kinfo_proc`.
///
/// An interactive shell with job control gives each foreground job its own process group and
/// makes it the terminal's foreground group; at its prompt the foreground group is the shell's
/// own again. So "running" is: the controlling terminal has a foreground group, and it is not the
/// shell's. No protocol change and nothing read from the PTY; a shell without job control
/// (`sh -c`, `cat`) never lights the lamp.
enum ForegroundJob {
    /// The parts of `kinfo_proc` the rule needs.
    struct Status: Equatable, Sendable {
        var pid: pid_t
        var parentPid: pid_t
        /// The process's own process group.
        var processGroup: pid_t
        /// The foreground process group of its controlling terminal (≤ 0 without one).
        var terminalProcessGroup: pid_t
    }

    /// Pure rule (unit-tested): `e_tpgid > 0 && e_tpgid != e_pgid`.
    static func isRunning(_ status: Status) -> Bool {
        status.terminalProcessGroup > 0 && status.terminalProcessGroup != status.processGroup
    }

    /// `sysctl(KERN_PROC_PID)` for one process; nil when it does not exist (or is not visible).
    static func status(of pid: pid_t) -> Status? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        return Status(pid: pid, parentPid: info.kp_eproc.e_ppid, processGroup: info.kp_eproc.e_pgid,
                      terminalProcessGroup: info.kp_eproc.e_tpgid)
    }

    /// Whether `childPid` runs a foreground job. With `holderPid`, the process must still be that
    /// holder's child: a pid reused after the shell exited (a tab never shown this run hears no
    /// EXIT) never lights a lamp.
    static func isRunning(childPid: pid_t, holderPid: pid_t?) -> Bool {
        guard let status = status(of: childPid) else { return false }
        if let holderPid, holderPid > 0, status.parentPid != holderPid { return false }
        return isRunning(status)
    }
}
