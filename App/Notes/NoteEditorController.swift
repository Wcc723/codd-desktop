import AppKit
import CoddFileEditorUI
import CoddNotebookUI
import CoddNotes
import CoddPreferences
import CoddTextKit
import CoddUI
import Observation

/// A note that is not on disk yet (D3): the editor shows `seed`, and the note is created only at
/// its first committed change that leaves the seed (or the first pasted image). Abandoned
/// untouched, it leaves nothing behind.
struct NoteDraft: Equatable, Sendable {
    var kind: NoteKind
    /// The title when the text names none (`隨手記 10/17`, `未命名筆記`).
    var title: String
    var seed: String
    var links: NoteLinks

    /// The seed of an untitled note: the empty title line (the `標題` placeholder) and a body line
    /// under it, so a click below the title or one Return after it lands in the body.
    static let untitledSeed = "# \n"

    /// `+ ⌘⇧N` in the Notebook (D13): a NOTE in INBOX with the `標題` placeholder.
    static func note(title: String? = nil) -> NoteDraft {
        if let title, !title.isEmpty {
            return NoteDraft(kind: .note, title: title, seed: "# \(title)\n\n", links: NoteLinks())
        }
        return NoteDraft(kind: .note, title: "未命名筆記", seed: untitledSeed, links: NoteLinks())
    }

    /// The drawer's `+ 新筆記（連結此 session）` (I2b): a NOTE with the `標題` placeholder, linked to
    /// the session and its project.
    static func linked(_ links: NoteLinks) -> NoteDraft {
        NoteDraft(kind: .note, title: "未命名筆記", seed: untitledSeed, links: links)
    }

    /// Where the caret starts: on the empty title line of an untitled seed, else in the body.
    var caret: Int {
        seed == Self.untitledSeed ? 2 : (seed as NSString).length
    }

    /// ⌘⇧N elsewhere, QUICK NOTE, 快速筆記 (D13): a SCRATCH titled `隨手記 M/D`, linked to the
    /// session on screen and its project.
    static func quick(now: Date, timeZone: TimeZone, links: NoteLinks) -> NoteDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day], from: now)
        let title = "隨手記 \(parts.month ?? 0)/\(parts.day ?? 0)"
        return NoteDraft(kind: .scratch, title: title, seed: "# \(title)\n\n", links: links)
    }

    /// The user typed something of their own: the text left the seed and is not blank.
    func isTouched(_ text: String) -> Bool {
        guard text != seed else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "#"
    }

    /// The text's first H1 (`# …` on line 1 … after blank lines), else nil.
    static func title(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("# ") else { return nil }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

/// The document slot of the Notebook chrome: the D7 banner over the C4 editor, or a comment line
/// when there is nothing to edit (no note, the folder unavailable), plus the paste toast.
final class NoteDocumentView: FlippedView, ZoomRefreshing {
    let editor: MarkdownEditorView
    let banner = DiskChangeBannerView(model: .noteChanged())
    private let message = Label.make(style: TextStyle.comment)
    private(set) var toast: ToastView?

    init(editor: MarkdownEditorView) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        banner.isHidden = true
        message.isHidden = true
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 3
        for view in [editor, banner, message] as [NSView] { addSubview(view) }
        // The document moves between the Notebook and the Files slot (I3): refreshed while out.
        UIZoom.track(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// M4 interface zoom: the editor's style is built at the design size, so the zoom is its
    /// font scale (it waits while an input method composes). Its text keeps its own styling.
    func zoomDidChange() { editor.setFontScale(UIZoom.scale) }
    var zoomRescalesTextViews: Bool { false }

    var showsBanner: Bool {
        get { !banner.isHidden }
        set {
            guard newValue != !banner.isHidden else { return }
            banner.isHidden = !newValue
            needsLayout = true
        }
    }

    /// A comment instead of the editor (`// 還沒有筆記 · ⌘⇧N 新增`); nil shows the editor.
    var messageText: String? {
        didSet {
            guard messageText != oldValue else { return }
            Label.set(message, messageText ?? "", style: TextStyle.comment)
            message.isHidden = messageText == nil
            editor.isHidden = messageText != nil
            needsLayout = true
        }
    }

    /// The D9 toast near the document's bottom edge (with `[UNDO]` for archive / trash, I1b).
    func showToast(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        toast?.removeFromSuperview()
        let view = ToastView(text: text, undo: undo, countdown: nil)
        addSubview(view)
        toast = view
        needsLayout = true
        view.dismiss(after: 6)
    }

    override func layout() {
        super.layout()
        let bannerHeight: CGFloat = banner.isHidden ? 0 : DiskChangeBannerView.height
        banner.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
        editor.frame = CGRect(x: 0, y: bannerHeight, width: bounds.width, height: max(0, bounds.height - bannerHeight))
        let size = message.sizeThatFits(NSSize(width: max(0, bounds.width - 88), height: 200))
        message.frame = CGRect(x: 44, y: 28, width: max(0, bounds.width - 88), height: ceil(size.height))
        if let toast, toast.superview === self {
            let fitting = toast.fittingSize
            let width = min(max(fitting.width, 200), max(0, bounds.width - 32))
            toast.frame = CGRect(x: 16, y: bounds.height - 16 - fitting.height, width: width, height: fitting.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
    }
}

/// Binds C4's `MarkdownEditorView` to a note (M4 I1a, D3, D7, D9, D11): loads the selected note,
/// creates a draft on disk at its first real change, autosaves 1 s after the last committed
/// change (never while an input method composes), flushes on note switch / area leave / window
/// close / quit, turns a `basedOn` conflict or an external change over unsaved text into the
/// `磁碟上的筆記已變更` banner, reloads a clean editor in place, saves pasted images (D9) and
/// resolves image lines with their annotation overlays.
///
/// Two of them run over one notebook: the Notebook's and the session drawer's (``NoteEditors``).
/// Each saves against the hash it last saw and hands what it saved to the other (``link(_:)``),
/// so the same note open in both stays one text: a clean one reloads in place, unsaved text
/// gets the banner, and neither ever writes over the other's change.
@MainActor @Observable
final class NoteEditorController {
    enum SaveState: Equatable, Sendable {
        case none
        case saved(Date)
        case unsaved
        case saving
    }

    /// Where the editor shows: the Notebook's document slot, or the session pane's notes drawer
    /// (a 300 pt column: the narrow style, no chips row, no annotation summary beside a figure).
    enum Placement: Sendable {
        case notebook
        case drawer
    }

    @ObservationIgnored let placement: Placement
    @ObservationIgnored let editor: MarkdownEditorView
    @ObservationIgnored let documentView: NoteDocumentView
    /// The chips row under the title (C4 title accessory; tag editing is I1b's).
    @ObservationIgnored let chipsRow = NoteChipsRowView(model: NoteChipsRowModel(kind: .note, tags: [], updated: ""))
    @ObservationIgnored let images = NoteImageCache()
    @ObservationIgnored private let service: NotesService
    @ObservationIgnored private let preferences: PreferencesService
    @ObservationIgnored private let timeZone: TimeZone

    // MARK: State

    private(set) var noteID: NoteID?
    private(set) var draft: NoteDraft?
    /// The note as last read or written (frontmatter facts for the chrome).
    private(set) var document: NoteDocument?
    /// The body the disk has (as far as CODD knows): the editor is dirty when its text differs.
    private(set) var baseBody = ""
    private(set) var baseHash: String?
    private(set) var saveState: SaveState = .none
    private(set) var caret = MarkdownCaret(line: 1, column: 1, selectionLength: 0)
    private(set) var mode: MarkdownEditorMode = .livePreview
    /// D7: the disk version that differs from unsaved text (the banner shows while set).
    private(set) var diskConflict: NoteDocument?
    /// Saves written (tests: the debounce).
    private(set) var saveCount = 0
    /// Clean reloads applied from disk (D7; the dump / tests).
    private(set) var externalReloads = 0
    /// Unsaved buffers kept in HISTORY (or, when that failed, as a new note) when the user left
    /// the note (D8; tests).
    private(set) var unsavedKept = 0
    /// Leaves refused because the unsaved text could be kept nowhere (it stays on screen; tests).
    private(set) var leavesRefused = 0
    /// Clean reloads of a save made by the other editor on the same note (tests).
    private(set) var peerReloads = 0
    /// The comment shown instead of the editor (no note, the folder unavailable).
    private(set) var placeholder: String?
    /// A `show` / `startDraft` is on its way (the area does not auto-select meanwhile).
    private(set) var isLoading = false
    /// How long the last `show` took: read, image sizes, editor load (numbers, the dump).
    @ObservationIgnored private(set) var lastOpenMs: Double?

    // MARK: Wiring

    /// 1 s after the last committed change (tests shorten it).
    @ObservationIgnored var autosaveDelay: Duration = .seconds(1)
    /// D29: opening a note for this long counts as activity.
    @ObservationIgnored var openedDelay: Duration = .seconds(3)
    @ObservationIgnored var onToast: ((String) -> Void)?
    /// A `codd://note/<id>` link was clicked.
    @ObservationIgnored var onOpenNote: ((NoteID) -> Void)?
    /// `[比較]` on the banner: the buffer and the disk text.
    @ObservationIgnored var onCompare: ((_ mine: String, _ disk: String) -> Void)?
    /// `[編輯標註]`, ⌘⇧A on an image line or a double click on a figure (I1b): the image's path
    /// as written in the note.
    @ObservationIgnored var onEditAnnotations: ((String) -> Void)?
    /// ⌘⏎ in the editor (D14 send, wired in I2b).
    @ObservationIgnored var onCommandReturn: (() -> Void)?
    /// Opens URLs (the default browser; tests record). Only ever called for a user's click.
    @ObservationIgnored var openURL: (URL) -> Void = { url in
        guard !AppActivation.isBackground else {
            HolderSessionStore.printLog("notes link open skipped (background run) scheme=\(url.scheme ?? "-")")
            return
        }
        NSWorkspace.shared.open(url)
    }
    /// Reveals a file in Finder (relative file links until I3 opens them in Files).
    @ObservationIgnored var revealFile: (URL) -> Void = { url in
        guard !AppActivation.isBackground else {
            HolderSessionStore.printLog("notes reveal skipped (background run) name=\(url.lastPathComponent)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ObservationIgnored private var figures = NoteFigureFacts()
    @ObservationIgnored private var figuresTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savingTask: Task<Void, Never>?
    @ObservationIgnored private var creation: Task<NoteDocument?, Never>?
    @ObservationIgnored private var openedTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var summaryViews: [String: ImageAnnotationSummaryView] = [:]
    /// The other editors over this notebook (``link(_:)``).
    @ObservationIgnored private var peers: [WeakNoteEditor] = []

    init(service: NotesService, preferences: PreferencesService, timeZone: TimeZone? = nil, placement: Placement = .notebook) {
        self.service = service
        self.preferences = preferences
        self.timeZone = timeZone ?? service.timeZone
        self.placement = placement
        // The editor scales its own style (⌘+ / ⌘−): built at the design size, then scaled.
        editor = UIZoom.unzoomed {
            MarkdownEditorView(style: placement == .drawer ? MarkdownEditorStyle.drawer : MarkdownEditorStyle.notebook)
        }
        editor.setFontScale(UIZoom.scale)
        documentView = NoteDocumentView(editor: editor)
        // The chips row is the editor's accessory only while a note shows.
        UIZoom.track(chipsRow)
        wire()
        placeholder = NotebookCopy.noNotesEmpty
        documentView.messageText = placeholder
    }

    private func wire() {
        // The drawer's column has no room for the chips row or a summary beside a figure (the
        // figures keep their overlays; the Notebook edits tags and annotations).
        if placement == .notebook {
            editor.titleAccessory = chipsRow
            editor.imageAccessoryProvider = { [weak self] info in self?.accessory(for: info) }
        }
        editor.onTextChange = { [weak self] text in self?.textChanged(text) }
        editor.onCaretChange = { [weak self] caret in self?.caret = caret }
        editor.onPasteImage = { [weak self] image in
            guard let self else { return false }
            Task { await self.paste(image) }
            return true
        }
        editor.imageResolver = { [weak self] path in self?.resolve(path) }
        editor.onOpenLink = { [weak self] link in self?.openLink(link) }
        editor.onEditImageAnnotations = { [weak self] path in self?.onEditAnnotations?(path) }
        editor.onCommandReturn = { [weak self] in self?.onCommandReturn?() }
        images.onChange = { [weak self] path in self?.editor.reloadImage(path: path) }
        documentView.banner.onReload = { [weak self] in self?.reloadFromDisk() }
        documentView.banner.onKeepMine = { [weak self] in Task { await self?.keepMine() } }
        documentView.banner.onCompare = { [weak self] in
            guard let self, let disk = self.diskConflict else { return }
            self.onCompare?(self.editor.text, disk.body)
        }
    }

    /// The committed text differs from the disk's (never counts a composition).
    var isDirty: Bool { noteID != nil && editor.text != baseBody }
    var hasContent: Bool { noteID != nil || draft != nil }
    /// The text shown (committed only).
    var text: String { editor.text }

    // MARK: Loading

    /// Shows a saved note (after saving the one shown). Nil shows `placeholder` instead. When the
    /// shown note's unsaved text can be written nowhere (``keepUnsavedBeforeLeaving()``), the
    /// editor keeps it on screen and stays on that note.
    func show(_ id: NoteID?, placeholder text: String? = nil) async {
        // The request wins over every earlier one at once (before the flush awaits), so a later
        // draft or selection is never replaced by this one finishing late.
        loadToken += 1
        let token = loadToken
        isLoading = true
        defer { if token == loadToken { isLoading = false } }
        await flush()
        guard token == loadToken else { return }
        if id != noteID {
            let kept = await keepUnsavedBeforeLeaving()
            guard token == loadToken, kept else { return }
        }
        openedTask?.cancel()
        guard let id else {
            setEmpty(text ?? NotebookCopy.noNotesEmpty)
            return
        }
        guard id != noteID || draft != nil else {
            placeholder = nil
            documentView.messageText = nil
            return
        }
        let started = ContinuousClock.now
        let document: NoteDocument
        do {
            document = try await service.document(id)
        } catch {
            guard token == loadToken else { return }
            setEmpty("// \(error.localizedDescription)")
            return
        }
        guard token == loadToken else { return }
        images.reset(folder: document.fileURL.deletingLastPathComponent())
        summaryViews = [:]
        figures = NoteFigureFacts.parse(document.body)
        await images.prepare(Array(figures.figures.keys))
        guard token == loadToken else { return }
        noteID = id
        draft = nil
        self.document = document
        baseBody = document.body
        baseHash = document.contentHash
        diskConflict = nil
        documentView.showsBanner = false
        saveState = .saved(document.metadata.updated)
        placeholder = nil
        documentView.messageText = nil
        editor.load(document.body, selection: NSRange(location: 0, length: 0))
        lastOpenMs = NotesService.milliseconds(ContinuousClock.now - started)
        HolderSessionStore.printLog(String(format: "%@ show id=%@ bytes=%d ms=%.1f", logName, id.rawValue, document.body.utf8.count,
                                           lastOpenMs ?? 0))
        scheduleOpened(id)
    }

    /// Starts a draft (D3, D13): nothing on disk until the user types or pastes an image.
    func startDraft(_ next: NoteDraft) async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        defer { if token == loadToken { isLoading = false } }
        await flush()
        guard token == loadToken else { return }
        let kept = await keepUnsavedBeforeLeaving()
        guard token == loadToken, kept else { return }
        openedTask?.cancel()
        noteID = nil
        document = nil
        draft = next
        baseBody = next.seed
        baseHash = nil
        diskConflict = nil
        documentView.showsBanner = false
        saveState = .none
        placeholder = nil
        documentView.messageText = nil
        images.reset(folder: service.notesRoot)
        summaryViews = [:]
        figures = NoteFigureFacts()
        editor.load(next.seed, selection: NSRange(location: next.caret, length: 0))
        service.noteStarted(kind: next.kind)
        HolderSessionStore.printLog("notes draft kind=\(next.kind.rawValue) links=\(next.links.sessions.count + next.links.projects.count)")
    }

    private func setEmpty(_ text: String) {
        noteID = nil
        draft = nil
        document = nil
        baseBody = ""
        baseHash = nil
        diskConflict = nil
        documentView.showsBanner = false
        saveState = .none
        placeholder = text
        documentView.messageText = text
        images.reset(folder: nil)
        editor.load("", selection: nil)
    }

    /// The area shows a reason instead of the editor (the folder unavailable).
    func showUnavailable(_ reason: String) {
        loadToken += 1
        saveTask?.cancel()
        setEmpty("// 筆記資料夾無法使用：\(reason)")
    }

    /// The comment shown while there is nothing to edit (ignored while a note or draft shows).
    func setPlaceholder(_ text: String) {
        guard !hasContent, placeholder != text else { return }
        placeholder = text
        documentView.messageText = text
    }

    func focus() {
        guard placeholder == nil else { return }
        editor.focus()
    }

    // MARK: Editing

    private func textChanged(_ text: String) {
        scheduleFigures()
        if noteID == nil, let draft {
            if draft.isTouched(text) { Task { await ensureCreated() } }
            return
        }
        guard noteID != nil else { return }
        if text != baseBody {
            saveState = .unsaved
            scheduleSave()
        }
    }

    /// The draft on disk (D3), once; every caller waits for the same creation.
    @discardableResult
    func ensureCreated() async -> NoteID? {
        if let noteID { return noteID }
        if let creation { return await creation.value?.metadata.id ?? noteID }
        guard let draft else { return nil }
        let body = editor.text
        let title = NoteDraft.title(of: body) ?? draft.title
        let service = self.service
        let task = Task { () -> NoteDocument? in
            do {
                return try await service.create(NewNote(title: title, body: body, kind: draft.kind, links: draft.links))
            } catch {
                HolderSessionStore.printLog("notes create failed: \(error.localizedDescription)")
                return nil
            }
        }
        creation = task
        let document = await task.value
        creation = nil
        guard let document else {
            onToast?("無法建立筆記")
            return nil
        }
        guard self.draft == draft else { return document.metadata.id }
        noteID = document.metadata.id
        self.draft = nil
        self.document = document
        baseBody = document.body
        baseHash = document.contentHash
        saveState = .saved(document.metadata.updated)
        images.reset(folder: document.fileURL.deletingLastPathComponent())
        if editor.text != baseBody {
            saveState = .unsaved
            scheduleSave()
        }
        scheduleOpened(document.metadata.id)
        return document.metadata.id
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = autosaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            if self.editor.isComposing {
                // D11: never while marked text exists; look again after the next interval.
                self.scheduleSave()
                return
            }
            await self.flush()
        }
    }

    /// Writes pending text now (switch, leave, close, quit, an AI write). Nothing while composing
    /// or while the banner waits for the user's choice.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        if noteID == nil, let draft, draft.isTouched(editor.text) { await ensureCreated() }
        if let savingTask { await savingTask.value }
        guard let id = noteID, isDirty, !editor.isComposing, diskConflict == nil else { return }
        let task = Task { await self.save(id) }
        savingTask = task
        await task.value
        savingTask = nil
    }

    private func save(_ id: NoteID) async {
        let text = editor.text
        saveState = .saving
        do {
            var outcome = try await service.save(id, body: text, basedOn: baseHash)
            if case .conflict(let disk) = outcome, noteID == id, disk.body == baseBody {
                // Only the frontmatter moved since this editor's hash (a menu or a send rewrote it
                // through the other editor, or another program did): the body the text is based
                // on is still the disk's, so the text goes over the new hash (C1 keeps the new
                // frontmatter). A changed body is the banner below.
                baseHash = disk.contentHash
                document = disk
                outcome = try await service.save(id, body: text, basedOn: disk.contentHash)
            }
            switch outcome {
            case .saved(let document):
                // The other editor on this note takes the write (CODD's own: no watcher event).
                for peer in peers { peer.editor?.peerSaved(document) }
                guard noteID == id else { return }
                baseBody = text
                baseHash = document.contentHash
                self.document = document
                saveCount += 1
                saveState = editor.text == baseBody ? .saved(document.metadata.updated) : .unsaved
                if editor.text != baseBody { scheduleSave() }
            case .conflict(let disk):
                guard noteID == id else { return }
                HolderSessionStore.printLog("\(logName) save conflict id=\(id.rawValue)")
                showConflict(disk)
            }
        } catch {
            saveState = .unsaved
            onToast?(error.localizedDescription)
            HolderSessionStore.printLog("notes save failed id=\(id.rawValue): \(error.localizedDescription)")
        }
    }

    /// Leaving the shown note (another note, a draft, quit): the flush, then whatever it could not
    /// write is kept (``keepUnsavedBeforeLeaving()``).
    func flushForLeaving() async {
        await flush()
        await keepUnsavedBeforeLeaving()
    }

    /// D7 / D8: text a flush could not write never goes silently. That is text the banner holds
    /// back (it waits for 重新載入 / 保留我的), a composition kept from saving, a save that failed
    /// (the file moved or removed outside CODD, the note in TRASH, an I/O error) or text typed
    /// while the last save ran. Before the editor loads something else the buffer becomes a
    /// HISTORY version (`未儲存的編輯`), which 還原這一版 brings back; when even that fails (the
    /// note's file is gone), a new note with the same links. Returns false when neither could be
    /// written: the caller keeps the text on screen instead of loading something else.
    @discardableResult
    private func keepUnsavedBeforeLeaving() async -> Bool {
        guard let id = noteID, isDirty else { return true }
        let text = editor.text
        if await service.snapshotUnsaved(id, body: text) {
            unsavedKept += 1
            onToast?("未儲存的編輯已存到 HISTORY")
            return true
        }
        let title = NoteDraft.title(of: text) ?? document.map(\.metadata.title).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名筆記"
        do {
            // On the side: the selection (and a pending QUICK NOTE) stay where the user is going.
            let copy = try await service.create(NewNote(title: title, body: text, kind: document?.metadata.kind ?? .note,
                                                        links: document?.metadata.links ?? NoteLinks()), select: false)
            unsavedKept += 1
            onToast?(Self.keptAsCopyText(copy.metadata.title))
            HolderSessionStore.printLog("\(logName) unsaved kept as a new note id=\(id.rawValue) copy=\(copy.metadata.id.rawValue)")
            return true
        } catch {
            leavesRefused += 1
            onToast?(Self.keptOnScreenText(error.localizedDescription))
            HolderSessionStore.printLog("\(logName) unsaved kept on screen id=\(id.rawValue): \(error.localizedDescription)")
            return false
        }
    }

    /// The toast when the note itself could not take the text (nor a HISTORY version of it).
    static func keptAsCopyText(_ title: String) -> String {
        "無法寫入原筆記，未儲存的編輯已另存為新筆記「\(title.isEmpty ? "未命名筆記" : title)」"
    }

    /// The toast when nothing could take the text: it stays in the editor.
    static func keptOnScreenText(_ reason: String) -> String {
        "無法保存未儲存的編輯（\(reason)），內容仍留在編輯器"
    }

    /// C1 wrote the shown note for an AI (`notes_append` / `notes_write`: CODD's own write, so the
    /// watcher stays quiet). The editor was flushed right before it: a clean one takes the new body
    /// in place, text typed since gets the D7 banner over the AI's version now, instead of a
    /// conflict for CODD's own write at the next autosave. A save in flight settles it itself.
    func aiWrote(_ next: NoteDocument) {
        guard next.metadata.id == noteID, savingTask == nil, next.contentHash != baseHash else { return }
        adopt(next)
    }

    /// C1's AI write waits for this: saves when dirty, after up to 2 s for a composition to end.
    func flushForAI(_ id: NoteID) async {
        guard id == noteID else { return }
        let deadline = ContinuousClock.now + .seconds(2)
        while editor.isComposing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        await flush()
    }

    // MARK: Disk changes (D7)

    /// Another program changed the shown note: a clean editor reloads in place (the selection
    /// kept; C4 waits while composing), unsaved text gets the banner.
    func externalChange(_ id: NoteID) async {
        guard id == noteID, let disk = try? await service.document(id), id == noteID else { return }
        guard disk.contentHash != baseHash else { return }
        if !isDirty, diskConflict == nil {
            applyDisk(disk)
            externalReloads += 1
            HolderSessionStore.printLog("\(logName) external reload id=\(id.rawValue)")
        } else {
            showConflict(disk)
            HolderSessionStore.printLog("\(logName) external banner id=\(id.rawValue)")
        }
    }

    // MARK: The other editor (the Notebook's and the drawer's, ``NoteEditors``)

    /// Saves of this editor reach `other` and the other way round (once per pair).
    func link(_ other: NoteEditorController) {
        guard other !== self, !peers.contains(where: { $0.editor === other }) else { return }
        peers.append(WeakNoteEditor(other))
        other.link(self)
    }

    /// The other editor wrote the note this one shows (`document` is the file as written): a
    /// frontmatter-only write moves the hash, a clean editor reloads in place, unsaved text gets
    /// the D7 banner over it (nothing is replaced), a waiting banner moves to the newest version.
    func peerSaved(_ document: NoteDocument) {
        guard document.metadata.id == noteID, document.contentHash != baseHash else { return }
        if diskConflict != nil {
            diskConflict = document
            self.document = document
            return
        }
        if document.body == baseBody {
            self.document = document
            baseHash = document.contentHash
            return
        }
        guard let id = noteID else { return }
        if !isDirty {
            applyDisk(document)
            peerReloads += 1
            HolderSessionStore.printLog("\(logName) peer reload id=\(id.rawValue)")
        } else {
            showConflict(document)
            HolderSessionStore.printLog("\(logName) peer banner id=\(id.rawValue)")
        }
    }

    /// The log lines' prefix (the Notebook's stay `notes …`).
    private var logName: String { placement == .drawer ? "notes drawer" : "notes" }

    private func showConflict(_ disk: NoteDocument) {
        saveTask?.cancel()
        diskConflict = disk
        documentView.banner.update(.noteChanged(showsUnsaved: isDirty))
        documentView.showsBanner = true
    }

    private func applyDisk(_ disk: NoteDocument) {
        editor.applyExternalText(disk.body)
        baseBody = disk.body
        baseHash = disk.contentHash
        document = disk
        saveState = .saved(disk.metadata.updated)
        diskConflict = nil
        documentView.showsBanner = false
        scheduleFigures()
    }

    /// `[重新載入]`: the disk version replaces the buffer (one undo step brings it back).
    func reloadFromDisk() {
        guard let disk = diskConflict else { return }
        applyDisk(disk)
    }

    /// `[保留我的]`: the disk version goes into HISTORY (D8), then the buffer is written over it.
    func keepMine() async {
        guard let disk = diskConflict, let id = noteID else { return }
        await service.snapshot(id, reason: "external")
        baseHash = disk.contentHash
        diskConflict = nil
        documentView.showsBanner = false
        if isDirty { saveState = .unsaved }
        await flush()
    }

    // MARK: Images (D9, D10)

    /// A pasted / dropped image: the note is created first when it is a draft, the file goes to
    /// `assets/<id>/` off the main actor, the Markdown goes in at the caret, and the toast says where.
    @discardableResult
    func paste(_ image: MarkdownPastedImage) async -> AssetRef? {
        guard let id = await ensureCreated() else { return nil }
        let notebook = preferences.preferences.notebook
        do {
            let ref = try await service.saveAsset(image.data, typeHint: image.typeIdentifier, for: id,
                                                  resizeLongEdge: notebook.resizeImages ? 2576 : nil, keepOriginal: notebook.keepOriginal)
            guard noteID == id else { return ref }
            images.register(path: ref.markdownPath, size: ref.pixelSize)
            editor.insertImageMarkdown(alt: "截圖 " + Self.stamp(service.clock(), timeZone: timeZone), path: ref.markdownPath)
            onToast?("已貼上圖片 → \(ref.relativePath)" + (ref.resized ? " · 已縮小到 2576px" : ""))
            return ref
        } catch {
            let message = (error as? NotesError)?.errorDescription ?? error.localizedDescription
            onToast?(message)
            HolderSessionStore.printLog("notes paste refused id=\(id.rawValue): \(message)")
            return nil
        }
    }

    /// `yyyy-MM-dd HH:mm` (the D9 alt text).
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
    }

    private func resolve(_ path: String) -> MarkdownImageInfo? {
        guard let size = images.size(for: path) else {
            images.request(path)
            return nil
        }
        let figure = figures.figures[path]
        let annotations = figure?.annotations
        let pixelSize = annotations.map { CGSize(width: $0.size.width, height: $0.size.height) } ?? size
        return MarkdownImageInfo(path: path, image: images.image(for: path), pixelSize: pixelSize, caption: figure?.alt ?? "",
                                 overlay: NoteFigureFacts.overlay(annotations))
    }

    private func accessory(for info: MarkdownImageInfo) -> NSView? {
        guard let annotations = figures.figures[info.path]?.annotations, !annotations.items.isEmpty else { return nil }
        let model = NoteFigureFacts.summary(annotations)
        if let view = summaryViews[info.path] {
            view.update(model)
            return view
        }
        let view = ImageAnnotationSummaryView(model: model)
        let path = info.path
        view.onEdit = { [weak self] in self?.onEditAnnotations?(path) }
        summaryViews[info.path] = view
        return view
    }

    /// Image lines and annotation blocks after a committed change (debounced: a 1 MB note is
    /// not re-scanned per keystroke); only figures whose facts changed are redrawn.
    private func scheduleFigures() {
        figuresTask?.cancel()
        figuresTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let next = NoteFigureFacts.parse(self.editor.text)
            let previous = self.figures
            guard next != previous else { return }
            self.figures = next
            let paths = Set(next.figures.keys).union(previous.figures.keys)
            for path in paths where next.figures[path] != previous.figures[path] {
                self.summaryViews[path] = nil
                self.editor.reloadImage(path: path)
            }
            await self.images.prepare(Array(next.figures.keys))
        }
    }

    // MARK: Links, mode, chips

    private func openLink(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("codd://") || trimmed.hasPrefix("[[note:") || trimmed.hasPrefix("@") {
            if let id = NoteReferences.parseRef(trimmed) { onOpenNote?(id) }
            return
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            openURL(url)
            return
        }
        // A relative file link: revealed in Finder (I3 opens it in Files).
        if let target = images.url(for: trimmed.removingPercentEncoding ?? trimmed), FileManager.default.fileExists(atPath: target.path) {
            revealFile(target)
        }
    }

    /// ⌘E (D36): 原始碼 ⇄ 即時預覽 (never while composing: the menu item is disabled then).
    func toggleMode() {
        guard !editor.isComposing else { return }
        mode = mode == .livePreview ? .source : .livePreview
        editor.mode = mode
    }

    /// The chips row under the title (its tag field and chips are wired by the area, I1b).
    func updateChips(_ model: NoteChipsRowModel) {
        guard chipsRow.model != model else { return }
        chipsRow.update(model)
        editor.invalidateAccessoryLayout()
    }

    // MARK: Metadata, history, annotations (I1b)

    /// CODD rewrote the shown note's frontmatter (a menu, a picker, a pin): the file's hash moved
    /// while the body stayed, so the next save is based on the new hash. A body that differs
    /// from what the editor last saw is another program's change and takes the D7 path.
    func adopt(_ next: NoteDocument) {
        guard next.metadata.id == noteID else { return }
        if diskConflict != nil {
            // The banner keeps waiting for the user, now over the newest disk version.
            diskConflict = next
            document = next
            return
        }
        if next.body == baseBody {
            document = next
            baseHash = next.contentHash
        } else {
            Task { await externalChange(next.metadata.id) }
        }
    }

    /// `還原這一版` replaced the note's body on disk (CODD's own write, so no watcher event): the
    /// editor shows it as one undoable step and takes its hash.
    func applyRestored(_ next: NoteDocument) {
        guard next.metadata.id == noteID else { return }
        applyDisk(next)
    }

    /// ⋯ › 類型 on a note that is not on disk yet: the draft is created with that kind.
    func setDraftKind(_ kind: NoteKind) {
        draft?.kind = kind
    }

    /// The note's image paths in body order (⌘⇧A, ASSETS thumbnails).
    var imagePaths: [String] { figures.order }

    /// The `codd-annotations` block of `path` (D10), as the editor text has it now.
    func annotations(of path: String) -> ImageAnnotations? {
        FencedBlocks.find(info: "codd-annotations", in: editor.text).first { $0.imagePath == path }
            .flatMap { ImageAnnotations.decode($0.content) }
    }

    /// The ImageAnnotate `完成` (D10): the block after `path`'s image line becomes `json` (inserted
    /// after the image line when missing, removed when nil) as ONE undoable edit of the editor
    /// text; the autosave writes it. False when the image line is gone or nothing changed.
    @discardableResult
    func replaceAnnotationBlock(of path: String, with json: String?) -> Bool {
        let text = editor.text
        guard let line = FencedBlocks.imageLines(in: text).first(where: { $0.path == path }) else { return false }
        let next = FencedBlocks.replacingBlock(after: line.line, info: "codd-annotations", with: json, in: text)
        guard let (range, replacement) = Self.difference(text as NSString, next as NSString) else { return false }
        editor.replace(range, with: replacement, actionName: "編輯標註")
        return true
    }

    /// The smallest replacement turning `old` into `new` (common prefix and suffix, never splitting
    /// a surrogate pair), so the undo step and the selection mapping stay local.
    nonisolated static func difference(_ old: NSString, _ new: NSString) -> (NSRange, String)? {
        let oldLength = old.length
        let newLength = new.length
        let limit = min(oldLength, newLength)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix == oldLength, prefix == newLength { return nil }
        while prefix > 0, UTF16.isTrailSurrogate(old.character(at: prefix - 1)) || UTF16.isLeadSurrogate(old.character(at: prefix - 1)) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        while suffix > 0, UTF16.isTrailSurrogate(old.character(at: oldLength - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: oldLength - prefix - suffix)
        return (range, new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix)))
    }

    /// An ASSETS thumbnail: the caret goes to the image line whose file is `name` and the editor
    /// scrolls to it. False when the body has no such image line.
    @discardableResult
    func revealImage(named name: String) -> Bool {
        let text = editor.text
        let lines = FencedBlocks.imageLines(in: text)
        guard let target = lines.first(where: { ($0.path as NSString).lastPathComponent == name }) else { return false }
        var location = 0
        var index = 0
        let ns = text as NSString
        while index < target.line, location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            index += 1
        }
        editor.revealLocation(location)
        return true
    }

    private func scheduleOpened(_ id: NoteID) {
        openedTask?.cancel()
        let delay = openedDelay
        openedTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.noteID == id else { return }
            await self.service.markOpened(id)
        }
    }

    /// `-codd-notes-type`: typed through the text view's `insertText`, as the keyboard does.
    func type(_ text: String) {
        focus()
        let view = editor.textViewForTesting
        if draft == nil, noteID != nil {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

/// A weak reference to an editor (the peers and the group never keep one alive).
@MainActor
struct WeakNoteEditor {
    weak var editor: NoteEditorController?

    init(_ editor: NoteEditorController) { self.editor = editor }
}

/// The note editors of one notebook: the Notebook's and the session drawer's. The service's three
/// hooks (a disk change, an AI write's flush, the AI write itself) reach every editor, and a save
/// in one is handed to the others (``NoteEditorController/link(_:)``). No two writers race: each
/// saves against the hash it last saw, so a stale one gets the D7 banner instead of writing over
/// the other's text.
@MainActor
final class NoteEditors {
    private let members: [WeakNoteEditor]

    init(_ editors: [NoteEditorController]) {
        members = editors.map(WeakNoteEditor.init)
        for (index, editor) in editors.enumerated() {
            for other in editors[(index + 1)...] { editor.link(other) }
        }
    }

    var editors: [NoteEditorController] { members.compactMap(\.editor) }

    func externalChange(_ id: NoteID) async {
        for editor in editors { await editor.externalChange(id) }
    }

    func flushForAI(_ id: NoteID) async {
        for editor in editors { await editor.flushForAI(id) }
    }

    func aiWrote(_ document: NoteDocument) {
        for editor in editors { editor.aiWrote(document) }
    }

    /// Points the service's hooks at every editor (the hooks keep the group alive; it holds the
    /// editors weakly).
    func attach(to service: NotesService) {
        service.onExternalChange = { [self] id in Task { await self.externalChange(id) } }
        service.flushEditor = { [self] id in await self.flushForAI(id) }
        service.onAIWrite = { [self] document in self.aiWrote(document) }
    }
}

extension MarkdownEditorStyle {
    /// The session drawer's editor (a 300 pt column): the Notebook's type with smaller title and
    /// H2 lines, narrow padding (the fold glyph keeps its room on the left) and shorter figures.
    @MainActor static var drawer: MarkdownEditorStyle {
        var style = MarkdownEditorStyle.notebook
        style.titleFont = Typeface.display(18)
        style.heading2Font = Typeface.display(15)
        style.padding = NSEdgeInsets(top: 14, left: 22, bottom: 24, right: 14)
        style.foldGlyphOffset = 16
        style.figureMaxHeight = 160
        return style
    }
}
