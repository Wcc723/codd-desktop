import Darwin

/// Monotonic clock helpers on the same time base as `NSEvent.timestamp`
/// (`mach_absolute_time`, which does not advance during sleep).
public enum Monotonic {
    /// Nanoseconds since boot, excluding sleep (`CLOCK_UPTIME_RAW`).
    @inline(__always)
    public static func nanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Converts an `NSEvent.timestamp`-style uptime in seconds to nanoseconds.
    @inline(__always)
    public static func nanos(fromUptimeSeconds seconds: Double) -> UInt64 {
        seconds <= 0 ? 0 : UInt64(seconds * 1_000_000_000)
    }

    /// Milliseconds between two `nanos()` readings (0 when `end < start`).
    @inline(__always)
    public static func millis(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : 0
    }
}
