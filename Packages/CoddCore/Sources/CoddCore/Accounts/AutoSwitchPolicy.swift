import Foundation

/// Settings › 帳號 › 自動切換 (SPEC §9 R8). OFF by default; the user turns it on.
public struct AutoSwitchSettings: Sendable, Equatable, Codable {
    public static let thresholdRange: ClosedRange<Double> = 1...20

    public var isEnabled: Bool
    /// Switch when the active account's remaining % is ≤ this (default 2, range 1–20).
    public var thresholdPercent: Double
    /// Check the 5-hour window (default on).
    public var checkFiveHour: Bool
    /// Check the weekly window (default on).
    public var checkWeekly: Bool
    /// Minimum time between automatic switches (default 300 s).
    public var cooldownSeconds: TimeInterval

    public init(isEnabled: Bool = false, thresholdPercent: Double = 2, checkFiveHour: Bool = true,
                checkWeekly: Bool = true, cooldownSeconds: TimeInterval = 300) {
        self.isEnabled = isEnabled
        self.thresholdPercent = thresholdPercent
        self.checkFiveHour = checkFiveHour
        self.checkWeekly = checkWeekly
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = AutoSwitchSettings()

    /// The threshold clamped into ``thresholdRange``.
    public var effectiveThreshold: Double {
        min(Self.thresholdRange.upperBound, max(Self.thresholdRange.lowerBound, thresholdPercent))
    }
}

/// Why the active account needs to be switched away from.
public struct AutoSwitchTrigger: Sendable, Equatable {
    public var accountNumber: Int
    /// The window that crossed the threshold (the lower one if both did).
    public var window: QuotaWindowKind
    public var remainingPercent: Double

    public init(accountNumber: Int, window: QuotaWindowKind, remainingPercent: Double) {
        self.accountNumber = accountNumber
        self.window = window
        self.remainingPercent = remainingPercent
    }
}

/// Outcome of one policy evaluation.
public enum AutoSwitchDecision: Sendable, Equatable {
    case disabled
    case noActiveAccount
    /// The active account has no usable numbers for any checked window; nothing can be decided.
    case activeUsageUnknown(accountNumber: Int)
    /// Every checked window of the active account is above the threshold.
    case activeAboveThreshold
    /// A switch is due but the previous automatic switch was too recent.
    case coolingDown(until: Date, trigger: AutoSwitchTrigger)
    case switchTo(accountNumber: Int, trigger: AutoSwitchTrigger)
    /// A switch is due but no account qualifies → notify 「所有帳號都低於 2%」.
    case noEligibleTarget(trigger: AutoSwitchTrigger)
}

/// SPEC §9 R8 as pure functions.
///
/// Trigger: the ACTIVE account's remaining ≤ threshold on the 5h window OR the weekly window
/// (each only if its checkbox is on). Target: the first account in R7 order (``AccountOrdering``)
/// whose 5h AND weekly remaining are both above the threshold — regardless of the checkboxes, as R8
/// states. Windows are evaluated with ``QuotaWindow/status(at:)``: a not-started 5h window counts as
/// 100 % and a passed reset as rolled over (100 %). A missing window is unknown: it can neither
/// trigger nor qualify a target. Disabled accounts and accounts whose ``CswapUsageStatus`` does not
/// allow switching are never targets.
public enum AutoSwitchPolicy {
    public static func evaluate(
        accounts: [Account], settings: AutoSwitchSettings, now: Date, lastAutoSwitchAt: Date?
    ) -> AutoSwitchDecision {
        guard settings.isEnabled else { return .disabled }
        guard let active = accounts.first(where: \.isActive) else { return .noActiveAccount }
        let threshold = settings.effectiveThreshold

        var checked: [(QuotaWindowKind, Double)] = []
        if settings.checkFiveHour, let w = active.fiveHour { checked.append((.fiveHour, w.status(at: now).remainingPercent)) }
        if settings.checkWeekly, let w = active.weekly { checked.append((.weekly, w.status(at: now).remainingPercent)) }
        guard !checked.isEmpty else {
            return settings.checkFiveHour || settings.checkWeekly
                ? .activeUsageUnknown(accountNumber: active.number) : .activeAboveThreshold
        }
        let crossing = checked.filter { $0.1 <= threshold }.min { $0.1 < $1.1 }
        guard let (window, remaining) = crossing else { return .activeAboveThreshold }
        let trigger = AutoSwitchTrigger(accountNumber: active.number, window: window, remainingPercent: remaining)

        if let last = lastAutoSwitchAt {
            let until = last.addingTimeInterval(settings.cooldownSeconds)
            if now < until { return .coolingDown(until: until, trigger: trigger) }
        }
        guard let target = nextTarget(accounts: accounts, threshold: threshold, now: now) else {
            return .noEligibleTarget(trigger: trigger)
        }
        return .switchTo(accountNumber: target.number, trigger: trigger)
    }

    /// The account auto-switch would pick now (first eligible in R7 order), or `nil`.
    public static func nextTarget(accounts: [Account], threshold: Double, now: Date) -> Account? {
        AccountOrdering.sorted(accounts, now: now).first { isEligibleTarget($0, threshold: threshold, now: now) }
    }

    /// Both windows known and above `threshold`; not active, not disabled, usable status.
    public static func isEligibleTarget(_ account: Account, threshold: Double, now: Date) -> Bool {
        guard !account.isActive, !account.isDisabled, account.usageStatus.allowsAutoSwitchTarget,
              let five = account.fiveHour, let week = account.weekly else { return false }
        return five.status(at: now).remainingPercent > threshold && week.status(at: now).remainingPercent > threshold
    }

    /// One row of the live preview in Settings (R8): accounts in R7 order with 「距門檻」.
    public struct PreviewRow: Sendable, Equatable {
        public var accountNumber: Int
        public var isActive: Bool
        /// The lower of the two windows (`nil` when neither is known).
        public var lowerWindow: QuotaWindowKind?
        public var lowerRemainingPercent: Double?
        /// `lowerRemainingPercent − threshold`.
        public var marginPercent: Double?
        public var isEligibleTarget: Bool
        /// The account auto-switch would pick next (「下一個」).
        public var isNextTarget: Bool
    }

    public static func preview(accounts: [Account], settings: AutoSwitchSettings, now: Date) -> [PreviewRow] {
        let threshold = settings.effectiveThreshold
        let next = nextTarget(accounts: accounts, threshold: threshold, now: now)?.number
        return AccountOrdering.sorted(accounts, now: now).map { a in
            let windows: [(QuotaWindowKind, Double)] = [
                a.fiveHour.map { (.fiveHour, $0.status(at: now).remainingPercent) },
                a.weekly.map { (.weekly, $0.status(at: now).remainingPercent) },
            ].compactMap { $0 }
            let lower = windows.min { $0.1 < $1.1 }
            return PreviewRow(
                accountNumber: a.number, isActive: a.isActive, lowerWindow: lower?.0,
                lowerRemainingPercent: lower?.1, marginPercent: lower.map { QuotaMath.round1($0.1 - threshold) },
                isEligibleTarget: isEligibleTarget(a, threshold: threshold, now: now),
                isNextTarget: a.number == next
            )
        }
    }
}

/// What the agent should do after a policy tick.
public enum AutoSwitchAction: Sendable, Equatable {
    case none
    case switchAccount(to: Int, trigger: AutoSwitchTrigger)
    /// Show 「所有帳號都低於 N%」 once per episode.
    case notifyNoEligibleTarget(trigger: AutoSwitchTrigger)
}

/// UNDO of an automatic switch: no automatic switch away from ``account`` until ``until`` (the
/// reset of the window that triggered it), until the user switches to another account, or until
/// the rule changes. Without it the cooldown's end switched away again (M3 review).
public struct AutoSwitchHold: Sendable, Equatable {
    public var account: Int
    public var until: Date
    /// The rule when UNDO was pressed: an edit ends the hold.
    public var settings: AutoSwitchSettings
    public var since: Date
    /// The account was active again after the UNDO (from then on, leaving it is the user's switch).
    public var reached = false

    public init(account: Int, until: Date, settings: AutoSwitchSettings, since: Date) {
        self.account = account
        self.until = until
        self.settings = settings
        self.since = since
    }
}

/// Small state machine around ``AutoSwitchPolicy`` that applies the cooldown, de-duplicates the
/// "no eligible account" notification (once until the condition clears or a switch happens),
/// backs off a switch that keeps failing and keeps an UNDO (``AutoSwitchHold``).
public struct AutoSwitchController: Sendable, Equatable {
    public private(set) var lastAutoSwitchAt: Date?
    public private(set) var notifiedNoTarget = false
    /// Failed switches in a row this episode (a success or a cleared trigger ends the episode).
    public private(set) var consecutiveFailures = 0
    /// No new attempt before this: a `cswap switch` that keeps failing writes and rolls back the
    /// global credentials on every try, so it is not retried on every tick (M3 review).
    public private(set) var retryNotBefore: Date?
    public private(set) var hold: AutoSwitchHold?
    /// `lastAutoSwitchAt` before the most recent ``AutoSwitchAction/switchAccount(to:trigger:)``,
    /// restored by ``switchFailed(at:cooldownSeconds:)``.
    private var previousAutoSwitchAt: Date?

    /// An UNDO that never brings its account back (the switch back failed) stops holding after this.
    public static let holdReachTimeout: TimeInterval = 120
    /// The longest wait between retries of a failing switch.
    public static let maxRetryDelay: TimeInterval = 3600

    public init(lastAutoSwitchAt: Date? = nil) {
        self.lastAutoSwitchAt = lastAutoSwitchAt
    }

    /// The wait before the next attempt after `failures` failed switches in a row: none after the
    /// first (a credential lock clears quickly; D13: a failed switch starts no cooldown), then the
    /// cooldown (at least 60 s), doubled per further failure, at most an hour.
    public static func retryDelay(afterFailures failures: Int, cooldownSeconds: TimeInterval) -> TimeInterval? {
        guard failures >= 2 else { return nil }
        let base = max(60, cooldownSeconds)
        return min(maxRetryDelay, base * pow(2, Double(min(failures - 2, 16))))
    }

    /// The cooldown starts when the switch action is RETURNED (so a tick that overlaps a running
    /// `cswap switch` cannot issue a second one). Call this when that switch then fails
    /// (`ClaudeCodeLockTimeout`, …): a failed switch is not a switch, so the cooldown is undone; the
    /// next tick may retry once, further failures wait ``retryDelay(afterFailures:cooldownSeconds:)``.
    /// Returns the failures in a row (1 = the first of this episode: tell the user).
    @discardableResult
    public mutating func switchFailed(at now: Date? = nil, cooldownSeconds: TimeInterval = AutoSwitchSettings.default.cooldownSeconds) -> Int {
        lastAutoSwitchAt = previousAutoSwitchAt
        consecutiveFailures += 1
        if let now, let delay = Self.retryDelay(afterFailures: consecutiveFailures, cooldownSeconds: cooldownSeconds) {
            retryNotBefore = now.addingTimeInterval(delay)
        }
        return consecutiveFailures
    }

    /// The switch the controller asked for went through: the failure episode is over.
    public mutating func switchSucceeded() {
        consecutiveFailures = 0
        retryNotBefore = nil
    }

    /// UNDO / 復原 of an automatic switch back to `account`: held until `until` (see ``AutoSwitchHold``).
    public mutating func undoAutoSwitch(back account: Int, until: Date, settings: AutoSwitchSettings, now: Date) {
        hold = AutoSwitchHold(account: account, until: until, settings: settings, since: now)
        consecutiveFailures = 0
        retryNotBefore = nil
    }

    public mutating func step(accounts: [Account], settings: AutoSwitchSettings, now: Date) -> AutoSwitchAction {
        updateHold(active: accounts.first(where: \.isActive)?.number, settings: settings, now: now)
        let decision = AutoSwitchPolicy.evaluate(
            accounts: accounts, settings: settings, now: now, lastAutoSwitchAt: lastAutoSwitchAt)
        switch decision {
        case .switchTo(let n, let trigger):
            if hold?.account == trigger.accountNumber { return .none }
            if let retryNotBefore, now < retryNotBefore { return .none }
            previousAutoSwitchAt = lastAutoSwitchAt
            lastAutoSwitchAt = now
            notifiedNoTarget = false
            return .switchAccount(to: n, trigger: trigger)
        case .noEligibleTarget(let trigger):
            guard !notifiedNoTarget, hold?.account != trigger.accountNumber else { return .none }
            notifiedNoTarget = true
            return .notifyNoEligibleTarget(trigger: trigger)
        case .coolingDown, .activeUsageUnknown:
            return .none
        case .disabled, .noActiveAccount, .activeAboveThreshold:
            notifiedNoTarget = false
            consecutiveFailures = 0
            retryNotBefore = nil
            return .none
        }
    }

    /// Ends the hold once its window reset passed, the rule changed, or the user left its account.
    private mutating func updateHold(active: Int?, settings: AutoSwitchSettings, now: Date) {
        guard var h = hold else { return }
        if active == h.account { h.reached = true }
        let left = h.reached ? active != h.account : now.timeIntervalSince(h.since) > Self.holdReachTimeout
        hold = now >= h.until || h.settings != settings || left ? nil : h
    }

    /// Why ``step(accounts:settings:now:)`` holds back a due switch, for the dump (nil: it does not).
    public func waitReason(for decision: AutoSwitchDecision, now: Date) -> String? {
        guard case .switchTo(_, let trigger) = decision else { return nil }
        if hold?.account == trigger.accountNumber { return "held-by-undo" }
        if let retryNotBefore, now < retryNotBefore { return "retry-wait" }
        return nil
    }
}
