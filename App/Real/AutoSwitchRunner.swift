import CoddCore
import CoddPreferences
import CoddUI
import Foundation
import Observation

/// CODD's own auto-switch (D13, R8; not `cswap auto`, which polls the usage API): CoddCore's
/// `AutoSwitchController` decides on the merged quota numbers after every quota or account change
/// and every 30 s while Settings › 帳號 › 自動切換 is ON. A switch goes through the D5 path
/// (reason `auto`); its toast and notification carry UNDO / 復原, and an UNDO holds that account
/// until the triggering window resets (``AutoSwitchHold``); a failed switch undoes the cooldown so
/// the next tick retries once, then waits longer each time, and the first failure of an episode
/// is notified; "no eligible account" is notified once per episode. The cooldown start is kept in
/// quota.json (D37), so a relaunch cannot switch again within 300 s.
///
/// It also scans for `cswap menubar` / `cswap auto` (every 60 s while auto-switch is ON or STATUS
/// is shown): both tools switching would fight (D13's warning).
@MainActor @Observable
final class AutoSwitchRunner {
    private(set) var lastDecision = "idle"
    /// How the last automatic switch ended (`switched #3 -> #2`, `failed #3 -> #2`), nil before one.
    private(set) var lastSwitchResult: String?
    /// Background cswap tools found by the last scan.
    private(set) var backgroundTools = CswapBackgroundTools()
    /// The last action's notification was for "no eligible account" (the dump's `notified`).
    var notifiedNoTarget: Bool { controller.notifiedNoTarget }
    /// A switch the runner started is still running.
    var isSwitchInFlight: Bool { switching }

    @ObservationIgnored let accounts: CswapAccountStore
    @ObservationIgnored private let preferences: PreferencesService
    @ObservationIgnored private let notifier: AppNotifier
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var controller = AutoSwitchController()
    @ObservationIgnored private let tick: Duration
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var loop: ObservationLoop?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var switching = false
    /// The last automatic switch that went through: the account it left and the window that
    /// triggered it (UNDO holds that account until the window resets).
    @ObservationIgnored private var lastSwitched: (from: Int, window: QuotaWindowKind)?
    /// STATUS (and later Settings › 帳號) is shown: keep scanning for background tools.
    @ObservationIgnored var scanDemand = false { didSet { if scanDemand != oldValue { updateScanning() } } }
    /// Process scan (tests inject one; the default reads this user's processes, D13).
    @ObservationIgnored var scan: @Sendable () -> CswapBackgroundTools = { CswapProcessDetector.scan() }
    @ObservationIgnored var scanInterval: Duration = .seconds(60)
    /// The D5 toast (`↻ 已自動切換到 #2 藍鵲 · #3 工作 1w 剩 2%` with UNDO).
    @ObservationIgnored var toast: (@MainActor (String, (@MainActor () -> Void)?) -> Void)?

    init(accounts: CswapAccountStore, preferences: PreferencesService, notifier: AppNotifier, tick: Duration = .seconds(30),
         now: @escaping @MainActor () -> Date = { Date() }, log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.accounts = accounts
        self.preferences = preferences
        self.notifier = notifier
        self.tick = tick
        self.now = now
        self.log = log
        notifier.onUndo = { [weak self] account in self?.undo(to: account) }
    }

    var isEnabled: Bool { preferences.preferences.accounts.autoSwitch.enabled }

    /// The settings the policy runs with (Settings › 帳號 › 自動切換).
    var settings: AutoSwitchSettings {
        let rule = preferences.preferences.accounts.autoSwitch
        return AutoSwitchSettings(isEnabled: rule.enabled, thresholdPercent: Double(rule.thresholdPercent), checkFiveHour: rule.checkFiveHour,
                                  checkWeekly: rule.checkWeekly, cooldownSeconds: TimeInterval(rule.cooldownSeconds))
    }

    /// After the accounts' first read (the cooldown comes from quota.json).
    func start() {
        guard !started else { return }
        started = true
        controller = AutoSwitchController(lastAutoSwitchAt: accounts.lastAutoSwitchAt)
        loop = ObservationLoop(track: { [weak self] () -> [String] in
            guard let self else { return [] }
            // Quota, the active account, the rule: any change is a reason to decide again.
            let rule = self.preferences.preferences.accounts.autoSwitch
            var keys = ["\(rule.enabled) \(rule.thresholdPercent) \(rule.checkFiveHour) \(rule.checkWeekly) \(rule.cooldownSeconds)",
                        self.accounts.activeAccountID ?? "-", "\(self.accounts.availability.key)"]
            for account in self.accounts.accounts {
                keys.append("\(account.id) \(account.fiveHour.remainingPercent) \(account.week.remainingPercent) \(account.health.key)")
            }
            return keys
        }, apply: { [weak self] _ in
            self?.updateTicking()
            self?.updateScanning()
            self?.evaluate()
        })
    }

    func stop() {
        loop?.cancel()
        loop = nil
        tickTask?.cancel()
        tickTask = nil
        scanTask?.cancel()
        scanTask = nil
    }

    private func updateTicking() {
        guard isEnabled else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        let tick = self.tick
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled, let self else { return }
                self.evaluate()
            }
        }
    }

    // MARK: Deciding

    /// One policy step (also from tests with a manual clock). A switch it starts runs on its own task.
    @discardableResult
    func evaluate() -> AutoSwitchAction {
        guard started, !switching, !accounts.isSwitching else { return .none }
        let at = now()
        let settings = self.settings
        let core = accounts.coreAccounts(now: at)
        let before = controller.lastAutoSwitchAt
        let action = controller.step(accounts: core, settings: settings, now: at)
        persistCooldown()
        switch action {
        case .switchAccount(let to, let trigger):
            lastDecision = "switch #\(trigger.accountNumber) -> #\(to)"
            log("auto-switch to=#\(to) from=#\(trigger.accountNumber) window=\(trigger.window.rawValue) remaining=\(Int(trigger.remainingPercent.rounded()))")
            switching = true
            Task { [weak self] in await self?.perform(to: to, trigger: trigger) }
        case .notifyNoEligibleTarget(let trigger):
            lastDecision = "none-eligible"
            let threshold = Int(settings.effectiveThreshold.rounded())
            let from = accounts.account(String(trigger.accountNumber))?.displayName ?? "#\(trigger.accountNumber)"
            log("auto-switch none eligible (threshold \(threshold)%)")
            notifier.post(.noEligibleTarget, title: "所有帳號都低於 \(threshold)%",
                          body: "\(from) \(Self.windowLabel(trigger.window)) 剩 \(Int(trigger.remainingPercent.rounded()))% · 沒有額度足夠的帳號可以切換")
        case .none:
            let decision = AutoSwitchPolicy.evaluate(accounts: core, settings: settings, now: at, lastAutoSwitchAt: before)
            lastDecision = controller.waitReason(for: decision, now: at) ?? Self.decisionName(decision)
        }
        return action
    }

    /// The switch the controller asked for (D5 with reason `auto`).
    private func perform(to number: Int, trigger: AutoSwitchTrigger) async {
        let outcome = await accounts.switchTo(String(number), reason: .auto)
        switching = false
        switch outcome {
        case .switched(let from, let to, let following):
            let name = accounts.account(to)?.displayName ?? "#\(to)"
            let fromName = from.flatMap { accounts.account($0)?.displayName } ?? "#\(trigger.accountNumber)"
            let low = "\(fromName) \(Self.windowLabel(trigger.window)) 剩 \(Int(trigger.remainingPercent.rounded()))%"
            var undo: (@MainActor () -> Void)?
            if let from { undo = { [weak self] in self?.undo(to: from) } }
            toast?("↻ 已自動切換到 \(name) · \(low)", undo)
            notifier.post(.autoSwitch, title: "↻ 已自動切換到 \(name)", body: "\(low) · \(following) 個 session 約 30 秒內套用",
                          undoAccount: from)
            lastSwitchResult = "switched #\(trigger.accountNumber) -> #\(to)"
            controller.switchSucceeded()
            lastSwitched = (trigger.accountNumber, trigger.window)
        case .alreadyActive:
            lastSwitchResult = "already-active #\(number)"
        case .failed(let message), .refused(let message):
            // A failed switch is not a switch (no cooldown); the next tick retries once, then the
            // wait grows. The user hears about it once per episode, not on every retry.
            let cooldown = settings.cooldownSeconds
            let failures = controller.switchFailed(at: now(), cooldownSeconds: cooldown)
            persistCooldown()
            lastSwitchResult = "failed #\(trigger.accountNumber) -> #\(number)"
            let delay = AutoSwitchController.retryDelay(afterFailures: failures, cooldownSeconds: cooldown)
            log("auto-switch to=#\(number) failed failures=\(failures); retrying "
                + (delay.map { "in \(Int($0)) s" } ?? "on the next tick"))
            if failures == 1 {
                let name = accounts.account(String(number))?.displayName ?? "#\(number)"
                toast?("[ERROR] 自動切換到 \(name) 失敗：\(message)", nil)
                notifier.post(.autoSwitchFailed, title: "自動切換到 \(name) 失敗", body: "\(message) · CODD 稍後會再試")
            }
        }
    }

    /// UNDO (toast) / 復原 (notification): back to the account the auto-switch left, held there
    /// until the window that triggered the switch resets (or the user switches, or edits the rule).
    func undo(to account: AccountID) {
        var suffix = ""
        if let number = Int(account) {
            let at = now()
            let settings = self.settings
            let window = lastSwitched?.from == number ? lastSwitched?.window : nil
            let core = accounts.coreAccounts(now: at).first { $0.number == number }
            let reset = window.flatMap { kind in
                (kind == .fiveHour ? core?.fiveHour : core?.weekly)?.status(at: at).upcomingReset
            }
            let until = min(reset ?? at.addingTimeInterval(settings.cooldownSeconds), at.addingTimeInterval(7 * 86_400))
            controller.undoAutoSwitch(back: number, until: until, settings: settings, now: at)
            log("auto-switch held on #\(number) until \(JSDate.isoString(until))")
            suffix = " · 在 \(window.map(Self.windowLabel) ?? "冷卻") 重置前不再自動切走"
        }
        AccountSwitching.run(account, in: accounts, reason: .undo) { [weak self] text, undo in
            self?.toast?(text.hasPrefix("已切換到") ? text + suffix : text, undo)
        }
    }

    private func persistCooldown() {
        if accounts.lastAutoSwitchAt != controller.lastAutoSwitchAt { accounts.lastAutoSwitchAt = controller.lastAutoSwitchAt }
    }

    static func windowLabel(_ kind: QuotaWindowKind) -> String { kind == .fiveHour ? "5h" : "1w" }

    static func decisionName(_ decision: AutoSwitchDecision) -> String {
        switch decision {
        case .disabled: "disabled"
        case .noActiveAccount: "no-active-account"
        case .activeUsageUnknown: "active-usage-unknown"
        case .activeAboveThreshold: "above-threshold"
        case .coolingDown: "cooling-down"
        case .switchTo: "switch-due"
        case .noEligibleTarget: "none-eligible"
        }
    }

    // MARK: Background tools (D13)

    private func updateScanning() {
        let wanted = isEnabled || scanDemand
        if !wanted {
            scanTask?.cancel()
            scanTask = nil
            return
        }
        guard scanTask == nil else { return }
        let interval = scanInterval
        let scan = self.scan
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { scan() }.value
                guard !Task.isCancelled, let self else { return }
                if found != self.backgroundTools {
                    self.backgroundTools = found
                    self.log("cswap background tools menubar=\(found.menubar) auto=\(found.auto)")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// `! cswap menubar 也在執行，兩邊可能同時切換` (or `cswap auto`), nil when neither runs.
    var backgroundWarning: String? {
        switch (backgroundTools.menubar, backgroundTools.auto) {
        case (true, true): "! cswap menubar 與 cswap auto 也在執行，可能同時切換"
        case (true, false): "! cswap menubar 也在執行，兩邊可能同時切換"
        case (false, true): "! cswap auto 也在執行，兩邊可能同時切換"
        case (false, false): nil
        }
    }

    // MARK: Dump

    /// `autoSwitch {enabled, lastDecision, lastAutoSwitchAt, notified, failures, retryNotBefore,
    /// hold, backgroundTools}`.
    var dumpObject: [String: Any] {
        ["enabled": isEnabled, "lastDecision": lastDecision, "lastSwitch": lastSwitchResult.map { $0 as Any } ?? NSNull(),
         "lastAutoSwitchAt": accounts.lastAutoSwitchAt.map { JSDate.isoString($0) as Any } ?? NSNull(),
         "notified": controller.notifiedNoTarget, "failures": controller.consecutiveFailures,
         "retryNotBefore": controller.retryNotBefore.map { JSDate.isoString($0) as Any } ?? NSNull(),
         "hold": controller.hold.map { ["account": $0.account, "until": JSDate.isoString($0.until)] as Any } ?? NSNull(),
         "backgroundTools": ["menubar": backgroundTools.menubar, "auto": backgroundTools.auto]]
    }
}
