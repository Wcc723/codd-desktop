import AppKit
import CoddAnnotateUI
import CoddDialogsUI
import CoddFiles
import CoddHooks
import CoddNotebookUI
import CoddNotes
import CoddUI

/// The NOTES area's modes (D12): Notebook, ImageAnnotate (I1b) and Files (I3); Cleanup (I4a)
/// takes the same area later. The mode is remembered for the run.
enum NotesMode: String, Sendable {
    case notebook, annotate, files, cleanup
}

/// The Notebook artboard's columns: lists 220 · note list 300 · the editor chrome (flex, its info
/// panel 240 inside) with the app status bar under the chrome only, as the artboard draws it.
///
/// Narrow windows and large interface zooms (M4 layout sweep): the document keeps
/// `documentMinimum`; the info panel folds first, then the note list narrows to
/// `listMinimum`, then the lists column folds (⌘F brings it back until a note is opened).
final class NotebookModeView: FlippedView {
    /// Column widths for an area width (all at the current zoom).
    struct Columns: Equatable {
        var lists: CGFloat
        var list: CGFloat
        var info: Bool
    }

    /// The narrowest the document column gets before a column folds (design points).
    static let documentMinimum: CGFloat = 320
    /// The narrowest the note list gets (design points).
    static let listMinimum: CGFloat = 240

    /// The lists column even where it would fold (⌘F searches in it); cleared by the owner.
    var revealsLists = false { didSet { if revealsLists != oldValue { needsLayout = true } } }
    private(set) var columns = Columns(lists: 0, list: 0, info: true)

    /// Pure: which columns show at `width` (`revealLists` keeps the lists column).
    static func columns(width: CGFloat, revealLists: Bool = false) -> Columns {
        let lists = NotebookListsView.preferredWidth
        let list = NoteListView.preferredWidth
        let info = NoteInfoPanelView.preferredWidth
        let document = UIZoom.pt(documentMinimum)
        let narrowList = min(list, UIZoom.pt(listMinimum))
        if width - lists - list - info >= document { return Columns(lists: lists, list: list, info: true) }
        if width - lists - list >= document { return Columns(lists: lists, list: list, info: false) }
        if width - lists - narrowList >= document || revealLists {
            return Columns(lists: lists, list: max(narrowList, min(list, width - lists - document)), info: false)
        }
        return Columns(lists: 0, list: max(narrowList, min(list, width - document)), info: false)
    }

    let lists: NotebookListsView
    let noteList: NoteListView
    let chrome: NoteEditorChromeView
    let statusBar: NSView

    init(lists: NotebookListsView, noteList: NoteListView, chrome: NoteEditorChromeView, statusBar: NSView) {
        self.lists = lists
        self.noteList = noteList
        self.chrome = chrome
        self.statusBar = statusBar
        super.init(frame: NSRect(x: 0, y: 0, width: 1368, height: 900))
        for view in [lists, noteList, chrome, statusBar] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = bounds.height
        let columns = Self.columns(width: bounds.width, revealLists: revealsLists)
        self.columns = columns
        lists.isHidden = columns.lists == 0
        chrome.showsInfoPanel = columns.info
        lists.frame = CGRect(x: 0, y: 0, width: columns.lists, height: height)
        noteList.frame = CGRect(x: lists.frame.maxX, y: 0, width: columns.list, height: height)
        let x = noteList.frame.maxX
        let width = max(0, bounds.width - x)
        statusBar.frame = CGRect(x: x, y: height - Metrics.statusBarHeight, width: width, height: Metrics.statusBarHeight)
        chrome.frame = CGRect(x: x, y: 0, width: width, height: max(0, height - Metrics.statusBarHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }
}

/// The NOTES area's root: the Notebook mode or the Files mode (I3), and the Annotate mode over
/// them while an image is being annotated (D12: one mode shows at a time, each fills the area).
final class NotesAreaRootView: FlippedView {
    let notebook: NotebookModeView
    /// Annotate mode (I1b): `ImageAnnotateView` with the app status bar under it, full width.
    var annotate: AnnotateModeView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let annotate { addSubview(annotate) }
            applyVisibility()
        }
    }
    /// The Files mode's view (I3; installed once the app has a file editor).
    var files: NSView? {
        didSet {
            guard files !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let files { addSubview(files, positioned: .below, relativeTo: annotate) }
            applyVisibility()
        }
    }
    /// The Files mode shows instead of the Notebook.
    var showsFiles = false {
        didSet { if showsFiles != oldValue { applyVisibility() } }
    }
    /// The Cleanup mode's view (I4a; installed when the app has the cleanup page).
    var cleanup: NSView? {
        didSet {
            guard cleanup !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let cleanup { addSubview(cleanup, positioned: .below, relativeTo: annotate) }
            applyVisibility()
        }
    }
    /// The Cleanup mode shows instead of the Notebook and the Files mode.
    var showsCleanup = false {
        didSet { if showsCleanup != oldValue { applyVisibility() } }
    }

    private func applyVisibility() {
        let cleanupShown = showsCleanup && cleanup != nil
        let filesShown = showsFiles && files != nil && !cleanupShown
        notebook.isHidden = annotate != nil || filesShown || cleanupShown
        files?.isHidden = annotate != nil || !filesShown
        cleanup?.isHidden = annotate != nil || !cleanupShown
        needsLayout = true
    }

    init(notebook: NotebookModeView) {
        self.notebook = notebook
        super.init(frame: notebook.frame)
        addSubview(notebook)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        notebook.frame = bounds
        files?.frame = bounds
        cleanup?.frame = bounds
        annotate?.frame = bounds
    }
}

/// The ImageAnnotate artboard: the C8 screen (1368 × 876 at the artboard size) with the app status
/// bar under it, which shows `標註模式` and `3 個標註 · ● 已儲存 10:46`.
final class AnnotateModeView: FlippedView {
    let screen: ImageAnnotateView
    let statusBar: StatusBarView

    init(screen: ImageAnnotateView, statusBar: StatusBarView) {
        self.screen = screen
        self.statusBar = statusBar
        super.init(frame: NSRect(x: 0, y: 0, width: 1368, height: 900))
        addSubview(screen)
        addSubview(statusBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        statusBar.frame = CGRect(x: 0, y: bounds.height - Metrics.statusBarHeight, width: bounds.width, height: Metrics.statusBarHeight)
        screen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Metrics.statusBarHeight))
    }
}

/// The NOTES area (D12): hosts the Notebook mode on CoddNotebookUI's views, maps `NotesService`
/// and `NoteEditorController` onto their models (`NotebookPresenter`) and routes their callbacks.
/// The session sidebar column is collapsed while it shows (`MainSplitViewController`).
final class NotesAreaViewController: NSViewController {
    let service: NotesService
    let editor: NoteEditorController
    let store: any SessionStore
    let shell: ShellState
    let preferences: PreferencesService
    private let recentFiles: RecentFilesStore?
    /// D39: COPY REF, ⌘⇧C and 複製 ID write through it.
    let pasteboard: CoddPasteboard
    var mode: NotesMode = .notebook

    let lists = NotebookListsView(model: NotebookListsModel(counts: [:], notesPath: "", mcp: NotebookMCPLine(running: false, clients: "0 clients")))
    let noteList = NoteListView(model: NoteListModel(title: "Inbox", count: "0", sections: []))
    let chrome: NoteEditorChromeView
    private(set) var modeView: NotebookModeView?
    private(set) var rootView: NotesAreaRootView?

    // MARK: I1b state

    /// The hook port and the external MCP token (config.json, §3.11) for COPY REF forms 5; mock
    /// mode passes its own. Read at every model build, so a rotation (D23) shows at once.
    var refContext: () -> (port: Int?, mcpToken: String?) = { (nil, nil) }
    /// The MCP server name of `@<server>:codd://note/<id>` (I2a may resolve `codd-desktop`, D18).
    var refServerName = "codd"
    /// Pickers (link, tags) go here: a non-activating child panel; tests and DEBUG snapshots
    /// pass an `InlineMenuPresenter`.
    var pickerPresenter: NotebookMenuPresenting = PopoverMenuPresenter()
    /// The HISTORY row the user clicked (`[比較]` compares it with the current text).
    var selectedHistoryID: String?
    /// The last COPY REF (the dump's `notes.copyRef`; the URL token masked).
    var lastCopyRef: (form: Int, text: String, chars: Int, target: String)?
    /// The last metadata / lifecycle action and its outcome (the dump, DEBUG flags).
    var lastAction: (kind: String, id: String, ok: Bool, error: String?)?
    /// Annotate mode (D10): the screen and what it edits.
    var annotateSession: AnnotateSession?
    /// The last `完成` (the dump's `notes.annotate.lastDone`).
    var lastAnnotate: (id: String, asset: String, items: Int, annotatedPNG: String?)?
    /// The open history compare sheet and what it shows.
    var historySheet: (window: NSWindow, view: HistoryCompareView, state: HistoryCompareState)?
    var linkPicker: LinkPickerView?
    var tagEditor: TagEditorView?
    /// The editor requests in flight (I1b callers wait for them before acting on the shown note).
    var hasPendingRequests: Bool { pendingRequests > 0 }

    private var projectsExpanded = true
    private var filesExpanded = true
    /// The prompt footer's chosen session (D14 default until the user picks one).
    private var footerTarget: SessionID?
    private var recent: [RecentFile] = []
    /// Resolved project paths (realpath touches the file system; layout paths rarely change).
    private var resolved: [String: String] = [:]
    private var loops: [ObservationLoop] = []
    private var lastChrome: NoteEditorChromeModel?
    /// The doc status as its loop last built it (read untracked by the chrome loop).
    private var currentStatus = NoteDocStatusModel(position: "Ln 1, Col 1", save: .saved("—"))
    private(set) var isActive = false
    private var compareSheet: NSWindow?
    /// Editor requests (open, new note, quick note) not yet started: auto-select waits for them.
    private(set) var pendingRequests = 0

    /// Something the dump shows changed.
    var onDumpNeeded: (() -> Void)?
    /// Shows a session (a chip, a LINKS row).
    var onOpenSession: ((SessionID) -> Void)?
    /// D14 (I2b): the footer, SEND TO SESSION and ⌘⏎ in the editor send through it.
    var sending: NoteSending?
    /// The Files mode (I3): set by the app before the view loads (nil: no file editor).
    var filesMode: FilesModeController?
    /// The local file editor behind the Files mode.
    var files: FileEditorService? { filesMode?.service }
    /// LOCAL FILES' `開啟資料夾…` (a user action: the app shows the open panel).
    var onOpenFolder: (() -> Void)?
    /// The Cleanup mode (I4a): set by the app before the view loads.
    var cleanupMode: CleanupController?

    init(service: NotesService, editor: NoteEditorController, store: any SessionStore, shell: ShellState, preferences: PreferencesService,
         recentFiles: RecentFilesStore?, pasteboard: CoddPasteboard = CoddPasteboard()) {
        self.service = service
        self.editor = editor
        self.store = store
        self.shell = shell
        self.preferences = preferences
        self.recentFiles = recentFiles
        self.pasteboard = pasteboard
        chrome = NoteEditorChromeView(model: Self.emptyChrome)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let emptyChrome = NoteEditorChromeModel(crumb: "Inbox", title: "", noteID: nil, ai: .read, refs: nil, info: nil,
                                                   status: NoteDocStatusModel(position: "Ln 1, Col 1", save: .unsaved), footer: nil)

    override func loadView() {
        let status = StatusBarView(store: store)
        let notebook = NotebookModeView(lists: lists, noteList: noteList, chrome: chrome, statusBar: status)
        modeView = notebook
        let root = NotesAreaRootView(notebook: notebook)
        rootView = root
        chrome.documentView = editor.documentView
        root.files = filesMode?.view
        root.cleanup = cleanupMode?.modeView
        root.showsCleanup = mode == .cleanup
        wire()
        wireFeatures()
        wireFiles()
        wireCleanup()
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if isActive { startLoops() }
    }

    private func wire() {
        lists.onNew = { [weak self] in self?.newNote() }
        lists.onSearch = { [weak self] text in self?.service.setSearchText(text) }
        lists.onSelect = { [weak self] id in self?.selectList(NotebookPresenter.smartList(id)) }
        lists.onToggleSection = { [weak self] section, open in
            switch section {
            case .byProject: self?.projectsExpanded = open
            case .localFiles: self?.filesExpanded = open
            }
        }
        noteList.onSelect = { [weak self] id in self?.open(id, focus: false) }
        noteList.onOpen = { [weak self] id in
            self?.modeView?.revealsLists = false
            self?.open(id, focus: true)
        }
        noteList.onSort = { [weak self] sort in self?.service.setSort(NotebookPresenter.noteSort(sort)) }
        noteList.onRowAction = { [weak self] raw, action in
            guard let id = NoteID(rawValue: raw) else { return }
            Task { await self?.rowAction(id, action) }
        }
        chrome.docStatus.onToggleMode = { [weak self] in self?.editor.toggleMode() }
        chrome.promptFooter.onTarget = { [weak self] id in
            self?.footerTarget = id
            self?.refreshChrome()
        }
        chrome.promptFooter.onInsertRef = { [weak self] in Task { await self?.sendShown(.ref) } }
        chrome.promptFooter.onInsertFull = { [weak self] in Task { await self?.sendShown(.full) } }
        chrome.promptFooter.onSend = { [weak self] in Task { await self?.sendShown(.submit) } }
        chrome.onSend = { [weak self] session, action in Task { await self?.sendShown(NoteSending.Action(action), to: session) } }
        // ⌘⏎ in the editor (D36: the menu's 允許 is disabled outside the sessions area).
        editor.onCommandReturn = { [weak self] in Task { await self?.sendShown(.submit) } }
        editor.onToast = { [weak self] text in self?.editor.documentView.showToast(text) }
        editor.onOpenNote = { [weak self] id in self?.reveal(id) }
        editor.onCompare = { [weak self] mine, disk in self?.presentCompare(mine: mine, disk: disk) }
        editor.chipsRow.onOpenSession = { [weak self] id in self?.onOpenSession?(id) }
    }

    // MARK: Models

    func resolve(_ path: String) -> String {
        if let known = resolved[path] { return known }
        let value = NotebookPresenter.resolvePath(path)
        resolved[path] = value
        return value
    }

    func presenter() -> NotebookPresenter {
        let projects = NotebookPresenter.layoutProjects(store: store) { [unowned self] in self.resolve($0) }
        return NotebookPresenter(now: service.clock(), timeZone: service.timeZone, store: store, projects: projects)
    }

    /// The models follow the data only while the area shows (a hidden Notebook costs nothing).
    private func startLoops() {
        guard loops.isEmpty else { return }
        loops.append(ObservationLoop(track: { [weak self] in self?.listsModels() }, apply: { [weak self] models in
            guard let self, let models else { return }
            self.lists.update(models.lists)
            self.noteList.update(models.list)
            self.autoSelect()
            self.onDumpNeeded?()
        }))
        // The doc status follows the caret on every keystroke: its own loop, so typing never
        // rebuilds the chrome, the info panel or the footer.
        loops.append(ObservationLoop(track: { [weak self] in self?.statusModel() }, apply: { [weak self] status in
            guard let self, let status else { return }
            self.currentStatus = status
            guard var model = self.lastChrome, model.status != status else { return }
            model.status = status
            self.lastChrome = model
            self.chrome.update(model)
        }))
        loops.append(ObservationLoop(track: { [weak self] in self?.chromeModel() }, apply: { [weak self] model in
            guard let self, let model else { return }
            self.lastChrome = model
            self.chrome.update(model)
            self.onDumpNeeded?()
        }))
        loops.append(ObservationLoop(track: { [weak self] () -> NoteChipsRowModel? in
            guard let self else { return nil }
            return self.presenter().chips(self.editor.document?.metadata, draft: self.editor.draft, resolve: { self.resolve($0) })
        }, apply: { [weak self] model in
            if let model { self?.editor.updateChips(model) }
        }))
        loops.append(ObservationLoop(track: { [weak self] in self?.service.availability ?? .closed }, apply: { [weak self] availability in
            guard let self else { return }
            switch availability {
            case .unavailable(let reason): self.editor.showUnavailable(reason)
            case .closed, .loading: self.editor.setPlaceholder(Self.openingText)
            case .ready: self.autoSelect()
            }
        }))
    }

    private func listsModels() -> (lists: NotebookListsModel, list: NoteListModel) {
        let p = presenter()
        let host = store.host
        let path = PathFormat.abbreviateHome(service.notesRoot.path)
        let listsModel = p.lists(counts: service.counts, selected: service.list, searchText: service.searchText,
                                 projectsExpanded: projectsExpanded, filesExpanded: filesExpanded, recent: files?.recent ?? recent,
                                 notesPath: path, host: host, filesReason: files == nil ? NotebookPresenter.filesReason : nil,
                                 cleanupCount: cleanupMode == nil ? nil : host.cleanupSuggestions, resolve: { self.resolve($0) })
        let selected = editor.noteID ?? (editor.draft == nil ? service.selectedID : nil)
        let listModel: NoteListModel
        if let search = service.search, !service.searchText.isEmpty {
            listModel = p.searchList(search, selected: selected)
        } else {
            listModel = p.noteList(rows: service.rows, list: service.list, sort: service.sort, selected: selected,
                                   total: Self.total(service.counts, list: service.list, shown: service.rows.count),
                                   resolve: { self.resolve($0) })
        }
        return (listsModel, listModel)
    }

    /// The list's size from the counts (rows load at most `NotesService.listLimit`).
    static func total(_ counts: NotesCounts, list: SmartList, shown: Int) -> Int {
        let value: Int
        switch list {
        case .inbox: value = counts.inbox
        case .pinned: value = counts.pinned
        case .prompts: value = counts.prompts
        case .stale: value = counts.stale
        case .archive: value = counts.archive
        case .trash: value = counts.trash
        case .project(let path): value = counts.byProject[path] ?? shown
        }
        return max(value, shown)
    }

    /// `LIVE PREVIEW · ⌘E 原始碼 … Ln 14, Col 38 · Markdown · ● 已儲存 10:05`.
    private func statusModel() -> NoteDocStatusModel {
        let caret = editor.caret
        let p = NotebookPresenter(now: service.clock(), timeZone: service.timeZone, store: store, projects: [:])
        return NoteDocStatusModel(sourceMode: editor.mode == .source, position: "Ln \(caret.line), Col \(caret.column)",
                                  save: editor.hasContent ? p.saveState(editor.saveState) : .saved("—"))
    }

    private func chromeModel() -> NoteEditorChromeModel {
        let p = presenter()
        let crumb = p.listTitle(service.list, resolve: { self.resolve($0) })
        let status = currentStatus
        let targets = p.liveTargets
        let metadata = editor.document?.metadata
        let links = metadata?.links ?? editor.draft?.links
        let target = footerTarget.flatMap { id in targets.first { $0.id == id } } ?? p.defaultTarget(links: links, viewed: shell.viewedSessionIDs)
        let footerReason = editor.noteID == nil ? NotebookCopy.unsavedReason : (target == nil ? NotebookCopy.noTargetReason : nil)
        let footer = PromptFooterModel(target: target.map(p.target), targets: targets.map(p.target), disabledReason: footerReason)
        guard editor.hasContent else {
            var empty = Self.emptyChrome
            empty.crumb = crumb
            empty.status = status
            empty.aiDisabledReason = Self.nothingShownReason
            empty.scopeDisabledReason = Self.nothingShownReason
            empty.moreDisabledReason = Self.nothingShownReason
            return empty
        }
        let title = metadata?.title ?? NoteDraft.title(of: editor.text) ?? editor.draft?.title ?? ""
        let id = editor.noteID
        var refs: NotebookRefTexts?
        if let set = referenceSet() {
            let texts = set.displayTexts
            refs = NotebookRefTexts(uri: texts.uri, mention: texts.mention, path: texts.path, url: texts.url)
        }
        var info: NoteInfoPanelModel?
        if let selected = service.selected, selected.document.metadata.id == id {
            let policy = NotesService.policy(preferences.preferences)
            info = p.info(selected, retention: (policy.0.staleDays, policy.0.archiveDays), selectedHistory: selectedHistoryID,
                          thumbnail: { [weak self] name in self?.thumbnail(named: name) }, resolve: { self.resolve($0) })
        }
        let scopeOptions = p.scopeOptions(metadata, resolve: { self.resolve($0) })
        let scopeID = metadata.flatMap { $0.scope == .project ? $0.primaryProject : nil } ?? NotebookScopeOption.globalID
        let location: NotebookNoteLocation
        switch metadata?.state {
        case .archived?: location = .archived
        case .trashed?: location = .trashed
        default: location = .active
        }
        // A draft (D3) takes neither access nor scope until it is on disk; COPY REF and SEND say
        // why themselves (C7's unsaved tooltip).
        let unsaved = id == nil ? NotebookCopy.unsavedReason : nil
        return NoteEditorChromeModel(
            crumb: crumb, title: title.isEmpty ? "未命名筆記" : title, noteID: id?.rawValue,
            ai: NotebookPresenter.access(metadata?.ai ?? NotesService.policy(preferences.preferences).1), scopeID: scopeID, scopeOptions: scopeOptions,
            refs: refs, kind: NotebookPresenter.kind(metadata?.kind ?? editor.draft?.kind ?? .note), pinned: metadata?.pinned ?? false,
            location: location, sourceMode: editor.mode == .source, sessions: targets.map(p.target),
            aiDisabledReason: unsaved, scopeDisabledReason: unsaved, copyRefDisabledReason: nil,
            sendDisabledReason: targets.isEmpty ? NotebookCopy.noTargetReason : nil, sendActionsDisabledReason: nil, moreDisabledReason: nil,
            info: info, status: status, footer: footer)
    }

    /// The pills and ⋯ with nothing shown (the folder opening, an empty list).
    static let nothingShownReason = "先選一則筆記"

    /// The five COPY REF forms of the shown note (nil: nothing on disk is shown, D15).
    func referenceSet() -> NoteReferenceSet? {
        guard let id = editor.noteID, let document = editor.document else { return nil }
        let context = refContext()
        let token = context.mcpToken.map { MCPAuth.noteURLToken(mcpToken: $0, noteID: id.rawValue) }
        return NoteReferenceSet(id: id, fileURL: document.fileURL, port: context.port, urlToken: token, ai: document.metadata.ai,
                                serverName: refServerName)
    }

    func refreshChrome() {
        var model = chromeModel()
        model.status = currentStatus
        lastChrome = model
        chrome.update(model)
    }

    // MARK: Selection

    /// Nothing shown yet: the first row of the list (never over a draft, never during a search;
    /// only while the Notebook mode shows: the Files mode keeps the keyboard and the screen).
    func autoSelect() {
        guard isActive, mode == .notebook, !editor.hasContent, !editor.isLoading, pendingRequests == 0, service.availability.isReady
        else { return }
        if !service.searchText.isEmpty {
            // A search shows its first hit.
            if let first = service.search?.hits.first { open(first.summary.id, focus: false) }
            return
        }
        if let id = service.selectedID, service.rows.contains(where: { $0.id == id }) {
            open(id, focus: false)
        } else if let first = service.rows.first {
            open(first.id, focus: false)
        } else {
            editor.setPlaceholder(service.counts.inbox == 0 ? NotebookCopy.noNotesEmpty : Self.pickNoteText)
        }
    }

    /// Notes exist but this list has none to show (D34 copy).
    static let pickNoteText = "// 選一則筆記 · ⌘⇧N 新增"
    /// The notebook is still opening (its index builds off the main actor).
    static let openingText = "// 筆記本開啟中…"

    /// Shows a note in the editor (saving the one shown first).
    func open(_ raw: String, focus: Bool) {
        guard let id = NoteID(rawValue: raw) else { return }
        open(id, focus: focus)
    }

    func open(_ id: NoteID, focus: Bool) {
        if id != editor.noteID { selectedHistoryID = nil }
        closeAnnotateKeepingEdits()
        if mode == .files || mode == .cleanup { showNotebookMode() }
        service.select(id)
        request { [weak self] in
            await self?.editor.show(id)
            if focus { self?.editor.focus() }
        }
    }

    /// Runs an editor request; until it starts, nothing auto-selects over it.
    private func request(_ body: @escaping @MainActor () async -> Void) {
        pendingRequests += 1
        Task { [weak self] in
            await body()
            self?.pendingRequests -= 1
            self?.onDumpNeeded?()
        }
    }

    /// A `codd://note/<id>` link or `-codd-notes-select`: shows the note, switching to INBOX /
    /// clearing a search when the shown list does not have it.
    func reveal(_ id: NoteID) {
        if !service.rows.contains(where: { $0.id == id }), service.list != .inbox { service.selectList(.inbox) }
        open(id, focus: false)
    }

    private func selectList(_ list: SmartList) {
        service.selectList(list)
    }

    // MARK: Commands

    /// `+ ⌘⇧N` / ⌘⇧N while NOTES shows (D13): a NOTE in INBOX, caret in the title.
    func newNote(title: String? = nil) {
        closeAnnotateKeepingEdits()
        if mode == .files || mode == .cleanup { showNotebookMode() }
        if service.list != .inbox || !service.searchText.isEmpty { service.selectList(.inbox) }
        service.select(nil)
        request { [weak self] in
            await self?.editor.startDraft(.note(title: title))
            self?.editor.focus()
        }
    }

    /// ⌘⇧N elsewhere, QUICK NOTE, 快速筆記 (D13): a SCRATCH linked to the session that was on screen.
    func quickNote(links: NoteLinks) {
        closeAnnotateKeepingEdits()
        if mode == .files || mode == .cleanup { showNotebookMode() }
        service.select(nil)
        let draft = NoteDraft.quick(now: service.clock(), timeZone: service.timeZone, links: links)
        request { [weak self] in
            await self?.editor.startDraft(draft)
            self?.editor.focus()
        }
    }

    /// The drawer's `+ 新筆記（連結此 session）` (I2b): a NOTE linked to the session and its project
    /// (D20: scope project), on disk at its first typing (D3), shown with the caret in its title.
    func newLinkedNote(links: NoteLinks) {
        closeAnnotateKeepingEdits()
        if mode == .files || mode == .cleanup { showNotebookMode() }
        if service.list != .inbox || !service.searchText.isEmpty { service.selectList(.inbox) }
        service.select(nil)
        request { [weak self] in
            await self?.editor.startDraft(.linked(links))
            self?.editor.focus()
        }
    }

    // MARK: Send to session (D14, I2b)

    /// The footer's target (the user's pick, else the D14 default) as the chrome last showed it.
    var footerTargetID: SessionID? { chrome.model.footer?.target?.id ?? lastChrome?.footer?.target?.id }

    /// 插入引用 / 插入全文 / 送出 of the shown note to `session` (the footer's target when nil). A
    /// draft (D3) has nothing to send; the outcome is the note's toast.
    @discardableResult
    func sendShown(_ action: NoteSending.Action, to session: SessionID? = nil) async -> NoteSending.Outcome? {
        guard let sending else { return nil }
        guard !editor.editor.isComposing else { return nil }
        let outcome: NoteSending.Outcome
        if let id = editor.noteID {
            if let target = session ?? footerTargetID {
                outcome = await sending.perform(action, note: id, to: target)
            } else {
                outcome = sending.refuse(NoteSending.noTargetText)
            }
        } else {
            outcome = sending.refuse(NoteSending.unsavedText)
        }
        showToast(sending.toast(for: outcome))
        onDumpNeeded?()
        return outcome
    }

    /// ⌘F (D36): the search field.
    func focusSearch() {
        // A folded lists column (narrow window, zoom) comes back for the search.
        modeView?.revealsLists = true
        modeView?.layoutSubtreeIfNeeded()
        lists.focusSearch()
    }

    /// The area came on screen or left it: leaving saves the editor (D12).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        filesMode?.setActive(active && mode == .files)
        cleanupMode?.setActive(active && mode == .cleanup)
        if active {
            if isViewLoaded { startLoops() }
            autoSelect()
            loadRecentFiles()
            files?.loadRecent()
            // The keyboard leaves whatever the area covers (a terminal, the composer): the list
            // (Files: the tree's filter field stays free; the editor takes it) takes it unless
            // something in the area has it already.
            if let window = view.window, !(window.firstResponder.flatMap { $0 as? NSView }?.isDescendant(of: view) ?? false) {
                if mode == .files {
                    filesMode?.focusEditor()
                } else if mode == .cleanup {
                    cleanupMode?.focus()
                } else {
                    window.makeFirstResponder(noteList)
                }
            }
        } else {
            loops.forEach { $0.cancel() }
            loops.removeAll()
            Task { await editor.flush() }
        }
    }

    // MARK: Compare (D7 `[比較]`)

    private func presentCompare(mine: String, disk: String) {
        guard compareSheet == nil, let window = view.window else { return }
        let lines = Self.diffLines(old: disk, new: mine)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        let model = HistoryCompareModel(versions: [HistoryVersionOption(id: "disk", title: "磁碟上的版本"),
                                                   HistoryVersionOption(id: "mine", title: "你的未儲存版本")],
                                        fromID: "disk", toID: "mine", lines: lines, summary: "−\(removed) +\(added)",
                                        restoreEnabled: false, restoreDisabledReason: "用橫幅的［重新載入］或［保留我的］決定")
        let view = HistoryCompareView(model: model)
        view.onClose = { [weak self] in
            if let sheet = self?.compareSheet { DialogPresenter.dismiss(sheet) }
            self?.compareSheet = nil
        }
        compareSheet = DialogPresenter.presentSheet(view, on: window)
    }

    /// Line hunks (CoddFiles `LineDiff`) as CoddUI diff lines with 2 lines of context.
    static func diffLines(old: String, new: String) -> [DiffLinesView.Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var out: [DiffLinesView.Line] = []
        for hunk in LineDiff.hunks(old: a, new: b, context: 2) {
            out.append(DiffLinesView.Line(kind: .hunk, text: LineDiff.unifiedHeader(hunk)))
            var oldLine = hunk.oldRange.lowerBound
            var newLine = hunk.newRange.lowerBound
            // Context lines are the leading / trailing lines the two sides share.
            let shared = zip(hunk.oldLines, hunk.newLines).prefix { $0 == $1 }.count
            let oldTail = Array(hunk.oldLines.dropFirst(shared))
            let newTail = Array(hunk.newLines.dropFirst(shared))
            let trailing = zip(oldTail.reversed(), newTail.reversed()).prefix { $0 == $1 }.count
            for line in hunk.oldLines.prefix(shared) {
                out.append(DiffLinesView.Line(kind: .context, oldNumber: oldLine + 1, newNumber: newLine + 1, text: line))
                oldLine += 1
                newLine += 1
            }
            for line in oldTail.dropLast(trailing) {
                out.append(DiffLinesView.Line(kind: .removed, oldNumber: oldLine + 1, text: line))
                oldLine += 1
            }
            for line in newTail.dropLast(trailing) {
                out.append(DiffLinesView.Line(kind: .added, newNumber: newLine + 1, text: line))
                newLine += 1
            }
            for line in newTail.suffix(trailing) {
                out.append(DiffLinesView.Line(kind: .context, oldNumber: oldLine + 1, newNumber: newLine + 1, text: line))
                oldLine += 1
                newLine += 1
            }
        }
        return out
    }

    // MARK: Recent files (LOCAL FILES)

    private func loadRecentFiles() {
        guard let recentFiles else { return }
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) { recentFiles.load() }.value
            guard let self, items != self.recent else { return }
            self.recent = items
            self.loops.first?.refresh()
        }
    }

    // MARK: Dump

    /// The core notes keys of the state dump (§6).
    var dumpObject: [String: Any] {
        NotesDump.object(service: service, editor: editor, mode: mode, area: self)
    }
}
