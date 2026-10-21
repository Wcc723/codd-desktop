import AppKit
import CoddUI

// Value atoms shared by every Notebook view. Every type name carries a `Notebook` / `Note…View`
// prefix that CoddNotes (C1) does not use, so App code that imports both packages never needs to
// qualify a name. Texts in models are already formatted by the app (`10:05`, `已送出 10:02`,
// `37m 前`); the views only draw them.

/// A CODD session state as the lamps draw it (SPEC §3: glyph + color, double encoded).
public enum NotebookSessionState: String, Sendable, CaseIterable, Equatable {
    case waiting, error, done, busy, compacting, idle, starting, unknown, shell, exited, stopped

    /// The lamp glyph (`◆` waiting, `●` busy, `○` idle, …).
    public var glyph: String {
        switch self {
        case .waiting: "◆"
        case .error: "▲"
        case .done: "◇"
        case .busy, .unknown: "●"
        case .compacting, .starting: "◌"
        case .idle: "○"
        case .shell: "$"
        case .exited: "✕"
        case .stopped: "⟲"
        }
    }

    /// `--st` of `.st-<state>`.
    public var color: NSColor {
        switch self {
        case .waiting: Palette.amber
        case .error: Palette.danger
        case .busy: Palette.success
        case .compacting: Palette.successDim
        case .done, .idle: Palette.cyan
        case .starting, .unknown, .shell: Palette.bone
        case .exited, .stopped: Palette.dimmer
        }
    }

    /// `.st-busy .lamp{text-shadow:0 0 6px rgba(124,255,154,.55)}`.
    var glows: Bool { self == .busy }
}

/// A Claude Code `/color` tag (SPEC §3), drawn only as small squares.
public enum NotebookTag: String, Sendable, CaseIterable, Equatable {
    case red, blue, green, yellow, purple, orange, pink, cyan

    /// `--t-<name>`.
    public var color: NSColor {
        switch self {
        case .red: NSColor(hex: 0xEF5B5B)
        case .blue: NSColor(hex: 0x5B8DEF)
        case .green: NSColor(hex: 0x4EC9B0)
        case .yellow: NSColor(hex: 0xE6C84E)
        case .purple: NSColor(hex: 0xB07CFF)
        case .orange: NSColor(hex: 0xFF9B4E)
        case .pink: NSColor(hex: 0xFF7CB5)
        case .cyan: NSColor(hex: 0x4ED1E6)
        }
    }
}

/// A note's kind as stored (`kind: note|prompt|scratch`); the ⋯ menu's 類型 items.
public enum NotebookNoteKind: String, Sendable, CaseIterable, Equatable {
    case note, prompt, scratch

    /// Structural label (`NOTE`).
    public var title: String { rawValue.uppercased() }
}

/// The kind chip of a row, a card or the chips row (`NOTE`, amber `PROMPT`, dashed `SCRATCH`,
/// amber dashed `PROMPT · 草稿` for a PROMPT that was never sent).
public enum NotebookKindBadge: String, Sendable, CaseIterable, Equatable {
    case note, prompt, promptDraft, scratch

    /// Drawn uppercase (`.chip.caps`).
    public var text: String {
        switch self {
        case .note: "Note"
        case .prompt: "Prompt"
        case .promptDraft: "Prompt · 草稿"
        case .scratch: "Scratch"
        }
    }

    var amber: Bool { self == .prompt || self == .promptDraft }
    var dashed: Bool { self == .scratch || self == .promptDraft }
}

/// A note's AI access (`ai: off|read|append`).
public enum NotebookAIAccess: String, Sendable, CaseIterable, Equatable {
    case off, read, append

    /// `READ` / `OFF` / `APPEND` (rows, drawer cards).
    public var label: String { rawValue.uppercased() }

    /// The row glyph: eye = READ, lock = OFF, plus = APPEND.
    public var icon: NotebookIcon {
        switch self {
        case .off: .lock
        case .read: .eye
        case .append: .plus
        }
    }

    /// The editor pill (`AI 可讀 READ ▾`).
    public var pillTitle: String {
        switch self {
        case .off: "AI 關閉 OFF"
        case .read: "AI 可讀 READ"
        case .append: "AI 可附加 APPEND"
        }
    }

    /// The AI menu's hint under each option (D34).
    public var hint: String {
        switch self {
        case .off: "AI 看不到這則筆記（MCP 與引用展開都不提供）"
        case .read: "AI 可透過 MCP 讀取"
        case .append: "AI 可讀取，也可以在最後附加內容"
        }
    }
}

/// A live CODD claude session the note can go to (SEND TO SESSION, the prompt footer, pickers).
public struct NotebookSessionTarget: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var state: NotebookSessionState
    /// The footer's dim `project · state duration` (`orb-toolkit-frontend · busy 6m`) and the
    /// menus' second line.
    public var detail: String
    public var tag: NotebookTag?

    public init(id: String, title: String, state: NotebookSessionState, detail: String = "", tag: NotebookTag? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.tag = tag
    }
}

/// What a note is linked to (chips, info panel LINKS, link picker results).
public enum NotebookLink: Sendable, Equatable, Hashable {
    case session(id: String)
    case project(id: String)
}

/// One of the five COPY REF forms (§3.6), in the artboard's order.
public enum NotebookRefForm: Int, Sendable, CaseIterable, Equatable {
    /// `codd://note/<id>` (推薦, ⌘⇧C; the split button's left part).
    case uri = 1
    /// `@codd:codd://note/<id>`.
    case mention = 2
    /// The absolute file path (shown `~`-abbreviated).
    case path = 3
    /// 複製全文 Markdown.
    case markdown = 4
    /// `http://127.0.0.1:<port>/n/<id>.md?t=…` (shown `?t=••••`).
    case url = 5

    /// The artboard hint under each form.
    public var hint: String {
        switch self {
        case .uri: "CODD 啟動的 session 會由 UserPromptSubmit hook 自動展開內容"
        case .mention: "在 Claude Code 輸入框用 @ 附加（MCP resource）"
        case .path: "檔案路徑 · 任何 agent 都能用 Read 讀取"
        case .markdown: "貼到任何地方；圖片改寫成絕對路徑"
        case .url: "瀏覽器 / curl 用；Claude 的 WebFetch 讀不到 localhost"
        }
    }

    /// The URL item's hint when the note's AI access is OFF (D15).
    public static let urlOffHint = "AI 存取為 OFF，不提供網址"
}

/// The three ways a note goes to a session (D14).
public enum NotebookSendAction: String, Sendable, CaseIterable, Equatable {
    /// 插入引用: `codd://note/<id>` into the composer draft.
    case insertRef
    /// 插入全文: the AI text into the composer draft.
    case insertFull
    /// 送出全文: the AI text pasted and submitted.
    case send

    public var title: String {
        switch self {
        case .insertRef: "插入引用"
        case .insertFull: "插入全文"
        case .send: "送出全文"
        }
    }
}

/// Copy shared by several views (D34 additions are listed in the README).
public enum NotebookCopy {
    /// Tooltip of COPY REF / SEND on a note that is not on disk yet (D3, D15).
    public static let unsavedReason = "筆記尚未建立：輸入內容後才會存成檔案"
    /// Footer and drawer actions without a live session.
    public static let noTargetReason = "沒有執行中的 Claude session"
    public static let noNotesEmpty = "// 還沒有筆記 · ⌘⇧N 新增"
    public static let noMatchEmpty = "// 找不到符合的筆記"
    public static let drawerEmpty = "// 還沒有連結這個 session 的筆記"
}
