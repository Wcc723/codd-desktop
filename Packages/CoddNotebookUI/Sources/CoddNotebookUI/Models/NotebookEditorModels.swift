import AppKit
import CoddUI

// MARK: - Editor chrome (`.nb-top`, `.nb-body`)

/// One choice of the scope menu: `Global` or a project.
public struct NotebookScopeOption: Sendable, Equatable, Identifiable {
    /// `global` or the project's id.
    public var id: String
    /// `Global` / the project name.
    public var title: String
    /// false for Global.
    public var isProject: Bool
    /// A project's tag square (nil: the dashed "no color" square); unused for Global.
    public var tag: NotebookTag?

    public init(id: String, title: String, isProject: Bool, tag: NotebookTag? = nil) {
        self.id = id
        self.title = title
        self.isProject = isProject
        self.tag = tag
    }

    public static let globalID = "global"
    public static var global: NotebookScopeOption { NotebookScopeOption(id: globalID, title: "Global", isProject: false) }
}

/// The display strings of the five COPY REF forms (§3.6), formatted by the app.
public struct NotebookRefTexts: Sendable, Equatable {
    /// `codd://note/rwd-punch-k7x2`.
    public var uri: String
    /// `@codd:codd://note/rwd-punch-k7x2`.
    public var mention: String
    /// `~/…/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md`.
    public var path: String
    /// `http://127.0.0.1:47821/n/rwd-punch-k7x2.md?t=••••` (never the token).
    public var url: String

    public init(uri: String, mention: String, path: String, url: String) {
        self.uri = uri
        self.mention = mention
        self.path = path
        self.url = url
    }

    /// The forms of `id` with CODD's defaults (server `codd`).
    public static func standard(id: String, path: String, port: Int, server: String = "codd") -> NotebookRefTexts {
        NotebookRefTexts(uri: "codd://note/\(id)", mention: "@\(server):codd://note/\(id)", path: path,
                         url: "http://127.0.0.1:\(port)/n/\(id).md?t=••••")
    }
}

/// The ⋯ menu's actions.
public enum NotebookMoreAction: Sendable, Equatable {
    case togglePin
    case kind(NotebookNoteKind)
    case archive
    case unarchive
    case trash
    case restore
    case revealInFinder
    case toggleSource
    case copyID
}

/// Where the note lives, for the ⋯ menu (封存 vs 還原).
public enum NotebookNoteLocation: Sendable, Equatable {
    case active, archived, trashed
}

/// The menus the chrome opens.
public enum NoteChromeMenu: String, Sendable, CaseIterable, Equatable {
    case ai, scope, copyRef, send, more
}

public struct NoteEditorChromeModel: Sendable, Equatable {
    /// The crumb's list (`Inbox`, drawn uppercase).
    public var crumb: String
    public var title: String
    /// nil: not on disk yet (D3): `id —`, COPY REF and SEND disabled (D15).
    public var noteID: String?
    public var ai: NotebookAIAccess
    /// The selected scope option's id (`global` or a project id).
    public var scopeID: String
    public var scopeOptions: [NotebookScopeOption]
    public var refs: NotebookRefTexts?
    public var kind: NotebookNoteKind
    public var pinned: Bool
    public var location: NotebookNoteLocation
    /// The editor shows the Markdown source (`⋯` then offers 即時預覽 ⌘E).
    public var sourceMode: Bool
    /// SEND TO SESSION's sessions (live CODD claude sessions only).
    public var sessions: [NotebookSessionTarget]
    /// Disabled controls with their tooltip (integration wires them step by step).
    public var aiDisabledReason: String?
    public var scopeDisabledReason: String?
    public var copyRefDisabledReason: String?
    public var sendDisabledReason: String?
    /// The three actions inside the SEND menu (the menu itself still opens).
    public var sendActionsDisabledReason: String?
    public var moreDisabledReason: String?
    public var info: NoteInfoPanelModel?
    public var status: NoteDocStatusModel
    public var footer: PromptFooterModel?

    public init(crumb: String, title: String, noteID: String?, ai: NotebookAIAccess, scopeID: String = NotebookScopeOption.globalID,
                scopeOptions: [NotebookScopeOption] = [.global], refs: NotebookRefTexts?, kind: NotebookNoteKind = .note,
                pinned: Bool = false, location: NotebookNoteLocation = .active, sourceMode: Bool = false,
                sessions: [NotebookSessionTarget] = [], aiDisabledReason: String? = nil, scopeDisabledReason: String? = nil,
                copyRefDisabledReason: String? = nil, sendDisabledReason: String? = nil, sendActionsDisabledReason: String? = nil,
                moreDisabledReason: String? = nil, info: NoteInfoPanelModel?, status: NoteDocStatusModel, footer: PromptFooterModel?) {
        self.crumb = crumb
        self.title = title
        self.noteID = noteID
        self.ai = ai
        self.scopeID = scopeID
        self.scopeOptions = scopeOptions
        self.refs = refs
        self.kind = kind
        self.pinned = pinned
        self.location = location
        self.sourceMode = sourceMode
        self.sessions = sessions
        self.aiDisabledReason = aiDisabledReason
        self.scopeDisabledReason = scopeDisabledReason
        self.copyRefDisabledReason = copyRefDisabledReason
        self.sendDisabledReason = sendDisabledReason
        self.sendActionsDisabledReason = sendActionsDisabledReason
        self.moreDisabledReason = moreDisabledReason
        self.info = info
        self.status = status
        self.footer = footer
    }

    /// The note exists on disk (D3).
    public var isSaved: Bool { noteID != nil && refs != nil }

    public var scope: NotebookScopeOption? { scopeOptions.first { $0.id == scopeID } }
}

// MARK: - Chips row (`.nb-meta`)

public struct NoteChipsRowModel: Sendable, Equatable {
    public var kind: NotebookKindBadge
    /// Without `#`.
    public var tags: [String]
    public var session: NotebookSessionTarget?
    public var project: NotebookScopeOption?
    /// `updated 10:05`.
    public var updated: String
    /// Shows the `+ #` affordance and its inline field.
    public var allowsAddTag: Bool

    public init(kind: NotebookKindBadge, tags: [String], session: NotebookSessionTarget? = nil, project: NotebookScopeOption? = nil,
                updated: String, allowsAddTag: Bool = true) {
        self.kind = kind
        self.tags = tags
        self.session = session
        self.project = project
        self.updated = updated
        self.allowsAddTag = allowsAddTag
    }
}

// MARK: - Image annotation summary (`.nb-annp`)

public struct ImageAnnotationSummaryItem: Sendable, Equatable {
    public var number: Int
    public var note: String
    /// `rect · x 20 y 1150 · 710×120`.
    public var coordinates: String

    public init(number: Int, note: String, coordinates: String) {
        self.number = number
        self.note = note
        self.coordinates = coordinates
    }
}

public struct ImageAnnotationSummaryModel: Sendable, Equatable {
    public var items: [ImageAnnotationSummaryItem]
    /// `AI 會收到標註後的圖與座標清單` (follows the image's send options).
    public var hint: String
    public var shortcut: String

    public init(items: [ImageAnnotationSummaryItem], hint: String = "AI 會收到標註後的圖與座標清單", shortcut: String = "⌘⇧A") {
        self.items = items
        self.hint = hint
        self.shortcut = shortcut
    }
}

// MARK: - Info panel (`.nb-info`)

public enum NoteInfoLinkRow: Sendable, Equatable, Identifiable {
    case session(id: String, title: String, state: NotebookSessionState)
    case project(id: String, name: String, tag: NotebookTag?)

    public var id: String {
        switch self {
        case .session(let id, _, _): "session:\(id)"
        case .project(let id, _, _): "project:\(id)"
        }
    }

    public var link: NotebookLink {
        switch self {
        case .session(let id, _, _): .session(id: id)
        case .project(let id, _, _): .project(id: id)
        }
    }
}

/// AI ACTIVITY rows: `讀取 · 打卡頁 RWD 調整 · 10:12`, `附加 —`.
public enum NoteAIActivityKind: String, Sendable, CaseIterable, Equatable {
    case read, append, write, expand, url

    public var title: String {
        switch self {
        case .read: "讀取"
        case .append: "附加"
        case .write: "改寫"
        case .expand: "展開"
        case .url: "網址"
        }
    }

    var icon: NotebookIcon {
        switch self {
        case .read, .expand, .url: .eye
        case .append, .write: .plus
        }
    }
}

public struct NoteAIActivityRow: Sendable, Equatable {
    public var kind: NoteAIActivityKind
    /// The session title (nil with `time` nil: the `—` row).
    public var who: String?
    public var time: String?

    public init(kind: NoteAIActivityKind, who: String? = nil, time: String? = nil) {
        self.kind = kind
        self.who = who
        self.time = time
    }
}

/// HISTORY rows: `10:05 你 · 目前` (current `.on`), `09:41 你` (selected `.sel`), `昨天 18:20 建立`.
public struct NoteHistoryRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var time: String
    public var label: String
    public var isCurrent: Bool
    public var isSelected: Bool

    public init(id: String, time: String, label: String, isCurrent: Bool = false, isSelected: Bool = false) {
        self.id = id
        self.time = time
        self.label = label
        self.isCurrent = isCurrent
        self.isSelected = isSelected
    }
}

public enum NotebookImageOrientation: String, Sendable, Equatable {
    case portrait, landscape
}

/// An ASSETS thumbnail (the app passes the decoded image; nil draws the artboard placeholder).
public struct NoteAssetThumb: Equatable, Identifiable, @unchecked Sendable {
    public var id: String
    public var name: String
    public var image: NSImage?
    public var orientation: NotebookImageOrientation

    public init(id: String, name: String, image: NSImage? = nil, orientation: NotebookImageOrientation) {
        self.id = id
        self.name = name
        self.image = image
        self.orientation = orientation
    }
}

/// RETENTION rows: `最後活動 37m 前`, `自動封存 豁免 · session 使用中` (ok).
public struct NoteRetentionRow: Sendable, Equatable {
    public var term: String
    public var value: String
    public var ok: Bool

    public init(term: String, value: String, ok: Bool = false) {
        self.term = term
        self.value = value
        self.ok = ok
    }
}

public struct NoteInfoPanelModel: Sendable, Equatable {
    public var links: [NoteInfoLinkRow]
    public var aiActivity: [NoteAIActivityRow]
    public var aiActivityHint: String
    /// `3 版`.
    public var historyCount: String
    public var history: [NoteHistoryRow]
    /// `2 張 · 1.4 MB`.
    public var assetsSummary: String
    public var assets: [NoteAssetThumb]
    public var retention: [NoteRetentionRow]
    public var pinned: Bool
    /// Disables the panel's buttons with this tooltip (integration step by step).
    public var actionsDisabledReason: String?

    public init(links: [NoteInfoLinkRow], aiActivity: [NoteAIActivityRow], aiActivityHint: String = "AI 讀取不計入活動時間",
                historyCount: String, history: [NoteHistoryRow], assetsSummary: String, assets: [NoteAssetThumb],
                retention: [NoteRetentionRow], pinned: Bool, actionsDisabledReason: String? = nil) {
        self.links = links
        self.aiActivity = aiActivity
        self.aiActivityHint = aiActivityHint
        self.historyCount = historyCount
        self.history = history
        self.assetsSummary = assetsSummary
        self.assets = assets
        self.retention = retention
        self.pinned = pinned
        self.actionsDisabledReason = actionsDisabledReason
    }
}

// MARK: - Doc status bar (`.nb-docstat`)

public enum NoteSaveState: Sendable, Equatable {
    /// `● 已儲存 10:05` (green dot).
    case saved(String)
    /// `● 未儲存` (amber).
    case unsaved
    /// `◌ 儲存中…`.
    case saving
}

public struct NoteDocStatusModel: Sendable, Equatable {
    public var sourceMode: Bool
    /// `Ln 14, Col 38`.
    public var position: String
    public var language: String
    public var save: NoteSaveState

    public init(sourceMode: Bool = false, position: String, language: String = "Markdown", save: NoteSaveState) {
        self.sourceMode = sourceMode
        self.position = position
        self.language = language
        self.save = save
    }
}

// MARK: - Prompt footer (`.nb-send`)

public struct PromptFooterModel: Sendable, Equatable {
    /// The current target (nil: no live session; the pill reads `沒有 session`).
    public var target: NotebookSessionTarget?
    public var targets: [NotebookSessionTarget]
    /// Disables all three buttons (unsaved note, no target) with this tooltip.
    public var disabledReason: String?
    /// Disables only 送出.
    public var sendDisabledReason: String?

    public init(target: NotebookSessionTarget?, targets: [NotebookSessionTarget], disabledReason: String? = nil,
                sendDisabledReason: String? = nil) {
        self.target = target
        self.targets = targets
        self.disabledReason = disabledReason
        self.sendDisabledReason = sendDisabledReason
    }
}
