import AppKit
import CoddUI

/// Read-only facts the Settings page shows, set by the app (never edited by the page). Every
/// string is already formatted (`3d01h後`, `10/18 週日 12:00`, `statusline · 12s 前`); there are
/// no CoddCore types, so the app maps its own data in (integration step I3).
public struct SettingsInfo: Equatable {
    /// Footer: `<dataRoot>/preferences.json` (abbreviated with `~`).
    public var preferencesPath: String
    /// ADVANCED › 資料庫: the data root (abbreviated).
    public var dataRootPath: String
    /// ADVANCED › 紀錄檔 (nil: `—`).
    public var logPath: String?
    /// Footer `Saved ● 變更即時儲存 · hh:mm`: the last successful save (nil: no time shown).
    public var savedAt: Date?
    /// Footer problem instead of `變更即時儲存` (a newer preferences.json is read-only, a failed
    /// save): shown as `▲ <text>`.
    public var saveProblem: String?
    /// GENERAL › 登入時啟動 status under the hint (D21: `請到 系統設定 › 一般 › 登入項目 允許`,
    /// `測試資料根目錄不會註冊登入項目`, a refusal from SMAppService).
    public var loginItemStatus: String?
    /// GENERAL › 全域快捷鍵 failure under the row (D22: `⌥ Space 已被其他 App 使用，請改用別的組合鍵`).
    public var hotkeyError: String?
    /// SESSIONS › 預設啟動設定檔 options (`claude-default · claude`).
    public var profileNames: [SettingsProfileName]
    public var defaultProfileID: String?
    /// NOTIFICATIONS › 依群組靜音 chips, in sidebar order (an ungrouped entry has no color).
    public var groups: [SettingsGroup]
    public var cswap: SettingsCswapInfo
    /// ACCOUNTS › 帳號別名 rows, in R7 order (soonest weekly reset first).
    public var accounts: [SettingsAccountRow]
    /// Why cswap's state files cannot be used (`sequence.json 無法解析`); nil when they can. The
    /// alias card then ends with D1's notice and `重新讀取`, the only Settings action that may
    /// fall back to `cswap list` (which queries usage once).
    public var accountsUnavailable: String?
    /// ACCOUNTS › 即時預覽 when the app computes it; empty = the page derives it from `accounts`
    /// and the current preferences (`SettingsAutoSwitchPreview`), so it follows every edit at once.
    public var autoSwitchPreview: [SettingsPreviewRow]
    public var autoSwitchCurrent: String
    public var autoSwitchNext: String
    public var autoSwitchNote: String
    /// ACCOUNTS › 用量來源 lines.
    public var usageSources: [SettingsUsageSource]
    public var hooks: SettingsHooksInfo
    /// CLEANUP › cleanupPeriodDays chip (Claude Code's own setting; nil = not set, Claude's 30).
    public var cleanupPeriodDays: Int?
    /// REMOTE: live sessions with Remote Control and their titles.
    public var rcCount: Int
    public var rcTitles: [String]
    /// ABOUT versions grid (D28: App, macOS, Claude Code, cswap, libghostty).
    public var versions: [SettingsVersion]
    /// ABOUT chip and the nav tail (`1.0.0`).
    public var appVersion: String
    /// ABOUT hint next to the version chip.
    public var platformLine: String
    /// D34: shown inline when an alias does not follow cswap's rule.
    public var aliasRuleHint: String
    /// SESSIONS › 外部 session hint `（目前 n 個）` (nil: not shown).
    public var externalSessionCount: Int?
    /// NOTIFICATIONS › Dock 徽章 hint `，目前 n` (nil: not shown).
    public var waitingCount: Int?
    /// CLEANUP head button `查看清理建議 · n →` (nil: `查看清理建議 →`, before the engine counted).
    public var cleanupCandidateCount: Int?
    /// CLEANUP head button pressable (`SettingsActions.openCleanup`): false until the app has the
    /// Cleanup page (integration I4a), so an older caller's button is drawn disabled, not dead.
    public var canOpenCleanup: Bool
    /// NOTEBOOK & MCP and ADVANCED › 重建筆記索引 facts (M4). The default is the neutral
    /// ``SettingsNotebookInfo/unavailable``: `—` values, buttons disabled.
    public var notebook: SettingsNotebookInfo
    /// CLEANUP › 交給 Claude 濃縮 account select, in menu order (`跟隨全域登入（#3 工作）`, `#1 個人`,
    /// …). The select stores the picked `id` in `cleanup.condenseAccount`; a nil preference shows
    /// the first entry. Empty: the select shows `—` and is disabled.
    public var condenseAccounts: [SettingsCondenseAccount]

    public init(preferencesPath: String = "", dataRootPath: String = "", logPath: String? = nil, savedAt: Date? = nil,
                saveProblem: String? = nil, loginItemStatus: String? = nil, hotkeyError: String? = nil,
                profileNames: [SettingsProfileName] = [], defaultProfileID: String? = nil, groups: [SettingsGroup] = [],
                cswap: SettingsCswapInfo = SettingsCswapInfo(), accounts: [SettingsAccountRow] = [],
                autoSwitchPreview: [SettingsPreviewRow] = [], autoSwitchCurrent: String = "", autoSwitchNext: String = "",
                autoSwitchNote: String = "", usageSources: [SettingsUsageSource] = [], hooks: SettingsHooksInfo = SettingsHooksInfo(),
                cleanupPeriodDays: Int? = nil, rcCount: Int = 0, rcTitles: [String] = [], versions: [SettingsVersion] = [],
                appVersion: String = "", platformLine: String = "macOS · Apple Silicon", aliasRuleHint: String = AliasRule.hint,
                externalSessionCount: Int? = nil, waitingCount: Int? = nil, cleanupCandidateCount: Int? = nil,
                accountsUnavailable: String? = nil, notebook: SettingsNotebookInfo = .unavailable,
                condenseAccounts: [SettingsCondenseAccount] = [], canOpenCleanup: Bool = false) {
        self.preferencesPath = preferencesPath
        self.dataRootPath = dataRootPath
        self.logPath = logPath
        self.savedAt = savedAt
        self.saveProblem = saveProblem
        self.loginItemStatus = loginItemStatus
        self.hotkeyError = hotkeyError
        self.profileNames = profileNames
        self.defaultProfileID = defaultProfileID
        self.groups = groups
        self.cswap = cswap
        self.accounts = accounts
        self.autoSwitchPreview = autoSwitchPreview
        self.autoSwitchCurrent = autoSwitchCurrent
        self.autoSwitchNext = autoSwitchNext
        self.autoSwitchNote = autoSwitchNote
        self.usageSources = usageSources
        self.hooks = hooks
        self.cleanupPeriodDays = cleanupPeriodDays
        self.rcCount = rcCount
        self.rcTitles = rcTitles
        self.versions = versions
        self.appVersion = appVersion
        self.platformLine = platformLine
        self.aliasRuleHint = aliasRuleHint
        self.externalSessionCount = externalSessionCount
        self.waitingCount = waitingCount
        self.cleanupCandidateCount = cleanupCandidateCount
        self.accountsUnavailable = accountsUnavailable
        self.notebook = notebook
        self.condenseAccounts = condenseAccounts
        self.canOpenCleanup = canOpenCleanup
    }
}

// MARK: - NOTEBOOK & MCP (M4, D21–D23, D33)

/// NOTEBOOK & MCP › 註冊: one other app CODD's MCP server can be registered into (D22).
public struct SettingsMCPRegistration: Equatable, Sendable, Identifiable {
    /// What `SettingsActions.mcpRegistration` receives: `claude-code`, `codex`, `claude-desktop`.
    public var id: String
    /// `Claude Code` (cream).
    public var name: String
    /// `已註冊 · user scope`, `未註冊`, `需要重新註冊（token 已輪替）`, `未安裝`.
    public var hint: String
    /// `●` (success) when registered, else `○` (dimmer).
    public var isOn: Bool
    /// `移除`, `註冊`, `安裝 .mcpb`; nil = no button.
    public var actionTitle: String?
    public var actionEnabled: Bool
    /// `.btn.accent` (註冊, 安裝 .mcpb) instead of the plain look (移除).
    public var accent: Bool
    /// A milestone chip before the button (`FUTURE`); the button is then disabled whatever
    /// `actionEnabled` says.
    public var chip: String?
    /// The button's tooltip (why it is disabled: `註冊在 I2b 接上`, `測試資料根目錄不會寫入 ~/.claude.json`).
    public var toolTip: String?

    public init(id: String, name: String, hint: String, isOn: Bool = false, actionTitle: String? = nil, actionEnabled: Bool = true,
                accent: Bool = false, chip: String? = nil, toolTip: String? = nil) {
        self.id = id
        self.name = name
        self.hint = hint
        self.isOn = isOn
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
        self.accent = accent
        self.chip = chip
        self.toolTip = toolTip
    }

    /// The button can be pressed.
    public var isActionable: Bool { actionTitle != nil && actionEnabled && chip == nil }
}

/// The notebook and MCP facts the Settings page shows (NOTEBOOK & MCP, ADVANCED › 重建筆記索引).
/// Everything is formatted already; the token arrives masked, never in clear.
public struct SettingsNotebookInfo: Equatable, Sendable {
    /// `<dataRoot>/notes` abbreviated with `~` (位置 hint `<path> · 每則筆記是一個 .md 檔`); empty: `—`.
    public var notesPath: String
    /// The MCP endpoint and handler run (group head `● 執行中 · n clients`, else `○ 未執行`).
    public var mcpRunning: Bool
    /// D21's client count.
    public var mcpClients: Int
    /// The hook server's port, which MCP shares (D33), shown read-only; nil = `—`.
    public var port: Int?
    /// `••••••••••••` (never the token itself); empty: `—`.
    public var tokenMasked: String
    /// The 註冊 box rows, in the artboard's order (Claude Code, Codex, Claude Desktop). Empty:
    /// the three names with `—` and no buttons.
    public var registrations: [SettingsMCPRegistration]
    /// ADVANCED › 重建筆記索引 line under the hint (`已重建 · 128 則 · 0.4 s`, `重建中…`); nil = none.
    public var indexLine: String?
    /// A rebuild runs: `[重建]` is disabled.
    public var rebuilding: Bool
    /// `[開啟筆記本資料夾]` pressable (`SettingsActions.openNotesFolder`).
    public var canOpenFolder: Bool
    /// `[輪替]` pressable (`SettingsActions.rotateMCPToken`; D23).
    public var canRotateToken: Bool
    /// `[重建]` pressable when not `rebuilding` (`SettingsActions.rebuildNotesIndex`).
    public var canRebuildIndex: Bool

    public init(notesPath: String, mcpRunning: Bool = false, mcpClients: Int = 0, port: Int? = nil, tokenMasked: String = "",
                registrations: [SettingsMCPRegistration] = [], indexLine: String? = nil, rebuilding: Bool = false,
                canOpenFolder: Bool = true, canRotateToken: Bool = true, canRebuildIndex: Bool = true) {
        self.notesPath = notesPath
        self.mcpRunning = mcpRunning
        self.mcpClients = mcpClients
        self.port = port
        self.tokenMasked = tokenMasked
        self.registrations = registrations
        self.indexLine = indexLine
        self.rebuilding = rebuilding
        self.canOpenFolder = canOpenFolder
        self.canRotateToken = canRotateToken
        self.canRebuildIndex = canRebuildIndex
    }

    /// Before the app has a notes service (M3 callers, `SettingsInfo()`): every value `—`, MCP
    /// `○ 未執行`, every button disabled.
    public static let unavailable = SettingsNotebookInfo(notesPath: "", canOpenFolder: false, canRotateToken: false,
                                                         canRebuildIndex: false)

    /// `[重建]` can be pressed now.
    public var rebuildEnabled: Bool { canRebuildIndex && !rebuilding }
}

/// CLEANUP › 交給 Claude 濃縮: one entry of the account select (D32).
public struct SettingsCondenseAccount: Equatable, Sendable, Identifiable {
    /// Stored in `cleanup.condenseAccount`: `follow` (跟隨全域登入) or a cswap number (`"3"`).
    public var id: String
    /// `跟隨全域登入（#3 工作）`, `#1 個人`.
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// The id of 跟隨全域登入.
    public static let followID = "follow"
}

/// One launch profile for the 預設啟動設定檔 select.
public struct SettingsProfileName: Equatable, Sendable, Identifiable {
    public var id: String
    /// `claude-default · claude`.
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One sidebar group for 依群組靜音 (`color` nil: the dashed 未分類 square).
public struct SettingsGroup: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var color: NSColor?

    public init(id: String, name: String, color: NSColor?) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// ACCOUNTS › cswap 路徑 chip: `● v0.26.0`, `▲ 需 ≥ 0.26`, `▲ 找不到`.
public struct SettingsCswapInfo: Equatable, Sendable {
    /// The configured (or default) cswap executable exists.
    public var pathOK: Bool
    /// `0.26.0`, nil when not read (yet).
    public var version: String?
    /// ≥ 0.26 (D3).
    public var versionOK: Bool
    /// D13 background-tool warning (`! cswap menubar 也在執行，兩邊可能同時切換`), or another
    /// reader problem, shown under the auto-switch card.
    public var warning: String?
    /// Placeholder of the path field when `accounts.cswapPath` is nil.
    public var defaultPath: String
    /// CODD is still looking for cswap (the first look after launch captures the login shell's
    /// PATH, which can take seconds): no verdict yet, so neither `▲ 找不到` nor the install guide.
    public var locating: Bool

    public init(pathOK: Bool = false, version: String? = nil, versionOK: Bool = false, warning: String? = nil,
                defaultPath: String = "~/.local/bin/cswap", locating: Bool = false) {
        self.pathOK = pathOK
        self.version = version
        self.versionOK = versionOK
        self.warning = warning
        self.defaultPath = defaultPath
        self.locating = locating
    }
}

/// One quota window of an account row (remaining %, already toned).
public struct SettingsQuota: Equatable, Sendable {
    /// Remaining 0...100; nil = unknown (`—`).
    public var remaining: Double?
    public var tone: Tone
    /// Replaces the `98%` value text (`未開始` for a 5h window that has not started).
    public var text: String?

    public init(remaining: Double?, tone: Tone? = nil, text: String? = nil) {
        self.remaining = remaining
        self.tone = tone ?? Tone.tone(forRemaining: remaining)
        self.text = text
    }

    /// The value as drawn: `text`, else `91%`, else `—`.
    public var valueText: String {
        if let text { return text }
        guard let remaining, remaining.isFinite else { return "—" }
        return "\(Int(min(100, max(0, remaining)).rounded()))%"
    }
}

/// ACCOUNTS › 帳號別名: one cswap account (R7 order is the array order).
public struct SettingsAccountRow: Equatable, Sendable, Identifiable {
    /// The cswap number as a string (`"3"`): what `SettingsActions.setAlias` receives.
    public var id: String
    /// `#3`.
    public var slot: String
    /// cswap's alias as it is (CJK aliases already in `sequence.json` included).
    public var alias: String
    /// `MAX 20x` (D25); nil = no chip.
    public var plan: String?
    public var fiveHour: SettingsQuota
    public var weekly: SettingsQuota
    /// `3d01h後` (the 1w reset countdown, the sort key).
    public var resetIn: String
    /// `10/18 週日 12:00`.
    public var resetAt: String
    /// `12 session`, `1 session 固定 · cswap run`, `0 session`.
    public var sessions: String
    public var isActive: Bool
    /// The pseudo `default` account (D4) has no cswap alias.
    public var canEditAlias: Bool
    /// Auto-switch may pick it (not disabled, no relogin needed).
    public var isEligibleTarget: Bool

    public init(id: String, slot: String, alias: String, plan: String? = nil, fiveHour: SettingsQuota, weekly: SettingsQuota,
                resetIn: String = "", resetAt: String = "", sessions: String = "", isActive: Bool = false, canEditAlias: Bool = true,
                isEligibleTarget: Bool = true) {
        self.id = id
        self.slot = slot
        self.alias = alias
        self.plan = plan
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.resetIn = resetIn
        self.resetAt = resetAt
        self.sessions = sessions
        self.isActive = isActive
        self.canEditAlias = canEditAlias
        self.isEligibleTarget = isEligibleTarget
    }
}

/// ACCOUNTS › 即時預覽: one account with its distance to the threshold.
public struct SettingsPreviewRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var slot: String
    public var alias: String
    /// `3d01h後`.
    public var resetIn: String
    /// `1w 15% · 距切換 13%`, `5h 未開始 · 距切換 98%`, `1w 2% · 已達門檻`, `未檢查任何視窗`.
    public var distance: String
    /// nil = bone, `.warn` amber (≤ 15 points), `.crit` danger (reached).
    public var distanceTone: Tone?
    public var isActive: Bool
    public var isNext: Bool
    public var fiveHour: SettingsQuota
    public var weekly: SettingsQuota
    /// Threshold ticks on the bars (the window is checked).
    public var tickFiveHour: Bool
    public var tickWeekly: Bool

    public init(id: String, slot: String, alias: String, resetIn: String, distance: String, distanceTone: Tone? = nil,
                isActive: Bool = false, isNext: Bool = false, fiveHour: SettingsQuota, weekly: SettingsQuota,
                tickFiveHour: Bool = true, tickWeekly: Bool = true) {
        self.id = id
        self.slot = slot
        self.alias = alias
        self.resetIn = resetIn
        self.distance = distance
        self.distanceTone = distanceTone
        self.isActive = isActive
        self.isNext = isNext
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.tickFiveHour = tickFiveHour
        self.tickWeekly = tickWeekly
    }
}

/// ACCOUNTS › 用量來源: `● #3 工作 statusline 的 rate_limits · 12s 前`.
public struct SettingsUsageSource: Equatable, Sendable {
    /// `●` (live status line: green glyph, amber accounts) or `○` (cache: dimmer glyph, cyan accounts).
    public var glyph: String
    /// `#2 藍鵲 · #1 個人`.
    public var accounts: String
    /// `statusline 的 rate_limits`, `cswap 快取`.
    public var source: String
    /// `12s 前`.
    public var age: String

    public init(glyph: String, accounts: String, source: String, age: String) {
        self.glyph = glyph
        self.accounts = accounts
        self.source = source
        self.age = age
    }
}

/// HOOKS & STATUS facts (D10): the status dir, the installer's parts, the events, backups.
public struct SettingsHooksInfo: Equatable, Sendable {
    public var statusDir: String
    /// The `! 與預設不同` chip.
    public var statusDirDiffersFromDefault: Bool
    /// `Hooks` / `Statusline` / `Legacy` rows.
    public var components: [SettingsHooksComponent]
    /// The 14 events with their state (`●` installed / injected, `◆` missing).
    public var events: [SettingsHookEvent]
    /// `外部 hooks 保持不動：hook-tap ×11 · osascript 通知 ×2` (nil: no line).
    public var foreignSummary: String?
    /// `settings.json.codd-bak-…` rows, newest first.
    public var backups: [SettingsBackupRow]
    /// Nav tail (`◆ 更新`, amber) when something needs attention.
    public var navTail: String?
    /// The head buttons `重新安裝` / `解除安裝`.
    public var canReinstall: Bool
    public var canUninstall: Bool

    public init(statusDir: String = "", statusDirDiffersFromDefault: Bool = false, components: [SettingsHooksComponent] = [],
                events: [SettingsHookEvent] = [], foreignSummary: String? = nil, backups: [SettingsBackupRow] = [],
                navTail: String? = nil, canReinstall: Bool = true, canUninstall: Bool = true) {
        self.statusDir = statusDir
        self.statusDirDiffersFromDefault = statusDirDiffersFromDefault
        self.components = components
        self.events = events
        self.foreignSummary = foreignSummary
        self.backups = backups
        self.navTail = navTail
        self.canReinstall = canReinstall
        self.canUninstall = canUninstall
    }

    /// The 14 hook events CODD injects, in the artboard's chip order.
    public static let eventNames = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                                    "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop", "PreCompact",
                                    "PostCompact", "Stop", "StopFailure", "SessionEnd"]
}

/// What a HOOKS component button does (mapped to `SettingsActions`).
public enum SettingsHooksAction: Sendable, Equatable {
    /// `預覽變更` → `openHookDiff`.
    case previewChanges
    /// `更新` → `reinstallHooks`.
    case update
    /// `只移除舊版` → `removeLegacy`.
    case removeLegacy
    /// `解除安裝` → `uninstallHooks`.
    case uninstall
}

/// One component row: `Hooks ● 14 / 14 · 每個 CODD session 自動注入`.
public struct SettingsHooksComponent: Equatable, Sendable, Identifiable {
    public enum ButtonStyle: Sendable, Equatable { case normal, primary, danger }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: SettingsHooksAction
        public var style: ButtonStyle
        public var isEnabled: Bool

        public init(title: String, action: SettingsHooksAction, style: ButtonStyle = .normal, isEnabled: Bool = true) {
            self.title = title
            self.action = action
            self.style = style
            self.isEnabled = isEnabled
        }
    }

    /// `hooks`, `statusline`, `legacy`.
    public var id: String
    /// `Hooks` (drawn in caps).
    public var part: String
    /// `● 已安裝`, `◆ 需要更新`, `○ 未偵測到`.
    public var status: String
    /// Status color: ok green, warn amber, crit danger, muted dimmer.
    public var statusTone: Tone
    public var hint: String
    /// `最近收到資料 8s 前`.
    public var chip: String?
    public var buttons: [Button]

    public init(id: String, part: String, status: String, statusTone: Tone, hint: String, chip: String? = nil, buttons: [Button] = []) {
        self.id = id
        self.part = part
        self.status = status
        self.statusTone = statusTone
        self.hint = hint
        self.chip = chip
        self.buttons = buttons
    }
}

/// One hook event chip.
public struct SettingsHookEvent: Equatable, Sendable {
    public var name: String
    public var installed: Bool

    public init(name: String, installed: Bool) {
        self.name = name
        self.installed = installed
    }
}

/// One backup of the user's Claude settings.
public struct SettingsBackupRow: Equatable, Sendable, Identifiable {
    /// What `compareBackup` / `restoreBackup` receive.
    public var id: String
    /// `settings.json.codd-bak-20261012-091503`.
    public var name: String
    /// `10/12 09:15 · 安裝 statusline · 4.1 KB`.
    public var hint: String
    /// `10/12` for the buttons' accessibility labels (`比較 10/12 備份差異`).
    public var label: String

    public init(id: String, name: String, hint: String, label: String) {
        self.id = id
        self.name = name
        self.hint = hint
        self.label = label
    }
}

/// ABOUT versions grid cell.
public struct SettingsVersion: Equatable, Sendable {
    /// `Claude Code` (drawn in caps).
    public var key: String
    /// `2.1.302`.
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
