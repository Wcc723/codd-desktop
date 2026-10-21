import Darwin
import Foundation

/// Decides whether a registry entry still describes a running process.
public protocol ProcessLivenessChecking: Sendable {
    /// `true` when `pid` is running and (if `procStart` is given and parseable) started at that time,
    /// which rules out a recycled pid.
    func isAlive(pid: Int, procStart: String?) -> Bool
}

/// `sysctl(KERN_PROC_PID)`-based liveness check with start-time comparison.
///
/// `procStart` is written by Claude Code as the `ps -o lstart` layout **in UTC**
/// (`Thu Oct 15 01:02:22 2026` for a process started at 09:02:22 in UTC+8; verified against
/// `TZ=UTC ps -o lstart` for every live entry on this Mac, Claude Code 2.1.296–2.1.300). The check
/// therefore compares in UTC first and accepts the same wall-clock reading in local time as a
/// fallback, in case a future Claude version switches to local time. A recycled pid would have to
/// start at exactly one of those two instants to be mistaken for the original process.
public struct DarwinProcessLiveness: ProcessLivenessChecking {
    /// Allowed difference between the recorded and the actual start time (the string has 1 s
    /// resolution and is truncated).
    public var tolerance: TimeInterval = 1.5
    /// The zone tried after UTC.
    public var fallbackTimeZone: TimeZone = .current

    public init() {}

    public func isAlive(pid: Int, procStart: String?) -> Bool {
        guard pid > 0, pid <= Int(Int32.max), let started = Self.startTime(pid: Int32(pid)) else { return false }
        guard let procStart, let fields = Self.parseFields(procStart) else { return true }
        let candidates = [Self.utc, fallbackTimeZone].compactMap { Self.date(fields, timeZone: $0) }
        return candidates.contains { abs(started.timeIntervalSince($0)) <= tolerance }
    }

    /// The kernel's start time for `pid`, or `nil` when no such process exists.
    public static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { m in
            sysctl(m.baseAddress, u_int(m.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// Parses `Thu Oct 15 01:02:22 2026` (ctime / `ps -o lstart` layout) as a wall-clock time in
    /// `timeZone` (default UTC, which is what Claude Code writes). Runs of spaces are accepted, so the
    /// space-padded day of ctime (`Oct  5`) also parses. The weekday name is required but not checked.
    public static func parseProcStart(_ s: String, timeZone: TimeZone = utc) -> Date? {
        parseFields(s).flatMap { date($0, timeZone: timeZone) }
    }

    /// Formats a date the way Claude Code writes `procStart` (UTC unless `timeZone` is given).
    public static func formatProcStart(_ date: Date, timeZone: TimeZone = utc) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let weekday = weekdayNames[((c.weekday ?? 1) - 1 + 7) % 7]
        let month = monthNames[((c.month ?? 1) - 1 + 12) % 12]
        func two(_ v: Int?) -> String { let n = v ?? 0; return n < 10 ? "0\(n)" : "\(n)" }
        let day = c.day ?? 1
        return "\(weekday) \(month) \(day < 10 ? " \(day)" : "\(day)") \(two(c.hour)):\(two(c.minute)):\(two(c.second)) \(c.year ?? 1970)"
    }

    // MARK: - Parsing

    public static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .gmt

    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    struct Fields: Equatable {
        var year: Int64, month: Int64, day: Int64, hour: Int64, minute: Int64, second: Int64
    }

    /// Splits and validates the five fields; no `DateFormatter` (fast, locale-independent).
    static func parseFields(_ s: String) -> Fields? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 5, weekdayNames.contains(String(parts[0])),
              let monthIndex = monthNames.firstIndex(of: String(parts[1])),
              let day = Int64(parts[2]), let year = Int64(parts[4]), (1970...9999).contains(year) else { return nil }
        let time = parts[3].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 3, time.allSatisfy({ $0.count == 2 }),
              let hh = Int64(time[0]), let mm = Int64(time[1]), let ss = Int64(time[2]),
              (0...23).contains(hh), (0...59).contains(mm), (0...60).contains(ss) else { return nil }
        let month = Int64(monthIndex + 1)
        let daysInMonth = JSDate.days(fromCivil: month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1, 1)
            - JSDate.days(fromCivil: year, month, 1)
        guard (1...daysInMonth).contains(day) else { return nil }
        return Fields(year: year, month: month, day: day, hour: hh, minute: mm, second: ss)
    }

    /// The instant at which the wall clock in `timeZone` showed `f`.
    static func date(_ f: Fields, timeZone: TimeZone) -> Date? {
        let wallSeconds = JSDate.days(fromCivil: f.year, f.month, f.day) * 86_400 + (f.hour * 60 + f.minute) * 60 + f.second
        let asUTC = Date(timeIntervalSince1970: TimeInterval(wallSeconds))
        // Two passes so the offset is the one in effect at the resulting instant (DST edges).
        let first = asUTC.addingTimeInterval(-TimeInterval(timeZone.secondsFromGMT(for: asUTC)))
        return asUTC.addingTimeInterval(-TimeInterval(timeZone.secondsFromGMT(for: first)))
    }
}
