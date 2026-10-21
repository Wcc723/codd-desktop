import AppKit
import CoddClaudeSettings
import CoddCore
import CoddHost
import CoddStatusUI
import CoddUI

/// The rail's STATUS area (D16, D26, D32): CoddStatusUI's 220 px sidebar (in the split's sidebar
/// column) and page (in the pane), fed by `StatusPageData` from the stores.
///
/// While shown and not paused it refreshes every 5 s: a HOST sample off the main actor (CoddHost,
/// 10-minute history for the sparklines), the hook endpoint's counters, the Claude settings
/// inspection (re-parsed only when the file changed); the main-thread latency probe runs too.
/// Discrete changes (session states, the active account, a switch, the rule, the inspection)
/// rebuild the model in between (`LiveKey`); numbers that move every second (status-line ages,
/// quota) wait for the 5 s refresh, so a status line reporting every second does not relayout
/// the page every second. The views redraw only what changed. Hidden or paused, nothing is sampled.
@MainActor
final class StatusController {
    struct Sources {
        var store: any SessionStore
        var accounts: any AccountStore
        var cswap: CswapAccountStore?
        var hooks: HookPipeline?
        var installer: ClaudeSettingsService?
        var preferences: PreferencesService
        /// `<dataRoot>/hooks` (abbreviated) and whether that is not the standard data root's.
        var statusDir: String
        var statusDirDiffers: Bool
        /// Mock mode: the SPEC §5 host sample and settings inspection instead of real ones.
        var mock = false
        /// M4 I2a: the MCP SERVER card (real mode; mock mode draws the SPEC sample).
        var mcp: MCPService?
        /// `<dataRoot>/notes`, abbreviated (the card's `CODD MCP · <path>`).
        var notesPath = ""
        /// M4 I2b: the registration buttons' states and `[輪替]`.
        var registration: MCPRegistrationService?
    }

    /// What the page's buttons do (set by the app).
    struct Actions {
        var openSession: @MainActor (SessionID) -> Void = { _ in }
        var openSessions: @MainActor () -> Void = {}
        var switchAccount: @MainActor (AccountID) -> Void = { _ in }
        var addAccount: @MainActor () -> Void = {}
        var openSettings: @MainActor (String) -> Void = { _ in }
        var installer: @MainActor (InstallerAction) -> Void = { _ in }
        /// M4 I2b: a REGISTRATIONS row's button (`claude-code`, `codex`) and `[輪替]` (D22, D23).
        var mcpRegistration: @MainActor (String) -> Void = { _ in }
        var rotateMCPToken: @MainActor () -> Void = {}
    }

    let sources: Sources
    /// Auto-switch (real mode, set once the accounts are read): the cswap background-tool warning.
    weak var autoSwitch: AutoSwitchRunner? { didSet { autoSwitch?.scanDemand = isActive } }
    let sidebarView: StatusSidebarView
    let pageView: StatusPageView
    var actions = Actions()
    private(set) var isActive = false
    private(set) var paused = false
    private(set) var updatedAt: Date
    /// HOST samples taken since launch (the dump's `hostSampled`).
    private(set) var hostSamples = 0
    private(set) var lastSample: HostSample?
    private(set) var history = HostHistory()
    private(set) var model: StatusPageModel?
    private(set) var visibleSection: StatusSection = .host
    /// Sample cost (ms) of the last HOST sample, for the step report and the dump.
    private(set) var lastSampleMilliseconds: Double?
    private lazy var sampler = HostSampler()
    let probe = MainThreadLatencyProbe()
    private var refreshTask: Task<Void, Never>?
    private var switchTicker: Task<Void, Never>?
    private var loop: ObservationLoop?
    var calendar: Calendar = .current

    static let refreshInterval: Duration = .seconds(5)

    init(sources: Sources) {
        self.sources = sources
        updatedAt = sources.store.clock.now()
        sidebarView = StatusSidebarView(actions: StatusPageActions())
        pageView = StatusPageView(actions: StatusPageActions())
        let actions = pageActions()
        sidebarView.setActions(actions)
        pageView.setActions(actions)
        sidebarView.onSelectSection = { [weak self] section in
            self?.pageView.scroll(to: section)
            self?.sidebarView.selectedSection = section
        }
        pageView.onVisibleSectionChange = { [weak self] section in
            self?.visibleSection = section
            self?.sidebarView.selectedSection = section
        }
        if sources.mock {
            lastSample = MockData.hostSample()
            history = MockData.hostHistory()
        }
    }

    private func pageActions() -> StatusPageActions {
        StatusPageActions(
            refresh: { [weak self] in self?.refreshNow(userInitiated: true) },
            togglePause: { [weak self] in self?.togglePause() },
            openSessions: { [weak self] in self?.actions.openSessions() },
            openSession: { [weak self] id in self?.actions.openSession(id) },
            switchAccount: { [weak self] id in self?.actions.switchAccount(id) },
            addAccount: { [weak self] in self?.actions.addAccount() },
            openAutoSwitch: { [weak self] in self?.actions.openSettings("accounts") },
            toggleAutoSwitch: { [weak self] in
                self?.sources.preferences.update { $0.accounts.autoSwitch.enabled.toggle() }
            },
            previewHooks: { [weak self] in self?.actions.installer(.update) },
            update: { [weak self] in self?.actions.installer(.update) },
            uninstall: { [weak self] in self?.actions.installer(.uninstall) },
            removeLegacy: { [weak self] in self?.actions.installer(.removeLegacy) },
            disableDuplicateNotifications: { [weak self] in self?.actions.installer(.disableDuplicateNotifications) },
            openRemoteSettings: { [weak self] in self?.actions.openSettings("remote") },
            onMCPRegistration: { [weak self] id in self?.actions.mcpRegistration(id) },
            onRotateMCPToken: { [weak self] in self?.actions.rotateMCPToken() },
            // The switch's value, not a toggle: it may have moved in Settings › 帳號 while the
            // ON confirmation was up.
            setAutoSwitch: { [weak self] on in
                self?.sources.preferences.update { $0.accounts.autoSwitch.enabled = on }
            })
    }

    // MARK: Lifecycle

    /// The rail is on STATUS and the window is visible (true), or not.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        autoSwitch?.scanDemand = active
        if active {
            let start = ContinuousClock.now
            rebuild()
            pageView.layoutSubtreeIfNeeded()
            sidebarView.layoutSubtreeIfNeeded()
            HolderSessionStore.printLog(String(format: "STATUS shown ms=%.2f", TerminalHub.milliseconds(ContinuousClock.now - start)))
            startObserving()
            if !paused { startRefreshing() }
        } else {
            stopObserving()
            stopRefreshing()
        }
    }

    /// `↻` / `[↻ 立即更新]` (D32): re-reads cswap's state (the D1 fallback may run, this is the user
    /// asking), the hook counters, the settings and a HOST sample.
    func refreshNow(userInitiated: Bool) {
        Task { [weak self] in
            guard let self else { return }
            if userInitiated { await self.sources.accounts.refresh(userInitiated: true) }
            await self.refreshOnce()
        }
    }

    /// `[暫停]` / `[繼續]`: sampling and refreshing stop; the page keeps what it shows.
    func togglePause() {
        paused.toggle()
        if paused {
            stopObserving()
            stopRefreshing()
        } else if isActive {
            startObserving()
            startRefreshing()
        }
        rebuild()
    }

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        if !sources.mock { probe.start() }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        switchTicker?.cancel()
        switchTicker = nil
        probe.stop()
    }

    private func startObserving() {
        guard loop == nil else { return }
        lastKey = nil
        loop = ObservationLoop(track: { [weak self] () -> LiveKey? in self?.liveKey() }, apply: { [weak self] key in
            guard let self, key != self.lastKey else { return }
            let first = self.lastKey == nil
            self.lastKey = key
            if !first { self.rebuild() }
        })
    }

    /// What rebuilds the page right away (read inside observation tracking; cheap).
    struct LiveKey: Equatable {
        var sessions: [String]
        var active: AccountID?
        var accounts: [AccountID]
        var switching: AccountSwitchState
        var availability: AccountAvailability
        var rule: String
        var inspection: ClaudeSettingsService.InspectionState
        var listening: Bool
        var warning: String?
        /// M4: the MCP server's run state, clients and Claude Code registration.
        var mcp: String
    }

    private var lastKey: LiveKey?

    private func liveKey() -> LiveKey {
        let sessions = sources.store.allSessions.map { session in
            "\(session.id) \(session.state.rawValue) \(session.waitingReason?.rawValue ?? "-") \(session.errorReason ?? "-") "
                + "\(session.title) \(session.tag?.rawValue ?? "-") \(session.remoteControl) \(session.accountPinned) "
                + "\(session.accountID ?? "-") \(session.unreachableSince != nil)"
        }.sorted()
        let rule = sources.preferences.preferences.accounts.autoSwitch
        return LiveKey(sessions: sessions, active: sources.accounts.activeAccountID, accounts: sources.accounts.accounts.map(\.id),
                       switching: sources.accounts.switchState, availability: sources.accounts.availability,
                       rule: "\(rule.enabled) \(rule.thresholdPercent) \(rule.checkFiveHour) \(rule.checkWeekly) \(rule.cooldownSeconds)",
                       inspection: sources.installer?.inspection ?? .unknown, listening: isLive, warning: autoSwitch?.backgroundWarning,
                       mcp: (sources.mcp.map { mcp in
                           "\(mcp.running) \(mcp.endpoint) \(mcp.clients.map { "\($0.key) \($0.title)" }) \(MCPService.registrationName(mcp.claudeCode))"
                       } ?? "-")
                           + (sources.registration.map { " \($0.isApplying) \($0.isRotating) \($0.tokenRotatedAt?.timeIntervalSince1970 ?? 0)" } ?? ""))
    }

    private func stopObserving() {
        loop?.cancel()
        loop = nil
    }

    /// One refresh: HOST sample (off the main actor), hook counters, settings inspection.
    func refreshOnce() async {
        if !sources.mock {
            let sampler = self.sampler
            let started = ContinuousClock.now
            let sample = await Task.detached(priority: .utility) { sampler.sample() }.value
            lastSampleMilliseconds = TerminalHub.milliseconds(ContinuousClock.now - started)
            lastSample = sample
            history.append(sample)
            hostSamples += 1
            await sources.hooks?.refreshStatistics()
            await sources.installer?.refreshInspection()
            await sources.mcp?.refreshRegistrations()
        }
        updatedAt = sources.store.clock.now()
        rebuild()
    }

    /// Rebuilds the model now (outside observation) and shows it.
    func rebuild() {
        guard let model = buildModel() else { return }
        show(model)
    }

    private func show(_ model: StatusPageModel) {
        self.model = model
        sidebarView.apply(model)
        pageView.apply(model)
        updateSwitchTicker()
    }

    /// While a switch runs its progress line counts seconds: rebuild every second.
    private func updateSwitchTicker() {
        guard isActive, sources.accounts.isSwitching else {
            switchTicker?.cancel()
            switchTicker = nil
            return
        }
        guard switchTicker == nil else { return }
        switchTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.switchTicker = nil
                self.rebuild()
                return
            }
        }
    }

    // MARK: Model

    func buildModel() -> StatusPageModel? {
        let store = sources.store
        let now = store.clock.now()
        var inputs = StatusPageInputs(now: now, calendar: calendar, updatedAt: updatedAt, paused: paused, live: isLive,
                                      host: hostFacts(), accounts: accountFacts(), hooks: hookFacts())
        inputs.mcp = mcpModel(now: now)
        return StatusPageData.model(store: store, accounts: sources.accounts, inputs: inputs)
    }

    /// MCP SERVER (D21): the SPEC sample in mock mode; real mode's service otherwise.
    private func mcpModel(now: Date) -> StatusMCPModel? {
        if sources.mock { return StatusSamples.mcp }
        guard let mcp = sources.mcp else { return nil }
        return StatusPageData.mcpModel(mcp, notesPath: sources.notesPath, now: now, registration: sources.registration)
    }

    private var isLive: Bool {
        guard let hooks = sources.hooks else { return sources.mock }
        if case .listening = hooks.status { return true }
        return false
    }

    private func hostFacts() -> StatusHostFacts {
        if sources.mock {
            return StatusHostFacts(sample: lastSample, history: history, p99Milliseconds: 3,
                                   footprint: (physFootprint: 412 << 20, resident: 412 << 20))
        }
        return StatusHostFacts(sample: lastSample, history: history, p99Milliseconds: probe.p99Milliseconds,
                               footprint: HostSampler.footprint())
    }

    private func accountFacts() -> StatusAccountFacts {
        let rule = sources.preferences.preferences.accounts.autoSwitch
        var facts = StatusAccountFacts(autoSwitchOn: rule.enabled, thresholdPercent: rule.thresholdPercent, checkFiveHour: rule.checkFiveHour,
                                       checkWeekly: rule.checkWeekly, cooldownSeconds: rule.cooldownSeconds)
        facts.backgroundWarning = autoSwitch?.backgroundWarning
        if let cswap = sources.cswap {
            facts.base = cswap.baseAvailability
            facts.rootPath = cswap.rootDisplayPath
            for account in cswap.accounts { if let n = account.number { facts.profileShares[n] = cswap.profileSharesSettings(n) } }
        } else {
            // Mock mode: the SPEC §5 accounts, #2's profile linked.
            facts.base = sources.accounts.availability
            facts.rootPath = "~/.claude-swap-backup"
            facts.profileShares = [2: true]
        }
        return facts
    }

    private func hookFacts() -> StatusHooksFacts {
        let store = sources.store
        if sources.mock {
            let now = store.clock.now()
            return StatusHooksFacts(inspection: .loaded(MockData.settingsInspection, exists: true),
                                    statusDir: "~/Github/codd-web/agent-sandbox/.claude/codd-status",
                                    statusDirDiffers: true, lastHookAt: now.addingTimeInterval(-8), lastStatusLineAt: now.addingTimeInterval(-8))
        }
        let hooks = sources.hooks
        var listening = false
        if case .listening = hooks?.status { listening = true }
        let settingsPath = sources.installer.map { $0.displayPath } ?? "~/.claude/settings.json"
        return StatusHooksFacts(claudeDir: (settingsPath as NSString).deletingLastPathComponent,
                                fileName: (settingsPath as NSString).lastPathComponent,
                                inspection: sources.installer?.inspection ?? .unknown, injected: listening, statusDir: sources.statusDir,
                                statusDirDiffers: sources.statusDirDiffers, lastHookAt: hooks?.lastEventAt,
                                lastStatusLineAt: sources.cswap?.statusLine.lastAt ?? hooks?.statistics?.lastStatusLineAt,
                                details: EndpointDiagnostics.lines(hooks: hooks, statusLine: sources.cswap?.statusLine, now: store.clock.now()))
    }

    // MARK: Dump

    /// `status {shown, paused, section, updatedAt, hostSampled, sampleMs, p99}`.
    var dumpObject: [String: Any] {
        ["shown": isActive, "paused": paused, "section": visibleSection.rawValue, "updatedAt": JSDate.isoString(updatedAt),
         "hostSampled": hostSamples, "sampleMs": lastSampleMilliseconds.map { $0 as Any } ?? NSNull(),
         "p99": probe.p99Milliseconds.map { $0 as Any } ?? NSNull(),
         "accountsCards": model?.accounts.cards.map(\.id) ?? [], "unavailable": model?.accounts.unavailable as Any? ?? NSNull(),
         "hooksPending": model?.hooks.pendingUpdates ?? 0]
    }
}

/// The M1 STATUS rows, kept under `▸ 詳細` in the HOOKS card (the endpoint's state, accepted /
/// rejected counts by status, the last rejection, refused connections, status-line reports), so a
/// hook Claude sends and the endpoint refuses stays diagnosable.
@MainActor
enum EndpointDiagnostics {
    static func lines(hooks: HookPipeline?, statusLine: StatusLineStats?, now: Date) -> [String] {
        guard let hooks else { return ["STATE ○ 未啟用（沒有 hook pipeline）"] }
        var lines: [String] = []
        switch hooks.status {
        case .listening(let port): lines.append("STATE ● LISTENING · http://127.0.0.1:\(port)/hooks")
        case .portInUse(let port, let otherCODD):
            lines.append("STATE ▲ DEGRADED · 埠 \(port) \(otherCODD ? "另一個 CODD 正在使用" : "被其他程式佔用") · 新的 session 不帶 hook · 每隔幾秒重試")
        case .failed(let reason): lines.append("STATE ▲ DEGRADED · 無法啟動：\(reason) · 每隔幾秒重試")
        case .starting: lines.append("STATE ◌ 啟動中")
        }
        if let stats = hooks.statistics {
            let rejected = stats.rejected.values.reduce(0, +)
            let detail = stats.rejected.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")
            lines.append("ACCEPTED \(stats.accepted) 個 hook 事件 · \(stats.statusLinesAccepted) 個 statusline 回報")
            lines.append("REJECTED " + (rejected == 0 ? "0" : "\(rejected) · \(detail)"))
            if stats.refusedConnections > 0 { lines.append("REFUSED \(stats.refusedConnections) 個連線（超過上限）") }
            lines.append("LAST REJECTION \(stats.lastRejection ?? "—")")
        }
        let last = hooks.lastEventAt.map { DurationFormat.ago($0, now: now) } ?? "還沒有"
        lines.append("EVENTS \(hooks.eventCount) 個 · 最近 \(last)")
        if let statusLine {
            let at = statusLine.lastAt.map { DurationFormat.ago($0, now: now) } ?? "還沒有"
            let key = statusLine.lastKey.map { " · key \($0)" } ?? ""
            lines.append("STATUSLINE \(statusLine.accepted) 個回報 · 最近 \(at)\(key) · \(statusLine.dropped) 個沒有記入用量")
        }
        lines.append("CONFIG \(HolderSessionStore.abbreviate(hooks.dataRoot.appendingPathComponent("config.json").path)) · token ••••")
        lines.append("REGISTRY \(HolderSessionStore.abbreviate(hooks.registryPath))")
        return lines
    }
}
