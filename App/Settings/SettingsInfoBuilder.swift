import AppKit
import CoddClaudeSettings
import CoddCore
import CoddSettingsUI
import CoddUI

/// Everything Settings shows beyond the session and account stores, gathered by
/// `SettingsCoordinator` while the window is open.
struct SettingsFacts {
    var now: Date
    var calendar: Calendar = .current
    /// `~/Library/Application Support/CODD/preferences.json` (abbreviated).
    var preferencesPath = ""
    var dataRootPath = ""
    var logPath: String?
    var savedAt: Date?
    var saveProblem: String?
    var loginItemStatus: String?
    var hotkeyError: String?
    var profiles = LaunchProfileDocument.seeded
    var cswap = SettingsCswapInfo()
    /// D1: why cswap's state files cannot be used (`重新讀取`), nil when they can.
    var accountsUnavailable: String?
    /// cswap's accounts are listed (the alias rows can be edited).
    var accountsReady = false
    var inspection: ClaudeSettingsService.InspectionState = .unknown
    var backups: [SettingsBackupRow] = []
    var statusDir = ""
    var statusDirDiffers = false
    /// New CODD sessions get the 14 hook events (the endpoint is this app's).
    var injected = true
    var lastStatusLineAt: Date?
    /// Whether the ages that move with every status-line report (the accounts' capture times,
    /// ``lastStatusLineAt``) are read. The coordinator's observation pass leaves them out, so a
    /// report does not rebuild the page; its 5 s tick shows them (M3 review).
    var includesAges = true
    var cleanupPeriodDays: Int?
    var versions: [(key: String, value: String)] = []
    var externalCount: Int?
    /// cswap's accounts as the auto-switch engine sees them (empty in mock mode): the live
    /// preview marks the same targets `AutoSwitchPolicy` would (R8).
    var coreAccounts: [Account] = []
    /// M4 I2a (D33): 筆記本 & MCP and ADVANCED › 重建筆記索引.
    var notebook: SettingsNotebookInfo = .unavailable
    /// D32: 清理 › 交給 Claude 濃縮's account select (I4a runs it).
    var condenseAccounts: [SettingsCondenseAccount] = []
    /// M4 I4a (D31): the Cleanup page's candidates (`查看清理建議 · 15 →`) and whether it opens.
    var cleanupCount: Int?
    var canOpenCleanup = false
}

/// Maps the stores and the facts into CoddSettingsUI's `SettingsInfo` (Settings artboard, D10, D13,
/// D21, D22, D28, D34). Pure apart from reading the main-actor view models; never an e-mail or a
/// cswap profile path (D31).
@MainActor
enum SettingsInfoBuilder {
    static func info(store: (any SessionStore)?, accounts: (any AccountStore)?, facts: SettingsFacts) -> SettingsInfo {
        let rows = facts.accountsReady
            ? accounts.map { accountRows($0, now: facts.now, calendar: facts.calendar, core: facts.coreAccounts) } ?? [] : []
        let sessions = store?.allSessions ?? []
        let live = sessions.filter { $0.state.isLive }
        let rc = live.filter { $0.remoteControl }
        return SettingsInfo(
            preferencesPath: facts.preferencesPath, dataRootPath: facts.dataRootPath, logPath: facts.logPath, savedAt: facts.savedAt,
            saveProblem: facts.saveProblem, loginItemStatus: facts.loginItemStatus, hotkeyError: facts.hotkeyError,
            profileNames: profileNames(facts.profiles), defaultProfileID: facts.profiles.defaultProfileId,
            groups: store.map(groups) ?? [], cswap: facts.cswap, accounts: rows,
            usageSources: accounts.map { usageSources($0, now: facts.now, ages: facts.includesAges) } ?? [],
            hooks: hooks(facts, now: facts.now), cleanupPeriodDays: facts.cleanupPeriodDays, rcCount: rc.count,
            rcTitles: rc.map(\.title).sorted(),
            versions: facts.versions.map { SettingsVersion(key: $0.key, value: $0.value) }, appVersion: VersionProbe.appShortVersion,
            platformLine: VersionProbe.platformLine, aliasRuleHint: CswapAlias.hint, externalSessionCount: facts.externalCount,
            waitingCount: sessions.filter { $0.state.needsAttention }.count, cleanupCandidateCount: facts.cleanupCount,
            accountsUnavailable: facts.accountsUnavailable, notebook: facts.notebook, condenseAccounts: facts.condenseAccounts,
            canOpenCleanup: facts.canOpenCleanup)
    }

    // MARK: Notebook & MCP (M4 I2a)

    /// The 筆記本 & MCP facts: the notes folder, the MCP line (`● 執行中 · n clients`), the hook
    /// port MCP shares (read only, D33), the masked token with `[輪替]` (D23), the registrations
    /// (D22, each button with why it is disabled) and the index line of the last rebuild.
    static func notebook(notesPath: String, mcp: MCPService?, hasMCPToken: Bool, lastRebuild: (count: Int, ms: Double)?, rebuilding: Bool,
                         notesReady: Bool, registration: MCPRegistrationService? = nil) -> SettingsNotebookInfo {
        var line: String?
        if rebuilding {
            line = "重建中…"
        } else if let lastRebuild {
            line = "已重建 · \(lastRebuild.count) 則 · " + String(format: "%.1f s", lastRebuild.ms / 1000)
        }
        return SettingsNotebookInfo(notesPath: notesPath, mcpRunning: mcp?.running ?? false, mcpClients: mcp?.clientCount ?? 0,
                                    port: mcp?.port.map(Int.init), tokenMasked: hasMCPToken ? "••••••••••••" : "",
                                    registrations: MCPRegistrationRows.settings(mcp?.claudeCode ?? .unknown,
                                                                                claudeCodeReason: registration?.claudeCodeReason ?? noServer,
                                                                                codexReason: registration?.codexReason ?? noServer,
                                                                                exposed: mcp?.claudeCodeExposed ?? false),
                                    indexLine: line, rebuilding: rebuilding, canOpenFolder: !notesPath.isEmpty,
                                    canRotateToken: registration?.canRotate ?? false, canRebuildIndex: notesReady)
    }

    /// The registration rows without a registration service (mock mode, rigs without a hook server).
    static let noServer = "MCP server 尚未啟動"

    /// `跟隨全域登入（#3 工作）` first, then cswap's accounts by number (D32).
    static func condenseAccounts(_ accounts: (any AccountStore)?) -> [SettingsCondenseAccount] {
        guard let accounts else { return [] }
        let follow = "跟隨全域登入" + (accounts.activeAccount.map { "（\($0.displayName)）" } ?? "")
        let list = accounts.accounts.filter { !$0.isPseudo }.sorted { (Int($0.id) ?? .max, $0.id) < (Int($1.id) ?? .max, $1.id) }
        return [SettingsCondenseAccount(id: SettingsCondenseAccount.followID, title: follow)]
            + list.map { SettingsCondenseAccount(id: $0.id, title: $0.displayName) }
    }

    // MARK: Profiles, groups

    /// `claude-default · claude`, `claude-plan · --permission-mode plan`, `zsh · shell`.
    static func profileNames(_ document: LaunchProfileDocument) -> [SettingsProfileName] {
        document.profiles.map { profile in
            let what: String
            switch profile.kind {
            case .shell: what = "shell"
            case .claude:
                var flags: [String] = []
                if let mode = profile.defaultPermissionMode { flags.append("--permission-mode \(mode.rawValue)") }
                if let model = profile.defaultModel { flags.append("--model \(model)") }
                flags += profile.extraArguments
                what = flags.isEmpty ? "claude" : flags.joined(separator: " ")
            }
            return SettingsProfileName(id: profile.id, title: "\(profile.name) · \(what)")
        }
    }

    /// 依群組靜音 chips in sidebar order (未分類 last, without a color).
    static func groups(_ store: any SessionStore) -> [SettingsGroup] {
        store.groups.map { group in
            SettingsGroup(id: group.id, name: group.isUngrouped ? "未分類" : group.name, color: group.isUngrouped ? nil : group.color?.color)
        }
    }

    // MARK: Accounts

    /// 帳號別名 rows in R7 order (cswap's accounts; the D4 pseudo account has no alias to edit).
    /// A target is eligible as `AutoSwitchPolicy` decides (not disabled, a usage status that
    /// allows it, both windows known); the page then applies the threshold being edited.
    static func accountRows(_ accounts: any AccountStore, now: Date, calendar: Calendar, core: [Account] = []) -> [SettingsAccountRow] {
        let engine = Dictionary(core.map { (String($0.number), $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.accounts.filter { !$0.isPseudo }.map { vm in
            let active = vm.id == accounts.activeAccountID
            let sessions: String
            if active {
                sessions = "\(vm.sessionCount) session"
            } else {
                let pinned = accounts.pinnedCount(for: vm.id)
                sessions = pinned > 0 ? "\(pinned) session 固定 · cswap run" : "0 session"
            }
            let reset = vm.week.resetsAt
            return SettingsAccountRow(
                id: vm.id, slot: vm.slot, alias: vm.alias, plan: vm.plan, fiveHour: quota(vm.fiveHour), weekly: quota(vm.week),
                resetIn: reset.map { DurationFormat.countdown(to: $0, now: now) } ?? "—",
                resetAt: reset.map { ClockFormat.resetLabel($0, now: now, calendar: calendar) } ?? "",
                sessions: sessions, isActive: active, canEditAlias: true,
                isEligibleTarget: engine[vm.id].map { AutoSwitchPolicy.isEligibleTarget($0, threshold: 0, now: now) }
                    ?? (!vm.isDisabled && vm.health != .reloginRequired))
        }
    }

    static func quota(_ window: QuotaWindow) -> SettingsQuota {
        guard window.known else { return SettingsQuota(remaining: nil, tone: .muted) }
        if !window.started { return SettingsQuota(remaining: 100, tone: .muted, text: "未開始") }
        return SettingsQuota(remaining: Double(window.remainingPercent), tone: StatusPageData.tone(window.tone))
    }

    /// 用量來源: `● #3 工作 statusline 的 rate_limits · 12s 前`, `○ #2 藍鵲 · #1 個人 cswap 快取 · 3m 前`.
    static func usageSources(_ accounts: any AccountStore, now: Date, ages: Bool = true) -> [SettingsUsageSource] {
        var lines: [SettingsUsageSource] = []
        for (source, glyph, label) in [("statusline", "●", "statusline 的 rate_limits"), ("cswap cache", "○", "cswap 快取")] {
            let members = accounts.accounts.filter { $0.source == source }
            guard !members.isEmpty else { continue }
            let newest = ages ? members.compactMap(\.sourceAt).max() : nil
            lines.append(SettingsUsageSource(glyph: glyph, accounts: members.map(\.displayName).joined(separator: " · "), source: label,
                                             age: newest.map { DurationFormat.ago($0, now: now) } ?? ""))
        }
        return lines
    }

    // MARK: HOOKS & STATUS

    static func hooks(_ facts: SettingsFacts, now: Date) -> SettingsHooksInfo {
        // What every CODD session's `--settings` carries: SessionStart (command) + the http events.
        let injected = Set(([.sessionStart] + ClaudeHookSettings.httpEvents).map(\.rawValue))
        let events = SettingsHooksInfo.eventNames.map { SettingsHookEvent(name: $0, installed: facts.injected && injected.contains($0)) }
        let hooksRow = SettingsHooksComponent(
            id: "hooks", part: "Hooks",
            status: facts.injected ? "● \(events.filter(\.installed).count) / \(events.count) · 每個 CODD session 自動注入"
                : "○ 0 / \(events.count) · hook 端點不是這個 CODD 的",
            statusTone: facts.injected ? .ok : .warn,
            hint: "CODD Desktop 不寫全域 hooks；每個 CODD session 啟動時注入全部 14 個事件。")
        let chip = facts.lastStatusLineAt.map { "最近收到資料 " + DurationFormat.ago($0, now: now) }
        switch facts.inspection {
        case .unknown:
            return SettingsHooksInfo(statusDir: facts.statusDir, statusDirDiffersFromDefault: facts.statusDirDiffers, components: [hooksRow],
                                     events: events, backups: facts.backups, canReinstall: false, canUninstall: false)
        case .failed(let reason):
            let row = SettingsHooksComponent(id: "statusline", part: "Statusline", status: "▲ 讀不到 settings.json", statusTone: .crit,
                                             hint: reason, chip: chip)
            return SettingsHooksInfo(statusDir: facts.statusDir, statusDirDiffersFromDefault: facts.statusDirDiffers,
                                     components: [hooksRow, row], events: events, backups: facts.backups, canReinstall: false,
                                     canUninstall: false)
        case .loaded(let inspection, _):
            var components = [hooksRow, statusLineRow(inspection, chip: chip)]
            if inspection.hasLegacy {
                components.append(SettingsHooksComponent(
                    id: "legacy", part: "Legacy", status: "◆ 偵測到 CODD web hooks", statusTone: .warn,
                    hint: "\(inspection.legacyHookEvents.count) 個事件上有 status-writer.js；CODD Desktop 不需要它們。",
                    buttons: [.init(title: "只移除舊版", action: .removeLegacy)]))
            }
            var desktop = false
            var outdated = false
            var web = false
            switch inspection.statusLine {
            case .coddDesktop(_, let current): desktop = true; outdated = !current
            case .coddWeb: web = true
            default: break
            }
            let pending = (inspection.hasLegacy || web ? 1 : 0) + (outdated ? 1 : 0)
            return SettingsHooksInfo(statusDir: facts.statusDir, statusDirDiffersFromDefault: facts.statusDirDiffers,
                                     components: components, events: events, foreignSummary: foreignSummary(inspection.foreign),
                                     backups: facts.backups, navTail: pending > 0 ? "◆ 更新" : nil,
                                     canReinstall: inspection.statusLine != .undecodable, canUninstall: desktop)
        }
    }

    /// The Statusline row for each D10 state.
    static func statusLineRow(_ inspection: ClaudeSettingsInspection, chip: String?) -> SettingsHooksComponent {
        let preview = SettingsHooksComponent.Button(title: "預覽變更", action: .previewChanges)
        func chain(_ command: String?) -> String {
            let chips = StatusPageData.chainChips(command)
            return chips.isEmpty ? "" : "（串接 " + chips.joined(separator: " → ") + "）"
        }
        switch inspection.statusLine {
        case .none:
            return SettingsHooksComponent(id: "statusline", part: "Statusline", status: "○ 未安裝", statusTone: .muted,
                                          hint: "沒有 statusline；安裝後 CODD 以外的 claude 也會回報用量。", chip: chip,
                                          buttons: [preview, .init(title: "安裝", action: .update, style: .primary)])
        case .user(let command):
            return SettingsHooksComponent(id: "statusline", part: "Statusline", status: "○ 未安裝", statusTone: .muted,
                                          hint: "目前是你自己的 statusline\(chain(command))；安裝後由 CODD Desktop 串接，終端機上的顯示不變。",
                                          chip: chip, buttons: [preview, .init(title: "安裝", action: .update, style: .primary)])
        case .coddWeb(let inner):
            return SettingsHooksComponent(id: "statusline", part: "Statusline", status: "◆ 需要更新", statusTone: .warn,
                                          hint: "目前是 CODD web 的 statusline\(chain(inner))；更新後改由 CODD Desktop 串接，終端機上的顯示不變。",
                                          chip: chip, buttons: [preview, .init(title: "更新", action: .update, style: .primary)])
        case .coddDesktop(let chained, true):
            return SettingsHooksComponent(id: "statusline", part: "Statusline", status: "● 已安裝", statusTone: .ok,
                                          hint: "CODD Desktop 的全域 statusline\(chain(chained))；CODD 以外的 claude 也會回報用量。",
                                          chip: chip, buttons: [preview, .init(title: "解除安裝", action: .uninstall, style: .danger)])
        case .coddDesktop(let chained, false):
            return SettingsHooksComponent(id: "statusline", part: "Statusline", status: "◆ 需要更新", statusTone: .warn,
                                          hint: "CODD Desktop 的 statusline\(chain(chained)) 不是這個 CODD 的版本；更新後指向這個資料根目錄。",
                                          chip: chip, buttons: [preview, .init(title: "更新", action: .update, style: .primary)])
        case .undecodable:
            return SettingsHooksComponent(id: "statusline", part: "Statusline", status: "▲ 無法解析", statusTone: .crit,
                                          hint: "statusLine 串接的指令無法解碼，CODD 不會改動它。", chip: chip)
        }
    }

    /// `外部 hooks 保持不動：hook-tap ×11 · osascript 通知 ×2` (nil without foreign hooks).
    static func foreignSummary(_ tools: [ForeignHookTool]) -> String? {
        guard !tools.isEmpty else { return nil }
        let parts = tools.map { tool in (tool.code == "osascript" ? "osascript 通知" : tool.code) + " ×\(tool.events.count)" }
        return "外部 hooks 保持不動：" + parts.joined(separator: " · ")
    }

    /// One backup row: `10/12 09:15 · 更新 hooks 與 statusline · 4.1 KB` (the reason from the D10 index).
    static func backupRow(_ backup: SettingsBackup, reason: String?, calendar: Calendar = .current) -> SettingsBackupRow {
        let parts = calendar.dateComponents([.month, .day], from: backup.date)
        let day = String(format: "%02d/%02d", parts.month ?? 0, parts.day ?? 0)
        let hint = [day + " " + ClockFormat.hourMinute(backup.date, calendar: calendar), reason, size(backup.size)]
            .compactMap { $0 }.joined(separator: " · ")
        let name = backup.url.lastPathComponent
        return SettingsBackupRow(id: name, name: name, hint: hint, label: day)
    }

    /// `4.1 KB`, `812 B`, `1.2 MB`.
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
