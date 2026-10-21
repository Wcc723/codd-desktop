import Darwin

/// Time sources.
public enum Clock {
    /// Monotonic nanoseconds (CLOCK_UPTIME_RAW = mach_absolute_time), comparable across processes.
    @inline(__always)
    public static func monotonicNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Milliseconds since the Unix epoch.
    public static func wallMilliseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_REALTIME) / 1_000_000
    }

    /// Sleeps the calling thread (tests and CLI only; never inside the holder loop).
    public static func sleep(milliseconds: Int) {
        var request = timespec(tv_sec: milliseconds / 1000, tv_nsec: (milliseconds % 1000) * 1_000_000)
        var remaining = timespec()
        while nanosleep(&request, &remaining) < 0 && errno == EINTR {
            request = remaining
        }
    }
}
