import AppKit
import CoddDialogsUI
import CoddFileEditorUI
import CoddFiles
import CoddNotes

/// M4 I3: the local file editor in the app — the service (real git or mock mode's fixed one), the
/// NOTES area's Files mode, its entry points (the session header's files button, LOCAL FILES, the
/// drawer's `AI 改過的檔案`), the `檔案` menu (D36), the `files` dump key and the DEBUG flags (§6).
extension AppDelegate {
    // MARK: Building

    /// Real mode: `/usr/bin/git` read-only, `<dataRoot>/files/recent.json` and the hook pipeline's
    /// AI touch log (D26). Mock mode (D35): the mock project's fixed `GitReading` (never git) and
    /// stores in the temporary mock folder.
    static func makeFileEditor(holders: HolderSessionStore?, mockFolder: URL?, store: any SessionStore, notes: NotesService) -> FileEditorService {
        if let holders {
            let root = holders.root.url
            let git = GitReader(environment: gitEnvironment(standardRoot: holders.root == .standard), log: { HolderSessionStore.printLog($0) })
            let service = FileEditorService(git: git,
                                            recentStore: RecentFilesStore(file: root.appendingPathComponent("files/recent.json")),
                                            touchLog: holders.hooks?.aiTouches, store: store, clock: notes.clock, timeZone: notes.timeZone)
            holders.hooks?.onAITouch = { [weak service] touches in service?.handleTouches(touches) }
            service.notesRoot = notes.notesRoot
            service.unsavedFolder = root.appendingPathComponent("files/unsaved", isDirectory: true)
            return service
        }
        let folder = mockFolder ?? MockNotes.folder()
        let clock = notes.clock
        let service = FileEditorService(git: MockFiles.gitReader(folder: folder),
                                        recentStore: RecentFilesStore(file: folder.appendingPathComponent("files/recent.json"), clock: clock),
                                        touchLog: AITouchLog(file: folder.appendingPathComponent("files/ai-touches.json"), clock: clock),
                                        store: store, clock: clock, timeZone: notes.timeZone, isMock: true)
        service.rootForCwd = { MockFiles.root(forCwd: $0, folder: folder) }
        service.notesRoot = notes.notesRoot
        return service
    }

    /// D24: the user's own git config (includes, filters, status options) applies on the standard
    /// data root only; any other root (tests, fixtures, a try-out) runs git with no global and no
    /// system config, so a test run never depends on this Mac's `~/.gitconfig`.
    static func gitEnvironment(standardRoot: Bool) -> [String: String] {
        standardRoot ? [:] : ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    }

    // MARK: Quit with unsaved tabs (D24)

    /// What a quit request does with unsaved file tabs (pure; unit-tested).
    enum FilesQuitStep: Equatable {
        /// Nothing unsaved (or `不儲存` let it go): the quit goes on.
        case proceed
        /// ⌘Q / 結束: one sheet for every unsaved tab first.
        case ask
        /// Nothing may ask (logout, restart, `-codd-quit-after`, dialog D's answer): each buffer is
        /// kept as a copy under `files/unsaved/`, then the quit goes on.
        case keepCopies
    }

    static func filesQuitStep(_ trigger: QuitTrigger, unsaved: Int) -> FilesQuitStep {
        guard unsaved > 0 else { return .proceed }
        switch trigger {
        case .user, .statusItem: return .ask
        case .system, .automation, .confirmed: return .keepCopies
        }
    }

    /// The sheet's texts: one file by name, several by count.
    static func filesQuitTexts(_ names: [String]) -> (title: String, hint: String, save: String) {
        if names.count == 1, let name = names.first {
            return ("儲存「\(name)」的變更？", "不儲存的話，這次的修改會遺失。", "儲存")
        }
        return ("\(names.count) 個檔案有未儲存的變更", "不儲存的話，這些修改會遺失。", "儲存全部")
    }

    /// Whether the quit may go on with the file tabs as they are (false: the sheet asks first).
    func filesAllowQuit(_ trigger: QuitTrigger) -> Bool {
        let unsaved = files.dirtyTabs.filter { filesQuitApproved?[$0.id] != $0.state?.buffer }
        switch Self.filesQuitStep(trigger, unsaved: unsaved.count) {
        case .proceed:
            return true
        case .keepCopies:
            if let folder = files.unsavedFolder { files.preserveDirtyTabs(in: folder, tabs: unsaved) }
            return true
        case .ask:
            presentFilesQuitSheet(unsaved, trigger: trigger)
            return false
        }
    }

    /// The sheet over the main window (on its own when the window is closed), like dialog D.
    private func presentFilesQuitSheet(_ unsaved: [FileTab], trigger: QuitTrigger) {
        if let sheet = filesQuitSheet {
            sheet.orderFront(nil)
            return
        }
        let texts = Self.filesQuitTexts(unsaved.map(\.title))
        let view = DirtyCloseSheetView(title: texts.title, hint: texts.hint, saveTitle: texts.save)
        view.onChoice = { [weak self] choice in
            Task { await self?.filesQuitAnswered(choice, trigger: trigger) }
        }
        if let main = mainWindow?.window, main.isVisible, !main.isMiniaturized, main.attachedSheet == nil {
            filesQuitSheet = DialogPresenter.presentSheet(view, on: main)
        } else {
            filesQuitSheet = DialogPresenter.presentStandalone(view)
        }
        HolderSessionStore.printLog("files quit asks unsaved=\(unsaved.count) trigger=\(trigger.rawValue)")
    }

    /// `儲存全部` saves every unsaved tab (a refused save keeps CODD running on that tab), `不儲存`
    /// lets the buffers go for this quit, `取消` keeps everything; then the same quit request again.
    func filesQuitAnswered(_ choice: DirtyCloseChoice, trigger: QuitTrigger) async {
        if let sheet = filesQuitSheet { DialogPresenter.dismiss(sheet) }
        filesQuitSheet = nil
        let unsaved = files.dirtyTabs
        HolderSessionStore.printLog("files quit choice=\(choice) unsaved=\(unsaved.count)")
        switch choice {
        case .cancel:
            return
        case .discard:
            filesQuitApproved = Dictionary(unsaved.map { ($0.id, $0.state?.buffer ?? "") }, uniquingKeysWith: { first, _ in first })
        case .save:
            for tab in unsaved {
                if await files.save(tab) { continue }
                shell.area = .notes
                notesArea?.showFilesMode()
                if let workspace = files.workspaces.first(where: { $0.tabs.contains { $0 === tab } }) {
                    files.openRoot(workspace.root)
                    files.select(tab.id)
                }
                return
            }
        }
        pendingQuitTrigger = trigger
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// The Files mode's controller (built with the NOTES area, before the main window).
    func makeFilesMode() -> FilesModeController {
        let mode = FilesModeController(service: files, store: sessionStore)
        let notes = self.notes
        files.noteResolver = { url in
            let path = url.standardizedFileURL.path
            return notes.activeNotes.first { $0.fileURL.standardizedFileURL.path == path }.map { (id: $0.id, title: $0.metadata.title) }
        }
        mode.onOpenSession = { [weak self] id in self?.mainWindow?.show(id) }
        files.sessionNumber = { [weak self] id in
            self?.mainWindow?.sidebar.snapshot.sessionOrder.firstIndex(of: id).map { $0 + 1 }
        }
        #if DEBUG
        mode.onDumpNeeded = { [weak self] in self?.scheduleStateDump() }
        #endif
        filesMode = mode
        return mode
    }

    /// The entry points on the main window (after it exists): the header's files button, the
    /// drawer's files section and its rows, and ⌘W's owner.
    func wireFiles(_ window: MainWindowController) {
        window.pane.onOpenFiles = { [weak self] id in self?.openFiles(for: id) }
        let drawer = notesDrawer
        drawer.filesSection = { [weak self] id in await self?.files.drawerSection(for: id) }
        drawer.filesRevision = { [weak self] in self?.files.touchRevision ?? 0 }
        drawer.view.onOpenFile = { [weak self] path in self?.openDrawerFile(path, showAI: false) }
        drawer.view.onDiff = { [weak self] path in self?.openDrawerFile(path, showAI: true) }
        (window.window as? CoddMainWindow)?.suppressesCloseItem = { [weak self] in self?.menuRules.closeTabOwnsCommandW ?? false }
    }

    // MARK: Entry points

    /// The session header's files button: the session's cwd in the Files mode (the rail on NOTES).
    func openFiles(for id: SessionID) {
        guard let session = sessionStore.session(id), let project = sessionStore.project(session.projectID) else {
            NSSound.beep()
            return
        }
        let root = URL(fileURLWithPath: files.rootForCwd(project.cwd), isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            _ = mainWindow?.showToast("找不到資料夾 \(HolderSessionStore.abbreviate(root.path))", undo: nil)
            return
        }
        files.openRoot(root)
        shell.area = .notes
        notesArea?.showFilesMode()
    }

    /// A drawer row (`差異`: SHOW AI CHANGES on, D27) in the workspace of the drawer's session.
    func openDrawerFile(_ path: String, showAI: Bool) {
        var root: URL?
        if let id = notesDrawer.sessionID, let session = sessionStore.session(id), let project = sessionStore.project(session.projectID) {
            root = URL(fileURLWithPath: files.rootForCwd(project.cwd), isDirectory: true)
        }
        Task { [weak self] in
            guard let self else { return }
            guard await self.files.open(URL(fileURLWithPath: path), preview: false, showAI: showAI, root: root) != nil else { return }
            self.shell.area = .notes
            self.notesArea?.showFilesMode()
        }
    }

    /// LOCAL FILES' `開啟資料夾…` (a user action, D39): a folder as a Files workspace.
    func chooseFilesFolder() {
        guard let window = mainWindow?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開啟"
        panel.message = "選擇要在檔案編輯器開啟的資料夾"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.files.openRoot(url)
            self.shell.area = .notes
            self.notesArea?.showFilesMode()
        }
    }

    // MARK: 檔案 menu (D36)

    /// ⌘S: the only path that writes a file (D24).
    @objc func saveFile(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(saveFile(_:))) == true, let tab = files.selectedTab else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        Task { await files.save(tab) }
    }

    /// ⌘W while the Files mode shows a tab: that tab (a dirty one asks first).
    @objc func closeFileTab(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(closeFileTab(_:))) == true, let tab = files.selectedTab else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        filesMode?.close(tab.id)
    }

    /// ⌘P while the Files mode shows: the tree's filter field.
    @objc func filterFiles(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(filterFiles(_:))) == true else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        notesArea?.focusFilesFilter()
    }

    /// ⌘F while the Files mode shows a file: the find widget (C5).
    @objc func findInFile(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(findInFile(_:))) == true else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        filesMode?.showFind(query: nil)
    }

    // MARK: Dump

    var filesDump: [String: Any] {
        FilesDump.object(files, mode: notesArea?.mode ?? .notebook, dirtySheet: filesMode?.dirtySheet?.tabID)
    }

    #if DEBUG
    // MARK: DEBUG flags (§6, I3)

    /// `-codd-show files:<path>`, `-codd-open-file`, then `-codd-file-type`,
    /// `-codd-file-show-ai-changes`, `-codd-file-baseline`, `-codd-file-hunk`, `-codd-file-save`
    /// and `-codd-file-find` on the shown tab, in that order (each through the user's path).
    func runFilesDebugActions() async {
        let o = realOptions
        if o.showKeyword == "files", let argument = o.showArgument { await debugShowFiles(argument) }
        if let path = o.openFile { await debugOpenFile(path) }
        guard files.selectedTab != nil else {
            if o.fileType != nil || o.fileShowAIChanges != nil || o.fileHunk != nil || o.fileSave || o.fileFind != nil {
                HolderSessionStore.printLog("debug files: no tab shown")
            }
            return
        }
        if let text = o.fileType, let tab = files.selectedTab, let editor = tab.editor {
            editor.textViewForTesting.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            HolderSessionStore.printLog("debug file-type chars=\(text.count) dirty=\(tab.isDirty)")
        }
        if let on = o.fileShowAIChanges, let tab = files.selectedTab {
            let runs = tab.diffRuns
            files.setShowAI(tab, on: on)
            if on { await waitFor { tab.diffRuns > runs } }
            // The ranges too: a later -codd-file-hunk in the same launch changes the hunks before the dump.
            let ranges = tab.hunks.map { LineDiff.unifiedHeader($0) }.joined(separator: ",")
            HolderSessionStore.printLog("debug file-show-ai-changes on=\(on) hunks=\(tab.hunks.count) ranges=\(ranges.isEmpty ? "-" : ranges)")
        }
        if let name = o.fileBaseline, let baseline = FileTab.Baseline(rawValue: name), let tab = files.selectedTab {
            let runs = tab.diffRuns
            files.setBaseline(tab, baseline)
            await waitFor { tab.diffRuns > runs || !tab.showAI }
            HolderSessionStore.printLog("debug file-baseline \(name) applied=\(tab.baseline == baseline) hunks=\(tab.hunks.count)")
        }
        if let spec = o.fileHunk, let tab = files.selectedTab { await debugHunk(spec, tab: tab) }
        if o.fileSave, let tab = files.selectedTab {
            let ok = await files.save(tab)
            HolderSessionStore.printLog("debug file-save ok=\(ok) reason=\(files.lastSave?.error ?? "-")")
        }
        if let query = o.fileFind {
            filesMode?.showFind(query: query)
            try? await Task.sleep(for: .milliseconds(100))
            let count = files.selectedTab?.findCount
            HolderSessionStore.printLog("debug file-find current=\(count?.current ?? -1) total=\(count?.total ?? -1)")
        }
        scheduleStateDump()
    }

    /// `-codd-show files:<path>` (mock mode: relative to the mock projects folder; punch.vue
    /// draws the artboard's state).
    func debugShowFiles(_ argument: String) async {
        var path = argument
        if let folder = mockNotesFolder, !path.hasPrefix("/") {
            path = MockFiles.projectRoot(in: folder).deletingLastPathComponent().appendingPathComponent(path).path
        }
        if let refusal = RealModeOptions.protectedPathReason(path) {
            HolderSessionStore.printLog("debug show files refused (\(refusal))")
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            HolderSessionStore.printLog("debug show files: no such path")
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: isFolder.boolValue)
        shell.area = .notes
        if isFolder.boolValue {
            files.openRoot(url)
        } else if let folder = mockNotesFolder {
            await MockFiles.showArtboard(files, root: MockFiles.projectRoot(in: folder), file: url, now: notes.clock())
        } else {
            await files.open(url, preview: false)
        }
        notesArea?.showFilesMode()
        HolderSessionStore.printLog("debug show files root=\(files.current?.name ?? "-") tabs=\(files.current?.tabs.count ?? 0)")
    }

    /// `-codd-open-file <path>`: a pinned tab, the Files mode at its workspace.
    private func debugOpenFile(_ path: String) async {
        if let refusal = RealModeOptions.protectedPathReason(path) {
            HolderSessionStore.printLog("debug open-file refused (\(refusal))")
            return
        }
        shell.area = .notes
        let tab = await files.open(URL(fileURLWithPath: path), preview: false)
        notesArea?.showFilesMode()
        HolderSessionStore.printLog("debug open-file name=\((path as NSString).lastPathComponent) ok=\(tab != nil) "
                                    + "binary=\(tab?.failure != nil) readOnly=\(tab?.isReadOnly ?? true) refusal=\(files.lastRefusal ?? "-")")
    }

    /// `-codd-file-hunk <index>:revert|accept`.
    private func debugHunk(_ spec: String, tab: FileTab) async {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 2, let index = Int(parts[0]), ["revert", "accept"].contains(parts[1]) else {
            HolderSessionStore.printLog("debug file-hunk refused spec")
            return
        }
        if tab.hunks.isEmpty, !tab.showAI {
            let runs = tab.diffRuns
            files.setShowAI(tab, on: true)
            await waitFor { tab.diffRuns > runs }
        }
        guard tab.hunks.indices.contains(index) else {
            HolderSessionStore.printLog("debug file-hunk no hunk \(index) of \(tab.hunks.count)")
            return
        }
        let runs = tab.diffRuns
        files.hunkAction(tab, index: index, action: parts[1] == "revert" ? .revert : .accept)
        if parts[1] == "revert" { await waitFor { tab.diffRuns > runs } }
        HolderSessionStore.printLog("debug file-hunk \(index):\(parts[1]) hunks=\(tab.hunks.count) dirty=\(tab.isDirty)")
    }
    #endif
}
