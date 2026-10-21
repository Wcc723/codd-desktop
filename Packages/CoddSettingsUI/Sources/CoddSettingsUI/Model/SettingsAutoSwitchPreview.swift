import CoddPreferences
import CoddUI
import Foundation

/// ACCOUNTS › 即時預覽 (SPEC R8): every account in R7 order with the distance from its lower
/// checked window to the threshold, the account that would be picked next, and the footer note.
/// `compute` is the artboard's own rule, so the preview follows the threshold stepper and the
/// window checkboxes at once without a round trip through the app.
public struct SettingsAutoSwitchPreview: Equatable, Sendable {
    public var rows: [SettingsPreviewRow]
    /// `#3 工作` (`—` without an active account).
    public var current: String
    /// `#2 藍鵲` (`—` when nobody qualifies).
    public var next: String
    /// `· 已達門檻，會立即切換`, `· 所有帳號都低於 2%，不切換`, `· 未勾選檢查視窗，不會切換`, or empty.
    public var note: String

    public init(rows: [SettingsPreviewRow], current: String, next: String, note: String) {
        self.rows = rows
        self.current = current
        self.next = next
        self.note = note
    }

    /// The artboard rule: the target is the first non-active, eligible account whose 5h AND 1w
    /// remaining are both above the threshold (an unknown window never qualifies); each row's
    /// distance uses the lower of the checked windows; `已達門檻` at or under the threshold
    /// (danger), amber within 15 points.
    public static func compute(accounts: [SettingsAccountRow], autoSwitch: CoddPreferences.AutoSwitch) -> SettingsAutoSwitchPreview {
        let threshold = Double(min(CoddPreferences.AutoSwitch.thresholdRange.upperBound,
                                   max(CoddPreferences.AutoSwitch.thresholdRange.lowerBound, autoSwitch.thresholdPercent)))
        let checkFive = autoSwitch.checkFiveHour
        let checkWeek = autoSwitch.checkWeekly
        func above(_ quota: SettingsQuota) -> Bool {
            guard let remaining = quota.remaining, remaining.isFinite else { return false }
            return remaining > threshold
        }
        let target = (checkFive || checkWeek)
            ? accounts.first { !$0.isActive && $0.isEligibleTarget && above($0.fiveHour) && above($0.weekly) }
            : nil
        var activeLow = false
        let rows = accounts.map { account -> SettingsPreviewRow in
            var windows: [(value: Double, label: String)] = []
            if checkFive, let value = account.fiveHour.remaining, value.isFinite {
                windows.append((value, account.fiveHour.text.map { "5h \($0)" } ?? "5h \(percent(value))"))
            }
            if checkWeek, let value = account.weekly.remaining, value.isFinite {
                windows.append((value, account.weekly.text.map { "1w \($0)" } ?? "1w \(percent(value))"))
            }
            // The first lowest wins a tie (the artboard's `w.val < low.val`).
            var low: (value: Double, label: String)?
            for window in windows where low == nil || window.value < low!.value { low = window }
            let distance: String
            let tone: Tone?
            if let low {
                let gap = Int(low.value.rounded()) - Int(threshold)
                if account.isActive, gap <= 0 { activeLow = true }
                distance = gap <= 0 ? "\(low.label) · 已達門檻" : "\(low.label) · 距切換 \(gap)%"
                tone = gap <= 0 ? .crit : (gap <= 15 ? .warn : nil)
            } else {
                distance = "未檢查任何視窗"
                tone = nil
            }
            return SettingsPreviewRow(id: account.id, slot: account.slot, alias: account.alias, resetIn: account.resetIn,
                                      distance: distance, distanceTone: tone, isActive: account.isActive,
                                      isNext: target?.id == account.id, fiveHour: account.fiveHour, weekly: account.weekly,
                                      tickFiveHour: checkFive, tickWeekly: checkWeek)
        }
        let note: String
        if !checkFive && !checkWeek {
            note = "· 未勾選檢查視窗，不會切換"
        } else if target == nil {
            note = "· 所有帳號都低於 \(Int(threshold))%，不切換"
        } else if activeLow {
            note = "· 已達門檻，會立即切換"
        } else {
            note = ""
        }
        let active = accounts.first(where: \.isActive)
        return SettingsAutoSwitchPreview(rows: rows, current: active.map { "\($0.slot) \($0.alias)" } ?? "—",
                                         next: target.map { "\($0.slot) \($0.alias)" } ?? "—", note: note)
    }

    private static func percent(_ value: Double) -> String { "\(Int(min(100, max(0, value)).rounded()))%" }
}
