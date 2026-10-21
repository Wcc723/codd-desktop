import AppKit
import CoddClaudeSettings
import CoddHost
import CoddStatusUI
import CoddUI

/// Everything the STATUS page shows beyond the session and account stores (D16, D26, D27, D32),
/// gathered by `StatusController` each refresh.
struct StatusPageInputs {
    var now: Date
    var calendar: Calendar = .current
    var updatedAt: Date
    var paused = false
    /// The hook endpoint listens (`● LIVE`; `○ OFFLINE` otherwise).
    var live = true
    var refreshSeconds = 5
    var host: StatusHostFacts
    var accounts: StatusAccountFacts
    var hooks: StatusHooksFacts
    /// M4 I2a: the MCP SERVER card (nil keeps M3's placeholder card and nav value).
    var mcp: StatusMCPModel?
}

/// HOST (D26): the latest CoddHost sample, its 10-minute history, the main-thread latency p99 and
/// CODD's own memory.
struct StatusHostFacts {
    var sample: HostSample?
    var history = HostHistory()
    var p99Milliseconds: Double?
    var footprint: (physFootprint: UInt64, resident: UInt64)?
}

/// ACCOUNTS facts the `AccountStore` protocol does not carry.
struct StatusAccountFacts: Equatable {
    /// cswap's own availability (before the D4 pseudo account), for the unavailable line.
    var base: AccountAvailability = .loading
    /// `~/.claude-swap-backup`.
    var rootPath: String?
    /// A pinned session's cswap profile shares `~/.claude/settings.json` (nil: unknown), per account.
    var profileShares: [Int: Bool?] = [:]
    /// D13: `! cswap menubar 也在執行，兩邊可能同時切換`.
    var backgroundWarning: String?
    /// Settings › 帳號 › 自動切換.
    var autoSwitchOn = false
    var thresholdPercent = 2
    var checkFiveHour = true
    var checkWeekly = true
    var cooldownSeconds = 300
}

/// HOOKS & STATUSLINE facts: the settings inspection (D10) and the endpoint (D9).
struct StatusHooksFacts: Equatable {
    var claudeDir = "~/.claude"
    var fileName = "settings.json"
    var inspection: ClaudeSettingsService.InspectionState = .unknown
    /// New CODD sessions get the 14 hook events (the endpoint is this app's).
    var injected = true
    var statusDir: String
    var statusDirDiffers: Bool
    var lastHookAt: Date?
    var lastStatusLineAt: Date?
    /// `▸ 詳細`: the endpoint diagnostics.
    var details: [String] = []
}

/// Maps the stores and the facts above into CoddStatusUI's `StatusPageModel` (Status artboard).
/// Pure apart from reading the main-actor view models: mock mode maps the SPEC §5 sample through
/// the same code.
@MainActor
enum StatusPageData {
    static func model(store: any SessionStore, accounts: any AccountStore, inputs: StatusPageInputs) -> StatusPageModel {
        let host = hostSection(inputs.host, store: store, now: inputs.now, calendar: inputs.calendar)
        let accountsSection = accountsSection(accounts, store: store, facts: inputs.accounts, now: inputs.now, calendar: inputs.calendar)
        let hooks = hooksCard(inputs.hooks, store: store, accounts: accounts, facts: inputs.accounts)
        let sessions = store.allSessions
        let remote = sessions.filter { $0.remoteControl && $0.state.isLive }.sorted { $0.title < $1.title }
        let remoteModel = RemoteModel(count: remote.count, titles: remote.map(\.title))
        return StatusPageModel(updatedAt: inputs.updatedAt, refreshSeconds: inputs.refreshSeconds, paused: inputs.paused, live: inputs.live,
                               nav: nav(host: host, sample: inputs.host.sample, accounts: accounts, section: accountsSection, hooks: hooks,
                                        remote: remoteModel, mcp: inputs.mcp),
                               needsYou: needsYou(store), counts: counts(sessions), liveCount: SessionCounts(sessions: sessions).live,
                               host: host, accounts: accountsSection, hooks: hooks, remote: remoteModel, mcp: inputs.mcp)
    }

    // MARK: MCP SERVER (M4 I2a, D21)

    /// The card from the service: run state, `127.0.0.1:<port>`, the clients with `連線 42m`, the
    /// registrations (D22, I2b: their buttons with why one is disabled), the masked token with
    /// `[輪替]` (D23), `<dataRoot>/notes`.
    static func mcpModel(_ mcp: MCPService, notesPath: String, now: Date, registration: MCPRegistrationService? = nil) -> StatusMCPModel {
        let clients = mcp.clients.map { client in
            StatusMCPClient(id: client.key, title: client.title, kind: client.clientKind,
                            connectedFor: "連線 " + DurationFormat.compact(now.timeIntervalSince(client.since)))
        }
        let running = mcp.running
        return StatusMCPModel(running: running, endpoint: mcp.endpoint == "—" ? "" : mcp.endpoint, clientsCount: clients.count,
                              clients: clients,
                              registrations: MCPRegistrationRows.status(mcp.claudeCode,
                                                                        claudeCodeReason: registration?.claudeCodeReason ?? SettingsInfoBuilder.noServer,
                                                                        codexReason: registration?.codexReason ?? SettingsInfoBuilder.noServer,
                                                                        exposed: mcp.claudeCodeExposed),
                              tokenMasked: "••••", notesPath: notesPath, note: running ? nil : mcpStoppedNote,
                              canRotateToken: registration?.canRotate ?? false)
    }

    /// Under `○ STOPPED`: the MCP server shares the hook server's port (D16).
    static let mcpStoppedNote = "// hook server 未執行，MCP 暫停"

    // MARK: Sidebar

    static func nav(host: HostSectionModel, sample: HostSample?, accounts: any AccountStore, section: AccountsSectionModel,
                    hooks: HooksCardModel, remote: RemoteModel, mcp: StatusMCPModel? = nil) -> [StatusNavItem] {
        let cpu = sample?.cpu.map { "cpu \(Int($0.total.rounded()))%" } ?? "cpu —"
        var items = [StatusNavItem(id: .host, glyph: host.healthy ? .ok : .attention, value: cpu)]
        // ACCOUNTS: the lowest weekly remaining (R7 cares about the week), toned like its bar.
        if section.unavailable != nil {
            items.append(StatusNavItem(id: .accounts, glyph: .off, value: "—"))
        } else if let worst = accounts.accounts.filter({ !$0.isPseudo && $0.week.known }).min(by: { $0.week.remainingPercent < $1.week.remainingPercent }) {
            let tone = worst.week.tone
            let glyph: StatusGlyph = tone == .crit ? .bad : (tone == .warn ? .attention : .ok)
            let color: NSColor? = tone == .crit ? Palette.danger : (tone == .warn ? Palette.amber : nil)
            items.append(StatusNavItem(id: .accounts, glyph: glyph, value: "1w \(worst.week.remainingPercent)%", valueColor: color))
        } else {
            items.append(StatusNavItem(id: .accounts, glyph: .off, value: "1w —"))
        }
        if hooks.problem != nil {
            items.append(StatusNavItem(id: .hooks, glyph: .bad, value: "讀不到", valueColor: Palette.danger))
        } else if hooks.pendingUpdates > 0 {
            items.append(StatusNavItem(id: .hooks, glyph: .attention, value: "需更新", valueColor: Palette.amber))
        } else {
            items.append(StatusNavItem(id: .hooks, glyph: hooks.hooksInjected >= hooks.hooksTotal ? .ok : .attention,
                                       value: "\(hooks.hooksInjected) / \(hooks.hooksTotal)"))
        }
        items.append(mcp.map { StatusNavItem.mcp($0) } ?? StatusNavItem(id: .mcp, glyph: .off, value: "M4"))
        items.append(StatusNavItem(id: .remote, glyph: remote.count > 0 ? .remote : .off, value: "\(remote.count) rc"))
        return items
    }

    /// NEEDS YOU in the sidebar's tree order: `修正登入 API 401 · PERM`, line 2 `3m · orb-toolkit-backend`.
    static func needsYou(_ store: any SessionStore) -> [StatusSessionRow] {
        SidebarSnapshotBuilder.needsYou(store: store, filter: "").map { session in
            let style = StateStyle.of(session)
            let project = store.project(session.projectID)?.name ?? ""
            let error = session.state == .error
            let detail = error ? [session.errorReason?.lowercased(), project].compactMap { $0 }.joined(separator: " · ") : project
            return StatusSessionRow(id: session.id, glyph: StatusGlyph(style.glyph, style.color), tag: session.tag?.color,
                                    title: session.title, pill: error ? "Error" : (session.waitingReason?.shortPill ?? "Wait"),
                                    since: session.stateSince, detail: detail, attention: error ? .error : .waiting)
        }
    }

    /// SESSIONS counts (artboard order). STARTING / RUNNING count as BUSY, STOPPED as EXITED: the
    /// sidebar has eight rows.
    static func counts(_ sessions: [SessionVM]) -> [StatusCount] {
        var tally: [SessionState: Int] = [:]
        for session in sessions {
            let state: SessionState
            switch session.state {
            case .starting, .unknown: state = .busy
            case .stopped: state = .exited
            default: state = session.state
            }
            tally[state, default: 0] += 1
        }
        let rows: [(SessionState, String)] = [(.waiting, "WAITING"), (.error, "ERROR"), (.done, "DONE"), (.busy, "BUSY"),
                                              (.compacting, "COMPACT"), (.idle, "IDLE"), (.shell, "SHELL"), (.exited, "EXITED")]
        return rows.map { state, label in
            let style = StateStyle.of(state)
            return StatusCount(glyph: StatusGlyph(style.glyph, style.color), label: label, count: tally[state] ?? 0)
        }
    }

    // MARK: HOST

    static func hostSection(_ facts: StatusHostFacts, store: any SessionStore, now: Date, calendar: Calendar) -> HostSectionModel {
        let sessions = store.allSessions
        let codd = sessions.filter { $0.kind == .claude && !$0.external && $0.state.isLive }.count
        let external = sessions.filter { $0.external && $0.state.isLive }.count
        guard let sample = facts.sample else {
            return HostSectionModel(name: Host.currentName ?? "—", healthy: true,
                                    cards: placeholderCards(codd: codd, external: external))
        }
        var cards = [cpuCard(sample, history: facts.history, now: now), memoryCard(sample, history: facts.history)]
        cards.append(diskCard(sample.disk))
        cards.append(swapCard(sample))
        if let battery = sample.battery { cards.append(batteryCard(battery)) }
        cards.append(claudeCard(codd: codd, external: external))
        cards.append(appCard(facts, total: sample.memory.total))
        cards.append(uptimeCard(sample, calendar: calendar))
        let pressure = sample.memory.pressure
        let diskFull = (sample.disk?.usedFraction ?? 0) >= 0.95
        let batteryLow = sample.battery.map { !$0.onAC && $0.percent <= 10 } ?? false
        return HostSectionModel(name: sample.hostName, healthy: pressure == .normal && !diskFull && !batteryLow, cards: cards)
    }

    /// Before the first sample: the grid with `—` values (the first sample comes a few ms later).
    static func placeholderCards(codd: Int, external: Int) -> [HostCardModel] {
        [HostCardModel(kind: .cpu, label: "CPU", right: "user + sys", value: "—", sub: "取樣中", meter: .single(0), axis: ["-10m", "now"]),
         HostCardModel(kind: .memory, label: "MEM", value: "—", meter: .memory(app: 0, wired: 0, compressed: 0), axis: ["-10m", "now"]),
         HostCardModel(kind: .disk, label: "Disk", value: "—", meter: .single(0)),
         HostCardModel(kind: .swap, label: "Swap", value: "—", meter: .single(0)),
         claudeCard(codd: codd, external: external),
         HostCardModel(kind: .app, label: "CODD app", right: "RSS", value: "—", meter: .single(0, tone: .ok)),
         HostCardModel(kind: .uptime, label: "Uptime", value: "—", meter: .single(1, tone: .muted))]
    }

    /// `-10m` once the history spans ten minutes, else its real span (`-3m`, `-40s`).
    static func historyStart(_ history: HostHistory, now: Date) -> String {
        guard let first = history.points.first?.at else { return "-10m" }
        let span = now.timeIntervalSince(first)
        if span >= 9.5 * 60 { return "-10m" }
        if span < 60 { return "-\(max(0, Int(span.rounded())))s" }
        return "-\(Int((span / 60).rounded()))m"
    }

    static func cpuCard(_ sample: HostSample, history: HostHistory, now: Date) -> HostCardModel {
        let load = sample.cpu.map { String(format: "load %.2f", $0.load1) } ?? "load —"
        let cores = sample.cpu.map { "\($0.cores) cores" } ?? "\(ProcessInfo.processInfo.activeProcessorCount) cores"
        guard let cpu = sample.cpu else {
            return HostCardModel(kind: .cpu, label: "CPU", right: "user + sys", value: "—", unit: "%", sub: "\(load) · \(cores)",
                                 meter: .single(0), axis: [historyStart(history, now: now), "now"])
        }
        let total = max(0, min(100, cpu.total))
        let spark = history.cpuTotal.map { max(0, min(1, $0 / 100)) }
        let peak = history.cpuPeak.map { "peak \(Int($0.rounded()))%" }
        return HostCardModel(kind: .cpu, label: "CPU", right: "user + sys", value: "\(Int(total.rounded()))", unit: "%",
                             sub: "\(load) · \(cores)", meter: .single(total / 100), spark: spark.count >= 2 ? spark : nil,
                             sparkBaseline: spark.count >= 2 ? total / 100 : nil,
                             axis: [historyStart(history, now: now)] + (peak.map { [$0] } ?? []) + ["now"])
    }

    /// `21.4` of `/36G`: one decimal below 100 GB.
    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value < 100 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
    }

    static func memoryCard(_ sample: HostSample, history: HostHistory) -> HostCardModel {
        let m = sample.memory
        let total = Double(max(1, m.total))
        let (right, color): (String, NSColor) = switch m.pressure {
        case .normal: ("● pressure normal", Palette.success)
        case .warning: ("◆ pressure warning", Palette.amber)
        case .critical: ("▲ pressure critical", Palette.danger)
        }
        let colors = HostColors.legend
        let legend = [HostLegendItem(label: "app", value: ByteText.short(m.app), color: colors[0]),
                      HostLegendItem(label: "wired", value: ByteText.short(m.wired), color: colors[1]),
                      HostLegendItem(label: "compressed", value: ByteText.short(m.compressed), color: colors[2])]
        let label = "記憶體 app \(ByteText.short(m.app))、wired \(ByteText.short(m.wired))、compressed \(ByteText.short(m.compressed))，"
            + "共 \(ByteText.short(m.used)) / \(ByteText.short(m.total))"
        let spark = history.memoryUsedFraction
        return HostCardModel(kind: .memory, label: "MEM", right: right, rightColor: color, value: gigabytes(m.used),
                             unit: "/\(ByteText.short(m.total))",
                             meter: .memory(app: Double(m.app) / total, wired: Double(m.wired) / total, compressed: Double(m.compressed) / total),
                             meterLabel: label, spark: spark.count >= 2 ? spark : nil, axis: ["-10m", "now"], legend: legend)
    }

    static func diskCard(_ disk: HostSample.Disk?) -> HostCardModel {
        guard let disk else {
            return HostCardModel(kind: .disk, label: "Disk", value: "—", sub: "讀不到磁碟", meter: .single(0))
        }
        let used = Int((disk.usedFraction * 100).rounded())
        return HostCardModel(kind: .disk, label: "Disk", right: ByteText.short(disk.total), value: ByteText.short(disk.available),
                             unit: "free", sub: "已用 \(used)% · \(disk.volumeName)", meter: .single(disk.usedFraction))
    }

    static func swapCard(_ sample: HostSample) -> HostCardModel {
        let pressure = switch sample.memory.pressure {
        case .normal: "壓力正常"
        case .warning: "壓力偏高"
        case .critical: "壓力過高"
        }
        return HostCardModel(kind: .swap, label: "Swap", value: ByteText.short(sample.swap.used),
                             sub: "共 \(ByteText.short(sample.swap.total)) · \(pressure)", meter: .single(sample.swap.usedFraction))
    }

    static func batteryCard(_ battery: HostSample.Battery) -> HostCardModel {
        let sub = battery.charging ? "充電中" : (battery.onAC ? "接上電源" : "使用電池")
        let tone: Tone = battery.percent <= 20 && !battery.onAC ? .crit : .ok
        return HostCardModel(kind: .battery, label: "Bat", right: battery.onAC ? "AC" : "電池", value: "\(battery.percent)", unit: "%",
                             sub: sub, meter: .single(Double(battery.percent) / 100, tone: tone))
    }

    /// CLAUDE: live claudes CODD started and external ones (the split meter).
    static func claudeCard(codd: Int, external: Int) -> HostCardModel {
        let total = codd + external
        let main = total == 0 ? 0 : Double(codd) / Double(total)
        let other = total == 0 ? 0 : Double(external) / Double(total)
        return HostCardModel(kind: .claude, label: "Claude", right: "processes", value: "\(total)",
                             sub: "\(codd) CODD + \(external) 外部", meter: .split(main, other: other))
    }

    /// CODD APP: resident memory (`RSS`) and the main thread's p99 delay (D26).
    static func appCard(_ facts: StatusHostFacts, total: UInt64) -> HostCardModel {
        let resident = facts.footprint?.resident ?? 0
        let megabytes = Int((Double(resident) / 1_048_576).rounded())
        let p99 = facts.p99Milliseconds.map { "\(Int($0.rounded()))ms" } ?? "—"
        let fraction = total == 0 ? 0 : Double(resident) / Double(total)
        return HostCardModel(kind: .app, label: "CODD app", right: "RSS", value: facts.footprint == nil ? "—" : "\(megabytes)",
                             unit: "MB", sub: "event loop p99 \(p99)", meter: .single(fraction, tone: .ok))
    }

    /// `3d4h`, `4h12m`, `12m`.
    static func uptimeText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(rest)m" }
        return "\(rest)m"
    }

    static func uptimeCard(_ sample: HostSample, calendar: Calendar) -> HostCardModel {
        let parts = calendar.dateComponents([.month, .day], from: sample.bootedAt)
        let booted = "\(parts.month ?? 0)/\(parts.day ?? 0) \(ClockFormat.hourMinute(sample.bootedAt, calendar: calendar))"
        return HostCardModel(kind: .uptime, label: "Uptime", value: uptimeText(sample.uptime), sub: "開機於 \(booted)",
                             meter: .single(1, tone: .muted))
    }

    // MARK: ACCOUNTS

    static func tone(_ tone: QuotaTone) -> Tone {
        switch tone {
        case .ok: .ok
        case .warn: .warn
        case .crit: .crit
        case .muted: .muted
        }
    }

    /// The D1 / D3 lines (nil while cswap's accounts are shown).
    static func unavailableLine(_ base: AccountAvailability) -> String? {
        switch base {
        case .ready: nil
        case .loading: "// 正在讀取 cswap 的帳號…"
        case .noCswap: AccountsSectionModel.cswapMissing
        case .unsupported(let version): AccountsSectionModel.cswapTooOld(version)
        case .unreadable(let reason): AccountsSectionModel.stateUnreadable(reason)
        case .pseudo(let note): note
        }
    }

    static func accountsSection(_ accounts: any AccountStore, store: any SessionStore, facts: StatusAccountFacts, now: Date,
                                calendar: Calendar) -> AccountsSectionModel {
        let autoSwitch = AutoSwitchModel(on: facts.autoSwitchOn, thresholdPercent: Double(facts.thresholdPercent),
                                         chips: AutoSwitchModel.ruleChips(thresholdPercent: facts.thresholdPercent, fiveHour: facts.checkFiveHour,
                                                                          weekly: facts.checkWeekly, cooldownSeconds: facts.cooldownSeconds),
                                         warning: facts.backgroundWarning, checksFiveHour: facts.checkFiveHour,
                                         checksWeekly: facts.checkWeekly)
        let version: String? = switch facts.base {
        case .ready, .unreadable: accounts.sourceLabel
        case .unsupported(let v): "cswap \(v)"
        default: nil
        }
        if let line = unavailableLine(facts.base) {
            return AccountsSectionModel(version: version, rootPath: facts.base == .noCswap ? nil : facts.rootPath, countHint: "不顯示 email",
                                        cards: [], canAdd: false, unavailable: line, autoSwitch: autoSwitch)
        }
        let list = accounts.accounts.filter { !$0.isPseudo }
        // Every account gets a row per scoped window any account reports (`Fable — 快取未提供`).
        var scopedNames: [String] = []
        for account in list { for scoped in account.scoped where !scopedNames.contains(scoped.name) { scopedNames.append(scoped.name) } }
        let cards = list.map { card($0, accounts: accounts, scopedNames: scopedNames, now: now, calendar: calendar) }
        // cswap without any account yet (no sequence.json): the add card is the way in.
        let hint = cards.isEmpty ? "cswap 還沒有帳號 · 加入第一個帳號" : AccountsSectionModel.countHint(cards.count)
        return AccountsSectionModel(version: version, rootPath: facts.rootPath, countHint: hint, cards: cards, canAdd: true,
                                    autoSwitch: autoSwitch)
    }

    static func card(_ vm: AccountVM, accounts: any AccountStore, scopedNames: [String], now: Date, calendar: Calendar) -> AccountCardModel {
        let active = vm.id == accounts.activeAccountID
        let health: CoddStatusUI.AccountHealth = switch vm.health {
        case .ok: .ok
        case .stale: .stale
        case .failing: CoddStatusUI.AccountHealth(text: "◆ 抓取失敗", color: Palette.amber)
        case .reloginRequired: .reloginRequired
        }
        let source: StatusText = vm.sourceAt.map { StatusText.ago($0, prefix: "\(vm.source.isEmpty ? "—" : vm.source) · ") } ?? "尚無用量"
        var rows = [fiveHourRow(vm.fiveHour, now: now, calendar: calendar), weeklyRow(vm.week, now: now, calendar: calendar)]
        for name in scopedNames {
            rows.append(scopedRow(name: name, vm: vm, now: now, calendar: calendar))
        }
        let pace = vm.paceText(calendar: calendar).map { "↗ " + $0 }
        let who: AccountWho = active ? .following(accounts.followingSessionCount) : .pinned(accounts.pinnedCount(for: vm.id))
        return AccountCardModel(id: vm.id, slot: vm.slot, alias: vm.alias, plan: vm.plan, isActive: active, health: health, source: source,
                                rows: rows, pace: pace, who: who, button: button(vm, active: active, accounts: accounts, now: now))
    }

    static func fiveHourRow(_ window: QuotaWindow, now: Date, calendar: Calendar) -> AccountQuotaRow {
        guard window.known else {
            return AccountQuotaRow(key: "5h", remaining: nil, tone: .muted, reset: "尚無資料", countdown: "等待回報")
        }
        guard window.started, let reset = window.resetsAt else {
            return AccountQuotaRow(key: "5h", remaining: Double(window.remainingPercent), tone: tone(window.tone), reset: "未開始",
                                   countdown: "第一則訊息後起算")
        }
        return AccountQuotaRow(key: "5h", remaining: Double(window.remainingPercent), tone: tone(window.tone),
                               reset: "重置 " + ClockFormat.resetLabel(reset, now: now, calendar: calendar), countdown: .countdown(reset))
    }

    static func weeklyRow(_ window: QuotaWindow, now: Date, calendar: Calendar) -> AccountQuotaRow {
        guard window.known else {
            return AccountQuotaRow(key: "1w", remaining: nil, tone: .muted, reset: "尚無資料", countdown: "等待回報", isSortKey: true)
        }
        guard let reset = window.resetsAt else {
            return AccountQuotaRow(key: "1w", remaining: Double(window.remainingPercent), tone: tone(window.tone), reset: "重置時間未知",
                                   countdown: "", isSortKey: true)
        }
        return AccountQuotaRow(key: "1w", remaining: Double(window.remainingPercent), tone: tone(window.tone),
                               reset: "重置 " + ClockFormat.resetLabel(reset, now: now, calendar: calendar), countdown: .countdown(reset),
                               isSortKey: true)
    }

    /// `Fable 100% · 週額度 · 同 1w 重置 · 未使用`; unknown for this account: `— 快取未提供 · 等待回報`.
    static func scopedRow(name: String, vm: AccountVM, now: Date, calendar: Calendar) -> AccountQuotaRow {
        guard let scoped = vm.scoped.first(where: { $0.name == name }) else {
            return AccountQuotaRow(key: name, remaining: nil, tone: .muted, reset: "快取未提供", countdown: "等待回報")
        }
        let remaining = Double(scoped.remainingPercent)
        let rowTone = tone(QuotaWindow(remainingPercent: scoped.remainingPercent, resetsAt: scoped.resetsAt).tone)
        let sameAsWeek: Bool
        if let reset = scoped.resetsAt, let week = vm.week.resetsAt {
            sameAsWeek = abs(reset.timeIntervalSince(week)) <= 120
        } else {
            sameAsWeek = scoped.resetsAt == nil
        }
        let reset = sameAsWeek ? "週額度 · 同 1w 重置" : "重置 " + ClockFormat.resetLabel(scoped.resetsAt ?? now, now: now, calendar: calendar)
        let countdown: StatusText = scoped.remainingPercent >= 100 ? "未使用" : (scoped.resetsAt.map { .countdown($0) } ?? "")
        return AccountQuotaRow(key: name, remaining: remaining, tone: rowTone, reset: reset, countdown: countdown)
    }

    /// `[ACTIVE]`, `[SWITCH]`, `[切換中…]` with the D5 progress line, or disabled with the reason.
    static func button(_ vm: AccountVM, active: Bool, accounts: any AccountStore, now: Date) -> AccountButton {
        if active { return .active }
        if case .switching(let to, _, let attempt, let since) = accounts.switchState {
            guard to == vm.id else { return .disabled(reason: "另一個帳號切換中…") }
            let seconds = max(0, Int(now.timeIntervalSince(since)))
            return .switching(progress: "◌ 等待 Claude Code credential lock… \(seconds)s（\(attempt)/3）")
        }
        if vm.isDisabled { return .disabled(reason: "\(vm.slot) 在 cswap 中已停用") }
        if vm.health == .reloginRequired {
            return .disabled(reason: "先在終端機執行 cswap 重新登入 \(vm.slot)")
        }
        return .switchable
    }

    // MARK: HOOKS

    /// The chain chips of a status-line command: the programs and scripts it names
    /// (`/…/hook-tap statusline ~/.hook-tap/statusline.sh` → `hook-tap`, `statusline.sh`).
    static func chainChips(_ command: String?) -> [String] {
        guard let command else { return [] }
        let shells: Set<String> = ["sh", "bash", "zsh", "node", "python", "python3", "env", "exec", "/bin/sh", "-c"]
        var chips: [String] = []
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\"();&|"))
        }
        for (index, token) in tokens.enumerated() where !token.isEmpty && !token.hasPrefix("-") && !token.contains("=") {
            let name = (token as NSString).lastPathComponent
            guard !shells.contains(name), !name.isEmpty else { continue }
            let looksLikeFile = token.contains("/") || name.contains(".")
            guard index == 0 || looksLikeFile else { continue }
            if !chips.contains(name) { chips.append(name) }
            if chips.count == 3 { break }
        }
        return chips
    }

    static func hooksCard(_ facts: StatusHooksFacts, store: any SessionStore, accounts: any AccountStore,
                          facts accountFacts: StatusAccountFacts) -> HooksCardModel {
        let received = [facts.lastHookAt, facts.lastStatusLineAt].compactMap { $0 }.max()
        let last = LastReceived(at: received, hooks: facts.lastHookAt != nil, statusline: facts.lastStatusLineAt != nil)
        let injected = facts.injected ? 14 : 0
        let profiles = profileCards(store: store, accounts: accounts, facts: accountFacts)
        switch facts.inspection {
        case .unknown, .failed:
            var problem: String?
            if case .failed(let reason) = facts.inspection { problem = "// 讀不到 settings.json：\(reason)" }
            return HooksCardModel(claudeDir: facts.claudeDir, fileName: facts.fileName, pendingUpdates: 0, problem: problem,
                                  hooksInjected: injected, statusline: StatuslinePart(state: .notInstalled), statusDir: facts.statusDir,
                                  statusDirDiffers: facts.statusDirDiffers, lastReceived: last, foreign: [], canPreview: false,
                                  canUpdate: false, canUninstall: false, canRemoveLegacy: false, canDisableDuplicates: false,
                                  profiles: profiles, details: facts.details)
        case .loaded(let inspection, _):
            let statusline: StatuslinePart
            var outdated = false
            var webLegacy = false
            switch inspection.statusLine {
            case .none: statusline = StatuslinePart(state: .notInstalled)
            case .user(let command): statusline = StatuslinePart(state: .notInstalled, chain: chainChips(command))
            case .coddWeb(let inner):
                webLegacy = true
                statusline = StatuslinePart(state: .legacyWeb, chain: ["codd-statusline.js"] + chainChips(inner))
            case .coddDesktop(let chain, let current):
                outdated = !current
                statusline = StatuslinePart(state: current ? .installed : .outdated, chain: ["CODD"] + chainChips(chain))
            case .undecodable: statusline = StatuslinePart(state: .undecodable)
            }
            let legacy = inspection.hasLegacy ? LegacyHooks(events: inspection.legacyHookEvents) : nil
            let pending = (inspection.legacyHandlerCount > 0 || webLegacy ? 1 : 0) + (outdated ? 1 : 0)
            let foreign = inspection.foreign.map { tool in
                ForeignHookRow(code: tool.code, name: tool.name, events: tool.events,
                               warnings: tool.blocking.map { "\($0.event) 會阻擋 \($0.seconds)s" },
                               duplicateNotifications: tool.code == "osascript" && inspection.duplicateNotificationHandlers > 0)
            }
            let undecodable = inspection.statusLine == .undecodable
            var desktop = false
            if case .coddDesktop = inspection.statusLine { desktop = true }
            return HooksCardModel(claudeDir: facts.claudeDir, fileName: facts.fileName, pendingUpdates: pending, hooksInjected: injected,
                                  legacy: legacy, statusline: statusline, statusDir: facts.statusDir, statusDirDiffers: facts.statusDirDiffers,
                                  lastReceived: last, foreign: foreign, canPreview: true,
                                  canUpdate: !inspection.isUpToDate && !undecodable, canUninstall: desktop,
                                  canRemoveLegacy: inspection.hasLegacy, canDisableDuplicates: inspection.duplicateNotificationHandlers > 0,
                                  profiles: profiles, details: facts.details)
        }
    }

    /// One card per account that live pinned sessions use (D12): linked = the profile's
    /// settings.json is the main one; the sessions' titles.
    static func profileCards(store: any SessionStore, accounts: any AccountStore, facts: StatusAccountFacts) -> [ProfileCardModel] {
        var titles: [AccountID: [String]] = [:]
        for session in store.allSessions where session.accountPinned && session.state.isLive && !session.external {
            guard let id = session.accountID else { continue }
            titles[id, default: []].append(session.title)
        }
        let order = accounts.accounts.map(\.id)
        return titles.keys.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }.map { id in
            let slot = accounts.account(id)?.slot ?? "#\(id)"
            let linked = Int(id).flatMap { facts.profileShares[$0] } ?? nil
            return ProfileCardModel(slot: slot, linked: linked, sessionTitles: titles[id]?.sorted() ?? [])
        }
    }
}

/// The computer's name for HOST before the first sample (`gethostname`, without `.local`).
enum Host {
    static var currentName: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        var name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.lowercased().hasSuffix(".local") { name.removeLast(6) }
        return name.isEmpty ? nil : name
    }
}
