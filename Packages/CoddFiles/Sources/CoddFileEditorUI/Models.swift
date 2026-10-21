import AppKit
import CoddFiles
import CoddUI

// MARK: - Tree

/// The `AI` chip of a file a CODD session edited (D26): in the session's color tag, a bone
/// outline when the session has none.
public struct AIChip: Equatable {
    public var color: NSColor?

    public init(color: NSColor?) {
        self.color = color
    }
}

/// One row of the tree (`.fe-node`): a file, a folder, or the `…` marker of a folder cut at
/// 2,000 entries. The app flattens its expanded folders into these rows.
public struct FileTreeRow: Equatable, Identifiable {
    public enum Kind: Equatable {
        case file
        case folder(expanded: Bool)
        /// The marker after the first 2,000 entries (`… 還有 n 個項目`).
        case overflow(count: Int)
    }

    /// The path the callbacks get (root-relative for project rows; the app's own id for Recent
    /// rows such as a note).
    public var id: String
    public var name: String
    public var kind: Kind
    /// Nesting level (`--d`): 14 pt per level.
    public var depth: Int
    /// `.fe-ext` (files; empty for none).
    public var ext: String
    /// The folder hint after the name in RECENT (`src/pages`, `notebook`, `/`).
    public var dirHint: String?
    /// git `M` (any change git reports).
    public var modified: Bool
    public var ai: AIChip?
    /// A folder that contains changes (`.fe-fdot`).
    public var containsChanges: Bool
    /// git-ignored (`.fe-node.ign`, drawn dimmer).
    public var ignored: Bool

    public init(id: String, name: String, kind: Kind = .file, depth: Int = 0, ext: String? = nil, dirHint: String? = nil,
                modified: Bool = false, ai: AIChip? = nil, containsChanges: Bool = false, ignored: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.depth = depth
        self.ext = ext ?? (kind == .file ? FileExt.label(for: name) : "")
        self.dirHint = dirHint
        self.modified = modified
        self.ai = ai
        self.containsChanges = containsChanges
        self.ignored = ignored
    }

    /// A project row for a CoddFiles tree entry.
    public init(entry: FileTreeEntry, depth: Int, expanded: Bool = false, modified: Bool = false, ai: AIChip? = nil,
                containsChanges: Bool = false) {
        let kind: Kind = entry.isOverflow ? .overflow(count: entry.overflowCount) : (entry.isDirectory ? .folder(expanded: expanded) : .file)
        self.init(id: entry.isOverflow ? entry.id : entry.relativePath, name: entry.name, kind: kind, depth: depth, modified: modified,
                  ai: ai, containsChanges: containsChanges, ignored: entry.isIgnored)
    }

    public var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}

/// The tree head's git line (`⎇ feat/punch-rwd ↑2 · M 3`).
public struct FileTreeGitHead: Equatable {
    /// The branch, or `(detached)`.
    public var branch: String
    public var ahead: Int
    public var behind: Int
    public var modified: Int

    public init(branch: String, ahead: Int = 0, behind: Int = 0, modified: Int = 0) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.modified = modified
    }

    public init(status: GitRepoStatus) {
        self.init(branch: status.branch ?? "(detached)", ahead: status.ahead, behind: status.behind, modified: status.changes.count)
    }
}

/// The tree foot's session line (`● ▪ 打卡頁 RWD 調整 · AI 改 2 · 10:41`).
public struct FileTreeSessionLine: Equatable {
    public var lamp: String
    public var lampColor: NSColor
    public var tag: NSColor?
    public var title: String
    /// The right side (`AI 改 2 · 10:41`).
    public var detail: String

    public init(lamp: String = "●", lampColor: NSColor = Palette.success, tag: NSColor?, title: String, detail: String) {
        self.lamp = lamp
        self.lampColor = lampColor
        self.tag = tag
        self.title = title
        self.detail = detail
    }
}

public enum FileTreeSection: Sendable, Equatable {
    case recent, project
}

/// Everything ``FileTreeView`` shows.
public struct FileTreeModelView: Equatable {
    public var project: String
    /// nil: not a repository (`// 不是 git 專案`, no badges).
    public var git: FileTreeGitHead?
    public var aiCount: Int
    /// The `AI n` color in the head (the session's tag; nil bone).
    public var aiColor: NSColor?
    /// The filter field's text (set by the app, e.g. cleared after ⏎).
    public var filter: String
    public var recent: [FileTreeRow]
    public var recentCollapsed: Bool
    public var rows: [FileTreeRow]
    public var projectCollapsed: Bool
    /// The open file's row id (`.cur`).
    public var currentID: String?
    /// The foot's `LOCAL` path (already abbreviated).
    public var footPath: String
    public var session: FileTreeSessionLine?
    /// The new-file button stays disabled in M4 (tooltip `新增檔案（之後提供）`).
    public var newFileEnabled: Bool

    public init(project: String, git: FileTreeGitHead? = nil, aiCount: Int = 0, aiColor: NSColor? = nil, filter: String = "",
                recent: [FileTreeRow] = [], recentCollapsed: Bool = false, rows: [FileTreeRow] = [], projectCollapsed: Bool = false,
                currentID: String? = nil, footPath: String, session: FileTreeSessionLine? = nil, newFileEnabled: Bool = false) {
        self.project = project
        self.git = git
        self.aiCount = aiCount
        self.aiColor = aiColor
        self.filter = filter
        self.recent = recent
        self.recentCollapsed = recentCollapsed
        self.rows = rows
        self.projectCollapsed = projectCollapsed
        self.currentID = currentID
        self.footPath = footPath
        self.session = session
        self.newFileEnabled = newFileEnabled
    }
}

// MARK: - Tabs

/// One `.fe-tab`.
public struct EditorTab: Equatable, Identifiable {
    public var id: String
    public var title: String
    /// `.fe-ext` before the name; nil with `isNote` (the note icon instead).
    public var ext: String?
    public var isNote: Bool
    public var isDirty: Bool
    /// A preview tab (italic, dim) that the next single click replaces.
    public var isPreview: Bool
    /// The `AI` chip after the name (D26).
    public var ai: AIChip?

    public init(id: String, title: String, ext: String? = nil, isNote: Bool = false, isDirty: Bool = false, isPreview: Bool = false,
                ai: AIChip? = nil) {
        self.id = id
        self.title = title
        self.ext = isNote ? nil : (ext ?? FileExt.label(for: title))
        self.isNote = isNote
        self.isDirty = isDirty
        self.isPreview = isPreview
        self.ai = ai
    }
}

/// The tab strip's session pill (`● ▪ 打卡頁 RWD 調整 Edit · 6m ⌘9`).
public struct EditorSessionPill: Equatable {
    public var lamp: String
    public var lampColor: NSColor
    public var tag: NSColor?
    public var title: String
    /// `Edit · 6m` (faint).
    public var detail: String?
    /// `⌘9`.
    public var shortcut: String?

    public init(lamp: String = "●", lampColor: NSColor = Palette.success, tag: NSColor?, title: String, detail: String? = nil,
                shortcut: String? = nil) {
        self.lamp = lamp
        self.lampColor = lampColor
        self.tag = tag
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
    }
}

public struct EditorTabStripModel: Equatable {
    public var tabs: [EditorTab]
    public var selectedID: String?
    public var session: EditorSessionPill?

    public init(tabs: [EditorTab], selectedID: String?, session: EditorSessionPill? = nil) {
        self.tabs = tabs
        self.selectedID = selectedID
        self.session = session
    }
}

// MARK: - Toolbar

/// One breadcrumb part (`src › pages › punch.vue › <style> › .punch-sticky`).
public struct EditorCrumb: Equatable {
    public enum Kind: Equatable {
        /// A folder (a link, dim, amber on hover).
        case folder
        /// The open file (cream).
        case file
        /// A symbol inside the file (dim text).
        case symbol
    }

    public var title: String
    public var kind: Kind

    public init(_ title: String, kind: Kind) {
        self.title = title
        self.kind = kind
    }

    /// `src/pages/punch.vue` → folder, folder, file crumbs.
    public static func path(_ relativePath: String) -> [EditorCrumb] {
        let parts = relativePath.split(separator: "/").map(String.init)
        return parts.enumerated().map { EditorCrumb($0.element, kind: $0.offset == parts.count - 1 ? .file : .folder) }
    }
}

public struct EditorToolbarModel: Equatable {
    public var crumbs: [EditorCrumb]
    /// `AI 變更 n 段` with ↑ ↓; nil hides them (no AI changes to step through).
    public var aiChangeCount: Int?
    public var showAIChanges: Bool
    /// `基準：git HEAD`, `基準：上次儲存 10:39`, `基準：AI 開始前 10:30`.
    public var baselines: [String]
    public var baselineEnabled: [Bool]
    public var selectedBaseline: Int

    public init(crumbs: [EditorCrumb], aiChangeCount: Int? = nil, showAIChanges: Bool = false, baselines: [String] = [],
                baselineEnabled: [Bool] = [], selectedBaseline: Int = 0) {
        self.crumbs = crumbs
        self.aiChangeCount = aiChangeCount
        self.showAIChanges = showAIChanges
        self.baselines = baselines
        self.baselineEnabled = baselineEnabled
        self.selectedBaseline = selectedBaseline
    }

    /// The three baseline titles (D27); `aiStart` nil leaves the AI item out.
    public static func baselineTitles(lastSave: String, aiStart: String?) -> [String] {
        ["基準：git HEAD", "基準：上次儲存 \(lastSave)"] + (aiStart.map { ["基準：AI 開始前 \($0)"] } ?? [])
    }
}

// MARK: - Banner

/// `.banner.warn` for a file (or, with ``noteChanged``, a note: D7 reuses the view).
public struct DiskChangeBannerModel: Equatable {
    public var title: String
    /// `· 你有未儲存的修改`.
    public var showsUnsaved: Bool
    /// 重新載入 (off when the disk version is not text).
    public var canReload: Bool

    public init(title: String, showsUnsaved: Bool = true, canReload: Bool = true) {
        self.title = title
        self.showsUnsaved = showsUnsaved
        self.canReload = canReload
    }

    /// `磁碟上的檔案已被 AI 變更（<session> · HH:mm）` or `磁碟上的檔案已變更`.
    public static func fileChanged(aiSession: String?, time: String?, showsUnsaved: Bool = true, canReload: Bool = true) -> Self {
        if let aiSession {
            let suffix = time.map { " · \($0)" } ?? ""
            return Self(title: "磁碟上的檔案已被 AI 變更（\(aiSession)\(suffix)）", showsUnsaved: showsUnsaved, canReload: canReload)
        }
        return Self(title: "磁碟上的檔案已變更", showsUnsaved: showsUnsaved, canReload: canReload)
    }

    /// D7: the notes editor's banner.
    public static func noteChanged(showsUnsaved: Bool = true) -> Self {
        Self(title: "磁碟上的筆記已變更", showsUnsaved: showsUnsaved)
    }
}

// MARK: - Status items

public enum EditorStatusItem: Sendable, Equatable, CaseIterable {
    case position, encoding, lineEnding, language, indentation
}

/// The editor's part of the app status bar.
public struct EditorStatusModel: Equatable {
    public enum Saved: Equatable {
        /// `● 已儲存 10:39` (amber-dim dot).
        case saved(String)
        /// `● 未儲存` (amber dot).
        case dirty
        /// `唯讀`.
        case readOnly
        case none
    }

    /// `feat/punch-rwd`; nil hides the branch item.
    public var branch: String?
    public var ahead: Int
    public var session: (tag: NSColor?, title: String)?
    public var line: Int
    public var column: Int
    public var encoding: String
    public var lineEnding: String
    public var language: String
    public var indentation: String
    public var saved: Saved

    public init(branch: String? = nil, ahead: Int = 0, session: (tag: NSColor?, title: String)? = nil, line: Int = 1, column: Int = 1,
                encoding: String = "UTF-8", lineEnding: String = "LF", language: String = "Plain Text", indentation: String = "—",
                saved: Saved = .none) {
        self.branch = branch
        self.ahead = ahead
        self.session = session
        self.line = line
        self.column = column
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.language = language
        self.indentation = indentation
        self.saved = saved
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.branch == rhs.branch && lhs.ahead == rhs.ahead && lhs.session?.tag == rhs.session?.tag && lhs.session?.title == rhs.session?.title
            && (lhs.session == nil) == (rhs.session == nil) && lhs.line == rhs.line && lhs.column == rhs.column && lhs.encoding == rhs.encoding
            && lhs.lineEnding == rhs.lineEnding && lhs.language == rhs.language && lhs.indentation == rhs.indentation && lhs.saved == rhs.saved
    }

    /// Encoding, EOL and indentation texts from a decoded file (`CRLF*` when mixed).
    public init(decoded: DecodedText, branch: String?, ahead: Int = 0, session: (tag: NSColor?, title: String)?, line: Int, column: Int,
                language: String, saved: Saved) {
        self.init(branch: branch, ahead: ahead, session: session, line: line, column: column, encoding: decoded.encoding.label,
                  lineEnding: decoded.lineEnding.label + (decoded.mixedLineEndings ? "*" : ""), language: language,
                  indentation: decoded.indentation.label, saved: saved)
    }
}

extension TextEncodingKind {
    /// The status bar text.
    public var label: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 BOM"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .big5: "Big5"
        case .latin1: "Latin-1"
        }
    }
}

extension LineEnding {
    public var label: String { rawValue.uppercased() }
}

extension Indentation {
    public var label: String {
        switch self {
        case .spaces(let count): "\(count) spaces"
        case .tabs: "Tab"
        case .unknown: "—"
        }
    }
}

// MARK: - Dirty close

public enum DirtyCloseChoice: Sendable, Equatable {
    case save, discard, cancel
}
