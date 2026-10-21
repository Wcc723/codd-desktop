import AppKit
import CoddUI

// Value models of the four StatusDialogs dialogs (M3-PLAN §4 C8). Strings arrive formatted by
// the app (aliases, plans, reset clocks); only durations that tick (`9s`, `12s 前`, `3d01h後`,
// `3m`) are kept as absolute dates, so the views can redraw them at 1 Hz without a new model.

/// A small `.chip` in a dialog (header right side of an account card, plan chips).
public struct DialogChip: Equatable, Sendable {
    public var text: String
    /// CoddUI's `.chip` variants (`.plain`, `.amber`, `.cyan`, `.ok`, `.bad`, `.fill`).
    public var kind: ChipKind
    /// `.chip.caps`: uppercase 10 px with wide tracking (`ACTIVE`).
    public var caps: Bool

    public init(_ text: String, kind: ChipKind = .plain, caps: Bool = false) {
        self.text = text
        self.kind = kind
        self.caps = caps
    }

    /// `<span class="chip caps amber">Active</span>`.
    public static let active = DialogChip("Active", kind: .amber, caps: true)

    /// `<span class="chip cy">1 個 session 固定</span>`.
    public static func pinned(_ count: Int) -> DialogChip {
        DialogChip("\(count) 個 session 固定", kind: .cyan)
    }
}

/// One account in dialog A (`.sd-acct` mini card).
public struct DialogAccount: Equatable, Sendable {
    /// `#3`.
    public var slot: String
    /// `工作`.
    public var alias: String
    /// `MAX 20x`; nil = no chip.
    public var plan: String?
    /// 5h remaining 0–100; nil draws `—`.
    public var fiveHourRemaining: Double?
    public var fiveHourTone: Tone
    /// 1w remaining 0–100; nil draws `—`.
    public var weeklyRemaining: Double?
    public var weeklyTone: Tone
    /// `1w 重置 10/18 12:00`.
    public var reset: String
    /// When set, ` · 3d01h後` (ticking) follows `reset`.
    public var resetsAt: Date?
    /// `statusline`, `cswap cache`.
    public var source: String
    /// When set, ` · 12s 前` (ticking) follows `source`.
    public var sourceAt: Date?
    /// Header chips at the right of `FROM · 剩餘` (`ACTIVE`, `1 個 session 固定`).
    public var chips: [DialogChip]

    public init(slot: String, alias: String, plan: String? = nil,
                fiveHourRemaining: Double?, fiveHourTone: Tone, weeklyRemaining: Double?, weeklyTone: Tone,
                reset: String, resetsAt: Date? = nil, source: String, sourceAt: Date? = nil, chips: [DialogChip] = []) {
        self.slot = slot
        self.alias = alias
        self.plan = plan
        self.fiveHourRemaining = fiveHourRemaining
        self.fiveHourTone = fiveHourTone
        self.weeklyRemaining = weeklyRemaining
        self.weeklyTone = weeklyTone
        self.reset = reset
        self.resetsAt = resetsAt
        self.source = source
        self.sourceAt = sourceAt
        self.chips = chips
    }

    /// `#2 藍鵲`.
    public var name: String { alias.isEmpty ? slot : "\(slot) \(alias)" }
}

// MARK: A · switch account

/// A running `cswap switch` (D5): `◌ 等待 Claude Code credential lock… 9s（1/3）`.
public struct SwitchProgress: Equatable, Sendable {
    public var attempt: Int
    public var of: Int
    /// The elapsed `9s` counts from here (1 Hz).
    public var since: Date
    public var label: String

    public init(attempt: Int, of: Int, since: Date, label: String = SwitchProgress.lockLabel) {
        self.attempt = attempt
        self.of = of
        self.since = since
        self.label = label
    }

    public static let lockLabel = "等待 Claude Code credential lock…"
}

/// Dialog A (shown only when 設定 › 帳號 › 切換前確認 is ON, R3).
public struct SwitchAccountModel: Equatable, Sendable {
    public var from: DialogAccount
    public var to: DialogAccount
    /// Sessions that follow the global login (`12 個跟隨全域登入的 session…`).
    public var followingCount: Int
    /// Titles of the sessions pinned to an account (`固定帳號的 session（…）不受影響`); empty hides the line.
    public var pinnedTitles: [String]
    /// `AUTO-SWITCH 目前 OFF|ON`.
    public var autoSwitchOn: Bool
    /// The `同時暫停自動切換` checkbox.
    public var pauseAutoSwitch: Bool
    /// Non-nil while switching: the progress line shows and `切換` is disabled.
    public var progress: SwitchProgress?
    /// The failure message (redacted by the app); drawn as `[ERROR] 切換失敗：<error>`.
    public var error: String?
    /// The header chip (`cswap 0.26.0`); nil hides it.
    public var cswapVersion: String?

    public init(from: DialogAccount, to: DialogAccount, followingCount: Int, pinnedTitles: [String] = [],
                autoSwitchOn: Bool = false, pauseAutoSwitch: Bool = false, progress: SwitchProgress? = nil,
                error: String? = nil, cswapVersion: String? = nil) {
        self.from = from
        self.to = to
        self.followingCount = followingCount
        self.pinnedTitles = pinnedTitles
        self.autoSwitchOn = autoSwitchOn
        self.pauseAutoSwitch = pauseAutoSwitch
        self.progress = progress
        self.error = error
        self.cswapVersion = cswapVersion
    }

    /// `切換` is enabled unless a switch is running.
    public var canConfirm: Bool { progress == nil }
}

// MARK: B · Hook 差異

/// Color of a chip in the Hook 差異 dialog (`.chip.ok` / `.chip.bad` / `.chip`).
public enum DiffChipKind: Equatable, Sendable {
    case added, removed, neutral
}

/// A chip in the event row (`+ PreCompact`).
public struct DiffChip: Equatable, Sendable {
    public var text: String
    public var kind: DiffChipKind

    public init(_ text: String, kind: DiffChipKind) {
        self.text = text
        self.kind = kind
    }
}

/// One line of the settings.json diff (`.sd-ln`), shaped like CoddClaudeSettings' `DiffLine`.
public struct DiffLineModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `@@ -38,5 +38,13 @@  "hooks"` (cyan, no number).
        case hunk
        case context
        case added
        case removed
        /// Foreign handlers collapsed into one dim line (`…（保留既有 n 組 hook）`, D10).
        case elided
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    /// The text; every `…` draws dim (`.el`).
    public var text: String
    /// Substrings drawn white and semibold (`.ev`, the event keys of added entries); the first
    /// occurrence of each is emphasized.
    public var emphasis: [String]

    public init(_ kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String, emphasis: [String] = []) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.emphasis = emphasis
    }
}

/// Dialog B: the preview of an installer plan (D10). Nothing is written before `套用並備份`.
public struct HookDiffModel: Equatable, Sendable {
    /// `~/.claude/settings.json` (abbreviated by the app).
    public var settingsPath: String
    /// Plan summary lines in 繁中 (`移除 CODD web 舊版 hook…`); drawn as a `▸` list, empty draws none.
    public var summary: [String]
    /// Label before the event chips; nil derives it from the chips (`補上 4 個 event`).
    public var chipsLabel: String?
    /// Event chips (`+ PreCompact`); empty hides the row.
    public var chips: [DiffChip]
    public var lines: [DiffLineModel]
    /// The header chips `+9` / `−1`.
    public var added: Int
    public var removed: Int
    /// `hook-tap ×11 · osascript ×2` (each ` · ` part bold); empty hides the FOREIGN row.
    public var foreignKept: String
    /// `移除 hook-tap ×2` (a restore): the FOREIGN row then warns that other tools' hooks change
    /// instead of saying they are kept (M3 review).
    public var foreignChanged: String
    /// `~/.claude/settings.json.codd-bak-20261015-104210`; empty hides the BACKUP row.
    public var backupPath: String
    /// False when the plan cannot be applied (unsupported shape, changed file).
    public var canApply: Bool
    /// Drawn as `[ERROR] <error>`.
    public var error: String?
    /// The primary button (`套用並備份`; the restore flow may pass `還原`).
    public var applyTitle: String
    /// The `.m-h` title (M4: the `~/.claude.json` MCP registration reuses dialog B with its own).
    public var dialogTitle: String
    /// The footer note (`只動 hooks 與 statusLine，其他 key 不碰` for the hooks).
    public var footerNote: String
    /// The diff box's line when the plan changes nothing (nil: the hooks' text).
    public var noChangesText: String?
    /// The plan changes something the diff does not show (the MCP registration's tighten-only
    /// plan makes files 0600): the primary button works with an empty diff.
    public var appliesWithoutDiff: Bool

    public init(settingsPath: String, summary: [String] = [], chipsLabel: String? = nil, chips: [DiffChip] = [],
                lines: [DiffLineModel], added: Int, removed: Int, foreignKept: String = "", foreignChanged: String = "",
                backupPath: String = "", canApply: Bool = true, error: String? = nil,
                applyTitle: String = HookDiffModel.defaultApplyTitle, dialogTitle: String = HookDiffModel.defaultDialogTitle,
                footerNote: String = HookDiffModel.defaultFooterNote, noChangesText: String? = nil,
                appliesWithoutDiff: Bool = false) {
        self.appliesWithoutDiff = appliesWithoutDiff
        self.dialogTitle = dialogTitle
        self.footerNote = footerNote
        self.noChangesText = noChangesText
        self.foreignChanged = foreignChanged
        self.settingsPath = settingsPath
        self.summary = summary
        self.chipsLabel = chipsLabel
        self.chips = chips
        self.lines = lines
        self.added = added
        self.removed = removed
        self.foreignKept = foreignKept
        self.backupPath = backupPath
        self.canApply = canApply
        self.error = error
        self.applyTitle = applyTitle
    }

    public static let defaultApplyTitle = "套用並備份"
    public static let defaultDialogTitle = "Hook diff · 預覽變更"
    public static let defaultFooterNote = "只動 hooks 與 statusLine，其他 key 不碰"

    /// The plan changes something.
    public var hasChanges: Bool { added > 0 || removed > 0 }
    /// `套用並備份` is enabled.
    public var canConfirm: Bool { canApply && (hasChanges || appliesWithoutDiff) }

    /// `補上 4 個 event` / `移除 2 個 event` / `變更 6 個 event`.
    public var resolvedChipsLabel: String {
        if let chipsLabel { return chipsLabel }
        let kinds = Set(chips.map(\.kind))
        if kinds == [.added] { return "補上 \(chips.count) 個 event" }
        if kinds == [.removed] { return "移除 \(chips.count) 個 event" }
        return "變更 \(chips.count) 個 event"
    }
}

// MARK: C · add account

/// Step 2's result: the current login compared with cswap's accounts (the e-mail never shown).
public struct DetectedLogin: Equatable, Sendable {
    /// True: `偵測到 新帳號`; false: `已是 #2 藍鵲（會更新它的登入資料）`.
    public var isNew: Bool
    /// The emphasized part: `新帳號` or the existing account's `#2 藍鵲`.
    public var text: String
    /// `MAX 20x` chip; nil = none.
    public var plan: String?

    public init(isNew: Bool, text: String, plan: String? = nil) {
        self.isNew = isNew
        self.text = text
        self.plan = plan
    }

    public static func newAccount(plan: String?) -> DetectedLogin { DetectedLogin(isNew: true, text: "新帳號", plan: plan) }
}

/// Dialog C (D24): 1 login in a terminal, 2 capture the login, 3 alias + slot → `cswap add`.
public struct AddAccountModel: Equatable, Sendable {
    /// When step 1 finished (the login changed); `已完成 · 10:41`.
    public var step1Done: Date?
    /// Step 2's result; non-nil makes step 3 current.
    public var detected: DetectedLogin?
    /// The alias as typed (the field's text).
    public var alias: String
    /// Free slot numbers for the select (`#4`, `#5`).
    public var slots: [Int]
    public var slot: Int
    /// The account the login returns to (`#3 工作`, the step-1 hint).
    public var previousActive: String
    /// A cswap call runs: every button but 取消 is disabled.
    public var busy: Bool
    /// Drawn as `[ERROR] <error>`.
    public var error: String?
    public var cswapVersion: String?

    public init(step1Done: Date? = nil, detected: DetectedLogin? = nil, alias: String = "", slots: [Int], slot: Int,
                previousActive: String, busy: Bool = false, error: String? = nil, cswapVersion: String? = nil) {
        self.step1Done = step1Done
        self.detected = detected
        self.alias = alias
        self.slots = slots
        self.slot = slot
        self.previousActive = previousActive
        self.busy = busy
        self.error = error
        self.cswapVersion = cswapVersion
    }

    /// D34: `別名只能用英文小寫、數字與 - _ .（cswap 規則）`.
    public static let aliasRuleHint = DialogAliasRule.hint

    /// The alias as cswap will store it, or nil when cswap's rule refuses it.
    public var normalizedAlias: String? { DialogAliasRule.normalize(alias) }

    /// The rule hint shows for a non-empty alias that cswap would refuse (`工作室`).
    public var showsAliasRuleHint: Bool {
        !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalizedAlias == nil
    }

    /// `加入 #n` is enabled: the login was captured, the alias passes cswap's rule, a free slot is
    /// chosen and nothing runs.
    public var canAdd: Bool { detected != nil && normalizedAlias != nil && slots.contains(slot) && !busy }

    /// 1, 2 or 3: the first step not done yet (a capture makes 3 current even when step 1 was
    /// skipped because the user logged in elsewhere).
    public var currentStep: Int {
        if detected != nil { return 3 }
        return step1Done == nil ? 1 : 2
    }
}

// MARK: D · quit

/// A NEEDS YOU row in the quit dialog (`.srow.flat`).
public struct DialogSessionRow: Equatable {
    public var id: String
    /// Lamp glyph (`◆`, `▲`).
    public var glyph: String
    /// State color (lamp, pill, duration, row tint).
    public var color: NSColor
    /// 8 px color tag; nil = none.
    public var tag: NSColor?
    public var title: String
    /// `Perm`, `Ask`, `Error` (drawn uppercase).
    public var pill: String
    /// Solid pill (waiting: amber fill, black text) or an outline in `color` (error).
    public var pillFilled: Bool
    /// The state's start; `3m` ticks from here.
    public var since: Date
    /// `藍鵲·網站 / orb-toolkit-backend` (or `overloaded · 個人·Github / Gear3D`).
    public var location: String

    public init(id: String, glyph: String, color: NSColor, tag: NSColor? = nil, title: String, pill: String,
                pillFilled: Bool, since: Date, location: String) {
        self.id = id
        self.glyph = glyph
        self.color = color
        self.tag = tag
        self.title = title
        self.pill = pill
        self.pillFilled = pillFilled
        self.since = since
        self.location = location
    }
}

/// Dialog D (D18).
public struct QuitModel: Equatable {
    /// `13 個 session 執行中`.
    public var running: Int
    /// `◆ 3 需要你` (hidden at 0).
    public var needs: Int
    /// The NEEDS YOU rows; empty hides the panel.
    public var rows: [DialogSessionRow]
    /// `停止 CODD 啟動的 12 個 session…`.
    public var stoppable: Int
    /// The `下次直接保留在選單列` checkbox.
    public var keepNextTime: Bool

    public init(running: Int, needs: Int, rows: [DialogSessionRow], stoppable: Int, keepNextTime: Bool = false) {
        self.running = running
        self.needs = needs
        self.rows = rows
        self.stoppable = stoppable
        self.keepNextTime = keepNextTime
    }
}

/// The quit dialog's answer (D18).
public enum QuitChoice: Equatable, Sendable {
    /// `[全部停止並結束]`: stop every CODD session and shell tab, then quit.
    case stopAllAndQuit
    /// `[結束 · session 繼續執行]`: quit; holders keep running and are re-attached next launch.
    case quitKeepingSessions
    /// `[保留在選單列（關閉視窗）]`: close the main window, CODD stays in the menu bar.
    case keepInMenuBar
    /// `[取消]`, ✕ or ⎋.
    case cancel
}
