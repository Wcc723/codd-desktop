import Foundation
import Observation
import CoddUI

/// One quota window (5 hours or 1 week) as reported by statusline / cswap.
struct QuotaWindow: Equatable, Sendable {
    /// Remaining percentage, 0...100.
    var remainingPercent: Int
    var resetsAt: Date?
    /// The 5h window starts with the first message; before that it is "not started".
    var started: Bool = true
    /// False while nothing was measured for this window yet (drawn `—`, muted, never a target).
    var known: Bool = true

    /// Bar tone: muted before the window starts (or while unknown), crit under 20 %, warn under 50 %.
    var tone: QuotaTone {
        guard known, started else { return .muted }
        if remainingPercent < 20 { return .crit }
        if remainingPercent < 50 { return .warn }
        return .ok
    }

    /// No measurement yet.
    static let unknown = QuotaWindow(remainingPercent: 0, resetsAt: nil, started: true, known: false)

    /// `91%`, or `—` while unknown.
    var valueText: String { known ? "\(remainingPercent)%" : "—" }
}

enum QuotaTone: Sendable { case ok, warn, crit, muted }

/// A per-model weekly window (`Fable`), cswap only (D7).
struct ScopedQuota: Equatable, Sendable {
    var name: String
    var remainingPercent: Int
    var resetsAt: Date?
}

/// How trustworthy an account's numbers are (cswap's cache health, D2).
enum AccountHealth: Equatable, Sendable {
    case ok
    /// cswap's cache row is older than 15 minutes.
    case stale
    /// cswap's last fetches failed (its error, redacted, D31); the numbers are last-good ones.
    case failing(String)
    /// cswap quarantined the login: only a re-login helps (never an auto-switch target).
    case reloginRequired

    /// The dump spelling.
    var key: String {
        switch self {
        case .ok: "ok"
        case .stale: "stale"
        case .failing: "failing"
        case .reloginRequired: "reloginRequired"
        }
    }
}

/// A cswap account slot. Never carries the email (aliases only, SPEC §5), nor its cswap session
/// profile path (it contains an e-mail slug, D31): only whether one exists.
@MainActor @Observable
final class AccountVM: Identifiable {
    let id: AccountID
    /// Slot label, e.g. `#3` (`—` for the D4 pseudo account).
    var slot: String
    var alias: String
    /// D25 plan chip (`MAX 20x`); nil when unknown.
    var plan: String?
    var fiveHour: QuotaWindow
    var week: QuotaWindow
    var scoped: [ScopedQuota] = []
    /// Where the newest number came from, e.g. `statusline`, `cswap cache` (empty: nothing yet).
    var source: String
    /// When that number was measured (D7: the account's age `12s 前`).
    var sourceAt: Date?
    /// The active account: sessions following the global login; any other: sessions pinned to it
    /// (D12, `cswap run` profile).
    var sessionCount: Int
    /// When the weekly quota runs out at the current pace, if before the reset (the source's
    /// forecast; Home's `1w 用量超前預期 · 預估 10/17 18:00 用完`). Nil: on pace or unknown.
    var weekExhaustsAt: Date?
    var health: AccountHealth = .ok
    /// cswap's `disabled` flag: never switched to automatically, still listed.
    var isDisabled = false
    /// D12: `<cswapRoot>/sessions/<n>-*` exists (the path itself is never kept here).
    var hasSessionProfile = false
    /// cswap's stale marker on that profile: pinning is refused until `cswap run <n>`.
    var profileStale = false
    /// D4: `#— 目前登入`, the global login when cswap is not available (never a switch target).
    var isPseudo = false

    init(id: AccountID, slot: String, alias: String, plan: String?, fiveHour: QuotaWindow, week: QuotaWindow,
         source: String, sourceAt: Date?, sessionCount: Int, weekExhaustsAt: Date? = nil) {
        self.id = id
        self.slot = slot
        self.alias = alias
        self.plan = plan
        self.fiveHour = fiveHour
        self.week = week
        self.source = source
        self.sourceAt = sourceAt
        self.sessionCount = sessionCount
        self.weekExhaustsAt = weekExhaustsAt
    }

    /// `#3 工作`, or `#3` without an alias.
    var displayName: String { alias.isEmpty ? slot : "\(slot) \(alias)" }

    /// The cswap number (nil for the pseudo account).
    var number: Int? { Int(id) }

    /// Worst tone of the two windows (rail account chip).
    var worstTone: QuotaTone {
        let order: [QuotaTone] = [.crit, .warn, .ok, .muted]
        let tones = [fiveHour.tone, week.tone]
        return order.first(where: tones.contains) ?? .ok
    }

    /// `statusline · 12s 前` (D7), `尚無用量` before the first number.
    func sourceLine(now: Date) -> String {
        guard let sourceAt, !source.isEmpty else { return "尚無用量" }
        return "\(source) · \(DurationFormat.ago(sourceAt, now: now))"
    }

    /// `1w 用量超前預期 · 預估 10/17 18:00 用完` while the forecast lands before the weekly reset.
    func paceText(calendar: Calendar = .current) -> String? {
        guard let empty = weekExhaustsAt, week.resetsAt.map({ empty < $0 }) ?? true else { return nil }
        let parts = calendar.dateComponents([.month, .day], from: empty)
        return "1w 用量超前預期 · 預估 \(parts.month ?? 0)/\(parts.day ?? 0) \(ClockFormat.hourMinute(empty, calendar: calendar)) 用完"
    }
}

/// R7: every account list is ordered by WEEKLY reset, soonest first. The active account keeps
/// its sorted place (it is never pinned to the top). Accounts without a reset sort last.
enum AccountOrdering {
    @MainActor
    static func byWeeklyReset(_ accounts: [AccountVM]) -> [AccountVM] {
        accounts.enumerated().sorted { lhs, rhs in
            switch (lhs.element.week.resetsAt, rhs.element.week.resetsAt) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
