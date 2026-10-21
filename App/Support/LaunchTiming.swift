import Darwin
import Foundation

/// When this process started, from the kernel (every build): the launch-to-sidebar log line
/// (M5 D16) and the post-load aside sweep (D14: `.corrupt-<ms>` files made since the launch)
/// count from it, not from the app delegate's first callback.
enum LaunchTiming {
    /// The process's start time (`kp_proc.p_starttime`), nil when sysctl fails.
    static func processStart(pid: pid_t = getpid()) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    /// `perf launch-to-sidebar ms=<n> rows=<n>` (the line `scripts/m5-perf.sh` reads).
    static func launchToSidebarLine(milliseconds: Double, rows: Int) -> String {
        String(format: "perf launch-to-sidebar ms=%.0f rows=%d", milliseconds, rows)
    }
}
