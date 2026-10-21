import Foundation

/// Compact durations in CODD's voice: `45s 1m12s 12m 1h02m 2h 1d 2d03h` (SPEC §4).
/// Ported from CODD web `fmtDur` (SessionSidebar.vue) with two additions: seconds are kept
/// under two minutes (`1m12s`, so a freshly started tool visibly ticks) and zero tails are
/// dropped (`2h00m` → `2h`, `1d00h` → `1d`). Above two minutes labels change once a minute,
/// which keeps the 1 Hz redraws to a minimum.
public enum DurationFormat {
    public static func compact(_ interval: TimeInterval, secondsBelow: Int = 120) -> String {
        // Int(_:) traps on NaN / infinity / out-of-range values; clamp first (a corrupt
        // timestamp must never crash the sidebar). 10^9 s is ~31 years.
        let bounded = interval.isFinite ? min(max(interval, 0), 1e9) : 0
        let total = Int(bounded.rounded(.down))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if total < secondsBelow {
            let seconds = total % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m\(pad(seconds))s"
        }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(pad(rest))m"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d\(pad(rest))h"
    }

    /// Countdown until `date`, e.g. `2h57m後`; minute resolution (seconds would jitter).
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite else { return "—" }
        if seconds <= 0 { return "已重置" }
        let minutes = Int(min(seconds, 1e9) / 60)
        if minutes < 60 { return "\(max(1, minutes))m後" }
        return compact(TimeInterval(minutes * 60)) + "後"
    }

    /// Time since `date` for "source age" labels: `12s 前`, `3m 前`.
    public static func ago(_ date: Date, now: Date) -> String {
        "\(compact(now.timeIntervalSince(date), secondsBelow: 60)) 前"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// Clock strings for reset times: `13:39` today, `10/18 週日 12:00` otherwise.
public enum ClockFormat {
    private static let weekdays = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]

    public static func resetLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = hourMinute(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
        return "\(parts.month ?? 0)/\(parts.day ?? 0) \(weekday) \(time)"
    }

    public static func hourMinute(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }

    /// `10:42:07` (STATUS `UPDATED …`).
    public static func hourMinuteSecond(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}

/// `~/Github/a/b/c` → `~/…/b/c` (keep the last two levels, they identify the project).
/// Ported from CODD web `shortPath`.
public enum PathFormat {
    public static func short(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 4, let head = parts.first else { return path }
        return "\(head)/…/\(parts.suffix(2).joined(separator: "/"))"
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    /// `~/x` for a path inside the home folder (the hover card's path line); others unchanged.
    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
