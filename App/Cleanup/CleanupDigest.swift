import CoddPreferences
import Foundation

/// D31: when the cleanup digest (`清理建議 · 15 項` / `筆記 8 · session 5 · 檔案 2`, action 查看) is
/// due. Every period starts on a Monday at 09:00 local time: 每週 every Monday, 雙週 every other
/// Monday (even weeks counted from Monday 2026-01-05, so the pattern never depends on when CODD
/// was installed), 每月 the first Monday of the month; 關 never. The digest shows at the first
/// launch or hourly tick inside a period it has not shown in, and only with at least
/// ``minimumCandidates``; showing it (posted or suppressed by `-codd-notifications NO`) records
/// the period in `cleanup.json` `digest.lastShownAt`. Pure.
enum CleanupDigest {
    static let minimumCandidates = 5
    static let hour = 9
    /// Week 0 of the 雙週 rhythm (a Monday).
    static let biweeklyAnchor = DateComponents(year: 2026, month: 1, day: 5)

    /// The start of the period `now` is in (nil: digests are off).
    static func periodStart(_ frequency: CoddPreferences.Digest, now: Date, calendar: Calendar) -> Date? {
        switch frequency {
        case .off:
            return nil
        case .weekly:
            return lastMonday(onOrBefore: now, calendar: calendar)
        case .biweekly:
            guard var monday = lastMonday(onOrBefore: now, calendar: calendar),
                  let anchor = calendar.date(from: biweeklyAnchor).flatMap({ calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) })
            else { return nil }
            let days = calendar.dateComponents([.day], from: anchor, to: monday).day ?? 0
            let week = Int((Double(days) / 7).rounded(.down))
            if !week.isMultiple(of: 2), let previous = calendar.date(byAdding: .day, value: -7, to: monday) { monday = previous }
            return monday
        case .monthly:
            for back in 0..<3 {
                guard let month = calendar.date(byAdding: .month, value: -back, to: now),
                      let first = firstMonday(of: month, calendar: calendar), first <= now else { continue }
                return first
            }
            return nil
        }
    }

    /// Whether the digest shows now.
    static func isDue(_ frequency: CoddPreferences.Digest, now: Date, lastShownAt: Date?, candidates: Int, calendar: Calendar) -> Bool {
        guard candidates >= minimumCandidates, let start = periodStart(frequency, now: now, calendar: calendar) else { return false }
        guard let last = lastShownAt else { return true }
        return last < start
    }

    /// The Cleanup page's meta rule, first part (`每週一 09:00`).
    static func scheduleText(_ frequency: CoddPreferences.Digest) -> String {
        switch frequency {
        case .weekly: "每週一 09:00"
        case .biweekly: "隔週一 09:00"
        case .monthly: "每月第一個週一 09:00"
        case .off: "清理提醒已關閉"
        }
    }

    /// POLICY's `提醒` rule (`週一 09:00 · ≥5 項才提醒`).
    static func ruleText(_ frequency: CoddPreferences.Digest) -> String {
        switch frequency {
        case .weekly: "週一 09:00 · ≥\(minimumCandidates) 項才提醒"
        case .biweekly: "隔週一 09:00 · ≥\(minimumCandidates) 項才提醒"
        case .monthly: "每月第一個週一 09:00 · ≥\(minimumCandidates) 項才提醒"
        case .off: "關閉"
        }
    }

    /// The notification's title and body.
    static func content(notes: Int, sessions: Int, files: Int) -> (title: String, body: String) {
        ("清理建議 · \(notes + sessions + files) 項", "筆記 \(notes) · session \(sessions) · 檔案 \(files)")
    }

    // MARK: Calendar

    /// The latest Monday 09:00 at or before `now`.
    static func lastMonday(onOrBefore now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)   // 1 = Sunday … 2 = Monday
        let back = (weekday + 5) % 7                               // days since Monday
        guard let monday = calendar.date(byAdding: .day, value: -back, to: today),
              let at = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: monday) else { return nil }
        if at <= now { return at }
        return calendar.date(byAdding: .day, value: -7, to: at)
    }

    /// The first Monday 09:00 of the month `date` is in.
    static func firstMonday(of date: Date, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let first = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)) else { return nil }
        let weekday = calendar.component(.weekday, from: first)
        let forward = (9 - weekday) % 7                            // days to the first Monday
        guard let monday = calendar.date(byAdding: .day, value: forward, to: first) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: monday)
    }
}
