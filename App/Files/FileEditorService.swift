import AppKit
import CoddCodeEditor
import CoddCore
import CoddFileEditorUI
import CoddFiles
import CoddNotes
import CoddUI
import Observation

/// The local file editor (M4 I3; D12, D24–D27): the Files workspaces, their tabs, the open files'
/// states, read-only git, the AI touches and SHOW AI CHANGES. Only files the user opens are read;
/// nothing is written except by ⌘S (`save`) or the dirty-close sheet's `儲存` (`close(_:choice:)`).
/// File reads, git and saves run off the main actor; the views read this model.
@MainActor @Observable
final class FileEditorService {
    @ObservationIgnored let git: any GitReading
    @ObservationIgnored let recentStore: RecentFilesStore?
    @ObservationIgnored let touchLog: AITouchLog?
    @ObservationIgnored let store: any SessionStore
    /// The display clock (the notes clock: mock mode's 10/15 10:42, DEBUG `-codd-now`).
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored let timeZone: TimeZone
    @ObservationIgnored let log: (String) -> Void
    /// Mock mode (D35): the mock project and a fixed `GitReading`; no live watchers needed.
    @ObservationIgnored let isMock: Bool
    /// Note tabs show the note in I1a's editor (set by the app).
    @ObservationIgnored weak var noteEditor: NoteEditorController?
    /// A session's cwd as a folder path (`~` expanded; mock mode maps its project onto the
    /// written mock project).
    @ObservationIgnored var rootForCwd: (String) -> String = { PathFormatShim.expandTilde($0) }
    /// A note file of the notebook (its id and title): opened as a note tab, never as text (the
    /// note editor keeps its frontmatter, autosave and history rules).
    @ObservationIgnored var noteResolver: ((URL) -> (id: NoteID, title: String)?)?
    @ObservationIgnored var notesRoot: URL?
    /// `<dataRoot>/files/unsaved` (real mode): where a quit that cannot ask keeps unsaved buffers.
    @ObservationIgnored var unsavedFolder: URL?

    private(set) var workspaces: [FilesWorkspace] = []
    private(set) var current: FilesWorkspace?
    private(set) var recent: [RecentFile] = []
    /// Bumped when AI touches arrive (models that show chips follow it).
    private(set) var touchRevision = 0
    /// The area shows the Files mode: the folder watchers run only then.
    private(set) var isActive = false
    private(set) var saveCount = 0
    private(set) var lastSave: (path: String, ok: Bool, error: String?)?
    private(set) var lastOpen: (path: String, ms: Double, bytes: Int64)?
    private(set) var lastRefusal: String?

    /// A toast in the Files mode (refusals, saves).
    @ObservationIgnored var onToast: ((String) -> Void)?
    /// ⌘1–9 of a session in sidebar order (the tab strip's session pill).
    @ObservationIgnored var sessionNumber: (SessionID) -> Int? = { _ in nil }
    /// A note tab was selected: the area shows the note editor in the editor slot.
    @ObservationIgnored var onNoteTabShown: ((NoteID) -> Void)?

    /// ±10 s (D25): a disk change and a CODD session's PostToolUse naming the file this close
    /// together are the session's change.
    nonisolated static let attributionWindow: TimeInterval = 10
    /// D24: folder changes refresh git this long after the last one.
    static let gitDebounce: Duration = .milliseconds(500)
    /// D27: the hunks follow edits this long after the last one.
    static let diffDebounce: Duration = .milliseconds(300)
    /// ⌘P shows at most this many matches.
    static let filterLimit = 60

    init(git: any GitReading, recentStore: RecentFilesStore?, touchLog: AITouchLog?, store: any SessionStore,
         clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current, isMock: Bool = false,
         log: @escaping (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.git = git
        self.recentStore = recentStore
        self.touchLog = touchLog
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        self.isMock = isMock
        self.log = log
    }

    // MARK: Copy (D24, D34)

    static let binaryText = "// 二進位檔案，無法以文字開啟"
    static let readOnlyText = "這個檔案是唯讀的"
    static let tooLargeText = "檔案超過 50 MB，無法開啟"
    static let bannerFirstText = "磁碟上的檔案已變更：先選［重新載入］或［保留我的］"
    static let changedOnDiskText = "磁碟上的檔案已變更，沒有儲存：先選［重新載入］或［保留我的］"
    static let noTabText = "// 從左側選一個檔案 · ⌘P 篩選"
    static let notRepoText = "// 不是 git 專案"

    // MARK: Lifecycle

    /// The Files mode came on screen or left it: the current workspace's folder watcher runs only
    /// while it shows; coming back refreshes git once.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard let current else { return }
        if active {
            startWatching(current)
            refreshGit(current, ignored: true)
        } else {
            stopWatching(current)
        }
    }

    /// Stops every watcher and task (quit, tests).
    func shutdown() {
        for workspace in workspaces { workspace.cancelTasks() }
        touchLog?.flush()
    }

    // MARK: Workspaces

    /// Opens (or shows) the workspace at `folder`: its root listing, git and, while the Files
    /// mode shows, its folder watcher.
    @discardableResult
    func openRoot(_ folder: URL) -> FilesWorkspace {
        let standardized = folder.standardizedFileURL
        let path = FilesWorkspace.trimmed(standardized.path)
        let resolved = FilesWorkspace.trimmed(standardized.resolvingSymlinksInPath().path)
        let workspace = workspaces.first { $0.rootPath == path || $0.resolvedRoot == resolved } ?? {
            let made = FilesWorkspace(root: standardized)
            workspaces.append(made)
            log("files workspace open root=\(HolderSessionStore.abbreviate(made.rootPath))")
            loadChildren(made, folder: "")
            refreshGit(made, ignored: true)
            refreshTouches(made)
            return made
        }()
        if current !== workspace {
            if let current, isActive { stopWatching(current) }
            current = workspace
            if isActive { startWatching(workspace) }
        }
        loadRecent()
        return workspace
    }

    /// The workspace that holds `url`: the deepest open root containing it, else the deepest
    /// project cwd containing it, else a new one at the file's folder (D12: a single opened file
    /// opens its folder).
    func workspace(for url: URL) -> FilesWorkspace {
        let path = url.standardizedFileURL.path
        let containing = workspaces.filter { $0.relativePath(path) != nil }.max { $0.rootPath.count < $1.rootPath.count }
        return containing ?? openRoot(projectRoot(containing: path) ?? url.deletingLastPathComponent())
    }

    /// The deepest project cwd (either spelling) that contains `path`.
    func projectRoot(containing path: String) -> URL? {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var best: String?
        for group in store.groups {
            for id in group.projectIDs {
                guard let project = store.project(id) else { continue }
                let cwd = FilesWorkspace.trimmed(URL(fileURLWithPath: rootForCwd(project.cwd)).standardizedFileURL.path)
                let resolvedCwd = FilesWorkspace.trimmed(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
                let inside = path.hasPrefix(cwd + "/") || resolvedPath.hasPrefix(resolvedCwd + "/")
                if inside, cwd.count > (best?.count ?? 0) { best = cwd }
            }
        }
        return best.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Opening files

    /// Opens `url` in a tab (D24, VS Code rules): `preview` replaces the current preview tab, an
    /// already open tab is selected (and pinned when `preview` is false). `showAI` turns SHOW AI
    /// CHANGES on (an AI badge, the drawer's `差異`). `source` is the RECENT entry's (nil: not
    /// recorded). Nil when the file was refused (> 50 MB, unreadable): a toast says why.
    @discardableResult
    func open(_ url: URL, preview: Bool, showAI: Bool = false, root: URL? = nil, source: String? = "user") async -> FileTab? {
        let file = url.standardizedFileURL
        let workspace = root.map { openRoot($0) } ?? workspace(for: file)
        if current !== workspace { _ = openRoot(workspace.root) }
        if let note = noteResolver?(file) {
            return openNote(note.id, title: note.title.isEmpty ? file.deletingPathExtension().lastPathComponent : note.title, preview: preview)
        }
        let id = file.path
        if let existing = workspace.tabs.first(where: { $0.id == id || $0.matches(path: id) }) {
            if !preview { existing.isPreview = false }
            select(existing.id)
            if showAI { setShowAI(existing, on: true) }
            return existing
        }
        let started = ContinuousClock.now
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<(OpenFileState, Bool), Error> in
            do {
                let state = try OpenFileState.load(file)
                return .success((state, Darwin.access(file.path, W_OK) == 0))
            } catch {
                return .failure(error)
            }
        }.value
        let tab = FileTab(id: id, kind: .file(file), title: file.lastPathComponent, isPreview: preview)
        tab.openedFromAI = showAI
        switch loaded {
        case .success(let (loadedState, writable)):
            var state = loadedState
            if !writable { state.decoded.readOnly = true }
            state.savedAt = clock()
            tab.state = state
            tab.plainMode = state.disk.size > Int64(TextFileCodec.readOnlyBytes)
            if tab.plainMode { tab.state?.decoded.readOnly = true }
            let firstLine = state.decoded.text.prefix(while: { $0 != "\n" })
            tab.language = CodeLanguageDetector.language(fileName: file.lastPathComponent, firstLine: String(firstLine.prefix(200)))
        case .failure(let error):
            if let refusal = Self.refusal(error, name: file.lastPathComponent) {
                lastRefusal = refusal
                onToast?(refusal)
                log("files open refused name=\(file.lastPathComponent) reason=\(Self.reasonCode(error))")
                return nil
            }
            tab.failure = Self.binaryText
        }
        insert(tab, into: workspace, preview: preview)
        if tab.state != nil {
            makeEditor(for: tab)
            startFileWatch(tab)
        }
        // Read, decode, and the code view's load with its first highlighted screen.
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        lastOpen = (file.path, ms, tab.state?.disk.size ?? 0)
        select(tab.id)
        if let source { recordRecent(file, root: workspace.root, source: source) }
        log("files open name=\(file.lastPathComponent) bytes=\(tab.state?.disk.size ?? 0) preview=\(preview) "
            + "binary=\(tab.failure != nil) readOnly=\(tab.state?.decoded.readOnly ?? true) ms=\(String(format: "%.1f", ms))")
        if showAI { setShowAI(tab, on: true) }
        return tab
    }

    /// A tab over a state built elsewhere (mock mode's artboard state, tests): its editor and,
    /// outside mock mode, its watch.
    @discardableResult
    func install(_ state: OpenFileState, in workspace: FilesWorkspace, preview: Bool) -> FileTab {
        let url = state.url.standardizedFileURL
        if let existing = workspace.tabs.first(where: { $0.id == url.path }) { remove(existing) }
        let tab = FileTab(id: url.path, kind: .file(url), title: url.lastPathComponent, isPreview: preview)
        tab.state = state
        tab.plainMode = state.disk.size > Int64(TextFileCodec.readOnlyBytes)
        let firstLine = state.decoded.text.prefix(while: { $0 != "\n" })
        tab.language = CodeLanguageDetector.language(fileName: url.lastPathComponent, firstLine: String(firstLine.prefix(200)))
        if current !== workspace { _ = openRoot(workspace.root) }
        insert(tab, into: workspace, preview: preview)
        makeEditor(for: tab)
        if !isMock { startFileWatch(tab) }
        select(tab.id)
        return tab
    }

    /// A note as a tab (the tree's RECENT note rows): shown in the note editor (I1a binding).
    @discardableResult
    func openNote(_ id: NoteID, title: String, preview: Bool) -> FileTab? {
        guard let workspace = current else { return nil }
        let tabID = "note:\(id.rawValue)"
        if let existing = workspace.tabs.first(where: { $0.id == tabID }) {
            if !preview { existing.isPreview = false }
            select(tabID)
            return existing
        }
        let tab = FileTab(id: tabID, kind: .note(id), title: title, isPreview: preview)
        insert(tab, into: workspace, preview: preview)
        select(tabID)
        return tab
    }

    /// A new tab goes after the selected one; a preview tab replaces the clean preview tab (the
    /// next single click replaces it, VS Code).
    private func insert(_ tab: FileTab, into workspace: FilesWorkspace, preview: Bool) {
        if preview, let index = workspace.tabs.firstIndex(where: { $0.isPreview && !$0.isDirty }) {
            workspace.tabs[index].cancelTasks()
            workspace.tabs[index] = tab
            return
        }
        if let selected = workspace.selectedTabID, let index = workspace.tabs.firstIndex(where: { $0.id == selected }) {
            workspace.tabs.insert(tab, at: index + 1)
        } else {
            workspace.tabs.append(tab)
        }
    }

    /// The toast for an open that must not become a tab (nil: show the tab with the binary comment).
    static func refusal(_ error: Error, name: String) -> String? {
        switch error {
        case TextFileError.binary: return nil
        case TextFileError.tooLarge, FileReadError.tooLarge: return tooLargeText
        case FileReadError.notAFile: return "無法開啟 \(name)：不是一般檔案"
        case FileReadError.open(_, let code), FileReadError.read(_, let code):
            return "無法開啟 \(name)（\(String(cString: strerror(code)))）"
        default: return "無法開啟 \(name)"
        }
    }

    static func reasonCode(_ error: Error) -> String {
        switch error {
        case TextFileError.tooLarge, FileReadError.tooLarge: "too-large"
        case FileReadError.notAFile: "not-a-file"
        case FileReadError.open, FileReadError.read: "unreadable"
        default: "other"
        }
    }

    /// M4 interface zoom: every tab's code view at the zoomed code size, shown or not.
    func applyZoom() {
        for workspace in workspaces {
            for tab in workspace.tabs { if let editor = tab.editor { Self.applyZoom(editor) } }
        }
    }

    /// The FileEditor artboard's 12.5 pt code at the current interface zoom (rows follow it).
    static func applyZoom(_ editor: CodeEditorView) {
        let size = CodeEditorStyle.fileEditor.fontSize * UIZoom.scale
        if editor.fontSize != size { editor.fontSize = size }
    }

    private func makeEditor(for tab: FileTab) {
        guard let state = tab.state else { return }
        let editor = CodeEditorView()
        Self.applyZoom(editor)
        // A background tab's view is out of the window: refreshed by a zoom change all the same.
        UIZoom.track(editor)
        editor.load(state.buffer, language: tab.language, readOnly: state.decoded.readOnly, plainMode: tab.plainMode)
        editor.onTextChange = { [weak self, weak tab] text in
            guard let self, let tab else { return }
            self.edited(tab, text: text)
        }
        editor.onCaretChange = { [weak tab] caret in tab?.caret = caret }
        editor.onHunkAction = { [weak self, weak tab] id, action in
            guard let self, let tab else { return }
            self.hunkAction(tab, index: id, action: action)
        }
        editor.onFindChange = { [weak tab] query, _, current, total in
            tab?.findQuery = query
            tab?.findCount = (current, total)
        }
        tab.editor = editor
    }

    /// A committed edit (never marked text): the buffer, the pin (D24), the hunks 300 ms later.
    private func edited(_ tab: FileTab, text: String) {
        guard var state = tab.state else { return }
        state.edit(text)
        tab.state = state
        if tab.isPreview { tab.isPreview = false }
        scheduleDiff(tab)
    }

    // MARK: Tabs

    var selectedTab: FileTab? { current?.selectedTab }

    func tab(_ id: String) -> FileTab? {
        for workspace in workspaces { if let tab = workspace.tabs.first(where: { $0.id == id }) { return tab } }
        return nil
    }

    func select(_ id: String) {
        guard let workspace = current, let tab = workspace.tabs.first(where: { $0.id == id }) else { return }
        workspace.selectedTabID = id
        if let note = tab.noteID { onNoteTabShown?(note) }
        if tab.showAI, tab.hunks.isEmpty { scheduleDiff(tab, immediately: true) }
    }

    /// Double click on a tab, an edit or a save: the preview tab stays.
    func pin(_ id: String) {
        tab(id)?.isPreview = false
    }

    enum CloseRequest: Equatable {
        case closed
        /// The tab is dirty: the dirty-close sheet asks (`[儲存] [不儲存] [取消]`).
        case needsConfirmation
        case none
    }

    /// ⌘W / the tab's ✕. A dirty file tab is not closed: the caller shows the sheet and calls
    /// `close(_:choice:)`.
    func requestClose(_ id: String) -> CloseRequest {
        guard let tab = tab(id) else { return .none }
        if tab.isDirty { return .needsConfirmation }
        remove(tab)
        return .closed
    }

    /// The dirty-close sheet's answer: `儲存` saves first (a refused save keeps the tab), `不儲存`
    /// drops the edits (nothing is written), `取消` keeps the tab.
    func close(_ id: String, choice: DirtyCloseChoice) async {
        guard let tab = tab(id) else { return }
        switch choice {
        case .cancel:
            return
        case .discard:
            log("files close discard name=\(tab.title)")
            remove(tab)
        case .save:
            if await save(tab) { remove(tab) }
        }
    }

    private func remove(_ tab: FileTab) {
        guard let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }),
              let index = workspace.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.cancelTasks()
        workspace.tabs.remove(at: index)
        if workspace.selectedTabID == tab.id {
            let next = workspace.tabs.indices.contains(index) ? workspace.tabs[index] : workspace.tabs.last
            workspace.selectedTabID = nil
            if let next { select(next.id) }
        }
    }

    // MARK: Saving (D24)

    /// ⌘S: the buffer through `FileSaver` with the load fingerprint. Refused for read-only files
    /// (`這個檔案是唯讀的`), while the disk banner waits for 重新載入 / 保留我的, and when the disk
    /// changed since the load (the banner then shows). A clean buffer writes nothing.
    ///
    /// One write at a time per tab: a second ⌘S waits for the first and then starts from its
    /// fingerprint (two writes against the same `expected` would refuse CODD's own write as a
    /// change on disk). Text typed while the write runs stays unsaved (the tab stays dirty).
    @discardableResult
    func save(_ tab: FileTab) async -> Bool {
        while let running = tab.saving { _ = await running.value }
        tab.saveGeneration += 1
        let generation = tab.saveGeneration
        let task = Task { @MainActor [weak self] () -> Bool in
            // Cleared inside the task, so a waiter that wakes at its end never sees it again.
            defer { if tab.saveGeneration == generation { tab.saving = nil } }
            return await self?.performSave(tab) ?? false
        }
        tab.saving = task
        return await task.value
    }

    private func performSave(_ tab: FileTab) async -> Bool {
        if let note = tab.noteID {
            if noteEditor?.noteID == note { await noteEditor?.flush() }
            return true
        }
        guard let url = tab.url, let state = tab.state else { return false }
        guard tab.editor?.isComposing != true else { return false }
        if state.decoded.readOnly { return refuseSave(tab, Self.readOnlyText, code: "read-only") }
        if state.showsBanner { return refuseSave(tab, Self.bannerFirstText, code: "banner") }
        guard state.isDirty else {
            tab.isPreview = false
            return true
        }
        let data: Data
        do {
            data = try state.encodedBuffer()
        } catch TextFileError.unencodable(let kind) {
            return refuseSave(tab, "這個檔案的編碼（\(kind.label)）存不下輸入的字元", code: "unencodable")
        } catch {
            return refuseSave(tab, "無法儲存 \(tab.title)", code: "encode")
        }
        let expected = state.disk
        // What goes to disk: keystrokes during the write change `tab.state.buffer`, not this.
        let written = state.buffer
        let result = await Task.detached(priority: .userInitiated) { () -> Result<FileFingerprint, Error> in
            Result { try FileSaver.save(data, to: url, expected: expected, force: false) }
        }.value
        switch result {
        case .success(let fingerprint):
            guard var latest = tab.state else { return false }
            latest.saved(fingerprint, at: clock(), text: written)
            tab.state = latest
            tab.isPreview = false
            saveCount += 1
            lastSave = (url.path, true, nil)
            log("files save name=\(tab.title) bytes=\(data.count)")
            if let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }) { refreshGit(workspace, ignored: false) }
            scheduleDiff(tab, immediately: true)
            return true
        case .failure(FileSaveError.changedOnDisk):
            _ = refuseSave(tab, Self.changedOnDiskText, code: "changed-on-disk")
            Task { await self.readDisk(tab) }
            return false
        case .failure(FileSaveError.readOnly):
            return refuseSave(tab, Self.readOnlyText, code: "read-only")
        case .failure(let error):
            return refuseSave(tab, "無法儲存 \(tab.title)（\(Self.saveErrorText(error))）", code: "io")
        }
    }

    private func refuseSave(_ tab: FileTab, _ text: String, code: String) -> Bool {
        lastSave = (tab.url?.path ?? tab.id, false, code)
        lastRefusal = text
        onToast?(text)
        log("files save refused name=\(tab.title) reason=\(code)")
        return false
    }

    static func saveErrorText(_ error: Error) -> String {
        switch error {
        case FileSaveError.notAFile: "不是一般檔案"
        case FileSaveError.io(_, let operation, let code): "\(operation): \(String(cString: strerror(code)))"
        default: "\(error)"
        }
    }

    // MARK: Quit (D24)

    /// File tabs with unsaved edits (a note tab never counts: the notebook saves itself).
    var dirtyTabs: [FileTab] { workspaces.flatMap(\.tabs).filter { $0.url != nil && $0.isDirty } }

    /// A quit that cannot ask (logout, restart, `-codd-quit-after`) with dirty tabs: each buffer
    /// is written in its file's own encoding to `<folder>/<yyyyMMdd-HHmmss>/<name>` (0600), never
    /// over the file, so the edits outlive the quit. Returns the copies written.
    @discardableResult
    func preserveDirtyTabs(in folder: URL, tabs: [FileTab]) -> [URL] {
        guard !tabs.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: clock())
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
        let target = folder.appendingPathComponent(stamp, isDirectory: true)
        var written: [URL] = []
        var names = Set<String>()
        for tab in tabs {
            guard let url = tab.url, let state = tab.state else { continue }
            let data = (try? state.encodedBuffer()) ?? Data(state.buffer.utf8)
            var name = url.lastPathComponent
            var n = 2
            while names.contains(name) {
                name = "\((url.lastPathComponent as NSString).deletingPathExtension) \(n)"
                    + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
                n += 1
            }
            names.insert(name)
            let copy = target.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: copy, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                written.append(copy)
                log("files quit kept unsaved name=\(tab.title) copy=\(HolderSessionStore.abbreviate(copy.path))")
            } catch {
                log("files quit unsaved copy failed name=\(tab.title): \(error.localizedDescription)")
            }
        }
        return written
    }

    // MARK: Disk changes (D25)

    private func startFileWatch(_ tab: FileTab) {
        guard let url = tab.url, tab.watch == nil else { return }
        let watch = FileWatch(url: url)
        tab.watch = watch
        let events = watch.events
        tab.watchTask = Task { [weak self, weak tab] in
            for await event in events {
                guard let self, let tab else { return }
                if event == .modified { await self.readDisk(tab) }
            }
        }
    }

    /// The watcher saw the file change: read it off the main actor and let the state decide
    /// (D25): a clean buffer reloads in place (caret and scroll kept), a dirty one shows the
    /// banner, attributed to a CODD session whose PostToolUse named the file within ±10 s.
    func readDisk(_ tab: FileTab) async {
        guard let url = tab.url else { return }
        // CODD's own write: read after it, against the fingerprint it recorded (else its bytes
        // look like another program's change and a dirty tab gets the banner).
        if let running = tab.saving { _ = await running.value }
        let paths = [url.path, tab.resolvedPath].compactMap { $0 }
        let touchLog = self.touchLog
        let read = await Task.detached(priority: .userInitiated) { () -> (Data, FileFingerprint, AITouch?, Date)? in
            guard let file = try? FileFingerprint.read(url) else { return nil }
            let real = Date()
            return (file.data, file.fingerprint, Self.attributionTouch(paths: paths, log: touchLog, around: real), real)
        }.value
        guard let read, var state = tab.state else { return }
        let (data, fingerprint, touch, real) = read
        let before = state.pendingDisk?.decoded?.text ?? state.savedText
        let aiTouch: (session: String, at: Date)? = touch.map { (session: $0.session, at: $0.at) }
        let decision = state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: aiTouch, now: clock())
        tab.state = state
        switch decision {
        case .none:
            return
        case .reloaded:
            tab.editor?.applyExternalText(state.buffer)
            tab.accepted = []
            log("files disk reload name=\(tab.title) ai=\(touch != nil)")
        case .banner:
            log("files disk banner name=\(tab.title) ai=\(touch != nil)")
        }
        if touch == nil {
            tab.unattributedChange = (before: before, at: real)
        } else {
            tab.unattributedChange = nil
        }
        if tab.baseline == .disk || tab.showAI { scheduleDiff(tab, immediately: true) }
        if let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }) { scheduleGitRefresh(workspace) }
    }

    /// The newest AI touch of `paths` (one file, both spellings) within ±10 s of `date` (D25).
    /// The log's first read loads its file: call off the main actor.
    nonisolated static func attributionTouch(paths: [String], log: AITouchLog?, around date: Date) -> AITouch? {
        guard let log else { return nil }
        guard let newest = paths.compactMap({ log.latest(for: $0) }).max(by: { $0.at < $1.at }),
              abs(newest.at.timeIntervalSince(date)) <= attributionWindow else { return nil }
        return newest
    }

    /// `重新載入`: the buffer takes the disk version (the edit before it stays on the undo stack).
    func reload(_ tab: FileTab) {
        guard var state = tab.state, state.canReload else { return }
        state.reloadFromDisk(now: clock())
        tab.state = state
        tab.editor?.applyExternalText(state.buffer)
        tab.accepted = []
        endCompare(tab)
        scheduleDiff(tab, immediately: true)
        log("files banner reload name=\(tab.title)")
    }

    /// `保留我的`: the buffer stays and the disk version becomes the base ⌘S overwrites on purpose.
    func keepMine(_ tab: FileTab) {
        guard var state = tab.state, state.showsBanner else { return }
        state.keepMine(now: clock())
        tab.state = state
        endCompare(tab)
        scheduleDiff(tab, immediately: true)
        log("files banner keep-mine name=\(tab.title)")
    }

    /// `比較`: the buffer against the disk text, inline (SHOW AI CHANGES with the disk baseline).
    func compare(_ tab: FileTab) {
        guard tab.state?.pendingDisk?.decoded != nil else { return }
        if tab.baseline != .disk { tab.baselineBeforeCompare = tab.baseline }
        tab.baseline = .disk
        tab.showAI = true
        tab.accepted = []
        scheduleDiff(tab, immediately: true)
    }

    private func endCompare(_ tab: FileTab) {
        guard tab.baseline == .disk else { return }
        tab.baseline = tab.baselineBeforeCompare ?? .head
        tab.baselineBeforeCompare = nil
    }

    // MARK: AI touches (D26)

    /// New PostToolUse touches of CODD sessions (the hook pipeline recorded them in the log off
    /// the main actor): the chips follow, and a disk change seen just before the hook is
    /// attributed now (the ±10 s window, D25).
    func handleTouches(_ touches: [AITouch]) {
        guard !touches.isEmpty else { return }
        touchRevision += 1
        for workspace in workspaces { refreshTouches(workspace) }
        for workspace in workspaces {
            for tab in workspace.tabs {
                guard let touch = touches.filter({ tab.matches(path: $0.path) }).max(by: { $0.at < $1.at }) else { continue }
                attributeLate(tab, touch: touch)
            }
        }
    }

    private func attributeLate(_ tab: FileTab, touch: AITouch) {
        guard let change = tab.unattributedChange, abs(change.at.timeIntervalSince(touch.at)) <= Self.attributionWindow,
              var state = tab.state else { return }
        if state.pendingDisk != nil, state.pendingDisk?.aiSession == nil {
            state.pendingDisk?.aiSession = touch.session
            state.pendingDisk?.at = touch.at
        }
        if state.aiBaseline == nil || state.aiBaseline?.session != touch.session {
            state.aiBaseline = (text: change.before, at: touch.at, session: touch.session)
        }
        tab.state = state
        tab.unattributedChange = nil
        log("files disk attributed name=\(tab.title) session=\(touch.session)")
    }

    /// The workspace's newest touch per file (7 days, D26), read off the main actor (the log's
    /// first read loads its file).
    func refreshTouches(_ workspace: FilesWorkspace) {
        guard let touchLog else { return }
        let root = workspace.root
        let since = clock().addingTimeInterval(-AITouchLog.retention)
        Task { [weak self, weak workspace] in
            let touches = await Task.detached(priority: .utility) { () -> [AITouch] in
                touchLog.touches(under: root, since: since)
            }.value
            guard let self, let workspace else { return }
            var map: [String: AITouch] = [:]
            for touch in touches {
                guard let relative = workspace.relativePath(touch.path) else { continue }
                if let known = map[relative], known.at >= touch.at { continue }
                map[relative] = touch
            }
            guard map != workspace.touches else { return }
            workspace.touches = map
            // The hunk bars take the session's color and name.
            for tab in workspace.tabs where tab.showAI { self.applyDiff(tab) }
        }
    }

    /// The touch of a tab's file (the tab chip, the hunk headers).
    func touch(of tab: FileTab) -> AITouch? {
        guard let workspace = workspaces.first(where: { $0.tabs.contains { $0 === tab } }), let url = tab.url,
              let relative = workspace.relativePath(url.path) else { return nil }
        return workspace.touches[relative]
    }

    // MARK: Git (D24)

    /// Repository root, status and (with `ignored`) the ignored paths, off the main actor; the
    /// newest run wins.
    func refreshGit(_ workspace: FilesWorkspace, ignored refreshIgnored: Bool) {
        workspace.gitGeneration += 1
        let token = workspace.gitGeneration
        let git = self.git
        let root = workspace.root
        let knownRepo = workspace.repoRoot
        let loaded = workspace.gitLoaded
        workspace.gitTask = Task { [weak self, weak workspace] in
            let repo: URL?
            if let knownRepo { repo = knownRepo } else if loaded { repo = nil } else { repo = await git.repoRoot(for: root) }
            guard let repo else {
                guard let self, let workspace, workspace.gitGeneration == token else { return }
                workspace.gitLoaded = true
                workspace.repoRoot = nil
                workspace.status = nil
                self.headsChanged(workspace)
                return
            }
            let started = ContinuousClock.now
            let status = try? await git.status(root: repo)
            let elapsed = ContinuousClock.now - started
            var ignored: Set<String>?
            if refreshIgnored || !loaded { ignored = try? await git.ignored(root: repo) }
            guard let self, let workspace, workspace.gitGeneration == token else { return }
            workspace.repoRoot = repo
            workspace.gitPrefix = Self.prefix(of: workspace, in: repo)
            workspace.gitLoaded = true
            workspace.gitRuns += 1
            workspace.gitStatusMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            if let status, status != workspace.status { workspace.status = status }
            if let ignored {
                let relative = Set(ignored.compactMap { workspace.rootRelative(gitPath: $0) })
                if relative != workspace.ignored { workspace.ignored = relative }
            }
            self.headsChanged(workspace)
        }
    }

    /// The root relative to the repository (both resolved: rev-parse answers with the real path).
    static func prefix(of workspace: FilesWorkspace, in repo: URL) -> String {
        let repoPath = FilesWorkspace.trimmed(repo.resolvingSymlinksInPath().path)
        if workspace.resolvedRoot == repoPath { return "" }
        if workspace.resolvedRoot.hasPrefix(repoPath + "/") { return String(workspace.resolvedRoot.dropFirst(repoPath.count + 1)) }
        if workspace.rootPath.hasPrefix(repo.path + "/") { return String(workspace.rootPath.dropFirst(repo.path.count + 1)) }
        return ""
    }

    /// A status changed: HEAD texts of open tabs may have moved (a commit).
    private func headsChanged(_ workspace: FilesWorkspace) {
        for tab in workspace.tabs where tab.showAI && tab.baseline == .head && tab.url != nil {
            loadHead(tab, in: workspace, force: true)
        }
    }

    private func scheduleGitRefresh(_ workspace: FilesWorkspace) {
        workspace.gitDebounce?.cancel()
        workspace.gitDebounce = Task { [weak self, weak workspace] in
            try? await Task.sleep(for: Self.gitDebounce)
            guard !Task.isCancelled, let self, let workspace else { return }
            self.refreshGit(workspace, ignored: false)
        }
    }

    // MARK: Folder watching

    private func startWatching(_ workspace: FilesWorkspace) {
        guard workspace.directoryWatcher == nil, !isMock else { return }
        let watcher = DirectoryWatcher(root: workspace.root)
        workspace.directoryWatcher = watcher
        let changes = watcher.changes
        workspace.watchTask = Task { [weak self, weak workspace] in
            for await paths in changes {
                guard let self, let workspace else { return }
                self.folderChanged(workspace, paths: paths)
            }
        }
    }

    private func stopWatching(_ workspace: FilesWorkspace) {
        workspace.watchTask?.cancel()
        workspace.watchTask = nil
        workspace.directoryWatcher?.cancel()
        workspace.directoryWatcher = nil
    }

    /// FSEvents: reload the listings of folders that changed, refresh git 500 ms after the last
    /// change (`.git/` included: a commit or a checkout), drop the ⌘P candidates.
    private func folderChanged(_ workspace: FilesWorkspace, paths: [String]) {
        var folders = Set<String>()
        var outsideGit = false
        var ignoreFile = false
        for path in paths {
            if path == ".git" || path.hasPrefix(".git/") { continue }
            outsideGit = true
            if path.hasSuffix(".gitignore") { ignoreFile = true }
            let parent = (path as NSString).deletingLastPathComponent
            folders.insert(parent == "." ? "" : parent)
        }
        for folder in folders where workspace.children[folder] != nil { loadChildren(workspace, folder: folder) }
        if outsideGit { workspace.filterCandidates = nil }
        if ignoreFile {
            refreshGit(workspace, ignored: true)
        } else {
            scheduleGitRefresh(workspace)
        }
    }

    // MARK: Tree

    func loadChildren(_ workspace: FilesWorkspace, folder: String) {
        let model = FileTreeModel(root: workspace.root)
        Task { [weak workspace] in
            let entries = await Task.detached(priority: .userInitiated) { () -> [FileTreeEntry]? in
                try? model.children(of: folder, ignored: [])
            }.value
            guard let workspace, let entries else { return }
            if workspace.children[folder] != entries { workspace.children[folder] = entries }
        }
    }

    /// A folder row: expand (listing it the first time) or collapse.
    func toggleFolder(_ relative: String) {
        guard let workspace = current else { return }
        if workspace.expanded.contains(relative) {
            workspace.expanded.remove(relative)
        } else {
            workspace.expanded.insert(relative)
            if workspace.children[relative] == nil { loadChildren(workspace, folder: relative) }
        }
    }

    /// Expands the folders down to a file's row (opening it from ⌘P, Recent, the drawer).
    func reveal(_ relative: String, in workspace: FilesWorkspace) {
        var folder = (relative as NSString).deletingLastPathComponent
        var chain: [String] = []
        while !folder.isEmpty && folder != "." {
            chain.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for path in chain.reversed() where !workspace.expanded.contains(path) {
            workspace.expanded.insert(path)
            if workspace.children[path] == nil { loadChildren(workspace, folder: path) }
        }
    }

    func collapseAll() {
        current?.expanded = []
    }

    func toggleSection(_ section: FileTreeSection) {
        guard let workspace = current else { return }
        switch section {
        case .recent: workspace.recentCollapsed.toggle()
        case .project: workspace.projectCollapsed.toggle()
        }
    }

    // MARK: ⌘P filter

    /// The filter text (never while 注音 composes: the view reports committed text only).
    func setFilter(_ text: String) {
        guard let workspace = current else { return }
        workspace.filter = text
        workspace.filterIndex = 0
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            workspace.filterResults = []
            return
        }
        if let candidates = workspace.filterCandidates {
            workspace.filterResults = Self.match(text, in: candidates, limit: Self.filterLimit)
            return
        }
        let git = self.git
        let root = workspace.root
        let repo = workspace.repoRoot
        Task { [weak workspace] in
            let candidates = await Self.candidates(git: git, root: root, repo: repo, workspace: workspace)
            guard let workspace else { return }
            workspace.filterCandidates = candidates
            if !workspace.filter.isEmpty {
                workspace.filterResults = Self.match(workspace.filter, in: candidates, limit: Self.filterLimit)
            }
        }
    }

    /// ⌘P's files: git's tracked and untracked (not ignored) inside the root, else a walk.
    private static func candidates(git: any GitReading, root: URL, repo: URL?, workspace: FilesWorkspace?) async -> [String] {
        if let repo, let workspace, let files = try? await git.trackedAndUntracked(root: repo) {
            return files.compactMap { workspace.rootRelative(gitPath: $0) }
        }
        let model = FileTreeModel(root: root)
        return await Task.detached(priority: .userInitiated) { model.walk() }.value
    }

    /// Fuzzy matches (CoddCore `FuzzyMatcher`): a hit in the file name outranks one in the path.
    nonisolated static func match(_ query: String, in candidates: [String], limit: Int) -> [String] {
        var scored: [(path: String, score: Int)] = []
        for path in candidates {
            let name = (path as NSString).lastPathComponent
            if let hit = FuzzyMatcher.match(query, in: name) {
                scored.append((path, hit.score * 2))
            } else if let hit = FuzzyMatcher.match(query, in: path) {
                scored.append((path, hit.score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.path.count != $1.path.count ? $0.path.count < $1.path.count : $0.path < $1.path) }
        return scored.prefix(limit).map(\.path)
    }

    /// The filter field's ↑ ↓ ⏎ esc (after the input method): ⏎ opens the highlighted match.
    func filterCommand(_ selector: Selector) -> Bool {
        guard let workspace = current, !workspace.filter.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            workspace.filterIndex = min(workspace.filterIndex + 1, max(0, workspace.filterResults.count - 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            workspace.filterIndex = max(0, workspace.filterIndex - 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard workspace.filterResults.indices.contains(workspace.filterIndex) else { return true }
            let relative = workspace.filterResults[workspace.filterIndex]
            setFilter("")
            reveal(relative, in: workspace)
            Task { await self.open(workspace.url(of: relative), preview: false, root: workspace.root) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            setFilter("")
            return true
        default:
            return false
        }
    }

    // MARK: Recent

    func loadRecent() {
        guard let recentStore else { return }
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) { recentStore.load() }.value
            guard let self, items != self.recent else { return }
            self.recent = items
        }
    }

    private func recordRecent(_ file: URL, root: URL, source: String) {
        guard let recentStore else { return }
        let at = clock()
        Task { [weak self] in
            await Task.detached(priority: .utility) { recentStore.record(file, root: root, source: source, at: at) }.value
            self?.loadRecent()
        }
    }

    // MARK: Sessions

    /// The CODD claude session working in the workspace's root (the tab strip's pill, the tree
    /// foot): the one on screen when several do, else the most recently changed.
    func session(for workspace: FilesWorkspace) -> SessionVM? {
        let candidates = store.allSessions.filter { session in
            guard !session.external, session.kind == .claude, let project = store.project(session.projectID) else { return false }
            return Self.samePath(rootForCwd(project.cwd), workspace)
        }
        return candidates.max { $0.stateSince < $1.stateSince }
    }

    /// The session's cwd names the workspace's root (either spelling, `~` expanded).
    static func samePath(_ cwd: String, _ workspace: FilesWorkspace) -> Bool {
        let path = FilesWorkspace.trimmed(URL(fileURLWithPath: cwd).standardizedFileURL.path)
        if path == workspace.rootPath || path == workspace.resolvedRoot { return true }
        return FilesWorkspace.trimmed(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) == workspace.resolvedRoot
    }

    /// `HH:mm` on the display clock's time zone.
    func hourMinute(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return ClockFormat.hourMinute(date, calendar: calendar)
    }
}
