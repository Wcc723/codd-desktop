import Foundation

/// Step 3: the `~/.CLAUDE · SETTINGS.JSON` card.
public struct HooksStepModel: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        /// `SESSION HOOKS`, `LEGACY`, `STATUSLINE`, `FOREIGN`.
        public let label: String
        /// `● 14 / 14`, `◆ 舊版 CODD web`, `○ 未安裝全域版`, or a FOREIGN tool's command (`hook-tap`).
        public let state: String
        /// `ok`, `amber`, `dim`, `danger`, `code` (a command drawn as code).
        public let tone: String
        public let detail: String

        public init(label: String, state: String, tone: String, detail: String) {
            self.label = label
            self.state = state
            self.tone = tone
            self.detail = detail
        }
    }

    public var rows: [Row]
    /// Items `[預覽變更]` would change (legacy hooks, an outdated status line).
    public var pending: Int
    public var canPreview: Bool
    /// `● 已套用 · 備份 <name>` after an apply.
    public var appliedBackup: String?

    public init(rows: [Row], pending: Int, canPreview: Bool, appliedBackup: String? = nil) {
        self.rows = rows
        self.pending = pending
        self.canPreview = canPreview
        self.appliedBackup = appliedBackup
    }

    public enum Statusline: Sendable, Equatable { case notInstalled, installed, outdated }

    /// A tool's own hooks in `settings.json` (kept as they are). `name` is the command itself
    /// for a tool known only by its program (`hook-tap`); the row then names it once.
    public struct Foreign: Sendable, Equatable {
        public let command: String
        public let name: String
        public let count: Int

        public init(command: String, name: String, count: Int) {
            self.command = command
            self.name = name
            self.count = count
        }
    }

    /// The §2.4 rows for the installer's inspection.
    public static func make(hooks: EnvironmentFacts.Hooks, statusline: Statusline = .notInstalled, sessionHooks: (installed: Int, total: Int) = (14, 14),
                            foreign: [Foreign] = [], appliedBackup: String? = nil) -> HooksStepModel {
        var rows = [Row(label: "SESSION HOOKS", state: "● \(sessionHooks.installed) / \(sessionHooks.total)", tone: "ok",
                        detail: "每個 CODD session 自動注入")]
        var pending = 0
        if case .legacy(let events, _) = hooks {
            rows.append(Row(label: "LEGACY", state: "◆ 舊版 CODD web", tone: "amber", detail: events.joined(separator: " / ")))
            pending += 1
        } else if case .unreadable(let reason) = hooks {
            rows.append(Row(label: "LEGACY", state: "▲ 讀不到設定", tone: "danger", detail: reason))
        } else {
            rows.append(Row(label: "LEGACY", state: "● 沒有舊版設定", tone: "ok", detail: ""))
        }
        var line = statusline
        if case .statuslineOutdated = hooks { line = .outdated }
        switch line {
        case .notInstalled: rows.append(Row(label: "STATUSLINE", state: "○ 未安裝全域版", tone: "dim", detail: "選用"))
        case .installed: rows.append(Row(label: "STATUSLINE", state: "● 已安裝", tone: "ok", detail: ""))
        case .outdated:
            rows.append(Row(label: "STATUSLINE", state: "◆ 需要更新", tone: "amber", detail: ""))
            pending += 1
        }
        for tool in foreign {
            let name = tool.name.isEmpty || tool.name == tool.command ? "" : tool.name + " "
            rows.append(Row(label: "FOREIGN", state: tool.command, tone: "code", detail: "\(name)×\(tool.count) · 保持不動"))
        }
        var readable = true
        if case .unreadable = hooks { readable = false }
        if case .unknown = hooks { readable = false }
        return HooksStepModel(rows: rows, pending: pending, canPreview: readable && (pending > 0 || line == .notInstalled),
                              appliedBackup: appliedBackup)
    }
}

/// Step 4: the fixed notes folder, the MCP endpoint, Claude Code and Codex registration.
public struct NotebookStepModel: Sendable, Equatable {
    /// `~/Library/Application Support/CODD/notes` (with `~`).
    public var notesPath: String
    /// `127.0.0.1:47821 · ● 運作中` / `○ 未啟動 · hooks 連接埠被占用`.
    public var mcpLine: String
    public var mcpRunning: Bool
    /// `○ 未註冊` / `● 已註冊`.
    public var claudeCodeState: String
    /// `註冊…` while it can be registered; nil otherwise.
    public var claudeCodeButton: String?
    /// `[複製設定…]` (the M4 snippet sheet).
    public var codexAvailable: Bool

    public init(notesPath: String, mcpLine: String, mcpRunning: Bool, claudeCodeState: String, claudeCodeButton: String?,
                codexAvailable: Bool) {
        self.notesPath = notesPath
        self.mcpLine = mcpLine
        self.mcpRunning = mcpRunning
        self.claudeCodeState = claudeCodeState
        self.claudeCodeButton = claudeCodeButton
        self.codexAvailable = codexAvailable
    }

    /// - Parameter claudeCodeRegistered: nil when registration is not possible here (a throwaway
    ///   data root never writes `~/.claude.json`, M4 D22).
    public static func make(notesPath: String, mcpEndpoint: String?, mcpRunning: Bool, claudeCodeRegistered: Bool?,
                            codexAvailable: Bool = true) -> NotebookStepModel {
        let line = mcpRunning ? "\(mcpEndpoint ?? "127.0.0.1") · ● 運作中" : "○ 未啟動 · hooks 連接埠被占用"
        let state: String
        let button: String?
        switch claudeCodeRegistered {
        case true?: state = "● 已註冊"; button = nil
        case false?: state = "○ 未註冊"; button = "註冊…"
        case nil: state = "○ 未註冊 · 這個資料夾不能註冊"; button = nil
        }
        return NotebookStepModel(notesPath: notesPath, mcpLine: line, mcpRunning: mcpRunning, claudeCodeState: state,
                                 claudeCodeButton: button, codexAvailable: codexAvailable)
    }
}

/// Step 5: cswap's accounts in R7 order (aliases only, never an e-mail).
public struct AccountsStepModel: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        /// `#2`.
        public let slot: String
        public let alias: String
        /// `MAX 20x`.
        public let plan: String?
        /// Remaining percent 0...100.
        public let fiveHourRemaining: Double?
        public let weeklyRemaining: Double?
        /// `1w 重置 1d12h後` (the sort key).
        public let weeklyReset: String
        public let active: Bool

        public init(slot: String, alias: String, plan: String?, fiveHourRemaining: Double?, weeklyRemaining: Double?,
                    weeklyReset: String, active: Bool) {
            self.slot = slot
            self.alias = alias
            self.plan = plan
            self.fiveHourRemaining = fiveHourRemaining
            self.weeklyRemaining = weeklyRemaining
            self.weeklyReset = weeklyReset
            self.active = active
        }
    }

    /// The comment when cswap cannot be used (`找不到 cswap`, `cswap 0.24.1 太舊，需要 0.26 以上`); nil when it can.
    public var availabilityNote: String?
    public var rows: [Row]
    public var canAdd: Bool
    /// The paragraph under the note (what to do without cswap).
    public var availabilityDetail: String?
    /// FB 「引導安裝 cswap」: how to install (missing) or update (too old) cswap; nil when it can be used.
    public var installGuide: OnboardingCswapGuide?

    public init(availabilityNote: String?, rows: [Row], canAdd: Bool, availabilityDetail: String? = nil,
                installGuide: OnboardingCswapGuide? = nil) {
        self.availabilityNote = availabilityNote
        self.rows = rows
        self.canAdd = canAdd
        self.availabilityDetail = availabilityDetail
        self.installGuide = installGuide
    }

    public static func make(cswap: EnvironmentFacts.Cswap, rows: [Row]) -> AccountsStepModel {
        let without = "沒有 cswap 也能使用 CODD：session 用目前登入的帳號。要管理多個帳號，安裝 cswap（0.26 以上）後按 ↻ 重新偵測。"
        switch cswap {
        case .ready: return AccountsStepModel(availabilityNote: nil, rows: rows, canAdd: true)
        case .missing:
            return AccountsStepModel(availabilityNote: "找不到 cswap", rows: [], canAdd: false, availabilityDetail: without,
                                     installGuide: OnboardingCswapGuide(kind: .install))
        case .unsupported(let version):
            return AccountsStepModel(availabilityNote: "cswap \(version) 太舊，需要 0.26 以上", rows: [], canAdd: false,
                                     availabilityDetail: "更新 cswap 後按 ↻ 重新偵測；在那之前 session 用目前登入的帳號。",
                                     installGuide: OnboardingCswapGuide(kind: .upgrade))
        case .unreadable(let reason):
            return AccountsStepModel(availabilityNote: "讀不到 cswap 狀態：\(reason)", rows: rows, canAdd: false)
        case .loading:
            return AccountsStepModel(availabilityNote: "讀取 cswap 狀態中…", rows: rows, canAdd: false)
        }
    }
}

/// FB 「引導安裝 cswap」 on step 5: cswap is the PyPI package `claude-swap`
/// (github.com/realiti4/claude-swap), installed with uv (Homebrew or uv's installer first when uv is
/// missing). `在終端機執行` types the command in a SHELL session without running it; `↻ 重新偵測`
/// probes again. STATUS and Settings › 帳號 show the same commands.
public struct OnboardingCswapGuide: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case install
        case upgrade
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public static let installCommand = "uv tool install claude-swap"
    public static let upgradeCommand = "uv tool upgrade claude-swap"
    public static let uvCommands = ["brew install uv", "curl -LsSf https://astral.sh/uv/install.sh | sh"]
    public static let projectURL = "https://github.com/realiti4/claude-swap"

    /// `INSTALL` / `UPGRADE`.
    public var label: String { kind == .install ? "INSTALL" : "UPGRADE" }
    public var lead: String {
        switch kind {
        case .install: "cswap（PyPI 套件 claude-swap）負責切換帳號與讀取用量快取。用 uv 安裝："
        case .upgrade: "這個 cswap 太舊，CODD 需要 0.26 以上。用 uv 更新（用 pipx 裝的改用 pipx upgrade claude-swap）："
        }
    }
    /// What `在終端機執行` types (not run).
    public var command: String { kind == .install ? Self.installCommand : Self.upgradeCommand }
    public var uvCommands: [String] { kind == .install ? Self.uvCommands : [] }
    public var commands: [String] { [command] + uvCommands }
    public static let uvHint = "還沒有 uv？先用其中一行安裝："
    public static let note = "// 在終端機執行 只會打好指令，按 Return 才會執行 · 裝好後按 ↻ 重新偵測，再用 + 加入帳號 登入各個帳號"
}

/// Step 6: the summary boot block and the notification permission.
public struct DoneStepModel: Sendable, Equatable {
    public enum Notifications: String, Sendable {
        case notAsked, asking, granted, denied, suppressed
    }

    public var summary: [BootLine]
    public var notifications: Notifications

    public init(summary: [BootLine], notifications: Notifications) {
        self.summary = summary
        self.notifications = notifications
    }

    public enum HooksOutcome: Sendable, Equatable { case skipped, applied, upToDate, notApplied }

    /// `[ OK ] projects 匯入 9 個專案 → 3 個群組`, `[ -- ] hooks 略過`, `[ OK ] notebook ~/…/CODD/notes`,
    /// `[ OK ] accounts 3 個帳號`.
    public static func make(imported: (projects: Int, groups: Int)?, hooks: HooksOutcome, notesPath: String, accounts: Int?,
                            notifications: Notifications) -> DoneStepModel {
        var lines: [BootLine] = []
        if let imported, imported.projects > 0 {
            lines.append(BootLine(tag: .ok, name: "projects", value: "匯入 \(imported.projects) 個專案 → \(imported.groups) 個群組"))
        } else {
            lines.append(BootLine(tag: .skipped, name: "projects", value: "略過"))
        }
        switch hooks {
        case .skipped: lines.append(BootLine(tag: .skipped, name: "hooks", value: "略過"))
        case .applied: lines.append(BootLine(tag: .ok, name: "hooks", value: "已套用"))
        case .upToDate: lines.append(BootLine(tag: .ok, name: "hooks", value: "已是最新"))
        case .notApplied: lines.append(BootLine(tag: .pending, name: "hooks", value: "未套用", detail: "之後可在 SETTINGS 調整"))
        }
        lines.append(BootLine(tag: .ok, name: "notebook", value: PathText.compact(notesPath)))
        if let accounts {
            lines.append(BootLine(tag: .ok, name: "accounts", value: "\(accounts) 個帳號"))
        } else {
            lines.append(BootLine(tag: .skipped, name: "accounts", value: "沒有 cswap"))
        }
        return DoneStepModel(summary: lines, notifications: notifications)
    }
}

/// Step 2 as the view draws it.
public struct ImportStepModel: Sendable, Equatable {
    public var catalog: ProjectCatalog
    public var selection: ImportSelection
    public var options: [GroupOption]
    /// Path → the suggested option key (D9; `建議` in the menu).
    public var suggestion: [String: String]
    /// `9 個專案 → 3 個群組`.
    public var summary: String
    /// The sidebar's groups (the view recomputes suggestions after its own changes).
    public var existing: [ExistingGroup]
    /// For the 最近使用 column.
    public var now: Date
    public var timeZone: TimeZone
    /// The home folder (never a suggested group).
    public var home: String?

    public init(catalog: ProjectCatalog, selection: ImportSelection, options: [GroupOption], suggestion: [String: String],
                summary: String, existing: [ExistingGroup] = [], now: Date = Date(), timeZone: TimeZone = .current,
                home: String? = nil) {
        self.catalog = catalog
        self.selection = selection
        self.options = options
        self.suggestion = suggestion
        self.summary = summary
        self.existing = existing
        self.now = now
        self.timeZone = timeZone
        self.home = home
    }

    /// The model for `selection`: suggestions for its checked rows, the user's groups kept, and every
    /// row whose group no longer exists moved to its suggestion.
    public static func make(catalog: ProjectCatalog, selection: ImportSelection, existing: [ExistingGroup], now: Date,
                            timeZone: TimeZone, home: String? = nil) -> ImportStepModel {
        let (options, suggestion) = GroupSuggester.suggest(for: catalog.candidates, checked: selection.checked, existing: existing,
                                                           userGroups: selection.newGroups, home: home)
        var normalized = selection
        let keys = Set(options.map(\.key))
        for (path, key) in selection.group where !keys.contains(key) {
            normalized.group[path] = suggestion[path] ?? GroupOption.ungroupedKey
        }
        return ImportStepModel(catalog: catalog, selection: normalized, options: options, suggestion: suggestion,
                               summary: summaryText(normalized, catalog: catalog, options: options), existing: existing,
                               now: now, timeZone: timeZone, home: home)
    }

    /// D8's first state (pre-checked rows on their suggestions).
    public static func initial(catalog: ProjectCatalog, existing: [ExistingGroup], now: Date, timeZone: TimeZone,
                               home: String? = nil) -> ImportStepModel {
        make(catalog: catalog, selection: ImportSelection.initial(catalog, existing: existing, now: now, home: home),
             existing: existing, now: now, timeZone: timeZone, home: home)
    }

    /// This model with another selection (what the view does after a change of its own).
    public func with(_ selection: ImportSelection) -> ImportStepModel {
        Self.make(catalog: catalog, selection: selection, existing: existing, now: now, timeZone: timeZone, home: home)
    }

    public var plan: ImportPlan { ImportPlan.make(selection, catalog: catalog, options: options) }

    /// `9 個專案 → 3 個群組` (`· 2 個未分類` when some checked rows have no group).
    public static func summaryText(_ selection: ImportSelection, catalog: ProjectCatalog, options: [GroupOption]) -> String {
        let plan = ImportPlan.make(selection, catalog: catalog, options: options)
        let loose = plan.additions.filter { $0.groupKey == nil }.count
        var text = "\(plan.additions.count) 個專案 → \(plan.groupCount) 個群組"
        if loose > 0 { text += " · \(loose) 個未分類" }
        return text
    }

    /// The option for `key` (未分類 for an unknown key).
    public func option(_ key: String) -> GroupOption {
        options.first { $0.key == key } ?? selection.newGroups.first { $0.key == key } ?? GroupOption.ungrouped
    }

    /// `已選 9` / the stepper's `已選 9 / 187`.
    public var checkedCount: Int { selection.checked.count }
}

/// Everything the wizard window draws. The App fills it (probes, catalog, installer, cswap) and
/// calls `OnboardingView.update(_:)`; the views never read the disk.
public struct OnboardingViewModel: Sendable, Equatable {
    public var flow: OnboardingFlow
    public var boot: EnvironmentReport
    /// `1.0.0 (build 412) · macOS 27.0` (D11).
    public var versionLine: String
    /// D12 `已在用 CODD Web？匯入它的設定 →` (only with CODD web leftovers).
    public var showsWebImportLink: Bool
    /// The stepper's detail line per step (a skipped step shows `已略過 · 可在 SETTINGS 調整`).
    public var stepDetails: [OnboardingStep: String]
    public var detect: [DetectItem]
    public var importStep: ImportStepModel
    public var hooks: HooksStepModel
    public var notebook: NotebookStepModel
    public var accounts: AccountsStepModel
    public var done: DoneStepModel

    public init(flow: OnboardingFlow, boot: EnvironmentReport, versionLine: String, showsWebImportLink: Bool,
                stepDetails: [OnboardingStep: String], detect: [DetectItem], importStep: ImportStepModel, hooks: HooksStepModel,
                notebook: NotebookStepModel, accounts: AccountsStepModel, done: DoneStepModel) {
        self.flow = flow
        self.boot = boot
        self.versionLine = versionLine
        self.showsWebImportLink = showsWebImportLink
        self.stepDetails = stepDetails
        self.detect = detect
        self.importStep = importStep
        self.hooks = hooks
        self.notebook = notebook
        self.accounts = accounts
        self.done = done
    }

    /// The skipped step's stepper detail.
    public static let skippedDetail = "已略過 · 可在 SETTINGS 調整"

    /// The §2.4 stepper details: `4 項正常 · 1 項待處理`, `已選 9 / 187`, `◆ 需要更新 · 舊版 4 個事件`,
    /// `~/…/CODD/notes · :47821`, `偵測到 3 個帳號`, `開第一個 session`.
    public static func stepDetails(facts: EnvironmentFacts, report: EnvironmentReport, importStep: ImportStepModel,
                                   notesPath: String) -> [OnboardingStep: String] {
        var details: [OnboardingStep: String] = [:]
        details[.detect] = report.summary
        details[.importProjects] = "已選 \(importStep.checkedCount) / \(importStep.catalog.visibleTotal)"
        switch facts.hooks {
        case .legacy(let events, _): details[.hooks] = "◆ 需要更新 · 舊版 \(events.count) 個事件"
        case .statuslineOutdated: details[.hooks] = "◆ 需要更新 · 狀態列"
        case .upToDate: details[.hooks] = "● 已是最新"
        case .unreadable: details[.hooks] = "▲ 讀不到設定"
        case .unknown: details[.hooks] = "尚未檢查"
        }
        let port = facts.dataRoot.mcpEndpoint.flatMap { endpoint in endpoint.split(separator: ":").last.map { ":\($0)" } }
        details[.notebook] = [PathText.compact(notesPath), port].compactMap { $0 }.joined(separator: " · ")
        switch facts.cswap {
        case .ready(_, _, let accounts): details[.accounts] = "偵測到 \(accounts) 個帳號"
        case .missing: details[.accounts] = "找不到 cswap"
        case .unsupported: details[.accounts] = "cswap 太舊"
        case .unreadable: details[.accounts] = "讀不到 cswap 狀態"
        case .loading: details[.accounts] = "讀取中…"
        }
        details[.done] = "開第一個 session"
        return details
    }

    /// D11's version line.
    public static func versionLine(shortVersion: String, build: String, os: OperatingSystemVersion) -> String {
        "\(shortVersion) (build \(build)) · macOS \(os.majorVersion).\(os.minorVersion)"
    }
}
