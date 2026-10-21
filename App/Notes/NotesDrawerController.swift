import AppKit
import CoddNotebookUI
import CoddNotes
import CoddUI

/// The session pane's `✎ NOTES` drawer (M4 I2b, Split artboard `.sp-pad`): C7's `NotesDrawerView`
/// fed with the active notes linked to the session on screen. Each card shows the note's first two
/// images (its assets, the ones the body shows first; decoded small, off the main actor), its
/// first three tasks with the `done/total` progress of all of them, its tags, `更新 10:05` and
/// `AI 讀取 10:12`; the note the session's composer draft references gets the amber border. The model follows the notebook's revision while the
/// drawer shows (an edit, an AI read, a new link) and costs nothing while it is closed. The files
/// section (`AI 改過的檔案`, I3) comes from the file editor's touches and a read-only git status.
///
/// A card's title opens the note in the drawer's own editor (``editor``, the Notebook's rules:
/// autosave 1 s after the last committed change and never while composing, the D7 banner, image
/// paste into the note's assets). The editor is saved and emptied when the user goes back to the
/// cards, the drawer closes or another session shows (each session remembers its note for the
/// run); the app also flushes it at quit. The Notebook's editor and this one take each other's
/// saves (``NoteEditors``).
@MainActor
final class NotesDrawerController {
    /// What a card is built from (the pure part, unit-tested).
    struct NoteFacts: Sendable {
        var summary: NoteSummary
        var body: String
        /// The newest AI read of the note (read / expand / url).
        var aiRead: Date?
        /// The first two images of the note's assets (the ones the body shows first) with their
        /// upright pixel sizes.
        var images: [(path: String, size: CGSize)]
        /// The first image line's alt text (`截圖 2026-10-15 09:32 · iPhone SE`).
        var caption: String?
    }

    let view: NotesDrawerView
    /// The drawer's note editor (its document view fills the drawer while a note is open in it).
    let editor: NoteEditorController
    private let notes: NotesService
    private let store: any SessionStore
    /// The note open in the drawer's editor (nil: the cards).
    private(set) var editingID: NoteID?
    /// The note each session's drawer had open (in memory for the run): it opens again when the
    /// session shows again.
    private(set) var editingBySession: [SessionID: NoteID] = [:]
    /// The editor's save state and title while a note is open.
    private var editorLoop: ObservationLoop?
    /// The last editor load or leave (tests wait for it).
    private(set) var editorTask: Task<Void, Never>?
    /// The session's composer draft references (the `.ref` card).
    var draftReferences: (SessionID) -> [String] = { _ in [] }
    /// I3: the `AI 改過的檔案` section of the session (its touched files, then git's other
    /// changes of its cwd); called only while the drawer shows.
    var filesSection: ((SessionID) async -> NotesDrawerFilesSection?)?
    /// Observed while the drawer shows: the files section follows new AI touches.
    var filesRevision: () -> Int = { 0 }
    /// Where the editor's messages go while its document is not on screen: back to the cards, the
    /// drawer closed or covered by a page, another session (a leave's `未儲存的編輯已存到 HISTORY`, a
    /// failed save). The app shows them in the main window; without it they stay in the document.
    var onToastElsewhere: ((String) -> Void)?
    private(set) var sessionID: SessionID?
    /// The session whose cards the view holds (kept while the drawer is hidden).
    private var shownSessionID: SessionID?
    private var loop: ObservationLoop?
    private var buildTask: Task<Void, Never>?
    private var generation = 0
    /// Bumped by `show` only (a rebuild in between must not stop the loop from starting).
    private var showGeneration = 0
    /// Bumped when `show` moves to another session or none (the editor follows the newest).
    private var sessionGeneration = 0
    /// Decoded thumbnails by file path + modification time.
    private var thumbnails: [String: NSImage] = [:]
    /// Builds finished (tests wait for it).
    private(set) var builds = 0

    /// Cards shown at most (a long list of linked notes scrolls in the notebook, not here).
    static let maxCards = 20
    /// The thumbnails' decode size (2× the 118 pt landscape box).
    static let thumbnailLongEdge = 240

    /// - Parameter preferences: the D9 image settings of a paste into the drawer's editor.
    init(notes: NotesService, store: any SessionStore, preferences: PreferencesService = .inMemory()) {
        self.notes = notes
        self.store = store
        editor = NoteEditorController(service: notes, preferences: preferences, placement: .drawer)
        view = NotesDrawerView(model: NotesDrawerModel(cards: [], notesPath: PathFormat.abbreviateHome(notes.notesRoot.path)))
        view.documentView = editor.documentView
        view.onEditNote = { [weak self] raw in
            guard let id = NoteID(rawValue: raw) else { return }
            self?.edit(id)
        }
        view.onBack = { [weak self] in self?.closeEditor() }
        view.onOpenInNotebook = { [weak self] raw in self?.openInNotebook(raw) }
        editor.onToast = { [weak self] text in self?.showEditorToast(text) }
        // A `codd://note/<id>` link in the note opens that note here; an image's annotations are
        // edited in the Notebook (ImageAnnotate needs the whole window).
        editor.onOpenNote = { [weak self] id in self?.edit(id) }
        editor.onEditAnnotations = { [weak self] _ in
            guard let id = self?.editingID else { return }
            self?.openInNotebook(id.rawValue)
        }
    }

    /// Shows the drawer for `id` (nil: hidden; the loop stops). Another session (or none) saves
    /// and empties the editor first; a session that had a note open gets it back.
    func show(_ id: SessionID?) {
        guard id != sessionID || (id != nil && loop == nil) else { return }
        let sessionChanged = id != sessionID
        if let id, id != shownSessionID {
            // Another session's cards never show under this one while its own load.
            shownSessionID = id
            view.update(NotesDrawerModel(cards: [], notesPath: PathFormat.abbreviateHome(notes.notesRoot.path),
                                         actionsDisabledReason: Self.actionsDisabledReason(NoteSending.session(id, in: store)),
                                         editing: view.model.editing))
        }
        sessionID = id
        loop?.cancel()
        loop = nil
        buildTask?.cancel()
        generation += 1
        showGeneration += 1
        let token = showGeneration
        if sessionChanged {
            // The editor's state is read outside the caller's observation too (the newest session
            // change wins; a repeated show of the same session does not cancel it).
            sessionGeneration += 1
            let change = sessionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == change else { return }
                self.sessionDidChange(to: self.sessionID)
            }
        }
        guard let id else { return }
        // Outside the caller's observation (the pane's render loop must not follow the notebook).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == id, self.showGeneration == token, self.loop == nil else { return }
            let notes = self.notes
            let store = self.store
            let filesRevision = self.filesRevision
            self.loop = ObservationLoop(track: { () -> String in
                let session = NoteSending.session(id, in: store)
                return "\(notes.revision)|\(notes.availability.isReady)|\(session?.title ?? "")|\(session?.kind == .claude)|"
                    + "\(session?.external ?? true)|\(filesRevision())"
            }, apply: { [weak self] _ in self?.rebuild() })
        }
    }

    /// Builds the model again (a send changed the draft, the drawer opened).
    func rebuild() {
        guard let id = sessionID else { return }
        buildTask?.cancel()
        generation += 1
        let token = generation
        buildTask = Task { [weak self] in
            guard let self else { return }
            let facts = await self.load(id)
            guard !Task.isCancelled, token == self.generation else { return }
            await self.decodeThumbnails(facts)
            let files = await self.filesSection?(id)
            guard !Task.isCancelled, token == self.generation else { return }
            self.view.update(self.model(for: id, facts: facts, files: files))
            self.builds += 1
        }
    }

    // MARK: Editing in place

    /// Another session (or none) is shown: the note it had open comes back, else the editor is
    /// saved and emptied.
    private func sessionDidChange(to id: SessionID?) {
        if let id, let remembered = editingBySession[id] {
            openEditor(remembered, focus: false)
        } else {
            leaveEditor()
        }
    }

    /// A card's title (or a note link in the drawer's editor): `id` opens in the drawer's editor
    /// with the keyboard in it (the note shown before is saved first).
    func edit(_ id: NoteID) {
        guard let session = sessionID else { return }
        editingBySession[session] = id
        openEditor(id, focus: true)
    }

    /// `‹ LINKED NOTES`: the editor is saved and emptied, the cards show again.
    func closeEditor() {
        if let session = sessionID { editingBySession[session] = nil }
        leaveEditor()
        rebuild()
    }

    /// The editor's pending text (quit; bounded by the quit's own 2 s).
    func flushForLeaving() async {
        await editor.flushForLeaving()
    }

    private func openEditor(_ id: NoteID, focus: Bool) {
        editingID = id
        startEditorLoop()
        applyEditing()
        let editor = self.editor
        let previous = editorTask
        editorTask = Task { [weak self] in
            await previous?.value
            guard self?.editingID == id else { return }
            let refused = editor.leavesRefused
            await editor.show(id, placeholder: "")
            guard let self, self.editingID == id else { return }
            if editor.leavesRefused > refused {
                // The note shown before kept its unsaved text on screen (it could be written
                // nowhere): the drawer stays on it.
                self.stayOnRefusedNote()
                return
            }
            guard editor.noteID == id else { return }
            self.applyEditing()
            if focus, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor { editor.focus() }
        }
    }

    /// Saves and empties the editor (back to the cards, the drawer hidden, another session).
    private func leaveEditor() {
        let wasEditing = editingID != nil
        editingID = nil
        editorLoop?.cancel()
        editorLoop = nil
        if wasEditing { applyEditing() }
        guard wasEditing || editor.hasContent else { return }
        let editor = self.editor
        let previous = editorTask
        editorTask = Task { [weak self] in
            await previous?.value
            // A note opened again meanwhile keeps the editor.
            guard self?.editingID == nil else { return }
            let refused = editor.leavesRefused
            await editor.show(nil, placeholder: "")
            guard editor.leavesRefused > refused, self?.editingID == nil else { return }
            self?.stayOnRefusedNote()
        }
    }

    /// The editor refused to leave its note: its unsaved text could be written nowhere (not the
    /// note, not HISTORY, not a new note), so the note stays open in the drawer with the text.
    private func stayOnRefusedNote() {
        guard let kept = editor.noteID else { return }
        editingID = kept
        if let session = sessionID { editingBySession[session] = kept }
        startEditorLoop()
        applyEditing()
    }

    /// The editor's toast: in its document while that shows, else where the app puts it (the
    /// document is hidden under the cards, a closed drawer or a page, review data-1).
    private func showEditorToast(_ text: String) {
        let document = editor.documentView
        let onScreen = editingID != nil && document.window != nil && !document.isHiddenOrHasHiddenAncestor
        if !onScreen, let elsewhere = onToastElsewhere {
            elsewhere(text)
        } else {
            document.showToast(text)
        }
    }

    /// `[筆記本 ↗]`: the pending text is written first, so the Notebook opens what was typed here.
    private func openInNotebook(_ raw: String) {
        let editor = self.editor
        Task { [weak self] in
            await editor.flush()
            self?.view.onOpenNote?(raw)
        }
    }

    /// The bar's and the action row's model follows the editor (its save state, the note's title)
    /// without loading the cards again.
    private func startEditorLoop() {
        guard editorLoop == nil else { return }
        let editor = self.editor
        editorLoop = ObservationLoop(track: { () -> String in
            "\(editor.noteID?.rawValue ?? "")|\(editor.saveState)|\(editor.document?.metadata.title ?? "")"
        }, apply: { [weak self] _ in self?.applyEditing() })
    }

    private func applyEditing() {
        var model = view.model
        model.editing = editingModel()
        view.update(model)
    }

    /// The drawer's editing part: the note's title (the editor's document, else its card) and
    /// the save state once the editor shows the note.
    func editingModel(cards: [NotesDrawerCard]? = nil) -> NotesDrawerEditing? {
        guard let id = editingID else { return nil }
        let shown = editor.noteID == id
        let cardTitle = (cards ?? view.model.cards).first { $0.id == id.rawValue }?.title
        let title = (shown ? editor.document?.metadata.title : nil).flatMap { $0.isEmpty ? nil : $0 } ?? cardTitle ?? "未命名筆記"
        let p = NotebookPresenter(now: notes.clock(), timeZone: notes.timeZone, store: store, projects: [:])
        return NotesDrawerEditing(id: id.rawValue, title: title, save: shown ? p.saveState(editor.saveState) : nil)
    }

    // MARK: Data

    private func load(_ id: SessionID) async -> [NoteFacts] {
        guard notes.availability.isReady, let summaries = try? await notes.summaries(linkedToSession: id) else { return [] }
        var out: [NoteFacts] = []
        for summary in summaries.sorted(by: { $0.metadata.updated > $1.metadata.updated }).prefix(Self.maxCards) {
            guard let document = try? await notes.document(summary.id) else { continue }
            let events = await notes.activity(of: summary.id, limit: 20)
            let read = events.first { ["read", "expand", "url"].contains($0.action) }?.at
            let assets = ((try? await notes.assets(of: summary.id)) ?? []).filter { !$0.isOriginalCopy }
                .enumerated().sorted { ($0.element.referenced ? 0 : 1, $0.offset) < ($1.element.referenced ? 0 : 1, $1.offset) }
                .map(\.element).prefix(2)
            let caption = FencedBlocks.imageLines(in: document.body).first?.alt
            out.append(NoteFacts(summary: summary, body: document.body, aiRead: read,
                                 images: assets.map { (path: $0.url.path, size: $0.pixelSize) }, caption: caption))
        }
        return out
    }

    private func decodeThumbnails(_ facts: [NoteFacts]) async {
        for path in facts.flatMap({ $0.images.map(\.path) }) where thumbnails[Self.thumbnailKey(path)] == nil {
            guard let image = await NoteImageCache.thumbnail(at: URL(fileURLWithPath: path), longEdge: Self.thumbnailLongEdge) else { continue }
            thumbnails[Self.thumbnailKey(path)] = NSImage(cgImage: image, size: .zero)
        }
    }

    /// A thumbnail's cache key: its path and modification time (an edited image decodes again).
    nonisolated static func thumbnailKey(_ path: String) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(modified)"
    }

    // MARK: Model (pure)

    func model(for id: SessionID, facts: [NoteFacts], files: NotesDrawerFilesSection? = nil) -> NotesDrawerModel {
        let p = NotebookPresenter(now: notes.clock(), timeZone: notes.timeZone, store: store, projects: [:])
        let referenced = Set(draftReferences(id))
        let cards = facts.map { fact in
            Self.card(fact, presenter: p, referenced: referenced.contains(fact.summary.id.rawValue),
                      thumbnail: { [thumbnails] path in thumbnails[Self.thumbnailKey(path)] })
        }
        return NotesDrawerModel(cards: cards, files: files, notesPath: PathFormat.abbreviateHome(notes.notesRoot.path),
                                actionsDisabledReason: Self.actionsDisabledReason(NoteSending.session(id, in: store)),
                                editing: editingModel(cards: cards))
    }

    /// Externals and shell sessions take no note (D14); the buttons say why.
    static func actionsDisabledReason(_ session: SessionVM?) -> String? {
        guard let session, session.kind == .claude, !session.external else { return NoteSending.notTargetText }
        return nil
    }

    static func card(_ fact: NoteFacts, presenter p: NotebookPresenter, referenced: Bool,
                     thumbnail: (String) -> NSImage? = { _ in nil }) -> NotesDrawerCard {
        let m = fact.summary.metadata
        let all = tasks(in: fact.body)
        let images = fact.images.map { image -> NotesDrawerImage in
            let landscape = image.size.width > image.size.height
            return NotesDrawerImage(image: thumbnail(image.path), orientation: landscape ? .landscape : .portrait,
                                    caption: landscape ? "橫向" : "直向")
        }
        let caption = fact.caption.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let summaryText = fact.summary.assetCount > 0
            ? "\(fact.summary.assetCount) 張 · \(NotebookPresenter.bytes(fact.summary.assetBytes))" : nil
        return NotesDrawerCard(id: m.id.rawValue, kind: NotebookPresenter.badge(m), title: m.title.isEmpty ? "未命名筆記" : m.title,
                               ai: NotebookPresenter.access(m.ai), images: images, imageCaption: images.isEmpty ? nil : caption,
                               imageSummary: images.isEmpty ? nil : summaryText, tasks: Array(all.prefix(3)),
                               taskProgress: all.isEmpty ? nil : NotesDrawerTaskProgress(done: all.filter(\.done).count, total: all.count),
                               tags: m.tags.map { "#\($0)" }.joined(separator: " "), updated: "更新 \(p.shortStamp(m.updated))",
                               aiRead: fact.aiRead.map { "AI 讀取 \(p.shortStamp($0))" }, isReferenced: referenced)
    }

    /// `- [ ] …` / `- [x] …` (also `*`, `+` and ordered markers, any indent) outside fenced code.
    static func tasks(in body: String) -> [NotesDrawerTask] {
        var out: [NotesDrawerTask] = []
        var fence: String?
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
                continue
            }
            var rest = Substring(line)
            if let first = rest.first, "-*+".contains(first) {
                rest = rest.dropFirst()
            } else if let dot = rest.firstIndex(where: { $0 == "." || $0 == ")" }), dot > rest.startIndex,
                      rest[rest.startIndex..<dot].allSatisfy(\.isNumber) {
                rest = rest[rest.index(after: dot)...]
            } else {
                continue
            }
            guard rest.first == " " else { continue }
            rest = rest.drop { $0 == " " }
            guard rest.count >= 3, rest.first == "[", rest.dropFirst(2).first == "]" else { continue }
            let mark = rest.dropFirst().first
            guard mark == " " || mark == "x" || mark == "X" else { continue }
            let text = rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out.append(NotesDrawerTask(text, done: mark != " "))
        }
        return out
    }
}
