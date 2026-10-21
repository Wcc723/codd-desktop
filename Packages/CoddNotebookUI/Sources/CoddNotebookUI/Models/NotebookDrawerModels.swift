import AppKit
import CoddUI

// MARK: - Notes drawer (Split artboard `.sp-pad`)

/// A card thumbnail (`.sp-ph` 42 × 74 portrait, `.sp-ls` 118 × 58 landscape) with its small
/// caption (`直向` / `橫向`). Without an image the artboard's schematic is drawn.
public struct NotesDrawerImage: Equatable, @unchecked Sendable {
    public var image: NSImage?
    public var orientation: NotebookImageOrientation
    public var caption: String

    public init(image: NSImage? = nil, orientation: NotebookImageOrientation, caption: String) {
        self.image = image
        self.orientation = orientation
        self.caption = caption
    }
}

/// A task line (`[x] 先重現…`). Backtick spans (`` `position: sticky` ``) draw as inline code.
public struct NotesDrawerTask: Sendable, Equatable {
    public var text: String
    public var done: Bool

    public init(_ text: String, done: Bool) {
        self.text = text
        self.done = done
    }
}

/// `done/total` of all the note's tasks (the card shows at most three).
public struct NotesDrawerTaskProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var text: String { "\(done)/\(total)" }
}

/// One `.sp-note` card.
public struct NotesDrawerCard: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: NotebookKindBadge
    public var title: String
    public var ai: NotebookAIAccess
    /// At most two are drawn.
    public var images: [NotesDrawerImage]
    /// `截圖 2026-10-15 09:32 · iPhone SE` (left of the caption line).
    public var imageCaption: String?
    /// `2 張 · 1.4 MB` (right of the caption line).
    public var imageSummary: String?
    /// At most three are drawn.
    public var tasks: [NotesDrawerTask]
    public var taskProgress: NotesDrawerTaskProgress?
    /// `#rwd #punch`.
    public var tags: String
    /// `更新 10:05`.
    public var updated: String
    /// `AI 讀取 10:12` (nil: no AI read yet).
    public var aiRead: String?
    /// The note referenced in the session's composer draft (`.ref`: amber border).
    public var isReferenced: Bool

    public init(id: String, kind: NotebookKindBadge = .note, title: String, ai: NotebookAIAccess = .read, images: [NotesDrawerImage] = [],
                imageCaption: String? = nil, imageSummary: String? = nil, tasks: [NotesDrawerTask] = [],
                taskProgress: NotesDrawerTaskProgress? = nil, tags: String = "", updated: String, aiRead: String? = nil,
                isReferenced: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.ai = ai
        self.images = images
        self.imageCaption = imageCaption
        self.imageSummary = imageSummary
        self.tasks = tasks
        self.taskProgress = taskProgress
        self.tags = tags
        self.updated = updated
        self.aiRead = aiRead
        self.isReferenced = isReferenced
    }

    /// The meta line's parts: tags, the task progress when the card shows no image, updated, AI read.
    public var metaParts: [String] {
        var parts: [String] = []
        if !tags.isEmpty { parts.append(tags) }
        if images.isEmpty, let taskProgress, taskProgress.total > 0 { parts.append(taskProgress.text) }
        parts.append(updated)
        if let aiRead { parts.append(aiRead) }
        return parts
    }
}

/// A row of `AI 改過的檔案`: `punch.vue  M  AI 10:41` / `src/pages/` / `[差異]`.
public struct NotesDrawerFile: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// git status letter (`M`), nil: none.
    public var status: String?
    /// `AI 10:41` / `AI`; nil: a file changed by git only (no AI chip).
    public var aiChip: String?
    public var directory: String

    public init(id: String, name: String, status: String? = "M", aiChip: String?, directory: String) {
        self.id = id
        self.name = name
        self.status = status
        self.aiChip = aiChip
        self.directory = directory
    }
}

/// The optional `AI 改過的檔案 · n  vs HEAD` section (D26).
public struct NotesDrawerFilesSection: Sendable, Equatable {
    public var title: String
    public var count: Int
    public var baseline: String
    public var files: [NotesDrawerFile]
    /// The AI chip's color: the session's tag (nil: bone outline, D26).
    public var aiTag: NotebookTag?

    public init(title: String = "AI 改過的檔案 ·", count: Int, baseline: String = "vs HEAD", files: [NotesDrawerFile], aiTag: NotebookTag?) {
        self.title = title
        self.count = count
        self.baseline = baseline
        self.files = files
        self.aiTag = aiTag
    }
}

/// The note open in the drawer's editor (a card's title opened it): the editing bar
/// `‹ LINKED NOTES n` + `[筆記本 ↗]`, the editor in the view's `documentView` slot, then
/// `[插入引用] [送出全文]` and the save state (`● 已儲存 10:05`, `● 未儲存`, `◌ 儲存中…`).
public struct NotesDrawerEditing: Sendable, Equatable {
    public var id: String
    /// The note's title (VoiceOver labels; the editor shows the title line itself).
    public var title: String
    /// Nil while the note loads.
    public var save: NoteSaveState?

    public init(id: String, title: String, save: NoteSaveState? = nil) {
        self.id = id
        self.title = title
        self.save = save
    }
}

public struct NotesDrawerModel: Sendable, Equatable {
    public var cards: [NotesDrawerCard]
    public var files: NotesDrawerFilesSection?
    /// The footer's notes folder (`~/.codd/notebook` in the artboard).
    public var notesPath: String
    public var emptyText: String
    /// Disables 插入引用 / 送出全文 on every card (and in the editor's action row) with this tooltip.
    public var actionsDisabledReason: String?
    /// The note open in the drawer's editor; nil shows the cards.
    public var editing: NotesDrawerEditing?

    public init(cards: [NotesDrawerCard], files: NotesDrawerFilesSection? = nil, notesPath: String,
                emptyText: String = NotebookCopy.drawerEmpty, actionsDisabledReason: String? = nil, editing: NotesDrawerEditing? = nil) {
        self.cards = cards
        self.files = files
        self.notesPath = notesPath
        self.emptyText = emptyText
        self.actionsDisabledReason = actionsDisabledReason
        self.editing = editing
    }
}

// MARK: - History compare sheet

public struct HistoryVersionOption: Sendable, Equatable, Identifiable {
    public var id: String
    /// `10:05 · 你 · 目前`.
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct HistoryCompareModel: Sendable, Equatable {
    public var versions: [HistoryVersionOption]
    /// The older side (what `還原這一版` restores).
    public var fromID: String
    /// The newer side (usually the current text).
    public var toID: String
    public var lines: [DiffLinesView.Line]
    /// `−3 +5` or similar, drawn dim next to the selects.
    public var summary: String
    /// Disabled while from = to or from is the current version.
    public var restoreEnabled: Bool
    public var restoreDisabledReason: String?

    public init(versions: [HistoryVersionOption], fromID: String, toID: String, lines: [DiffLinesView.Line], summary: String = "",
                restoreEnabled: Bool = true, restoreDisabledReason: String? = nil) {
        self.versions = versions
        self.fromID = fromID
        self.toID = toID
        self.lines = lines
        self.summary = summary
        self.restoreEnabled = restoreEnabled
        self.restoreDisabledReason = restoreDisabledReason
    }
}

// MARK: - Pickers

public struct LinkPickerSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var state: NotebookSessionState
    public var project: String

    public init(id: String, title: String, state: NotebookSessionState, project: String) {
        self.id = id
        self.title = title
        self.state = state
        self.project = project
    }
}

public struct LinkPickerProject: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var tag: NotebookTag?

    public init(id: String, name: String, tag: NotebookTag?) {
        self.id = id
        self.name = name
        self.tag = tag
    }
}

public struct LinkPickerModel: Sendable, Equatable {
    public var sessions: [LinkPickerSession]
    public var projects: [LinkPickerProject]
    /// Already linked (drawn with `✓`, picking one again unlinks it: the app decides).
    public var linked: Set<NotebookLink>

    public init(sessions: [LinkPickerSession], projects: [LinkPickerProject], linked: Set<NotebookLink> = []) {
        self.sessions = sessions
        self.projects = projects
        self.linked = linked
    }
}

public struct TagEditorModel: Sendable, Equatable {
    /// The note's tags (without `#`).
    public var tags: [String]
    /// Existing tags offered while typing.
    public var suggestions: [String]

    public init(tags: [String], suggestions: [String]) {
        self.tags = tags
        self.suggestions = suggestions
    }
}
