import AppKit
import CoddCodeEditor
import CoddFiles
import CoddNotes
import Observation

/// One open tab of the Files mode (D24, D27): a file in a CoddCodeEditor `CodeEditorView` over a
/// CoddFiles `OpenFileState`, or a note shown in I1a's note editor. VS Code's rules: a single click
/// opens a preview tab (italic) that the next single click replaces; a double click, an edit or a
/// save pins it.
@MainActor @Observable
final class FileTab: Identifiable {
    enum Kind: Equatable {
        case file(URL)
        case note(NoteID)
    }

    /// What SHOW AI CHANGES compares the buffer with (D27). `disk` is the banner's `比較`: the
    /// version waiting on disk while the buffer is dirty.
    enum Baseline: String, Sendable, CaseIterable {
        case head, saved, ai, disk
    }

    /// HEAD's text of the file, decoded like the file itself (raw blobs, no autocrlf).
    enum HeadText: Equatable {
        case unknown
        /// Not in HEAD (or not a repository): every line counts as added.
        case absent
        case text(String)
    }

    let id: String
    let kind: Kind
    var title: String
    var isPreview: Bool
    /// nil while loading, and for a file that cannot be shown as text (`failure`).
    var state: OpenFileState?
    /// `// 二進位檔案，無法以文字開啟` and other reasons the file shows a comment instead of text.
    var failure: String?
    var language: CodeLanguage = .plain
    /// > 5 MiB (D24): read-only, plain, no highlighting.
    var plainMode = false
    var caret = CodeCaret(line: 1, column: 1, selectionLength: 0)
    /// SHOW AI CHANGES (D27): ON when opened from an AI badge or `差異`, else OFF.
    var showAI = false
    var baseline: Baseline = .head
    /// The baseline before `比較` switched to the disk version (restored when the banner goes).
    var baselineBeforeCompare: Baseline?
    var headText: HeadText = .unknown
    /// The hunks of the buffer against the baseline (all of them, accepted ones included).
    var hunks: [DiffHunk] = []
    /// The baseline text the hunks were computed against (the revert target lines).
    var hunksBaseline: Baseline = .head
    /// `接受`: hidden (shown as a `.mod` bar) until the file or the baseline changes.
    var accepted: Set<String> = []
    /// The hunk ↑ ↓ moved to last (index into `hunks`).
    var currentHunk: Int?
    /// The find widget was opened from CODD (⌘F, the toolbar, DEBUG): the dump shows it.
    var findQuery: String?
    var findCount: (current: Int, total: Int)?
    /// Diff recomputations finished (tests wait for them).
    var diffRuns = 0
    /// The tab was opened from an AI badge or the drawer's `差異`.
    var openedFromAI = false
    /// When the tab opened (RECENT orders the open note tabs among the recent files by it).
    var openedAt = Date()

    /// The code view (file tabs; created at the first show).
    @ObservationIgnored var editor: CodeEditorView?
    @ObservationIgnored var watch: FileWatch?
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored var diffTask: Task<Void, Never>?
    /// The ⌘S write in flight (one at a time per tab; the disk watcher reads after it).
    @ObservationIgnored var saving: Task<Bool, Never>?
    @ObservationIgnored var saveGeneration = 0
    /// A disk change applied without an AI touch: a PostToolUse arriving within ±10 s attributes it
    /// afterwards (the hook usually lands just after the watcher saw the write, D25).
    @ObservationIgnored var unattributedChange: (before: String, at: Date)?
    /// The file's path with symlinks resolved (hook payloads may spell it either way).
    @ObservationIgnored let resolvedPath: String?

    init(id: String, kind: Kind, title: String, isPreview: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isPreview = isPreview
        if case .file(let url) = kind {
            resolvedPath = url.resolvingSymlinksInPath().path
        } else {
            resolvedPath = nil
        }
    }

    var url: URL? {
        if case .file(let url) = kind { return url }
        return nil
    }

    var noteID: NoteID? {
        if case .note(let id) = kind { return id }
        return nil
    }

    var isDirty: Bool { state?.isDirty ?? false }

    /// The file is read-only in the editor (Latin-1 fallback, > 5 MiB, not writable).
    var isReadOnly: Bool { state?.decoded.readOnly ?? true }

    /// `path` is this tab's file (as given or with symlinks resolved).
    func matches(path: String) -> Bool {
        guard let url else { return false }
        if url.path == path { return true }
        return resolvedPath == path || resolvedPath == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The hunk's identity for `接受` (its lines on both sides and the baseline).
    static func hunkKey(_ hunk: DiffHunk, baseline: Baseline) -> String {
        "\(baseline.rawValue)\u{1F}\(hunk.oldLines.joined(separator: "\n"))\u{1E}\(hunk.newLines.joined(separator: "\n"))"
    }

    func cancelTasks() {
        watchTask?.cancel()
        watchTask = nil
        watch?.cancel()
        watch = nil
        diffTask?.cancel()
        diffTask = nil
    }
}

/// One Files workspace (D12, D24): a project's cwd, a folder chosen with `開啟資料夾…`, or the
/// folder of a single opened file. The tree lists names only, lazily per expanded folder; git is
/// read-only (status at open, on folder changes debounced 500 ms, and after saves).
@MainActor @Observable
final class FilesWorkspace {
    let root: URL
    /// `root.path` (standardized).
    let rootPath: String
    /// The root with symlinks resolved (FSEvents and hook payloads may use either spelling).
    let resolvedRoot: String
    var name: String { root.lastPathComponent }

    /// The repository's top level; nil outside a work tree (`// 不是 git 專案`).
    var repoRoot: URL?
    /// The root relative to the repository (`""` when the root is the repository).
    var gitPrefix = ""
    var status: GitRepoStatus?
    /// Ignored paths relative to the root (dimmed rows).
    var ignored: Set<String> = []
    /// git answered at least once (or the folder is known not to be a repository).
    var gitLoaded = false
    var gitStatusMs: Double?
    var gitRuns = 0

    var expanded: Set<String> = []
    /// Loaded folder listings by root-relative folder path (`""` = the root).
    var children: [String: [FileTreeEntry]] = [:]
    var recentCollapsed = false
    var projectCollapsed = false

    /// ⌘P: the filter text, the candidates (loaded at the first filter) and the matches.
    var filter = ""
    var filterCandidates: [String]?
    var filterResults: [String] = []
    var filterIndex = 0

    var tabs: [FileTab] = []
    var selectedTabID: String?
    /// Root-relative path → the newest AI touch of that file (D26).
    var touches: [String: AITouch] = [:]

    @ObservationIgnored var directoryWatcher: DirectoryWatcher?
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored var gitTask: Task<Void, Never>?
    @ObservationIgnored var gitDebounce: Task<Void, Never>?
    @ObservationIgnored var gitGeneration = 0

    init(root: URL) {
        let standardized = root.standardizedFileURL
        self.root = standardized
        rootPath = Self.trimmed(standardized.path)
        resolvedRoot = Self.trimmed(standardized.resolvingSymlinksInPath().path)
    }

    var isRepo: Bool { repoRoot != nil }

    var selectedTab: FileTab? { selectedTabID.flatMap { id in tabs.first { $0.id == id } } }

    /// `path` (absolute, either spelling) relative to the root; nil outside it.
    func relativePath(_ path: String) -> String? {
        for base in [rootPath, resolvedRoot] {
            if path == base { return "" }
            if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        }
        let resolved = Self.trimmed(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        if resolved != path { return relativePath(resolved) }
        return nil
    }

    /// The git path (repository-relative) of a root-relative path.
    func gitPath(_ relative: String) -> String {
        gitPrefix.isEmpty ? relative : (relative.isEmpty ? gitPrefix : gitPrefix + "/" + relative)
    }

    /// The root-relative path of a repository-relative one; nil outside the root.
    func rootRelative(gitPath: String) -> String? {
        if gitPrefix.isEmpty { return gitPath }
        if gitPath == gitPrefix { return "" }
        guard gitPath.hasPrefix(gitPrefix + "/") else { return nil }
        return String(gitPath.dropFirst(gitPrefix.count + 1))
    }

    func url(of relative: String) -> URL {
        relative.isEmpty ? root : root.appendingPathComponent(relative)
    }

    /// git's change of a root-relative path.
    func change(_ relative: String) -> GitFileChange? { status?.changes[gitPath(relative)] }

    func folderContainsChanges(_ relative: String) -> Bool { status?.folderContainsChanges(gitPath(relative)) ?? false }

    /// The changed paths under the root, root-relative (the drawer, the head's `M n`).
    var changedPaths: [String] {
        (status?.changes.keys.compactMap { rootRelative(gitPath: $0) } ?? []).sorted()
    }

    func cancelTasks() {
        watchTask?.cancel()
        watchTask = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
        gitTask?.cancel()
        gitDebounce?.cancel()
        for tab in tabs { tab.cancelTasks() }
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
