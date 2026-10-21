import Foundation

/// Shared quota arithmetic. CODD shows REMAINING quota; cswap and the status line report USED.
public enum QuotaMath {
    /// `round1(clamp(100 − used, 0, 100))` (session-insights.js `usageWindow`).
    public static func remaining(usedPercent used: Double) -> Double {
        round1(min(100, max(0, 100 - used)))
    }

    static func round1(_ v: Double) -> Double {
        (v * 10).rounded() / 10
    }
}

/// Which quota window.
public enum QuotaWindowKind: String, Sendable, Codable, CaseIterable {
    /// The 5-hour window (`5h`).
    case fiveHour
    /// The 7-day window (`1w`).
    case weekly
}

/// One quota window as last measured.
public struct QuotaWindow: Sendable, Equatable, Codable {
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public init(_ w: CswapWindow) {
        self.init(usedPercent: w.pct, resetsAt: w.resetsAt)
    }

    /// The window evaluated at `now`. Port of session-insights.js `usageWindow`: once `resetsAt`
    /// has passed, the window has rolled over — usage is 0 and the next reset is unknown.
    public func status(at now: Date) -> QuotaWindowStatus {
        if let resetsAt, now > resetsAt {
            return QuotaWindowStatus(usedPercent: 0, remainingPercent: 100, resetsAt: resetsAt,
                                     resetPassed: true, notStarted: false)
        }
        let used = QuotaMath.round1(usedPercent)
        return QuotaWindowStatus(
            usedPercent: used, remainingPercent: QuotaMath.remaining(usedPercent: usedPercent),
            resetsAt: resetsAt, resetPassed: false,
            // cswap: "When the 5h window has not started (pct 0), resets_at is absent".
            notStarted: resetsAt == nil && usedPercent == 0
        )
    }
}

/// ``QuotaWindow`` at a point in time.
public struct QuotaWindowStatus: Sendable, Equatable {
    public var usedPercent: Double
    public var remainingPercent: Double
    /// The (possibly passed) reset time.
    public var resetsAt: Date?
    /// `resetsAt` is in the past: the window rolled over; real usage since then is unknown (≈ 0).
    public var resetPassed: Bool
    /// The window has not started yet (shown as 「未開始」, 100 % remaining).
    public var notStarted: Bool

    /// The upcoming reset, if known.
    public var upcomingReset: Date? { resetPassed ? nil : resetsAt }
}

/// A named per-model weekly window (e.g. "Fable").
public struct NamedQuotaWindow: Sendable, Equatable, Codable {
    public var name: String
    public var window: QuotaWindow
}

/// A cswap-managed Claude account as the app models it.
public struct Account: Sendable, Equatable, Identifiable {
    /// cswap account number — the stable key (never the e-mail).
    public var number: Int
    public var alias: String?
    public var isActive: Bool
    public var isDisabled: Bool
    public var usageStatus: CswapUsageStatus
    public var fiveHour: QuotaWindow?
    public var weekly: QuotaWindow?
    public var scoped: [NamedQuotaWindow]
    /// When the numbers were measured.
    public var usageAsOf: Date?
    /// The numbers are cswap's last-good fallback (the latest fetch failed).
    public var usageIsLastGood: Bool
    // M3 (D2, D7, D12, D25), filled by ``AccountAssembler``.
    /// D25 plan chip (`MAX 20x`), `nil` when unknown.
    public var plan: String?
    /// The cswap session profile for pinned sessions (D12). Its name carries the e-mail slug:
    /// never log, dump or show it (D31); ``description`` prints `profile: yes|no` only.
    public var sessionProfile: URL?
    public var sessionProfileStale: Bool
    public var sessionProfileSharesSettings: Bool?
    public var usageHealth: CswapUsageHealth
    /// Source and capture time of the newest window shown (`statusline · 12s 前`, D7).
    public var source: QuotaSource?
    public var sourceAt: Date?

    public var id: Int { number }

    public init(number: Int, alias: String? = nil, isActive: Bool = false, isDisabled: Bool = false,
                usageStatus: CswapUsageStatus = .ok, fiveHour: QuotaWindow? = nil, weekly: QuotaWindow? = nil,
                scoped: [NamedQuotaWindow] = [], usageAsOf: Date? = nil, usageIsLastGood: Bool = false,
                plan: String? = nil, sessionProfile: URL? = nil, sessionProfileStale: Bool = false,
                sessionProfileSharesSettings: Bool? = nil, usageHealth: CswapUsageHealth = .none,
                source: QuotaSource? = nil, sourceAt: Date? = nil) {
        self.number = number
        self.alias = alias
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.usageStatus = usageStatus
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.scoped = scoped
        self.usageAsOf = usageAsOf
        self.usageIsLastGood = usageIsLastGood
        self.plan = plan
        self.sessionProfile = sessionProfile
        self.sessionProfileStale = sessionProfileStale
        self.sessionProfileSharesSettings = sessionProfileSharesSettings
        self.usageHealth = usageHealth
        self.source = source
        self.sourceAt = sourceAt
    }

    /// Builds the model from a cswap row, using `usage` or else `lastGoodUsage`.
    public init(cswap row: CswapAccount) {
        let usage = row.effectiveUsage
        self.init(
            number: row.number,
            alias: row.alias,
            isActive: row.active,
            isDisabled: row.disabled,
            usageStatus: row.usageStatus,
            fiveHour: usage?.fiveHour.map(QuotaWindow.init),
            weekly: usage?.sevenDay.map(QuotaWindow.init),
            scoped: usage?.scoped.map { NamedQuotaWindow(name: $0.name, window: QuotaWindow($0.window)) } ?? [],
            usageAsOf: row.effectiveUsageFetchedAt,
            usageIsLastGood: row.isUsingLastGoodUsage
        )
    }

    /// All accounts of a `list --json` response.
    public static func accounts(from list: CswapListResponse) -> [Account] {
        list.accounts.map { row in
            var a = Account(cswap: row)
            if let n = list.activeAccountNumber, !list.accounts.contains(where: \.active) { a.isActive = row.number == n }
            return a
        }
    }

    /// `#3 工作`, or `#3` without alias (e-mails are never shown).
    public var displayName: String {
        alias.map { "#\(number) \($0)" } ?? "#\(number)"
    }

    public func window(_ kind: QuotaWindowKind) -> QuotaWindow? {
        kind == .fiveHour ? fiveHour : weekly
    }
}

extension Account: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        var parts = [EmailRedaction.redact(displayName)]
        if isActive { parts.append("active") }
        if isDisabled { parts.append("disabled") }
        parts.append("status: \(usageStatus)")
        if let fiveHour { parts.append("5h used \(fiveHour.usedPercent)") }
        if let weekly { parts.append("1w used \(weekly.usedPercent)") }
        if let plan { parts.append("plan: \(plan)") }
        if let source { parts.append("source: \(source.rawValue)") }
        parts.append("profile: \(sessionProfile == nil ? "no" : "yes")")
        return "Account(\(parts.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }

    /// `dump` shows every field except the profile path (D31).
    public var customMirror: Mirror {
        Mirror(self, children: [
            "number": number, "alias": alias.map(EmailRedaction.redact) as Any, "isActive": isActive, "isDisabled": isDisabled,
            "usageStatus": usageStatus, "fiveHour": fiveHour as Any, "weekly": weekly as Any, "scoped": scoped,
            "usageAsOf": usageAsOf as Any, "usageIsLastGood": usageIsLastGood, "plan": plan as Any,
            "profile": sessionProfile == nil ? "no" : "yes", "sessionProfileStale": sessionProfileStale,
            "sessionProfileSharesSettings": sessionProfileSharesSettings as Any, "usageHealth": usageHealth,
            "source": source as Any, "sourceAt": sourceAt as Any,
        ], displayStyle: .struct)
    }
}
