import Foundation

/// SPEC §9 R7: every account list is ordered by the WEEKLY reset time, soonest first. The active
/// account is not pinned to the top — it keeps its sorted place and is only marked.
public enum AccountOrdering {
    /// Sort key: the upcoming weekly reset. Accounts whose weekly reset is unknown — no usage, no
    /// weekly window, no `resetsAt`, or a reset already passed (the window rolled over and its next
    /// reset is a full week away) — sort after all known ones. Ties: account number ascending.
    public static func sorted(_ accounts: [Account], now: Date) -> [Account] {
        accounts.sorted { a, b in
            switch (weeklyResetKey(a, now: now), weeklyResetKey(b, now: now)) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.number < b.number
            }
        }
    }

    /// The upcoming weekly reset of `account`, or `nil` when unknown.
    public static func weeklyResetKey(_ account: Account, now: Date) -> Date? {
        account.weekly?.status(at: now).upcomingReset
    }

    /// The header hint shown above every account list (R7).
    public static let sortBasisLabel = "依每週重置排序 · 越快重置越上面"
}
