import Foundation

/// Every Settings row of the approved v3 artboard (`design/artboards-src/Settings.src.html`),
/// stored in `<dataRoot>/preferences.json` by ``PreferencesStore`` (M3 D14).
///
/// Defaults are the artboard's (its `SW` / `SG` / `CB` tables and the first option of each select)
/// with the D15 exceptions: 登入時啟動 OFF, CRT OFF, 依群組靜音 empty. Rows of later milestones
/// (D17: update channel, logs, …) are stored all the same so their values survive until the
/// feature exists; the notebook, MCP and cleanup rows are live since M4 (D33). Locked rows (`自動加上 --session-id`, `App 重開後恢復`) are
/// stored ON; the app does not offer turning them off.
///
/// Option lists (`…Options`) are in the artboard's order, which puts the default first.
public struct CoddPreferences: Sendable, Equatable {
    public static let currentVersion = 1

    /// The schema version of this model. Always ``currentVersion`` once decoded and always written
    /// as ``currentVersion``; a file from a newer CODD is reported by ``PreferencesStore/Origin``.
    public var version: Int
    public var general: General
    public var appearance: Appearance
    public var sessions: Sessions
    public var notifications: Notifications
    public var accounts: Accounts
    public var notebook: Notebook
    public var cleanup: Cleanup
    public var shortcuts: Shortcuts
    public var advanced: Advanced
    public var about: About

    public init(
        version: Int = CoddPreferences.currentVersion, general: General = General(), appearance: Appearance = Appearance(),
        sessions: Sessions = Sessions(), notifications: Notifications = Notifications(), accounts: Accounts = Accounts(),
        notebook: Notebook = Notebook(), cleanup: Cleanup = Cleanup(), shortcuts: Shortcuts = Shortcuts(),
        advanced: Advanced = Advanced(), about: About = About()
    ) {
        self.version = version
        self.general = general
        self.appearance = appearance
        self.sessions = sessions
        self.notifications = notifications
        self.accounts = accounts
        self.notebook = notebook
        self.cleanup = cleanup
        self.shortcuts = shortcuts
        self.advanced = advanced
        self.about = about
    }

    /// What a fresh data root starts with (and each section's `還原本頁預設`).
    public static let defaults = CoddPreferences()

    // MARK: - 01 GENERAL

    public struct General: Sendable, Equatable {
        /// D15: OFF (the artboard shows ON); a system login item is registered only after the user
        /// flips it, and only on the standard data root (D21).
        public var launchAtLogin: Bool
        public var showInDock: Bool
        public var keepInMenuBarOnClose: Bool
        /// D18: 詢問 / 全部停止 / 保留.
        public var quitBehavior: QuitBehavior
        /// D22: ⌥Space; registered only on the standard data root.
        public var hotkey: Hotkey
        /// Where 新增專案 and folder pickers start; `~` is expanded by the caller.
        public var projectRoot: String
        /// D17: persisted but the row is disabled `M5` (only the 繁體中文 copy exists).
        public var language: Language

        public init(
            launchAtLogin: Bool = false, showInDock: Bool = true, keepInMenuBarOnClose: Bool = true,
            quitBehavior: QuitBehavior = .ask, hotkey: Hotkey = Hotkey(), projectRoot: String = "~/Github",
            language: Language = .zhHant
        ) {
            self.launchAtLogin = launchAtLogin
            self.showInDock = showInDock
            self.keepInMenuBarOnClose = keepInMenuBarOnClose
            self.quitBehavior = quitBehavior
            self.hotkey = hotkey
            self.projectRoot = projectRoot
            self.language = language
        }
    }

    /// D18 結束時.
    public enum QuitBehavior: String, Sendable, CaseIterable, Codable {
        /// 詢問: dialog D when at least one CODD session runs.
        case ask
        /// 全部停止: stop every live session and shell tab, then quit.
        case stopAll
        /// 保留 (保留在選單列): ⌘Q closes the window instead.
        case keep
    }

    /// 繁體中文 / English / 跟隨系統.
    public enum Language: String, Sendable, CaseIterable, Codable {
        case zhHant, english, system
    }

    /// The global hotkey in Carbon terms, so the app registers it without conversion.
    public struct Hotkey: Sendable, Equatable {
        public var enabled: Bool
        /// Carbon virtual key code (`kVK_Space` = 49).
        public var keyCode: UInt32
        /// Carbon modifier mask (`optionKey` = 2048, `cmdKey` 256, `shiftKey` 512, `controlKey` 4096).
        public var modifiers: UInt32
        /// What the row shows (`⌥ Space`), written by the recorder with the combo.
        public var display: String

        public init(enabled: Bool = true, keyCode: UInt32 = 49, modifiers: UInt32 = 2048, display: String = "⌥ Space") {
            self.enabled = enabled
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display
        }
    }

    // MARK: - 02 APPEARANCE

    public struct Appearance: Sendable, Equatable {
        /// D15: OFF (the M1 look, no extra overlay cost); the artboard shows SUBTLE.
        public var crt: CRT
        /// D17: `M5`.
        public var density: Density
        /// The interface zoom (M4): every CODD UI text and the lengths tied to it, 13 = the design
        /// size. Clamped to ``uiFontSizeRange``; ⌘+ / ⌘− step it with ``terminalFontSize``.
        public var uiFontSize: Int
        /// One of ``terminalFontOptions``.
        public var terminalFont: String
        /// Clamped to ``terminalFontSizeRange`` (the A− / A+ stepper, ⌘+ / ⌘− with the UI size).
        public var terminalFontSize: Int
        /// D17: `M5`.
        public var nativeVibrancy: Bool
        public var reduceMotion: ReduceMotion
        /// The net change ⌘+ / ⌘− made to ``terminalFontSize`` (A− / A+ and Settings never touch
        /// it): 實際大小 ⌘0 takes exactly that back, so a 終端機字級 the user chose survives it.
        public var zoomTerminalSteps: Int

        /// UI 字級 10–20 (M4 interface zoom; 13 is the design size).
        public static let uiFontSizeRange = 10...20
        /// The UI 字級 select's items, ascending.
        public static var uiFontSizeOptions: [Int] { Array(uiFontSizeRange) }
        public static let terminalFontOptions = ["JetBrains Mono", "SF Mono", "Menlo"]
        public static let terminalFontSizeRange = 8...28
        /// The terminal range's span either way.
        public static let zoomTerminalStepsRange = -20...20

        public init(
            crt: CRT = .off, density: Density = .compact, uiFontSize: Int = 13, terminalFont: String = "JetBrains Mono",
            terminalFontSize: Int = 13, nativeVibrancy: Bool = false, reduceMotion: ReduceMotion = .system, zoomTerminalSteps: Int = 0
        ) {
            self.crt = crt
            self.density = density
            self.uiFontSize = uiFontSize
            self.terminalFont = terminalFont
            self.terminalFontSize = terminalFontSize
            self.nativeVibrancy = nativeVibrancy
            self.reduceMotion = reduceMotion
            self.zoomTerminalSteps = zoomTerminalSteps
        }
    }

    /// CRT 效果 Full / Subtle / Off.
    public enum CRT: String, Sendable, CaseIterable, Codable {
        case full, subtle, off
    }

    /// 介面密度 Compact (38 px rows) / Comfort (46 px).
    public enum Density: String, Sendable, CaseIterable, Codable {
        case compact, comfort
    }

    /// 減少動態 跟隨系統 / 開啟 / 關閉.
    public enum ReduceMotion: String, Sendable, CaseIterable, Codable {
        case system, on, off
    }

    // MARK: - 03 SESSIONS

    public struct Sessions: Sendable, Equatable {
        /// Locked ON (D17: `CODD 需要它對應 hook`).
        public var autoSessionId: Bool
        /// NO HOOK 警示, one of ``noHookWarningOptions``.
        public var noHookWarningSeconds: Int
        /// STALE 判定, one of ``staleAfterOptions``; nil = 永不. DEBUG `-codd-stale-after` wins for a run.
        public var staleAfterSeconds: Int?
        /// Locked ON (D17: `CODD 一律這樣做`).
        public var restoreAsStopped: Bool
        public var externalDisplay: ExternalDisplay
        public var hideSDKAndDesktop: Bool

        public static let noHookWarningOptions = [20, 10, 60]
        /// 1 小時 / 30 分鐘 / 4 小時 / 永不.
        public static let staleAfterOptions: [Int?] = [3600, 1800, 14400, nil]

        public init(
            autoSessionId: Bool = true, noHookWarningSeconds: Int = 20, staleAfterSeconds: Int? = 3600,
            restoreAsStopped: Bool = true, externalDisplay: ExternalDisplay = .project, hideSDKAndDesktop: Bool = true
        ) {
            self.autoSessionId = autoSessionId
            self.noHookWarningSeconds = noHookWarningSeconds
            self.staleAfterSeconds = staleAfterSeconds
            self.restoreAsStopped = restoreAsStopped
            self.externalDisplay = externalDisplay
            self.hideSDKAndDesktop = hideSDKAndDesktop
        }
    }

    /// 外部 session 顯示在專案下 / Detected 區 / 不顯示.
    public enum ExternalDisplay: String, Sendable, CaseIterable, Codable {
        case project, detected, hidden
    }

    // MARK: - 05 NOTIFICATIONS

    /// D29: the event matrix, 勿擾, muted groups and badges.
    public struct Notifications: Sendable, Equatable {
        public var waiting: EventRule
        public var error: EventRule
        public var done: EventRule
        /// EXITED with a non-zero exit code.
        public var exitedNonZero: EventRule
        public var quietHours: QuietHours
        /// D15: empty (the artboard's CODD chip is sample data). Muted groups never notify but
        /// still show in NEEDS YOU.
        public var mutedGroupIDs: [String]
        public var dockBadge: DockBadge
        /// D23: `圖示 + 數字` adds the `◆2 ▲1` title.
        public var menuBarIcon: MenuBarIcon
        /// D23 `暫停通知 1 小時`: banners and sounds are silenced until then; badges still update.
        public var pausedUntil: Date?

        public init(
            waiting: EventRule = EventRule(condition: .always, notify: true, sound: true),
            error: EventRule = EventRule(condition: .always, notify: true, sound: true),
            done: EventRule = EventRule(condition: .unfocusedOnly, notify: true, sound: false),
            exitedNonZero: EventRule = EventRule(condition: .always, notify: true, sound: false),
            quietHours: QuietHours = QuietHours(), mutedGroupIDs: [String] = [], dockBadge: DockBadge = .waiting,
            menuBarIcon: MenuBarIcon = .iconOnly, pausedUntil: Date? = nil
        ) {
            self.waiting = waiting
            self.error = error
            self.done = done
            self.exitedNonZero = exitedNonZero
            self.quietHours = quietHours
            self.mutedGroupIDs = mutedGroupIDs
            self.dockBadge = dockBadge
            self.menuBarIcon = menuBarIcon
            self.pausedUntil = pausedUntil
        }
    }

    /// One row of the event matrix: 條件 × 通知 × 聲音.
    public struct EventRule: Sendable, Equatable {
        public var condition: NotifyCondition
        public var notify: Bool
        public var sound: Bool

        public init(condition: NotifyCondition = .always, notify: Bool = true, sound: Bool = true) {
            self.condition = condition
            self.notify = notify
            self.sound = sound
        }
    }

    /// 一律通知 / 僅在未聚焦時 (CODD not active or the session not shown).
    public enum NotifyCondition: String, Sendable, CaseIterable, Codable {
        case always, unfocusedOnly
    }

    /// 勿擾時段 in local time; `start` after `end` spans midnight (the default 23:00–08:00).
    public struct QuietHours: Sendable, Equatable {
        public var enabled: Bool
        /// `HH:mm`.
        public var start: String
        /// `HH:mm`.
        public var end: String

        public init(enabled: Bool = true, start: String = "23:00", end: String = "08:00") {
            self.enabled = enabled
            self.start = start
            self.end = end
        }
    }

    /// Dock 徽章 等待數 (waiting + error) / 全部 (live) / 關.
    public enum DockBadge: String, Sendable, CaseIterable, Codable {
        case waiting, all, off
    }

    /// 選單列圖示 僅圖示 / 圖示 + 數字.
    public enum MenuBarIcon: String, Sendable, CaseIterable, Codable {
        case iconOnly, iconAndCounts
    }

    // MARK: - 06 ACCOUNTS

    public struct Accounts: Sendable, Equatable {
        /// nil = `~/.local/bin/cswap` on the standard root (the field shows that path).
        public var cswapPath: String?
        public var confirmBeforeSwitch: Bool
        public var autoSwitch: AutoSwitch

        public init(cswapPath: String? = nil, confirmBeforeSwitch: Bool = false, autoSwitch: AutoSwitch = AutoSwitch()) {
            self.cswapPath = cswapPath
            self.confirmBeforeSwitch = confirmBeforeSwitch
            self.autoSwitch = autoSwitch
        }
    }

    /// R8 剩餘不足時自動切換 (default OFF).
    public struct AutoSwitch: Sendable, Equatable {
        public var enabled: Bool
        /// 剩餘 ≤ this %, clamped to ``thresholdRange`` (the artboard's 1–20 stepper).
        public var thresholdPercent: Int
        public var checkFiveHour: Bool
        public var checkWeekly: Bool
        /// 冷卻, clamped to ``cooldownRange``.
        public var cooldownSeconds: Int

        public static let thresholdRange = 1...20
        public static let cooldownRange = 60...3600

        public init(
            enabled: Bool = false, thresholdPercent: Int = 2, checkFiveHour: Bool = true, checkWeekly: Bool = true,
            cooldownSeconds: Int = 300
        ) {
            self.enabled = enabled
            self.thresholdPercent = thresholdPercent
            self.checkFiveHour = checkFiveHour
            self.checkWeekly = checkWeekly
            self.cooldownSeconds = cooldownSeconds
        }
    }

    // MARK: - 08 NOTEBOOK & MCP (live since M4, D33)

    public struct Notebook: Sendable, Equatable {
        /// 位置: only ``NotebookLocation/local`` exists in M4 (`<dataRoot>/notes`); the iCloud
        /// Drive / 自訂… segments are drawn disabled `M5`, a stored other value is kept as is.
        public var location: NotebookLocation
        /// 圖片長邊壓到 2576px.
        public var resizeImages: Bool
        public var keepOriginal: Bool
        /// Unused since M4: the MCP server shares the hook server's loopback port (D16, D33), and
        /// Settings › Port 與 token shows that port read-only. Kept (clamped to ``mcpPortRange``)
        /// so a file written by M3 still round-trips and a later version may offer its own port.
        public var mcpPort: Int
        /// 自動掛載 MCP: CODD sessions get the per-session `--mcp-config` and the codd:// expansion.
        public var autoAttachMCP: Bool
        /// 新筆記預設 AI 存取.
        public var defaultAIAccess: AIAccess
        /// AI 可寫入: the MCP `notes_write` tool exists only while ON (and then only for APPEND
        /// notes, D17); OFF still lets APPEND notes take `notes_append`.
        public var aiCanWrite: Bool

        public static let mcpPortRange = 1024...65535

        public init(
            location: NotebookLocation = .local, resizeImages: Bool = true, keepOriginal: Bool = false, mcpPort: Int = 47821,
            autoAttachMCP: Bool = true, defaultAIAccess: AIAccess = .read, aiCanWrite: Bool = false
        ) {
            self.location = location
            self.resizeImages = resizeImages
            self.keepOriginal = keepOriginal
            self.mcpPort = mcpPort
            self.autoAttachMCP = autoAttachMCP
            self.defaultAIAccess = defaultAIAccess
            self.aiCanWrite = aiCanWrite
        }
    }

    /// 位置 Local / iCloud Drive / 自訂….
    public enum NotebookLocation: String, Sendable, CaseIterable, Codable {
        case local, iCloud, custom
    }

    /// 新筆記預設 AI 存取 Off / Read / Append.
    public enum AIAccess: String, Sendable, CaseIterable, Codable {
        case off, read, append
    }

    // MARK: - 09 CLEANUP (live since M4, the retention engine's values, D29–D32)

    /// Day counts; nil = 永不 (永久 for the tombstone).
    public struct Cleanup: Sendable, Equatable {
        /// Notes: 標示 STALE.
        public var notesStaleDays: Int?
        /// Notes: 自動封存.
        public var notesArchiveDays: Int?
        /// SCRATCH · 已送出 prompt.
        public var scratchArchiveDays: Int?
        /// 垃圾桶清除 (no 永不 option).
        public var trashPurgeDays: Int
        /// Tombstone: nil = 永久.
        public var tombstoneDays: Int?
        /// 豁免 釘選與使用中 session 的筆記.
        public var exempt: Bool
        /// Sessions: 標示 STALE (after stopping).
        public var sessionsStaleDays: Int?
        /// Sessions: 自動封存.
        public var sessionsArchiveDays: Int?
        /// 終端機紀錄: delete scrollback this long after archiving (nil = 永不). The one value the
        /// engine obeys; Settings › 進階 › 終端機紀錄保留 shows and edits this same leaf (D30).
        public var scrollbackDeleteDays: Int?
        /// resume 過期提醒.
        public var resumeWarning: Bool
        public var digest: Digest
        /// Account for 交給 Claude 濃縮, as the Settings select stores it: `follow` (跟隨全域登入)
        /// or a cswap account number (`"3"`); nil = not chosen yet, which means the select's first
        /// entry (跟隨全域登入, D32).
        public var condenseAccount: String?
        /// A `--model` value; see ``condenseModelOptions``.
        public var condenseModel: String

        public static let notesStaleOptions: [Int?] = [14, 7, 30, 60, nil]
        public static let notesArchiveOptions: [Int?] = [30, 14, 60, nil]
        public static let scratchArchiveOptions: [Int?] = [7, 14, 30, nil]
        public static let trashPurgeOptions = [30, 7, 60]
        public static let tombstoneOptions: [Int?] = [90, 30, nil]
        public static let sessionsStaleOptions: [Int?] = [3, 1, 7, nil]
        public static let sessionsArchiveOptions: [Int?] = [7, 3, 14, nil]
        public static let scrollbackDeleteOptions: [Int?] = [30, 7, 90, nil]
        /// The artboard's models; the stored value is any non-blank model name, because model
        /// names change faster than this file's version.
        public static let condenseModelOptions = ["sonnet-5.5", "opus-5.5"]

        public init(
            notesStaleDays: Int? = 14, notesArchiveDays: Int? = 30, scratchArchiveDays: Int? = 7, trashPurgeDays: Int = 30,
            tombstoneDays: Int? = 90, exempt: Bool = true, sessionsStaleDays: Int? = 3, sessionsArchiveDays: Int? = 7,
            scrollbackDeleteDays: Int? = 30, resumeWarning: Bool = true, digest: Digest = .weekly,
            condenseAccount: String? = nil, condenseModel: String = "sonnet-5.5"
        ) {
            self.notesStaleDays = notesStaleDays
            self.notesArchiveDays = notesArchiveDays
            self.scratchArchiveDays = scratchArchiveDays
            self.trashPurgeDays = trashPurgeDays
            self.tombstoneDays = tombstoneDays
            self.exempt = exempt
            self.sessionsStaleDays = sessionsStaleDays
            self.sessionsArchiveDays = sessionsArchiveDays
            self.scrollbackDeleteDays = scrollbackDeleteDays
            self.resumeWarning = resumeWarning
            self.digest = digest
            self.condenseAccount = condenseAccount
            self.condenseModel = condenseModel
        }
    }

    /// 清理建議頻率 每週 / 雙週 / 每月 / 關.
    public enum Digest: String, Sendable, CaseIterable, Codable {
        case weekly, biweekly, monthly, off
    }

    // MARK: - 10 SHORTCUTS / 12 ADVANCED / 13 ABOUT

    /// Reserved: only the global hotkey (``General/hotkey``) is configurable in M3. Keys a later
    /// version writes here are kept by the store.
    public struct Shortcuts: Sendable, Equatable {
        public init() {}
    }

    public struct Advanced: Sendable, Equatable {
        /// Unused since M4 (D30): the 終端機紀錄保留 row mirrors ``Cleanup/scrollbackDeleteDays``,
        /// which the retention engine obeys. Still stored (one of ``scrollbackRetentionOptions``)
        /// so M3 files round-trip unchanged; nothing reads it.
        public var scrollbackRetentionDays: Int

        public static let scrollbackRetentionOptions = [30, 7, 90]

        public init(scrollbackRetentionDays: Int = 30) {
            self.scrollbackRetentionDays = scrollbackRetentionDays
        }
    }

    public struct About: Sendable, Equatable {
        /// D17: `M5`.
        public var updateChannel: UpdateChannel

        public init(updateChannel: UpdateChannel = .stable) {
            self.updateChannel = updateChannel
        }
    }

    /// 更新頻道 Stable / Beta.
    public enum UpdateChannel: String, Sendable, CaseIterable, Codable {
        case stable, beta
    }
}
