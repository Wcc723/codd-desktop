import AppKit
import CoddUI

// MARK: - Lists column (`.nb-lists`)

/// The six smart lists, in the artboard's order.
public enum NotebookSmartList: String, Sendable, CaseIterable, Equatable {
    case inbox, pinned, prompts, stale, archive, trash

    /// Structural label (drawn uppercase).
    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .pinned: "Pinned"
        case .prompts: "Prompts"
        case .stale: "Stale"
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }
}

/// What the lists column can select.
public enum NotebookListID: Sendable, Hashable, Equatable {
    case smart(NotebookSmartList)
    /// A BY PROJECT row (its id, e.g. the `~`-abbreviated path).
    case project(String)
}

/// A collapsible section of the lists column.
public enum NotebookListsSection: String, Sendable, CaseIterable, Equatable {
    case byProject, localFiles
}

/// A BY PROJECT row: `■ orb-toolkit-frontend  2`.
public struct NotebookProjectRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// nil: the dashed "no color" square (a path outside the layout).
    public var tag: NotebookTag?
    public var count: Int

    public init(id: String, name: String, tag: NotebookTag?, count: Int) {
        self.id = id
        self.name = name
        self.tag = tag
        self.count = count
    }
}

/// A LOCAL FILES row: file icon, name, the dim root hint (`frontend`).
public struct NotebookFileRow: Sendable, Equatable, Identifiable {
    /// The file's path as the app identifies it (absolute in the app; `onOpenFile` gets it).
    public var id: String
    public var name: String
    public var rootHint: String

    public init(id: String, name: String, rootHint: String) {
        self.id = id
        self.name = name
        self.rootHint = rootHint
    }
}

/// The footer's `● MCP codd · 3 clients` line.
public struct NotebookMCPLine: Sendable, Equatable {
    /// Green lamp while the endpoint and the handler run, dim otherwise (D21).
    public var running: Bool
    public var serverName: String
    public var clients: String

    public init(running: Bool, serverName: String = "codd", clients: String) {
        self.running = running
        self.serverName = serverName
        self.clients = clients
    }
}

public struct NotebookListsModel: Sendable, Equatable {
    public var counts: [NotebookSmartList: Int]
    public var selected: NotebookListID
    /// TRASH's second line.
    public var trashHint: String
    public var projects: [NotebookProjectRow]
    public var projectsExpanded: Bool
    public var recentFiles: [NotebookFileRow]
    public var filesExpanded: Bool
    /// Disables the LOCAL FILES rows and `開啟資料夾…` with this tooltip (until I3 wires files).
    public var filesDisabledReason: String?
    /// `清理建議 [n] →`; nil hides the line.
    public var cleanupCount: Int?
    /// The notes folder (drawn dim, middle-truncated).
    public var notesPath: String
    public var mcp: NotebookMCPLine
    /// Applied to the search field only while the user is not editing it.
    public var searchText: String

    public init(counts: [NotebookSmartList: Int], selected: NotebookListID = .smart(.inbox), trashHint: String = "30 天後永久刪除",
                projects: [NotebookProjectRow] = [], projectsExpanded: Bool = true, recentFiles: [NotebookFileRow] = [],
                filesExpanded: Bool = true, filesDisabledReason: String? = nil, cleanupCount: Int? = nil, notesPath: String,
                mcp: NotebookMCPLine, searchText: String = "") {
        self.counts = counts
        self.selected = selected
        self.trashHint = trashHint
        self.projects = projects
        self.projectsExpanded = projectsExpanded
        self.recentFiles = recentFiles
        self.filesExpanded = filesExpanded
        self.filesDisabledReason = filesDisabledReason
        self.cleanupCount = cleanupCount
        self.notesPath = notesPath
        self.mcp = mcp
        self.searchText = searchText
    }
}

// MARK: - Note list (`.nb-notes`)

/// The sort menu's three orders.
public enum NoteListSort: String, Sendable, CaseIterable, Equatable {
    case updated, created, title

    public var title: String {
        switch self {
        case .updated: "最近更新"
        case .created: "建立時間"
        case .title: "標題"
        }
    }
}

/// The chip after the kind chip: the linked session (state lamp) or a project (tag square).
public enum NoteRowLinkChip: Sendable, Equatable {
    case session(title: String, state: NotebookSessionState)
    case project(name: String, tag: NotebookTag?)
}

/// A context menu item of a row (`釘選` / `封存` / `移到垃圾桶` / `還原` / …), given by the app.
public struct NoteRowAction: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isDestructive: Bool
    public var isEnabled: Bool

    public init(id: String, title: String, isDestructive: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
    }
}

/// One `.nb-nrow`.
public struct NoteListRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// `10:05`, `已送出 10:02`.
    public var time: String
    public var snippet: String
    /// Search mode: UTF-16 ranges of `title` / `snippet` drawn highlighted.
    public var titleHighlights: [NSRange]
    public var snippetHighlights: [NSRange]
    public var kind: NotebookKindBadge
    public var link: NoteRowLinkChip?
    /// Dim text after the chips (`7d 後封存`).
    public var extra: String?
    public var ai: NotebookAIAccess
    public var pinned: Bool
    /// Stale rows draw dimmed.
    public var stale: Bool
    /// Warning chips (`ID 重複`, `frontmatter`), drawn in the danger look.
    public var warnings: [String]
    /// The context menu (nil: the list model's `rowActions`).
    public var actions: [NoteRowAction]?

    public init(id: String, title: String, time: String, snippet: String, titleHighlights: [NSRange] = [],
                snippetHighlights: [NSRange] = [], kind: NotebookKindBadge = .note, link: NoteRowLinkChip? = nil,
                extra: String? = nil, ai: NotebookAIAccess = .read, pinned: Bool = false, stale: Bool = false,
                warnings: [String] = [], actions: [NoteRowAction]? = nil) {
        self.id = id
        self.title = title
        self.time = time
        self.snippet = snippet
        self.titleHighlights = titleHighlights
        self.snippetHighlights = snippetHighlights
        self.kind = kind
        self.link = link
        self.extra = extra
        self.ai = ai
        self.pinned = pinned
        self.stale = stale
        self.warnings = warnings
        self.actions = actions
    }
}

/// A day block: `TODAY · 10/15` + its rows (`day` nil: no separator, e.g. search results).
public struct NoteListSection: Sendable, Equatable {
    public var day: String?
    public var rows: [NoteListRow]

    public init(day: String?, rows: [NoteListRow]) {
        self.day = day
        self.rows = rows
    }
}

public struct NoteListModel: Sendable, Equatable {
    /// `Inbox` (drawn uppercase in `.h-sub`), `Search`, a project name.
    public var title: String
    public var count: String
    public var sort: NoteListSort
    /// Hides the sort button (search results keep their rank order).
    public var showsSort: Bool
    public var sections: [NoteListSection]
    public var selectedID: String?
    /// `// INBOX 6 則 · 已全部顯示` under the last row.
    public var endComment: String?
    /// Shown when there are no rows (`// 還沒有筆記 · ⌘⇧N 新增`, `// 找不到符合的筆記`).
    public var emptyText: String
    /// Default context menu of every row.
    public var rowActions: [NoteRowAction]

    public init(title: String, count: String, sort: NoteListSort = .updated, showsSort: Bool = true, sections: [NoteListSection],
                selectedID: String? = nil, endComment: String? = nil, emptyText: String = NotebookCopy.noNotesEmpty,
                rowActions: [NoteRowAction] = []) {
        self.title = title
        self.count = count
        self.sort = sort
        self.showsSort = showsSort
        self.sections = sections
        self.selectedID = selectedID
        self.endComment = endComment
        self.emptyText = emptyText
        self.rowActions = rowActions
    }

    /// Every row in display order.
    public var rows: [NoteListRow] { sections.flatMap(\.rows) }
}
