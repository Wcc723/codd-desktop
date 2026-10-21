import AppKit
import CoddUI

/// The SPEC §5 canonical sample as a `StatusPageModel` (the Status artboard's numbers), plus the
/// other states the demo renders. Used by the tests, `codd-status-demo` and the app's mock mode.
/// Dates are relative to `now`, so countdowns read like the artboard (`2h57m後`, `3d01h後`).
public enum StatusSamples {
    /// 2026-10-15 10:42:07 in Asia/Taipei: the artboard's `UPDATED 10:42:07`.
    public static let referenceNow = Date(timeIntervalSince1970: 1_792_032_127)

    /// The calendar the sample's clock labels are written in.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return calendar
    }

    /// The whole page as on the artboard (SPEC §5, with the C6 copy decisions: HOOKS shows the
    /// injected 14 / 14 and the CODD web leftovers as the one pending update; the cswap session
    /// profile #2 card is linked; M4: MCP running on the hook port with the three clients, the
    /// notes in `<dataRoot>/notes`).
    public static func spec(now: Date = referenceNow, calendar: Calendar = StatusSamples.calendar) -> StatusPageModel {
        StatusPageModel(updatedAt: now, refreshSeconds: 5, paused: false, live: true,
                        nav: nav, needsYou: needsYou(now: now), counts: counts, liveCount: 13,
                        host: host(), accounts: accounts(now: now, calendar: calendar), hooks: hooks(now: now),
                        remote: RemoteModel(count: 1, titles: ["修正登入 API 401"]), mcp: mcp)
    }

    // MARK: Sidebar

    public static var nav: [StatusNavItem] {
        [StatusNavItem(id: .host, glyph: .ok, value: "cpu 23%"),
         StatusNavItem(id: .accounts, glyph: .bad, value: "1w 15%", valueColor: Palette.danger),
         StatusNavItem(id: .hooks, glyph: .attention, value: "需更新", valueColor: Palette.amber),
         .mcp(mcp),
         StatusNavItem(id: .remote, glyph: .remote, value: "1 rc")]
    }

    public static func needsYou(now: Date) -> [StatusSessionRow] {
        [StatusSessionRow(id: "s1", glyph: .attention, tag: NSColor(srgbRed: 0xEF / 255, green: 0x5B / 255, blue: 0x5B / 255, alpha: 1),
                          title: "修正登入 API 401", pill: "Perm", since: now.addingTimeInterval(-180), detail: "orb-toolkit-backend"),
         StatusSessionRow(id: "s2", glyph: .attention, title: "發票匯出 CSV", pill: "Ask", since: now.addingTimeInterval(-720),
                          detail: "Northstar invoice system"),
         StatusSessionRow(id: "s3", glyph: .bad, tag: NSColor(srgbRed: 0xE6 / 255, green: 0xC8 / 255, blue: 0x4E / 255, alpha: 1),
                          title: "場景載入優化", pill: "Error", since: now.addingTimeInterval(-60), detail: "overloaded · Gear3D",
                          attention: .error)]
    }

    public static var counts: [StatusCount] {
        [StatusCount(glyph: StatusGlyph("◆", Palette.amber), label: "WAITING", count: 2),
         StatusCount(glyph: StatusGlyph("▲", Palette.danger), label: "ERROR", count: 1),
         StatusCount(glyph: StatusGlyph("◇", Palette.cyan), label: "DONE", count: 1),
         StatusCount(glyph: StatusGlyph("●", Palette.success), label: "BUSY", count: 3),
         StatusCount(glyph: StatusGlyph("◌", Palette.successDim), label: "COMPACT", count: 1),
         StatusCount(glyph: StatusGlyph("○", Palette.cyan), label: "IDLE", count: 4),
         StatusCount(glyph: StatusGlyph("$", Palette.bone), label: "SHELL", count: 1),
         StatusCount(glyph: StatusGlyph("✕", Palette.dimmer), label: "EXITED", count: 1)]
    }

    // MARK: HOST

    /// The artboard's sparkline points (SVG y in a 0…40 box) as 0…1 values.
    private static func spark(_ ys: [Double]) -> [Double] { ys.map { 1 - $0 / 40 } }

    public static func host(battery: Bool = true) -> HostSectionModel {
        var cards: [HostCardModel] = [
            HostCardModel(kind: .cpu, label: "CPU", right: "user + sys", value: "23", unit: "%", sub: "load 3.12 · 12 cores",
                          meter: .single(0.23),
                          spark: spark([28, 26, 27.3, 22.7, 19.3, 21.3, 24, 25.3, 22, 16.7, 14.7, 20, 23.3, 26, 27.3, 24, 20.7, 22.7, 25.3, 26.7, 24.7]),
                          sparkBaseline: 1 - 24.7 / 40, axis: ["-10m", "peak 38%", "now"]),
            HostCardModel(kind: .memory, label: "MEM", right: "● pressure normal", rightColor: Palette.success, value: "21.4", unit: "/36G",
                          meter: .memory(app: 0.383, wired: 0.119, compressed: 0.092),
                          meterLabel: "記憶體 app 13.8G、wired 4.3G、compressed 3.3G，共 21.4G / 36G",
                          spark: spark([17.1, 16.7, 16.3, 15.9, 16, 15.5, 14.8, 14.3, 14.5, 14.7, 13.9, 13.6, 14, 14.4, 14.1, 13.7, 13.5, 13.9, 14.1, 14.3, 14.1]),
                          axis: ["-10m", "now"],
                          legend: [HostLegendItem(label: "app", value: "13.8G", color: HostColors.legend[0]),
                                   HostLegendItem(label: "wired", value: "4.3G", color: HostColors.legend[1]),
                                   HostLegendItem(label: "compressed", value: "3.3G", color: HostColors.legend[2])]),
            HostCardModel(kind: .disk, label: "Disk", right: "1T", value: "412G", unit: "free", sub: "已用 59% · Macintosh HD", meter: .single(0.59)),
            HostCardModel(kind: .swap, label: "Swap", value: "1.2G", sub: "共 2G · 壓力正常", meter: .single(0.6)),
        ]
        if battery {
            cards.append(HostCardModel(kind: .battery, label: "Bat", right: "AC", value: "86", unit: "%", sub: "接上電源", meter: .single(0.86, tone: .ok)))
        }
        cards += [
            HostCardModel(kind: .claude, label: "Claude", right: "processes", value: "12", sub: "11 CODD + 1 外部", meter: .split(0.917, other: 0.083)),
            HostCardModel(kind: .app, label: "CODD app", right: "RSS", value: "412", unit: "MB", sub: "event loop p99 3ms", meter: .single(0.011, tone: .ok)),
            HostCardModel(kind: .uptime, label: "Uptime", value: "3d4h", sub: "開機於 10/12 06:42", meter: .single(1, tone: .muted)),
        ]
        return HostSectionModel(name: "studio-mbp", healthy: true, cards: cards)
    }

    // MARK: ACCOUNTS

    public static func accounts(now: Date, calendar: Calendar = StatusSamples.calendar) -> AccountsSectionModel {
        AccountsSectionModel(version: "cswap 0.26.0", rootPath: "~/.claude-swap-backup", countHint: AccountsSectionModel.countHint(3),
                             cards: accountCards(now: now, calendar: calendar), canAdd: true,
                             autoSwitch: AutoSwitchModel(on: false, chips: AutoSwitchModel.ruleChips()))
    }

    /// R7 order: #2 (1w resets first), #3 (active), #1.
    public static func accountCards(now: Date, calendar: Calendar = StatusSamples.calendar) -> [AccountCardModel] {
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            var parts = DateComponents()
            parts.year = 2026
            parts.month = month
            parts.day = day
            parts.hour = hour
            parts.minute = minute
            parts.second = 30
            let date = calendar.date(from: parts) ?? now
            // Keep the artboard's offsets when `now` is not the reference moment.
            return now.addingTimeInterval(date.timeIntervalSince(referenceNow))
        }
        func reset(_ date: Date) -> String { "重置 " + ClockFormat.resetLabel(date, now: now, calendar: calendar) }
        let five2 = at(10, 15, 13, 19), week2 = at(10, 16, 22, 59)
        let five3 = at(10, 15, 13, 39), week3 = at(10, 18, 12, 0)
        let week1 = at(10, 19, 20, 0)
        return [
            AccountCardModel(id: "2", slot: "#2", alias: "藍鵲", plan: "MAX 20x", source: .ago(now.addingTimeInterval(-180), prefix: "cswap cache · "),
                             rows: [AccountQuotaRow(key: "5h", remaining: 98, tone: .ok, reset: reset(five2), countdown: .countdown(five2)),
                                    AccountQuotaRow(key: "1w", remaining: 46, tone: .warn, reset: reset(week2), countdown: .countdown(week2), isSortKey: true),
                                    AccountQuotaRow(key: "Fable", remaining: nil, tone: .muted, reset: "快取未提供", countdown: "等待回報")],
                             who: .pinned(1), button: .switchable),
            AccountCardModel(id: "3", slot: "#3", alias: "工作", plan: "MAX 20x", isActive: true,
                             source: .ago(now.addingTimeInterval(-12), prefix: "statusline · "),
                             rows: [AccountQuotaRow(key: "5h", remaining: 91, tone: .ok, reset: reset(five3), countdown: .countdown(five3)),
                                    AccountQuotaRow(key: "1w", remaining: 15, tone: .crit, reset: reset(week3), countdown: .countdown(week3), isSortKey: true),
                                    AccountQuotaRow(key: "Fable", remaining: 100, tone: .ok, reset: "週額度 · 同 1w 重置", countdown: "未使用")],
                             pace: "↗ 1w 用量超前預期 · 預估 10/17 18:00 用完", who: .following(12), button: .active),
            AccountCardModel(id: "1", slot: "#1", alias: "個人", plan: "MAX 20x", source: .ago(now.addingTimeInterval(-180), prefix: "cswap cache · "),
                             rows: [AccountQuotaRow(key: "5h", remaining: 100, tone: .muted, reset: "未開始", countdown: "第一則訊息後起算"),
                                    AccountQuotaRow(key: "1w", remaining: 100, tone: .ok, reset: reset(week1), countdown: .countdown(week1), isSortKey: true),
                                    AccountQuotaRow(key: "Fable", remaining: nil, tone: .muted, reset: "快取未提供", countdown: "等待回報")],
                             who: .none, button: .switchable),
        ]
    }

    // MARK: MCP

    /// SPEC §5: `● 127.0.0.1:47821 · 3 clients` (修正登入 API 401, 打卡頁 RWD 調整, codex); Claude
    /// Code registered, Codex not, Claude Desktop `FUTURE` (D22).
    public static var mcp: StatusMCPModel {
        StatusMCPModel(running: true, endpoint: "127.0.0.1:47821", clientsCount: 3,
                       clients: [StatusMCPClient(id: "s1", title: "修正登入 API 401", kind: "Claude Code", connectedFor: "連線 42m"),
                                 StatusMCPClient(id: "s6", title: "打卡頁 RWD 調整", kind: "Claude Code", connectedFor: "連線 1h18m"),
                                 StatusMCPClient(id: "ext-codex", title: "codex", kind: "Codex CLI", connectedFor: "連線 12m")],
                       registrations: mcpRegistrations, tokenMasked: "••••", notesPath: "~/Library/Application Support/CODD/notes")
    }

    public static var mcpRegistrations: [StatusMCPRegistration] {
        [StatusMCPRegistration(id: "claude-code", name: "Claude Code", hint: "user scope", state: "● 已註冊", stateTone: .ok, actionTitle: "移除"),
         StatusMCPRegistration(id: "codex", name: "Codex", hint: "~/.codex/config.toml", state: "○ 未註冊", stateTone: .muted,
                               actionTitle: "註冊", accent: true),
         StatusMCPRegistration(id: "claude-desktop", name: "Claude Desktop", hint: "擴充功能", state: "○ 未安裝", stateTone: .muted,
                               actionTitle: "安裝 .mcpb", actionEnabled: false, chip: "FUTURE")]
    }

    // MARK: HOOKS

    /// CODD web's `status-writer.js` events in the user's settings (D10 Legacy).
    public static let legacyEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                                      "PermissionRequest", "Stop", "SubagentStop", "PreCompact", "SessionEnd"]

    public static func hooks(now: Date) -> HooksCardModel {
        HooksCardModel(pendingUpdates: 1, legacy: LegacyHooks(events: legacyEvents),
                       statusline: StatuslinePart(state: .installed, chain: ["CODD", "hook-tap", "statusline.sh"]),
                       statusDir: "~/Github/codd-web/agent-sandbox/.claude/codd-status", statusDirDiffers: true,
                       lastReceived: LastReceived(at: now.addingTimeInterval(-8), hooks: true, statusline: true),
                       foreign: foreign, canPreview: true, canUpdate: true, canUninstall: true, canRemoveLegacy: true,
                       canDisableDuplicates: true,
                       profiles: [ProfileCardModel(slot: "#2", linked: true, sessionTitles: ["現場示範：連線 MCP"])])
    }

    public static var foreign: [ForeignHookRow] {
        [ForeignHookRow(code: "hook-tap", name: "hook-tap",
                        events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification",
                                 "Stop", "SubagentStart", "SubagentStop", "PreCompact", "SessionEnd"],
                        warnings: ["PermissionRequest 會阻擋 600s"]),
         ForeignHookRow(code: "osascript", name: "通知", events: ["Notification", "Stop"], duplicateNotifications: true)]
    }

    // MARK: States

    /// One of the demo's named states.
    public enum State: String, CaseIterable, Sendable {
        case spec
        case accountsMissing = "accounts-missing"
        case accountsTooOld = "accounts-too-old"
        case accountsUnreadable = "accounts-unreadable"
        case autoSwitchOn = "auto-switch-on"
        case switching
        case hooksClean = "hooks-clean"
        case hooksLegacyWeb = "hooks-legacy-web"
        case noBattery = "no-battery"
        case profileNotLinked = "profile-not-linked"
        case paused
        /// MCP running, nobody connected yet; the token was rotated (Claude Code must re-register).
        case mcpNoClients = "mcp-no-clients"
        /// MCP stopped (the hook server is down).
        case mcpStopped = "mcp-stopped"
        /// A caller from before M4 (`mcp` nil): the D27 placeholder card.
        case mcpPlaceholder = "mcp-placeholder"
    }

    public static func model(_ state: State, now: Date = referenceNow, calendar: Calendar = StatusSamples.calendar) -> StatusPageModel {
        var model = spec(now: now, calendar: calendar)
        switch state {
        case .spec:
            break
        case .accountsMissing:
            model.accounts = unavailable(model.accounts, AccountsSectionModel.cswapMissing, version: nil)
            model.nav[1] = StatusNavItem(id: .accounts, glyph: .off, value: "—")
        case .accountsTooOld:
            model.accounts = unavailable(model.accounts, AccountsSectionModel.cswapTooOld("0.25.1"), version: "cswap 0.25.1")
            model.nav[1] = StatusNavItem(id: .accounts, glyph: .attention, value: "需 ≥ 0.26", valueColor: Palette.amber)
        case .accountsUnreadable:
            model.accounts = unavailable(model.accounts, AccountsSectionModel.stateUnreadable("cache/usage.json 版本不支援"),
                                         version: "cswap 0.26.0")
            model.nav[1] = StatusNavItem(id: .accounts, glyph: .attention, value: "讀不到", valueColor: Palette.amber)
        case .autoSwitchOn:
            model.accounts.autoSwitch = AutoSwitchModel(on: true, thresholdPercent: 2, chips: AutoSwitchModel.ruleChips(),
                                                        warning: AutoSwitchModel.menubarWarning)
            // The other health texts: a stale cache, an account that needs a new login.
            model.accounts.cards[2].health = .stale
            model.accounts.cards[0].health = .reloginRequired
            model.accounts.cards[0].button = .disabled(reason: "先在終端機執行 cswap 重新登入 #2")
        case .switching:
            model.accounts.cards[0].button = .switching(progress: "◌ 等待 Claude Code credential lock… 9s（1/3）")
            model.accounts.cards[2].button = .disabled(reason: "另一個帳號切換中…")
        case .hooksClean:
            model.hooks.pendingUpdates = 0
            model.hooks.legacy = nil
            model.hooks.statusline = StatuslinePart(state: .notInstalled, chain: ["hook-tap", "statusline.sh"])
            model.hooks.statusDir = "~/Library/Application Support/CODD/hooks"
            model.hooks.statusDirDiffers = false
            model.hooks.lastReceived = LastReceived(at: now.addingTimeInterval(-3), hooks: true, statusline: false)
            model.hooks.canUninstall = false
            model.hooks.canRemoveLegacy = false
            model.hooks.foreign = [model.hooks.foreign[0]]
            model.hooks.profiles = []
            model.nav[2] = StatusNavItem(id: .hooks, glyph: .ok, value: "14 / 14")
        case .hooksLegacyWeb:
            model.hooks.statusline = StatuslinePart(state: .legacyWeb, chain: ["codd-statusline.js", "hook-tap", "statusline.sh"])
            model.hooks.pendingUpdates = 1
            model.hooks.canUninstall = false
        case .noBattery:
            model.host = host(battery: false)
        case .profileNotLinked:
            model.hooks.profiles = [ProfileCardModel(slot: "#2", linked: false, sessionTitles: ["現場示範：連線 MCP"]),
                                    ProfileCardModel(slot: "#1", linked: nil, sessionTitles: ["keynote 第 3 章"])]
        case .paused:
            model.paused = true
        case .mcpNoClients:
            var mcp = mcp
            mcp.clientsCount = 0
            mcp.clients = []
            mcp.registrations[0] = StatusMCPRegistration(id: "claude-code", name: "Claude Code", hint: "user scope", state: "◆ 需要重新註冊",
                                                         stateTone: .warn, actionTitle: "註冊", accent: true)
            model.mcp = mcp
            model.nav[3] = .mcp(mcp)
        case .mcpStopped:
            var mcp = mcp
            mcp.running = false
            mcp.clientsCount = 0
            mcp.clients = []
            mcp.note = "// hook server 未執行，MCP 暫停"
            model.mcp = mcp
            model.nav[3] = .mcp(mcp)
        case .mcpPlaceholder:
            model.mcp = nil
            model.nav[3] = StatusNavItem(id: .mcp, glyph: .off, value: "M4")
        }
        return model
    }

    private static func unavailable(_ accounts: AccountsSectionModel, _ line: String, version: String?) -> AccountsSectionModel {
        var out = accounts
        out.cards = []
        out.canAdd = false
        out.unavailable = line
        out.version = version
        out.countHint = "不顯示 email"
        return out
    }
}
