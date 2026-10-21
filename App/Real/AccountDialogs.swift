import AppKit
import CoddCore
import CoddDialogsUI
import CoddPreferences
import CoddUI

// Dialog A (switch account, D5) and dialog C (add account, D24) on the real stores. Their
// models are built here from the account view models; CoddDialogsUI draws them.

// MARK: - Dialog A

/// The account cards of dialog A (`.sd-acct`): remaining quota, the weekly reset, the source.
@MainActor
enum SwitchDialogData {
    /// `1w 重置 10/18 12:00` (no weekday: the card is narrow).
    static func weeklyReset(_ account: AccountVM, calendar: Calendar) -> String {
        guard account.week.known, let reset = account.week.resetsAt else { return "1w 重置 —" }
        let parts = calendar.dateComponents([.month, .day], from: reset)
        return "1w 重置 \(parts.month ?? 0)/\(parts.day ?? 0) \(ClockFormat.hourMinute(reset, calendar: calendar))"
    }

    static func tone(_ tone: QuotaTone) -> Tone {
        switch tone {
        case .ok: .ok
        case .warn: .warn
        case .crit: .crit
        case .muted: .muted
        }
    }

    /// One card. The FROM card ticks its reset countdown (`· 3d01h後`); chips: `ACTIVE` on the global
    /// login, `n 個 session 固定` when sessions are pinned to the account.
    static func account(_ vm: AccountVM, isFrom: Bool, active: Bool, pinned: Int, calendar: Calendar) -> DialogAccount {
        var chips: [DialogChip] = []
        if active { chips.append(.active) }
        if pinned > 0 { chips.append(.pinned(pinned)) }
        return DialogAccount(slot: vm.slot, alias: vm.alias, plan: vm.plan,
                             fiveHourRemaining: vm.fiveHour.known ? Double(vm.fiveHour.remainingPercent) : nil,
                             fiveHourTone: tone(vm.fiveHour.tone),
                             weeklyRemaining: vm.week.known ? Double(vm.week.remainingPercent) : nil, weeklyTone: tone(vm.week.tone),
                             reset: weeklyReset(vm, calendar: calendar), resetsAt: isFrom ? vm.week.resetsAt : nil,
                             source: vm.source.isEmpty ? "尚無用量" : vm.source, sourceAt: vm.source.isEmpty ? nil : vm.sourceAt,
                             chips: chips)
    }

    /// The whole dialog for a switch from the active account to `target` (nil when either is unknown).
    static func model(target: AccountID, accounts: any AccountStore, pinnedTitles: [String], autoSwitchOn: Bool,
                      calendar: Calendar = .current) -> SwitchAccountModel? {
        guard let to = accounts.account(target), let from = accounts.activeAccount, from.id != to.id else { return nil }
        return SwitchAccountModel(from: account(from, isFrom: true, active: true, pinned: accounts.pinnedCount(for: from.id), calendar: calendar),
                                  to: account(to, isFrom: false, active: false, pinned: accounts.pinnedCount(for: to.id), calendar: calendar),
                                  followingCount: accounts.followingSessionCount, pinnedTitles: pinnedTitles, autoSwitchOn: autoSwitchOn,
                                  cswapVersion: accounts.sourceLabel)
    }
}

/// Dialog A's state machine: shown → `切換` (the switch runs, its attempts drawn as the progress
/// line) → success (closes, the D5 toast with UNDO follows) or failure (the redacted message in
/// the dialog, which stays open for another try or 取消).
@MainActor
final class SwitchDialogFlow {
    let target: AccountID
    let store: any AccountStore
    private(set) var model: SwitchAccountModel
    /// The attempts the progress line showed (tests).
    private(set) var attemptsShown: [Int] = []
    private(set) var view: SwitchAccountDialogView?
    private(set) var sheet: NSWindow?
    private(set) var outcome: AccountSwitchOutcome?
    private var waiters: [CheckedContinuation<AccountSwitchOutcome, Never>] = []
    private var progressLoop: ObservationLoop?
    private var running = false
    /// `同時暫停自動切換` was ticked when 切換 succeeded.
    var onPauseAutoSwitch: (() -> Void)?
    var toast: (@MainActor (String, (@MainActor () -> Void)?) -> Void)?
    var onFinish: (() -> Void)?

    init(target: AccountID, store: any AccountStore, model: SwitchAccountModel) {
        self.target = target
        self.store = store
        self.model = model
    }

    func present(on window: NSWindow) {
        let view = SwitchAccountDialogView(model: model, onConfirm: { [weak self] pause in self?.confirm(pauseAutoSwitch: pause) },
                                           onCancel: { [weak self] in self?.cancel() })
        self.view = view
        sheet = DialogPresenter.presentSheet(view, on: window)
    }

    /// Ends with the switch's outcome (`.refused` when cancelled).
    var result: AccountSwitchOutcome {
        get async {
            if let outcome { return outcome }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// `切換` / ⏎.
    func confirm(pauseAutoSwitch: Bool) {
        guard !running, outcome == nil else { return }
        Task { await self.run(pauseAutoSwitch: pauseAutoSwitch) }
    }

    func run(pauseAutoSwitch: Bool) async {
        guard !running, outcome == nil else { return }
        running = true
        model.error = nil
        model.pauseAutoSwitch = pauseAutoSwitch
        showProgress(attempt: 1, since: Date())
        let store = self.store
        let target = self.target
        progressLoop = ObservationLoop(track: { () -> AccountSwitchState in store.switchState }, apply: { [weak self] state in
            if case .switching(let to, _, let attempt, let since) = state, to == target { self?.showProgress(attempt: attempt, since: since) }
        })
        let result = await store.switchTo(target, reason: .user)
        progressLoop?.cancel()
        progressLoop = nil
        running = false
        model.progress = nil
        switch result {
        case .switched:
            if pauseAutoSwitch { onPauseAutoSwitch?() }
            finish(result)
            if let toast { AccountSwitching.report(result, in: store, reason: .user, toast: toast) }
        case .failed(let message), .refused(let message):
            model.error = message
            view?.update(model)
        case .alreadyActive:
            finish(result)
        }
    }

    private func showProgress(attempt: Int, since: Date) {
        guard model.progress?.attempt != attempt || model.progress == nil else { return }
        attemptsShown.append(attempt)
        model.progress = SwitchProgress(attempt: attempt, of: 3, since: since)
        view?.update(model)
    }

    /// 取消 / ⎋ / ✕ (ignored while the switch runs: cswap cannot be interrupted safely).
    func cancel() {
        guard !running else { return }
        finish(outcome ?? .refused("已取消"))
    }

    private func finish(_ result: AccountSwitchOutcome) {
        guard outcome == nil else { return }
        outcome = result
        if let sheet { DialogPresenter.dismiss(sheet) }
        sheet = nil
        for waiter in waiters { waiter.resume(returning: result) }
        waiters = []
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}

/// `AccountSwitching.confirmation`: every user switch shows dialog A while 切換前確認 is ON.
@MainActor
final class SwitchDialogController: AccountSwitchConfirming {
    private let preferences: PreferencesService
    private let window: @MainActor () -> NSWindow?
    /// Titles of the live sessions pinned to an account (`固定帳號的 session（…）不受影響`).
    var pinnedTitles: @MainActor () -> [String] = { [] }
    /// Before the sheet: the main window shown (a switch from the menu bar with the window closed).
    var beforePresenting: @MainActor () -> Void = {}
    private(set) var current: SwitchDialogFlow?

    init(preferences: PreferencesService, window: @escaping @MainActor () -> NSWindow?) {
        self.preferences = preferences
        self.window = window
    }

    func wantsConfirmation(for id: AccountID, in store: any AccountStore) -> Bool {
        preferences.preferences.accounts.confirmBeforeSwitch && window() != nil && id != store.activeAccountID
            && store.account(id) != nil && store.activeAccount != nil
    }

    func confirmSwitch(_ id: AccountID, in store: any AccountStore,
                       toast: @escaping @MainActor (String, (@MainActor () -> Void)?) -> Void) -> Task<AccountSwitchOutcome, Never> {
        guard current == nil else { return Task { .refused("切換確認已經開著") } }
        guard let flow = makeFlow(id, in: store), let window = window() else {
            return Task { @MainActor in await store.switchTo(id, reason: .user) }
        }
        flow.toast = toast
        current = flow
        flow.onFinish = { [weak self] in self?.current = nil }
        beforePresenting()
        flow.present(on: window)
        return Task { @MainActor in await flow.result }
    }

    /// The flow with its model (DEBUG `-codd-show dialog-switch`, tests).
    func makeFlow(_ id: AccountID, in store: any AccountStore) -> SwitchDialogFlow? {
        guard let model = SwitchDialogData.model(target: id, accounts: store, pinnedTitles: pinnedTitles(),
                                                 autoSwitchOn: preferences.preferences.accounts.autoSwitch.enabled) else { return nil }
        let flow = SwitchDialogFlow(target: id, store: store, model: model)
        let preferences = self.preferences
        flow.onPauseAutoSwitch = { preferences.update { $0.accounts.autoSwitch.enabled = false } }
        return flow
    }

    /// DEBUG `-codd-show dialog-switch`: the dialog for `id` without a switch behind it.
    func show(_ id: AccountID, in store: any AccountStore) {
        guard current == nil, let flow = makeFlow(id, in: store), let window = window() else { return }
        current = flow
        flow.onFinish = { [weak self] in self?.current = nil }
        flow.present(on: window)
    }
}

// MARK: - Dialog C

/// Dialog C · 加入帳號 (D24, D33, D34): 1 an ephemeral shell runs `claude /login` (the login is
/// watched every second until its identity changes), 2 the current login is captured (never shown:
/// `新帳號` or the account it already is), 3 alias + slot → `cswap add`, then `cswap switch` back to
/// the account that was active, a toast, and the ephemeral shell is discarded. Cancelling after
/// the login changed switches back too.
@MainActor
final class AddAccountFlow {
    struct Environment {
        var accounts: CswapAccountStore
        var holders: HolderSessionStore
        /// `'<claude>' /login\r`, nil when this run must not start a claude (a test data root
        /// without DEBUG `-codd-claude-path`): the shell opens and the user types it.
        var loginTyping: String?
        /// `'<cswap>' add-token\r`, nil without a cswap path.
        var addTokenTyping: String?
        var home: String = NSHomeDirectory()
        var showSession: @MainActor (SessionID) -> Void = { _ in }
        var toast: @MainActor (String) -> Void = { _ in }
        var now: @MainActor () -> Date = { Date() }
        /// How often the login is checked while the panel is open (D24: 1 s).
        var watchInterval: Duration = .seconds(1)
        var log: @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }
    }

    let env: Environment
    private(set) var model: AddAccountModel
    private(set) var view: AddAccountDialogView?
    private(set) var panel: NSPanel?
    /// The login when the panel opened (cancel switches back only when it changed).
    private(set) var openedLogin: CurrentLogin?
    private(set) var previousActive: AccountID?
    private(set) var loginShell: SessionID?
    private(set) var tokenShell: SessionID?
    private(set) var finished = false
    /// How the flow ended (`added`, `cancelled`, `failed`), for the debug log and tests.
    private(set) var ending: String?
    private var watchTask: Task<Void, Never>?
    var onFinish: (() -> Void)?

    init(env: Environment) {
        self.env = env
        let accounts = env.accounts
        previousActive = accounts.activeAccountID
        let slots = accounts.nextFreeSlots()
        model = AddAccountModel(slots: slots, slot: slots.first ?? 1,
                                previousActive: accounts.activeAccount?.displayName ?? "目前的帳號", cswapVersion: accounts.sourceLabel)
    }

    /// Reads the login it starts from and begins watching it.
    func start() async {
        openedLogin = await env.accounts.currentLogin()
        startWatching()
    }

    /// Shows the panel at the main window's right edge (D24).
    func present(over window: NSWindow) {
        let view = AddAccountDialogView(model: model, onOpenLoginTerminal: { [weak self] in self?.openLoginTerminal() },
                                        onCapture: { [weak self] in Task { await self?.capture() } },
                                        onAdd: { [weak self] alias, slot in Task { await self?.add(alias: alias, slot: slot) } },
                                        onAddToken: { [weak self] in self?.openAddToken() },
                                        onCancel: { [weak self] in Task { await self?.cancel() } })
        view.onAliasChange = { [weak self] text in self?.model.alias = text }
        view.onSlotChange = { [weak self] slot in self?.model.slot = slot }
        self.view = view
        panel = DialogPresenter.presentPanel(view, over: window)
    }

    private func render() { view?.update(model) }

    private func startWatching() {
        watchTask?.cancel()
        let interval = env.watchInterval
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !self.finished else { return }
                await self.checkLogin()
            }
        }
    }

    /// Step 1 is done once the login's identity differs from the one the panel opened with.
    func checkLogin() async {
        guard model.step1Done == nil, let login = await env.accounts.currentLogin() else { return }
        guard login.loggedIn, login.token != openedLogin?.token else { return }
        model.step1Done = env.now()
        env.log("add-account login changed (step 1 done)")
        render()
    }

    /// Step 1 `[開啟登入終端機]`: an ephemeral shell `加入帳號` in `~`, shown, typing the login command.
    func openLoginTerminal() {
        if let loginShell, env.holders.session(loginShell) != nil {
            env.showSession(loginShell)
            return
        }
        guard let id = env.holders.createEphemeralShell(title: "加入帳號", cwd: env.home, typing: env.loginTyping) else {
            model.error = env.holders.lastRefusal ?? "無法開啟終端機"
            render()
            return
        }
        if env.loginTyping == nil { env.log("add-account login shell opened without typing (no claude path on this data root)") }
        loginShell = id
        env.showSession(id)
    }

    /// `改用 setup-token / API key（cswap add-token）→`: another ephemeral shell, kept until it exits.
    func openAddToken() {
        guard let id = env.holders.createEphemeralShell(title: "cswap add-token", cwd: env.home, typing: env.addTokenTyping,
                                                        discardOnExit: true) else {
            model.error = env.holders.lastRefusal ?? "無法開啟終端機"
            render()
            return
        }
        tokenShell = id
        env.showSession(id)
    }

    /// Step 2 `[擷取目前登入]`: which account the login is (or new), never the e-mail.
    func capture() async {
        guard let login = await env.accounts.currentLogin(), login.loggedIn else {
            model.error = "目前沒有登入：先完成步驟 1 的 claude /login"
            render()
            return
        }
        model.error = nil
        if let number = login.existingAccount {
            let name = env.accounts.account(String(number))?.displayName ?? "#\(number)"
            model.detected = DetectedLogin(isNew: false, text: name, plan: login.plan)
            model.slots = [number]
            model.slot = number
            if model.alias.isEmpty, let alias = env.accounts.account(String(number))?.alias, CswapAlias.normalize(alias) != nil {
                model.alias = alias
            }
        } else {
            model.detected = .newAccount(plan: login.plan)
            let slots = env.accounts.nextFreeSlots()
            if !slots.isEmpty { model.slots = slots }
            if !model.slots.contains(model.slot) { model.slot = model.slots.first ?? model.slot }
        }
        if model.step1Done == nil, login.token != openedLogin?.token { model.step1Done = env.now() }
        render()
    }

    /// `[加入 #n]`: cswap's alias rule first (an invalid alias never reaches cswap, D34), then
    /// `cswap add`, the switch back, the toast, the ephemeral shell discarded.
    func add(alias rawAlias: String, slot: Int) async {
        guard !model.busy, !finished else { return }
        guard let alias = CswapAlias.normalize(rawAlias) else {
            model.error = CswapAlias.hint
            render()
            env.log("add-account refused: the alias does not pass cswap's rule")
            return
        }
        model.alias = alias
        model.slot = slot
        model.busy = true
        model.error = nil
        render()
        if let failure = await env.accounts.addCurrentLogin(slot: slot, alias: alias) {
            model.busy = false
            model.error = "cswap add 失敗：\(failure)"
            render()
            return
        }
        let added = "#\(slot) \(alias)"
        var text = "已加入 \(added)"
        if let back = await switchBack() { text += " · " + back }
        model.busy = false
        ending = "added"
        env.toast(text)
        close()
    }

    /// ✕ / ⎋ / 取消: back to the previous account when the login changed since the panel opened.
    func cancel() async {
        guard !finished, !model.busy else { return }
        var text: String?
        if let login = await env.accounts.currentLogin(), login.token != openedLogin?.token, let back = await switchBack() {
            text = "已取消加入 · " + back
        }
        ending = "cancelled"
        if let text { env.toast(text) }
        close()
    }

    /// `cswap switch <previous active>` (reason undo, no toast of its own): `已切回 #3 工作`, or why not.
    private func switchBack() async -> String? {
        guard let previous = previousActive else { return nil }
        let name = env.accounts.account(previous)?.displayName ?? "#\(previous)"
        // The login changed behind cswap's state files (`.claude.json` is not watched): read the
        // state first, so the switch is not skipped as "already active".
        await env.accounts.read(force: true)
        switch await env.accounts.switchTo(previous, reason: .undo) {
        case .switched, .alreadyActive:
            return "已切回 \(name)"
        case .failed(let message), .refused(let message):
            env.log("add-account switch back failed")
            return "切回 \(name) 失敗：\(message)"
        }
    }

    /// Ends the flow: the login shell is discarded (its terminal showed the e-mail), the panel goes.
    func close() {
        guard !finished else { return }
        finished = true
        watchTask?.cancel()
        watchTask = nil
        if let loginShell { env.holders.discardEphemeral(loginShell) }
        loginShell = nil
        if let panel { DialogPresenter.dismiss(panel) }
        panel = nil
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}
