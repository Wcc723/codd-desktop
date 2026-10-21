import Foundation

/// Merges cswap's state (who the accounts are) with the quota book (their freshest numbers) into
/// the app's ``Account`` values, so ``AccountOrdering`` and ``AutoSwitchPolicy`` run unchanged on
/// the merged numbers.
public enum AccountAssembler {
    /// One ``Account`` per snapshot account, in snapshot (sequence) order. Each window comes from
    /// the book (status line or cswap, whichever is newer, D7) and falls back to the snapshot's
    /// cswap usage; `source` / `sourceAt` / `usageAsOf` are those of the newest window shown.
    ///
    /// Without cswap state this returns `[]`, even when the book has a ``QuotaAccountRef/defaultLogin``
    /// entry: the D4 pseudo account (`#— 目前登入`) has no cswap number, and inventing one (0) would
    /// make it a switch target. The app builds that row itself from `book.entry(.defaultLogin)`.
    public static func accounts(state: CswapStateSnapshot?, book: QuotaBook, now: Date) -> [Account] {
        guard let state else { return [] }
        return state.accounts.map { a in
            let entry = book.entry(.number(a.number))
            var newest: (source: QuotaSource, at: Date)?
            func pick(_ booked: SourcedWindow?, _ cswap: CswapWindow?) -> QuotaWindow? {
                let candidate: (QuotaWindow, QuotaSource, Date?)?
                if let booked {
                    candidate = (booked.window, booked.source, booked.capturedAt)
                } else if let cswap {
                    candidate = (QuotaWindow(cswap), .cswap, a.usageFetchedAt)
                } else {
                    candidate = nil
                }
                if let (_, source, at) = candidate, let at, newest.map({ at > $0.at }) ?? true { newest = (source, at) }
                return candidate?.0
            }
            let five = pick(entry?.fiveHour, a.usage?.fiveHour)
            let week = pick(entry?.weekly, a.usage?.sevenDay)
            var scoped = entry?.scoped ?? []
            if scoped.isEmpty {
                scoped = a.usage?.scoped.map { NamedQuotaWindow(name: $0.name, window: QuotaWindow($0.window)) } ?? []
            }
            var isLastGood = false
            if case .failing = a.usageHealth, newest?.source == .cswap { isLastGood = true }
            return Account(
                number: a.number, alias: a.alias, isActive: a.isActive, isDisabled: a.isDisabled,
                usageStatus: usageStatus(a.usageHealth), fiveHour: five, weekly: week, scoped: scoped,
                usageAsOf: newest?.at, usageIsLastGood: isLastGood, plan: a.plan, sessionProfile: a.sessionProfile,
                sessionProfileStale: a.sessionProfileStale, sessionProfileSharesSettings: a.sessionProfileSharesSettings,
                usageHealth: a.usageHealth, source: newest?.source, sourceAt: newest?.at)
        }
    }

    /// `reloginRequired` → `.reloginRequired` (never an auto-switch target); `failing` →
    /// `.unavailable` (last-good numbers, still a target); fresh / stale / none → `.ok`.
    public static func usageStatus(_ health: CswapUsageHealth) -> CswapUsageStatus {
        switch health {
        case .reloginRequired: return .reloginRequired
        case .failing: return .unavailable
        case .none, .fresh, .stale: return .ok
        }
    }
}
