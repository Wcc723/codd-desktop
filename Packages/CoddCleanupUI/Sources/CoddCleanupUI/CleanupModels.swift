import AppKit
import CoddUI

// The Cleanup page is drawn from these plain values only (no CoddCore / CoddNotes / App types): the
// app maps its retention candidates into a `CleanupPageModel` and calls `update(_:)`, which redraws
// only what changed and keeps the page's own transient state (selection, focused row, the open
// select menu, scroll). Every text is already formatted by the app (`stale 21d`, `最後開啟 9/24`,
// `每週一 09:00 · 15 項 · 上次 10/08`). The values carry NSColor / NSAttributedString, so they are
// `Equatable` but not `Sendable`: build them on the main actor.

/// The three candidate lists (tabs `NOTES 8` / `SESSIONS 5` / `FILES 2`).
public enum CleanupTab: String, Sendable, CaseIterable {
    case notes, sessions, files

    /// Structural label, drawn uppercase.
    public var title: String {
        switch self {
        case .notes: "Notes"
        case .sessions: "Sessions"
        case .files: "Files"
        }
    }
}

/// Bulk bar action titles (`onBulk`'s first argument and the keys of `bulkDisabled`).
public enum CleanupBulkAction {
    public static let archive = "封存"
    public static let trash = "移到垃圾桶"
    public static let condense = "交給 Claude 濃縮…"
    /// In bar order.
    public static let all = [archive, trash, condense]
}

/// Row action titles the app uses (D31); `CleanupRow.actions` may carry any titles.
public enum CleanupRowAction {
    public static let keep = "保留 30 天"
    public static let archive = "封存"
    public static let trash = "移到垃圾桶"
}

/// One item on a row's second line (`.nb-cl-it .l2`).
public struct CleanupChip: Equatable {
    public enum Style: Sendable, Equatable {
        /// A small boxed chip (`.chip.nb-xs`): kind chips `NOTE`, `PROMPT` (amber), `SCRATCH` (dashed),
        /// `PROMPT · 草稿` (amber dashed), session state chips.
        case chip
        /// The project: its 8 px tag square (`tagColor`; nil = dashed outline) and the name in --dim.
        case project
        /// Plain --dimmer text (`未連結專案`).
        case faint
    }

    public var text: String
    /// Chip color (`.amber`, `.cyan`, …); nil = the plain bone chip.
    public var tone: ChipKind?
    public var tagColor: NSColor?
    public var dashed: Bool
    public var style: Style

    /// `style` defaults to `.project` when a tag color is given, else `.chip`.
    public init(text: String, tone: ChipKind? = nil, tagColor: NSColor? = nil, dashed: Bool = false, style: Style? = nil) {
        self.text = text
        self.tone = tone
        self.tagColor = tagColor
        self.dashed = dashed
        self.style = style ?? (tagColor != nil ? .project : .chip)
    }

    /// A kind chip (`NOTE`, `PROMPT` amber, `SCRATCH` dashed).
    public static func kind(_ text: String, tone: ChipKind? = nil, dashed: Bool = false) -> CleanupChip {
        CleanupChip(text: text, tone: tone, dashed: dashed, style: .chip)
    }

    /// The project chip: tag square + name.
    public static func project(_ name: String, color: NSColor?) -> CleanupChip {
        CleanupChip(text: name, tagColor: color, style: .project)
    }

    /// Plain dimmer text (`未連結專案`).
    public static func faint(_ text: String) -> CleanupChip {
        CleanupChip(text: text, style: .faint)
    }
}

/// The AI column (`.nb-cl-ai`).
public enum CleanupAIHint: Equatable, Sendable {
    /// `—`.
    case none
    /// Cyan eye + text: `AI 2d 前讀取 → 建議保留`.
    case keep(String)
    /// Amber-dim `✻` + text: `適合濃縮`, `適合濃縮舊段落` (a leading `✻ ` in the text is dropped:
    /// the glyph is drawn on its own).
    case condense(String)
    /// Dim eye + text: `AI 9d 前讀取`.
    case read(String)
}

/// One candidate row.
public struct CleanupRow: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var chips: [CleanupChip]
    /// WHY line 1 (`21 天未開啟`).
    public var why: String
    /// WHY line 2, dimmer (`最後開啟 9/24`); empty = none.
    public var sub: String
    /// STATUS chip: `stale 21d`, `archives in 0d`, `dup 82%`, `9 段 > 30d`, `resume expires 4d`,
    /// `deletes in 4d`, `unused 12d`.
    public var badge: String
    /// `.plain`, `.amber` (`archives in 0d`), `.cyan` (`dup 82%`), …
    public var badgeTone: ChipKind
    public var aiHint: CleanupAIHint
    /// Row buttons, right-aligned: `["保留 30 天", "封存"]` or `["保留 30 天", "移到垃圾桶"]`.
    public var actions: [String]

    public init(id: String, title: String, chips: [CleanupChip] = [], why: String, sub: String = "", badge: String,
                badgeTone: ChipKind = .plain, aiHint: CleanupAIHint = .none,
                actions: [String] = [CleanupRowAction.keep, CleanupRowAction.archive]) {
        self.id = id
        self.title = title
        self.chips = chips
        self.why = why
        self.sub = sub
        self.badge = badge
        self.badgeTone = badgeTone
        self.aiHint = aiHint
        self.actions = actions
    }
}

/// The CONDENSE card's run state (D32).
public enum CondenseState: Equatable, Sendable {
    /// `[✻ 產生摘要]` + `claude -p · 掛載 codd MCP` (disabled with `disabledReason`).
    case idle
    /// `◌ 產生中… 12s` + `[取消]`; `elapsed` is formatted by the app (`12s`).
    case running(elapsed: String)
    /// `[建立摘要並封存原稿] [重新產生] [捨棄]`.
    case preview
    /// `[ERROR] <text>` + `[重新產生]`.
    case failed(String)
}

/// One source note in the card's list.
public struct CondenseSource: Equatable {
    /// `每日工作日誌（舊段落 9 段）` for a long-note source (the app adds the label).
    public var title: String
    /// `NOTE`, `PROMPT`.
    public var kind: String
    /// The project's tag color; nil = the dashed `未連結專案` square.
    public var tagColor: NSColor?

    public init(title: String, kind: String, tagColor: NSColor? = nil) {
        self.title = title
        self.kind = kind
        self.tagColor = tagColor
    }
}

/// One account the condense run can use (`跟隨全域登入（#3 工作）`, `#1 個人`).
public struct CondenseAccountOption: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var enabled: Bool
    /// Tooltip of a disabled option (why it cannot be used).
    public var hint: String?

    public init(id: String, title: String, enabled: Bool = true, hint: String? = nil) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.hint = hint
    }
}

/// The CONDENSE · PREVIEW card (`.card.hot.nb-cl-cond`); nil in `CleanupPageModel` hides the card
/// and the review table takes the full width.
public struct CondenseModel: Equatable {
    /// `濃縮 5 則 → 1 則摘要` (the `→` is drawn amber).
    public var title: String
    public var sources: [CondenseSource]
    /// The select's value: `#1 個人 · sonnet-5.5`.
    public var accountTitle: String
    public var accounts: [CondenseAccountOption]
    public var models: [String]
    /// Checkmarks in the select's menu.
    public var selectedAccountID: String?
    public var selectedModel: String?
    /// `#1 個人 5h 未開始 · 1w 剩 100% · 不佔用 #3 工作的額度`.
    public var accountHint: String
    /// `codd://note/cleanup-1015-q8m3` next to `摘要預覽`.
    public var previewRef: String
    /// The summary as rendered Markdown (the app's `MarkdownRender.attributedPreview`); nil = not
    /// generated yet.
    public var preview: NSAttributedString?
    public var state: CondenseState
    /// Set when no run is possible (`測試資料根目錄只用 -codd-claude-path`): `[✻ 產生摘要]` and
    /// `[重新產生]` are disabled and the reason replaces the idle hint.
    public var disabledReason: String?

    public init(title: String, sources: [CondenseSource], accountTitle: String, accounts: [CondenseAccountOption] = [],
                models: [String] = [], selectedAccountID: String? = nil, selectedModel: String? = nil, accountHint: String = "",
                previewRef: String = "", preview: NSAttributedString? = nil, state: CondenseState = .idle,
                disabledReason: String? = nil) {
        self.title = title
        self.sources = sources
        self.accountTitle = accountTitle
        self.accounts = accounts
        self.models = models
        self.selectedAccountID = selectedAccountID
        self.selectedModel = selectedModel
        self.accountHint = accountHint
        self.previewRef = previewRef
        self.preview = preview
        self.state = state
        self.disabledReason = disabledReason
    }
}

/// One lifecycle box: `ACTIVE`, `STALE 14d`, `ARCHIVE 30d`, `TRASH`, `PURGE 30d`.
public struct CleanupPolicyStep: Equatable {
    /// Drawn uppercase in the step color (`Stale`).
    public var name: String
    /// The cream part after the name (`14d`); nil = none.
    public var detail: String?
    /// The line under the box (`變暗 · 仍可搜尋`).
    public var sub: String
    /// The box color; nil = by position (success, amber-dim, cyan, danger, dimmer as on the artboard).
    public var color: NSColor?

    public init(name: String, detail: String? = nil, sub: String, color: NSColor? = nil) {
        self.name = name
        self.detail = detail
        self.sub = sub
        self.color = color
    }
}

/// One `dt` / `dd` pair of the rules list (`SCRATCH` · `7 天後封存 · 含已送出 prompt`).
public struct CleanupPolicyRule: Equatable {
    /// Drawn uppercase.
    public var term: String
    public var text: String

    public init(term: String, text: String) {
        self.term = term
        self.text = text
    }
}

/// The POLICY · 保留規則 card.
public struct CleanupPolicyModel: Equatable {
    public var lifecycle: [CleanupPolicyStep]
    /// Two pairs per line, in reading order.
    public var rules: [CleanupPolicyRule]

    public init(lifecycle: [CleanupPolicyStep], rules: [CleanupPolicyRule]) {
        self.lifecycle = lifecycle
        self.rules = rules
    }
}

/// The whole page.
public struct CleanupPageModel: Equatable {
    /// The meta rule under the title (`每週一 09:00 · 15 項 · 上次 10/08`).
    public var meta: String
    /// Tab counts; a missing tab shows 0.
    public var counts: [CleanupTab: Int]
    public var tab: CleanupTab
    /// The rows of `tab`.
    public var rows: [CleanupRow]
    /// The selected row ids. The page adopts it when it differs from the previous model's value
    /// (so the app can set or clear the selection) and otherwise keeps its own; ids that are not
    /// rows are dropped.
    public var selected: Set<String>
    public var condense: CondenseModel?
    public var policy: CleanupPolicyModel
    /// Bulk actions drawn disabled per tab (`.sessions: ["移到垃圾桶", "交給 Claude 濃縮…"]`).
    public var bulkDisabled: [CleanupTab: Set<String>]
    /// The table's empty state.
    public var emptyText: String

    public static let defaultEmptyText = "// 這一類目前沒有清理建議"

    public init(meta: String, counts: [CleanupTab: Int], tab: CleanupTab, rows: [CleanupRow], selected: Set<String> = [],
                condense: CondenseModel? = nil, policy: CleanupPolicyModel, bulkDisabled: [CleanupTab: Set<String>] = [:],
                emptyText: String = CleanupPageModel.defaultEmptyText) {
        self.meta = meta
        self.counts = counts
        self.tab = tab
        self.rows = rows
        self.selected = selected
        self.condense = condense
        self.policy = policy
        self.bulkDisabled = bulkDisabled
        self.emptyText = emptyText
    }

    /// Whether `action` is enabled in the bulk bar of the current tab.
    public func isBulkEnabled(_ action: String) -> Bool { !(bulkDisabled[tab]?.contains(action) ?? false) }
}
