import CoddNotes
import CoddPreferences
import Foundation
import Observation

/// The app's side of the notebook (M4 I1a): owns the CoddNotes `NotesLibrary` (notes at
/// `<dataRoot>/notes`, USER DATA; the index and the burned-in annotated images in
/// `<dataRoot>/cache/`, DERIVED), opens it off the main actor after the preferences load, consumes its `changes` stream (the one consumer) and keeps
/// what the NOTES area and the dump show as observable state: availability, counts, the selected
/// list and its rows, the search, the selected note's facts, the last paste.
///
/// A failed open never blocks sessions: the area shows `// 筆記資料夾無法使用：<reason>` and every
/// other part of CODD runs as before. The editor itself is `NoteEditorController`; this service
/// is its storage and the library's `OpenNoteCoordinator` (an AI write saves a dirty editor first).
@MainActor @Observable
final class NotesService {
    enum Availability: Equatable, Sendable {
        /// Not opened yet (the preferences are still loading).
        case closed
        case loading
        case ready
        /// The folder or the index cannot be used (繁體中文 reason).
        case unavailable(String)

        var isReady: Bool { self == .ready }

        /// The dump's `available` / `reason`.
        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    struct SearchState: Equatable, Sendable {
        var query: String
        var hits: [NoteSearchHit]
        var ms: Double
    }

    /// D9: the last pasted image (the dump's `lastPaste`).
    struct PasteResult: Equatable, Sendable {
        var asset: String
        var resized: Bool
        var bytes: Int
        var reused: Bool
    }

    /// D13: the last quick note / new note started (the dump's `quickNote`): nil id until created.
    struct QuickNote: Equatable, Sendable {
        var id: NoteID?
        var kind: NoteKind
    }

    /// The selected note's facts for the chrome and the info panel (the editor reads the body
    /// itself, so a save never reloads the text under the caret).
    struct Selected: Equatable, Sendable {
        var summary: NoteSummary
        var document: NoteDocument
        var activity: [NoteActivityEvent]
        var history: [NoteSnapshotInfo]
        var assets: [AssetInfo]
    }

    // MARK: Configuration

    @ObservationIgnored let notesRoot: URL
    /// DERIVED data: `<dataRoot>/cache` (prepared at open, see ``prepareCache(_:removingLegacyIndex:log:)``).
    @ObservationIgnored let cacheFolder: URL
    /// `<cacheFolder>/notes-index.sqlite`.
    @ObservationIgnored let indexURL: URL
    /// `<cacheFolder>/annotated`: the burned-in copies the AI text and ImageAnnotate's preview name.
    @ObservationIgnored let annotatedFolder: URL
    /// The index an M4 build kept next to `notes/`, removed at open (nil: nothing to remove).
    @ObservationIgnored private let legacyIndexURL: URL?
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored let timeZone: TimeZone
    @ObservationIgnored let trash: AppTrash
    @ObservationIgnored private let preferences: PreferencesService
    @ObservationIgnored private let log: @Sendable (String) -> Void
    @ObservationIgnored private(set) var library: NotesLibrary?

    // MARK: Observable state

    private(set) var availability: Availability = .closed
    private(set) var openReport: NotesOpenReport?
    private(set) var counts = NotesCounts()
    private(set) var list: SmartList = .inbox
    private(set) var sort: NoteSort = .updated
    private(set) var rows: [NoteSummary] = []
    /// The search field's text (applied after the debounce); empty = the list.
    private(set) var searchText = ""
    private(set) var search: SearchState?
    private(set) var selectedID: NoteID?
    private(set) var selected: Selected?
    private(set) var lastPaste: PasteResult?
    private(set) var quickNote: QuickNote?
    /// Active notes linked to each CODD session (lowercase id → count): `SessionVM.notesCount`.
    private(set) var linkedSessionCounts: [String: Int] = [:]
    /// Every active note, newest update first (⌘K NOTES, I1b; the palette ranks them itself).
    private(set) var activeNotes: [NoteSummary] = []
    /// The tags of active notes, most used first (the tag editor's suggestions).
    private(set) var knownTags: [String] = []
    /// External changes seen since open (`NotesLibrary.externalEventCount`).
    private(set) var externalEvents = 0
    /// Bumped by every refresh (tests, the dump loop).
    private(set) var revision = 0
    /// The last `rebuildIndex` (`-codd-notes-rebuild`, Settings › 進階 › 重建筆記索引).
    private(set) var lastRebuild: NotesOpenReport?
    /// A rebuild runs (Settings' `[重建]` is disabled meanwhile, `重建中…`).
    private(set) var rebuilding = false

    // MARK: Wiring

    /// A note changed on disk by another program (the editor reloads or shows its banner).
    @ObservationIgnored var onExternalChange: ((NoteID) -> Void)?
    /// The editor's flush for an AI write (D20 / C1 `OpenNoteCoordinator`).
    @ObservationIgnored var flushEditor: ((NoteID) async -> Void)?
    /// An AI write landed (CODD's own write: no watcher event, so the open editor hears it here).
    @ObservationIgnored var onAIWrite: ((NoteDocument) -> Void)?

    /// How many rows a list loads at most (the end comment says when more exist).
    static let listLimit = 500
    /// D6 / I1a: the search runs this long after the last keystroke.
    @ObservationIgnored var searchDebounce: Duration = .milliseconds(150)

    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    /// How many searches actually ran (tests check the debounce).
    @ObservationIgnored private(set) var searchRuns = 0

    /// - Parameters:
    ///   - notesRoot: `<dataRoot>/notes` (mock mode: a temporary folder, D35).
    ///   - cacheFolder: `<dataRoot>/cache` (DERIVED): the index and the annotated copies live in it.
    ///   - legacyIndexURL: `<dataRoot>/notes-index.sqlite`, the M4 index location, removed at open.
    ///   - clock: `Date` or DEBUG `-codd-now`.
    init(notesRoot: URL, cacheFolder: URL, legacyIndexURL: URL? = nil, preferences: PreferencesService, trash: AppTrash,
         clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
         log: @escaping @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.notesRoot = notesRoot
        self.cacheFolder = cacheFolder
        indexURL = cacheFolder.appendingPathComponent(Self.indexFileName, isDirectory: false)
        annotatedFolder = cacheFolder.appendingPathComponent("annotated", isDirectory: true)
        self.legacyIndexURL = legacyIndexURL
        self.preferences = preferences
        self.trash = trash
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    static let indexFileName = "notes-index.sqlite"

    /// A data root's `notes/` (USER DATA), `cache/` (DERIVED) and the M4 index next to `notes/`.
    static func locations(dataRoot: CoddDataRoot) -> (notes: URL, cache: URL, legacyIndex: URL) {
        (dataRoot.url.appendingPathComponent("notes", isDirectory: true), dataRoot.cacheURL,
         dataRoot.url.appendingPathComponent(indexFileName, isDirectory: false))
    }

    /// The DERIVED folder (user decision 2026-10-18): created 0700 and excluded from Time Machine
    /// (like `sessions/`); a leftover M4 index next to `notes/` (with its `-wal` / `-shm`) is
    /// removed, the library rebuilds the index in the cache folder. Blocking file I/O: call it off
    /// the main actor. A failure here is reported by the index open that follows. It never touches
    /// `cache/VERSION`: the M5 data preflight (D14) writes it before this runs and wipes the
    /// folder's contents when it names another cache layout.
    nonisolated static func prepareCache(_ folder: URL, removingLegacyIndex legacy: URL?, log: @Sendable (String) -> Void) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        guard let legacy else { return }
        var removed: [String] = []
        for suffix in ["", "-wal", "-shm"] {
            let path = legacy.path + suffix
            // CODD's own derived files only: never a folder that happens to have the name.
            guard let type = (try? manager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
                  type == .typeRegular || type == .typeSymbolicLink else { continue }
            if (try? manager.removeItem(atPath: path)) != nil { removed.append(legacy.lastPathComponent + suffix) }
        }
        if !removed.isEmpty { log("notes legacy-index removed files=\(removed.joined(separator: ",")) (rebuilt in cache/)") }
    }

    /// The retention policy and new-note access from Settings › 清理 / 筆記本 (D29, D20).
    static func policy(_ value: CoddPreferences) -> (RetentionPolicy, NoteAIAccess) {
        let c = value.cleanup
        let policy = RetentionPolicy(staleDays: c.notesStaleDays, archiveDays: c.notesArchiveDays, scratchArchiveDays: c.scratchArchiveDays,
                                     trashPurgeDays: c.trashPurgeDays, tombstoneDays: c.tombstoneDays, exempt: c.exempt)
        let access = NoteAIAccess(rawValue: value.notebook.defaultAIAccess.rawValue) ?? .read
        return (policy, access)
    }

    // MARK: Lifecycle

    /// Opens the library (once; later calls wait for the same open). The index is built or
    /// brought up to date inside the actor, never on the main actor.
    func open() async {
        if let openTask { return await openTask.value }
        guard availability == .closed else { return }
        let task = Task { [weak self] () -> Void in await self?.performOpen() }
        openTask = task
        await task.value
    }

    private func performOpen() async {
        availability = .loading
        let (cache, legacy, log) = (cacheFolder, legacyIndexURL, log)
        await Task.detached(priority: .userInitiated) {
            NotesService.prepareCache(cache, removingLegacyIndex: legacy, log: log)
        }.value
        let (policy, access) = Self.policy(preferences.preferences)
        let lib = NotesLibrary(root: notesRoot, indexURL: indexURL, annotatedFolder: annotatedFolder, policy: policy,
                               defaultAccess: access, clock: clock, trash: trash.function, log: log, timeZone: timeZone)
        library = lib
        await lib.setOpenNoteCoordinator(EditorCoordinator(service: self))
        do {
            let report = try await lib.open()
            openReport = report
            availability = .ready
            log("notes ready count=\(report.count) rebuilt=\(report.rebuilt) reason=\(report.reason ?? "-") buildMs=\(Int(report.buildMs))")
            consume(lib)
            await refreshNow()
        } catch {
            let reason = error.errorDescription ?? "\(error)"
            availability = .unavailable(reason)
            log("notes unavailable reason=\(reason)")
        }
    }

    /// Settings changed (D29 policy, D20 default access).
    func apply(preferences value: CoddPreferences) {
        guard let library else { return }
        let (policy, access) = Self.policy(value)
        Task { await library.setPolicy(policy, defaultAccess: access) }
    }

    /// Writes state.json and ends the watcher (quit).
    func close() async {
        changesTask?.cancel()
        changesTask = nil
        await library?.close()
    }

    /// The one consumer of `changes` (C1: single consumer, newest wins per id).
    private func consume(_ lib: NotesLibrary) {
        changesTask?.cancel()
        changesTask = Task { [weak self] in
            for await change in lib.changes {
                guard let self else { return }
                self.handle(change)
            }
        }
    }

    private func handle(_ change: NotesChange) {
        switch change {
        case .external(let ids):
            for id in ids { onExternalChange?(id) }
        case .unavailable(let reason):
            availability = .unavailable(reason)
            log("notes unavailable reason=\(reason)")
        case .removed(let ids):
            if let selectedID, ids.contains(selectedID) { selected = nil }
        case .changed, .indexRebuilt, .activity:
            break
        }
        scheduleRefresh()
    }

    // MARK: Lists

    /// Coalesces bursts of changes (a save yields `.changed` and an activity right after).
    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            self?.refreshTask = nil
            await self?.refreshNow()
        }
    }

    /// Counts, the shown list, the linked-session counts, the search and the selected note.
    func refreshNow() async {
        guard let library, availability.isReady else { return }
        counts = (try? await library.counts()) ?? counts
        let shown = (try? await library.list(list, sort: sort, limit: Self.listLimit)) ?? []
        rows = shown
        let active: [NoteSummary]
        if list == .inbox, shown.count < Self.listLimit {
            active = shown
        } else {
            active = (try? await library.list(.inbox, sort: .updated, limit: 100_000)) ?? []
        }
        var linked: [String: Int] = [:]
        var tagUses: [String: Int] = [:]
        for summary in active {
            for session in Set(summary.metadata.links.sessions.map { $0.lowercased() }) { linked[session, default: 0] += 1 }
            for tag in Set(summary.metadata.tags) { tagUses[tag, default: 0] += 1 }
        }
        if linked != linkedSessionCounts { linkedSessionCounts = linked }
        let newest = active.sorted { $0.metadata.updated > $1.metadata.updated }
        if newest != activeNotes { activeNotes = newest }
        let tags = tagUses.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        if tags != knownTags { knownTags = tags }
        if !searchText.isEmpty { await runSearch(searchText) }
        await reloadSelected()
        externalEvents = await library.externalEventCount
        revision += 1
    }

    func selectList(_ next: SmartList) {
        guard next != list || !searchText.isEmpty else { return }
        list = next
        if !searchText.isEmpty { setSearchText("", debounce: false) }
        Task { await refreshNow() }
    }

    func setSort(_ next: NoteSort) {
        guard next != sort else { return }
        sort = next
        Task { await refreshNow() }
    }

    /// The note the chrome and the info panel describe (the editor loads it itself).
    func select(_ id: NoteID?) {
        guard id != selectedID else { return }
        selectedID = id
        selected = nil
        Task { await reloadSelected() }
    }

    private func reloadSelected() async {
        guard let library, let id = selectedID else { return }
        guard let summary = try? await library.summary(id), let document = try? await library.document(id) else {
            if selectedID == id { selected = nil }
            return
        }
        let activity = await library.activity(of: id, limit: 50)
        let history = (try? await library.history(of: id)) ?? []
        let assets = (try? await library.assets(of: id)) ?? []
        guard selectedID == id else { return }
        let next = Selected(summary: summary, document: document, activity: activity, history: history, assets: assets)
        if next != selected { selected = next }
    }

    // MARK: Search (D6)

    /// The lists' search field (never called while it has marked text: C7 holds those back).
    /// Runs `searchDebounce` after the last call; an empty text returns to the list.
    func setSearchText(_ text: String, debounce: Bool = true) {
        searchText = text
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            search = nil
            return
        }
        let delay = debounce ? searchDebounce : .zero
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            await self.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard let library, availability.isReady else { return }
        let started = ContinuousClock.now
        let hits = (try? await library.search(NoteQuery(text: text, limit: Self.listLimit))) ?? []
        let ms = Self.milliseconds(ContinuousClock.now - started)
        searchRuns += 1
        guard text == searchText else { return }
        search = SearchState(query: text, hits: hits, ms: ms)
        log(String(format: "notes search terms=%d hits=%d ms=%.2f", text.split(separator: " ").count, hits.count, ms))
    }

    // MARK: Notes (the editor's storage)

    func document(_ id: NoteID) async throws -> NoteDocument {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.document(id)
    }

    /// - Parameter select: the new note becomes the selection (and a pending QUICK NOTE's note);
    ///   false for a note made on the side (an editor's copy of text it could not save).
    func create(_ note: NewNote, select: Bool = true) async throws -> NoteDocument {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        let document = try await library.create(note)
        log("notes created id=\(document.metadata.id.rawValue) kind=\(document.metadata.kind.rawValue) file=\(document.fileURL.lastPathComponent)")
        guard select else {
            scheduleRefresh()
            return document
        }
        if quickNote != nil, quickNote?.id == nil, quickNote?.kind == document.metadata.kind {
            quickNote?.id = document.metadata.id
        }
        selectedID = document.metadata.id
        scheduleRefresh()
        return document
    }

    func save(_ id: NoteID, body: String, basedOn hash: String?) async throws -> SaveOutcome {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.save(id, body: body, basedOn: hash)
    }

    func saveAsset(_ data: Data, typeHint: String?, for id: NoteID, resizeLongEdge: Int?, keepOriginal: Bool) async throws -> AssetRef {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        let ref = try await library.saveAsset(data, typeHint: typeHint, for: id, resizeLongEdge: resizeLongEdge, keepOriginal: keepOriginal)
        lastPaste = PasteResult(asset: ref.relativePath, resized: ref.resized, bytes: ref.bytes, reused: ref.reused)
        log("notes paste asset=\(ref.relativePath) resized=\(ref.resized) bytes=\(ref.bytes) w=\(Int(ref.pixelSize.width)) h=\(Int(ref.pixelSize.height))")
        scheduleRefresh()
        return ref
    }

    func snapshot(_ id: NoteID, reason: String) async {
        _ = try? await library?.snapshot(id, reason: reason)
    }

    /// D8: the editor's text the D7 banner held back, as a HISTORY version (`未儲存的編輯`).
    func snapshotUnsaved(_ id: NoteID, body: String) async -> Bool {
        do {
            _ = try await library?.snapshot(id, body: body, reason: "unsaved")
            log("notes unsaved kept id=\(id.rawValue) chars=\(body.count)")
            return true
        } catch {
            log("notes unsaved snapshot failed id=\(id.rawValue): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Metadata and lifecycle (I1b)

    /// A frontmatter change (AI access, scope, kind, tags, links, pin). Throws C1's errors
    /// (`unparsableFrontmatter`, `trashed`), whose 繁體中文 text the app shows as a toast.
    @discardableResult
    func update(_ id: NoteID, _ change: MetadataChange) async throws -> NoteDocument {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        let document = try await library.update(id, change)
        log("notes update id=\(id.rawValue) change=\(Self.changeName(change))")
        scheduleRefresh()
        return document
    }

    /// The dump / log name of a change (never a tag or a path).
    static func changeName(_ change: MetadataChange) -> String {
        switch change {
        case .kind(let kind): "kind=\(kind.rawValue)"
        case .tags(let tags): "tags=\(tags.count)"
        case .addTag: "addTag"
        case .removeTag: "removeTag"
        case .linkSession: "linkSession"
        case .unlinkSession: "unlinkSession"
        case .linkProject: "linkProject"
        case .unlinkProject: "unlinkProject"
        case .ai(let access): "ai=\(access.rawValue)"
        case .scope(let scope, _): "scope=\(scope.rawValue)"
        case .pinned(let pinned): "pinned=\(pinned)"
        case .markSent: "markSent"
        case .condensedInto: "condensedInto"
        }
    }

    func archive(_ id: NoteID) async throws {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        try await library.archive([id], by: .user)
        scheduleRefresh()
    }

    func unarchive(_ id: NoteID) async throws {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        try await library.unarchive([id])
        scheduleRefresh()
    }

    /// CODD's TRASH (`.codd/trash/`, restorable; the purge after `trashPurgeDays` is I4a's).
    func trash(_ id: NoteID) async throws {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        try await library.trash([id])
        if selectedID == id { selected = nil }
        scheduleRefresh()
    }

    func restore(_ id: NoteID) async throws {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        try await library.restore([id])
        scheduleRefresh()
    }

    // MARK: History, AI text, images (I1b)

    func history(of id: NoteID) async throws -> [NoteSnapshotInfo] {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.history(of: id)
    }

    func snapshotText(_ snapshot: NoteSnapshotInfo, of id: NoteID) async throws -> String {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.snapshotText(snapshot, of: id)
    }

    /// `還原這一版` (D8): C1 snapshots the current file first, then replaces the body.
    func restoreSnapshot(_ snapshot: NoteSnapshotInfo, of id: NoteID) async throws -> NoteDocument {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        let document = try await library.restoreSnapshot(snapshot, of: id)
        log("notes restore-snapshot id=\(id.rawValue) snapshot=\(snapshot.id)")
        scheduleRefresh()
        return document
    }

    /// D10: the burned-in copy of an image in `annotatedFolder` (written inside the actor, off the
    /// main actor); nil when the image has no annotations.
    func annotatedImage(for id: NoteID, image relativePath: String) async throws -> URL? {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.annotatedImage(for: id, image: relativePath)
    }

    /// Post-M4 (review attachments-6): a composer send or resend names an annotated copy that is
    /// gone from `annotatedFolder` (DERIVED): the notes the text references (`codd://note/<id>`, the
    /// AI text's header; at most 20) render theirs again, inside the actor. Opens the notebook when
    /// it is not open yet.
    func restoreAnnotatedCopies(in text: String) async {
        let ids = NoteReferences.parse(text, limit: 20)
        guard !ids.isEmpty else { return }
        await open()
        guard let library else { return }
        await library.renderAnnotatedCopies(of: ids)
        log("notes annotated-cache restore notes=\(ids.count)")
    }

    /// 插入全文 / 送出 (D14, §3.7): the note's AI text from the start, at most `maxChars` characters
    /// (`truncated` says more follows). Access rules are not applied: the user may send any note.
    func aiText(_ id: NoteID, maxChars: Int) async throws -> NoteAIText.Rendered {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.aiText(id, offset: 0, maxChars: maxChars)
    }

    /// One note's list facts (kind, tags, assets), nil when the index does not have it.
    func summary(_ id: NoteID) async throws -> NoteSummary? {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.summary(id)
    }

    /// The drawer's cards (I2b): the active notes linked to a CODD session.
    func summaries(linkedToSession id: SessionID) async throws -> [NoteSummary] {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.summaries(linkedToSession: id.lowercased())
    }

    /// A note's images and their copies (the drawer's thumbnails).
    func assets(of id: NoteID) async throws -> [AssetInfo] {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.assets(of: id)
    }

    /// A note's newest AI activity (the drawer's `AI 讀取 10:12`).
    func activity(of id: NoteID, limit: Int) async -> [NoteActivityEvent] {
        await library?.activity(of: id, limit: limit) ?? []
    }

    /// COPY REF form 4 (§3.7): the body without the frontmatter, image links absolute.
    func copyMarkdown(_ id: NoteID) async throws -> String {
        guard let library else { throw NotesError.unavailable("筆記本尚未開啟") }
        return try await library.copyMarkdown(id)
    }

    /// D29: opening a note for ≥ 3 s is user activity.
    func markOpened(_ id: NoteID) async {
        await library?.markOpened(id, at: clock())
    }

    /// D13: what the dump's `quickNote` reports (the editor calls it when it starts a draft).
    func noteStarted(kind: NoteKind) {
        quickNote = QuickNote(id: nil, kind: kind)
        draftsStarted += 1
    }

    /// Drafts started this run (the shortcut matrix proves a refused ⌘⇧N starts none).
    @ObservationIgnored private(set) var draftsStarted = 0

    /// Settings › 進階 › 重建筆記索引 / `-codd-notes-rebuild`.
    @discardableResult
    func rebuildIndex() async -> NotesOpenReport? {
        guard let library, availability.isReady, !rebuilding else { return nil }
        rebuilding = true
        defer { rebuilding = false }
        do {
            let report = try await library.rebuildIndex()
            lastRebuild = report
            log("notes rebuild count=\(report.count) ms=\(Int(report.buildMs))")
            await refreshNow()
            return report
        } catch {
            log("notes rebuild failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The live CODD sessions (D29 exemptions) and their titles (AI text `links:`).
    func setSessions(live: Set<String>, titles: [String: String]) {
        guard let library else { return }
        Task {
            await library.setLiveSessions(live)
            await library.setSessionTitles(titles)
        }
    }

    // MARK: Helpers

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The flush an AI write waits for (C1 awaits it before appending to a note).
    func flushForAI(_ id: NoteID) async {
        await flushEditor?(id)
    }

    func aiWrote(_ document: NoteDocument) {
        onAIWrite?(document)
    }
}

/// C1's `OpenNoteCoordinator`: an AI append / write first saves the editor's pending text (the
/// app waits up to 2 s for a composition to end, `NoteEditorController.flushForAI`).
private struct EditorCoordinator: OpenNoteCoordinator {
    weak var service: NotesService?

    func flushPendingEdits(of id: NoteID) async {
        await service?.flushForAI(id)
    }

    func didWriteFromAI(_ document: NoteDocument) async {
        await service?.aiWrote(document)
    }
}
