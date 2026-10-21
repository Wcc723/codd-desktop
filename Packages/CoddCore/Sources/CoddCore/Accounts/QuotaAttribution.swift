import Foundation

/// An account switch, CODD's own or one detected in cswap's state (the active account changed).
public struct SwitchMark: Sendable, Equatable {
    public var at: Date
    public var from: Int?
    public var to: Int?

    public init(at: Date, from: Int?, to: Int?) {
        self.at = at
        self.from = from
        self.to = to
    }
}

public struct QuotaAttributionResult: Sendable, Equatable {
    /// The account the report belongs to; `nil` = dropped (better no number than a wrong one).
    public var account: QuotaAccountRef?
    /// D6: outside the grace window the report matched another account's known weekly reset and
    /// not the active one's: the global login changed in a way cswap's files have not shown yet,
    /// so the app re-reads cswap's state now.
    public var suspectedLoginChange: Bool

    public init(account: QuotaAccountRef?, suspectedLoginChange: Bool = false) {
        self.account = account
        self.suspectedLoginChange = suspectedLoginChange
    }

    public static let dropped = QuotaAttributionResult(account: nil)
}

/// D6: which account a status-line report belongs to.
///
/// A `default` report comes from a claude running on the global login, which is the active cswap
/// account — except right after a switch, when sessions keep the old credentials until they
/// reload them (about 30 s), so for ``switchGrace`` the report's weekly reset is matched against
/// the two accounts involved. The weekly reset is the fingerprint: it differs per account and is
/// stable for a whole week.
///
/// `slots` (cswap's current slots and the login each holds, ``QuotaBook/reconcile(slots:)``)
/// limits the fingerprint to entries of accounts cswap has now and of the login that holds that
/// slot now: a removed account's leftover entry, or one a `cswap swap` gave to another login,
/// would otherwise take the active login's reports. nil = every entry (tests of the bare rule).
public enum QuotaAttribution {
    public static let switchGrace: TimeInterval = 90
    public static let resetTolerance: TimeInterval = 120

    public static func account(for key: AccountKey, weeklyResetsAt: Date?, activeAccount: Int?, hasCswapAccounts: Bool,
                               lastSwitch: SwitchMark?, book: QuotaBook, profileKeys: [String: Int], now: Date,
                               slots: [Int: String?]? = nil) -> QuotaAttributionResult {
        switch key {
        case .cswap(let n):
            return QuotaAttributionResult(account: .number(n))
        case .other(let raw):
            // A pinned session CODD started with exactly this profile path; any other directory is
            // a login CODD cannot name.
            return profileKeys[raw].map { QuotaAttributionResult(account: .number($0)) } ?? .dropped
        case .default:
            break
        }
        guard hasCswapAccounts else { return QuotaAttributionResult(account: .defaultLogin) }

        func entry(_ n: Int) -> QuotaEntry? {
            guard let slots else { return book.entry(.number(n)) }
            guard let identity = slots[n] else { return nil }
            return book.entry(n, matching: identity)
        }
        func matches(_ n: Int?) -> Bool {
            guard let n, let reset = weeklyResetsAt, let known = entry(n)?.weekly?.window.resetsAt else { return false }
            return abs(known.timeIntervalSince(reset)) <= resetTolerance
        }

        if let mark = lastSwitch, now.timeIntervalSince(mark.at) < switchGrace {
            let to = matches(mark.to), from = matches(mark.from)
            switch (to, from) {
            case (true, false): return QuotaAttributionResult(account: mark.to.map(QuotaAccountRef.number))
            case (false, true): return QuotaAttributionResult(account: mark.from.map(QuotaAccountRef.number))
            case (true, true) where mark.to == mark.from: return QuotaAttributionResult(account: mark.to.map(QuotaAccountRef.number))
            default: return .dropped // no match, or both accounts share the reset: cannot tell
            }
        }

        guard let active = activeAccount else { return .dropped }
        if weeklyResetsAt != nil, !matches(active) {
            let others = book.entries.keys.compactMap { ref -> Int? in
                guard case .number(let n) = ref, n != active, matches(n) else { return nil }
                return n
            }
            if others.count == 1 { return QuotaAttributionResult(account: .number(others[0]), suspectedLoginChange: true) }
            if others.count > 1 { return QuotaAttributionResult(account: nil, suspectedLoginChange: true) }
        }
        return QuotaAttributionResult(account: .number(active))
    }
}
