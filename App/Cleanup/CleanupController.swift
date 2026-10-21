import AppKit
import CoddCleanupUI
import CoddNotebookUI
import CoddNotes
import CoddPreferences
import CoddUI
import Observation

/// The Cleanup artboard: C12's page (1368 × 876 at the artboard size) with the app status bar
/// under it, full width.
final class CleanupModeView: FlippedView {
    let page: CleanupPageView
    let statusBar: StatusBarView

    init(page: CleanupPageView, statusBar: StatusBarView) {
        self.page = page
        self.statusBar = statusBar
        super.init(frame: NSRect(x: 0, y: 0, width: 1368, height: 900))
        addSubview(page)
        addSubview(statusBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        statusBar.frame = CGRect(x: 0, y: bounds.height - Metrics.statusBarHeight, width: bounds.width, height: Metrics.statusBarHeight)
        page.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Metrics.statusBarHeight))
    }
}

/// M4 I4a, D31: the Cleanup mode of the NOTES area. Feeds `CleanupPageView` from
/// `RetentionService` (the candidates) and `CondenseRunner` (the CONDENSE card) and routes the
/// page's callbacks: row actions (`保留 30 天`, `封存`, `移到垃圾桶`), the per-tab bulk bar, `交給
/// Claude 濃縮…`, the card's buttons and selects, `← NOTEBOOK` / esc. Mock mode (no retention)
/// draws the Cleanup artboard's sample data (D35); its actions change nothing.
@MainActor @Observable
final class CleanupController {
    @ObservationIgnored let page: CleanupPageView
    @ObservationIgnored let modeView: CleanupModeView
    @ObservationIgnored let retention: RetentionService?
    @ObservationIgnored let condense: CondenseRunner?
    @ObservationIgnored let notes: NotesService
    @ObservationIgnored let preferences: PreferencesService

    // MARK: Wiring (the area and the app set these)

    @ObservationIgnored var presenter: () -> NotebookPresenter
    @ObservationIgnored var resolve: (String) -> String = { $0 }
    @ObservationIgnored var session: (String) -> SessionVM? = { _ in nil }
    @ObservationIgnored var project: (ProjectID) -> ProjectVM? = { _ in nil }
    /// The account select's options (`跟隨全域登入（#3 工作）`, then the cswap accounts).
    @ObservationIgnored var accountOptions: () -> [CondenseAccountOption] = { [CondenseAccountOption(id: "follow", title: "跟隨全域登入")] }
    @ObservationIgnored var accountHint: (String) -> String = { _ in "" }
    /// DEBUG `-codd-condense-account` (wins over the stored choice for this run).
    @ObservationIgnored var accountOverride: String?
    @ObservationIgnored var onBack: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onDumpNeeded: (() -> Void)?

    // MARK: State

    private(set) var tab: CleanupTab = .notes
    private(set) var selection: [CleanupTab: Set<String>] = [:]
    /// The CONDENSE card shows (`交給 Claude 濃縮…` opened it).
    private(set) var condenseOpen = false
    /// Ticks once a second while a condense run goes (`◌ 產生中… 12s`).
    private var ticks = 0
    private(set) var isActive = false
    /// The last row / bulk action (the dump).
    @ObservationIgnored private(set) var lastAction: (kind: String, tab: String, count: Int)?
    @ObservationIgnored private var loop: ObservationLoop?
    /// While the page shows: archived / live sessions changed → fresh candidates.
    @ObservationIgnored private var sessionsLoop: ObservationLoop?
    @ObservationIgnored private var sessionsSignature: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false

    init(retention: RetentionService?, condense: CondenseRunner?, notes: NotesService, preferences: PreferencesService, store: any SessionStore,
         presenter: @escaping () -> NotebookPresenter) {
        self.retention = retention
        self.condense = condense
        self.notes = notes
        self.preferences = preferences
        self.presenter = presenter
        let initial = retention == nil ? CleanupSamples.artboard : Self.emptyModel(preferences.preferences)
        page = CleanupPageView(model: initial)
        modeView = CleanupModeView(page: page, statusBar: StatusBarView(store: store))
        if retention == nil {
            selection = [.notes: CleanupSamples.selectedNotes, .sessions: CleanupSamples.sessions.selected,
                         .files: CleanupSamples.files.selected]
            condenseOpen = true
        }
        wire()
    }

    static func emptyModel(_ prefs: CoddPreferences) -> CleanupPageModel {
        CleanupPageModel(meta: CleanupDigest.scheduleText(prefs.cleanup.digest), counts: [:], tab: .notes, rows: [],
                         policy: CleanupPresenter.policy(prefs), bulkDisabled: CleanupPresenter.bulkDisabled)
    }

    private func wire() {
        page.onBack = { [weak self] in self?.onBack?() }
        page.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        page.onTab = { [weak self] tab in self?.tab = tab }
        page.onSelection = { [weak self] ids in
            guard let self else { return }
            self.selection[self.tab] = ids
        }
        page.onRowAction = { [weak self] id, action in Task { await self?.rowAction(id, action) } }
        page.onBulk = { [weak self] action, ids in Task { await self?.bulk(action, ids) } }
        page.onGenerate = { [weak self] in self?.generate() }
        page.onRegenerate = { [weak self] in self?.generate() }
        page.onCancelRun = { [weak self] in self?.condense?.cancel() }
        page.onApply = { [weak self] in Task { await self?.applyCondense() } }
        page.onDiscard = { [weak self] in self?.discardCondense() }
        page.onCondenseAccount = { [weak self] id in self?.preferences.update { $0.cleanup.condenseAccount = id } }
        page.onCondenseModel = { [weak self] model in self?.preferences.update { $0.cleanup.condenseModel = model } }
    }

    // MARK: Showing

    /// The mode came on screen (the page follows the data, the candidates are fresh) or left it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if loop == nil {
                loop = ObservationLoop(track: { [weak self] in self?.model() }, apply: { [weak self] model in
                    guard let self, let model else { return }
                    self.page.update(model)
                    self.onDumpNeeded?()
                })
            }
            if sessionsLoop == nil, let retention {
                sessionsSignature = nil
                sessionsLoop = ObservationLoop(track: { retention.sessionsSignature }, apply: { [weak self] signature in
                    guard let self else { return }
                    defer { self.sessionsSignature = signature }
                    guard let last = self.sessionsSignature, last != signature else { return }
                    self.refreshCandidates()
                })
            }
            refreshCandidates()
        } else {
            loop?.cancel()
            loop = nil
            sessionsLoop?.cancel()
            sessionsLoop = nil
        }
    }

    /// Fresh candidates (the page shows them once they are in).
    func refreshCandidates() {
        guard let retention, !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            await retention.refresh()
            self?.refreshing = false
        }
    }

    /// Makes the page the keyboard's (space, ⌘A, ⌫, esc).
    func focus() {
        guard let window = page.window else { return }
        window.makeFirstResponder(page)
    }

    func select(tab: CleanupTab) { self.tab = tab }

    // MARK: Model

    func model() -> CleanupPageModel {
        let prefs = preferences.preferences
        guard let retention else { return mockModel() }
        let p = presenter()
        let notesByID = Dictionary(notes.activeNotes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let presenter = CleanupPresenter(notebook: p, resolve: resolve, notes: notesByID, session: session, project: project)
        let c = retention.candidates
        let rows: [CleanupRow]
        switch tab {
        case .notes: rows = c.notes.map(presenter.noteRow)
        case .sessions: rows = c.sessions.map(presenter.sessionRow)
        case .files: rows = c.files.map(presenter.fileRow)
        }
        let calendar = retention.calendar
        var model = CleanupPageModel(
            meta: CleanupPresenter.meta(prefs, total: c.total, lastShownAt: retention.state.state.digest.lastShownAt, calendar: calendar),
            counts: [.notes: c.notes.count, .sessions: c.sessions.count, .files: c.files.count], tab: tab, rows: rows,
            selected: (selection[tab] ?? []).intersection(rows.map(\.id)), policy: CleanupPresenter.policy(prefs),
            bulkDisabled: CleanupPresenter.bulkDisabled)
        if condenseOpen, tab == .notes, let condense, !condense.sources.isEmpty || condense.isRunning {
            model.condense = condenseModel(condense, notebook: p, notes: notesByID, prefs: prefs)
        }
        _ = ticks
        _ = retention.revision
        return model
    }

    private func condenseModel(_ runner: CondenseRunner, notebook: NotebookPresenter, notes: [NoteID: NoteSummary],
                               prefs: CoddPreferences) -> CondenseModel {
        let account = currentAccount
        let options = accountOptions()
        let title = options.first { $0.id == account }?.title ?? account
        var longSections: [NoteID: Int] = [:]
        for candidate in retention?.candidates.notes ?? [] {
            if case .longNote(let sections, _) = candidate.reason { longSections[candidate.id] = sections }
        }
        var elapsed = ""
        if case .running(let started) = runner.phase {
            elapsed = "\(max(0, Int(runner.clock().timeIntervalSince(started))))s"
        }
        return CleanupPresenter.condense(runner, notebook: notebook, resolve: resolve, notes: notes, longSections: longSections,
                                         accounts: options, account: account, accountTitle: title, accountHint: accountHint(account),
                                         model: currentModel, elapsed: elapsed, now: runner.clock(), timeZone: runner.timeZone)
    }

    var currentAccount: String {
        accountOverride ?? preferences.preferences.cleanup.condenseAccount ?? "follow"
    }

    var currentModel: String {
        let model = preferences.preferences.cleanup.condenseModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? CoddPreferences.Cleanup.condenseModelOptions[0] : model
    }

    /// Mock mode: the artboard's NOTES / SESSIONS / FILES with the condense card in preview.
    private func mockModel() -> CleanupPageModel {
        var model: CleanupPageModel
        switch tab {
        case .notes:
            model = CleanupSamples.artboard
            if !condenseOpen { model.condense = nil }
        case .sessions: model = CleanupSamples.sessions
        case .files: model = CleanupSamples.files
        }
        model.selected = selection[tab] ?? []
        return model
    }

    // MARK: Actions

    private func toast(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        page.showToast(text, undo: undo)
    }

    private func clearSelection(_ ids: [String]) {
        selection[tab] = (selection[tab] ?? []).subtracting(ids)
    }

    /// A row button: `保留 30 天`, `封存`, `移到垃圾桶`.
    func rowAction(_ id: String, _ action: String) async {
        await perform(action, ids: [id])
    }

    /// `action` on rows of `tab` as the row buttons do it (DEBUG `-codd-cleanup-action`, tests).
    func act(_ action: String, ids: [String], tab: CleanupTab) async {
        self.tab = tab
        await perform(action, ids: ids)
    }

    /// The bulk bar (or ⌫): the action on the selected rows of the tab.
    func bulk(_ action: String, _ ids: Set<String>) async {
        // In row order (the condense card lists its sources so); ids the page no longer shows last.
        let known = page.model.rows.map(\.id).filter { ids.contains($0) }
        let ordered = known + ids.subtracting(known).sorted()
        if action == CleanupBulkAction.condense {
            await openCondense(ordered)
            return
        }
        await perform(action, ids: ordered)
    }

    private func perform(_ action: String, ids: [String]) async {
        guard !ids.isEmpty else { return }
        guard let retention else {
            toast("mock 模式不會變更任何東西")
            return
        }
        let tab = self.tab
        lastAction = (action, tab.rawValue, ids.count)
        switch (tab, action) {
        case (.notes, CleanupRowAction.keep):
            await retention.keepNotes(ids.compactMap(NoteID.init(rawValue:)))
            toast(Self.keptText(ids.count))
        case (.notes, CleanupRowAction.archive):
            let noteIDs = ids.compactMap(NoteID.init(rawValue:))
            do {
                try await retention.archiveNotes(noteIDs)
                toast("已封存 \(noteIDs.count) 則筆記", undo: { Task { await retention.unarchiveNotes(noteIDs) } })
            } catch {
                toast((error as? NotesError)?.errorDescription ?? "無法封存")
            }
        case (.notes, CleanupRowAction.trash):
            let noteIDs = ids.compactMap(NoteID.init(rawValue:))
            do {
                try await retention.trashNotes(noteIDs)
                let days = preferences.preferences.cleanup.trashPurgeDays
                toast("✕ \(noteIDs.count) 則筆記已移到垃圾桶 · \(days) 天後永久刪除", undo: { Task { await retention.restoreNotes(noteIDs) } })
            } catch {
                toast((error as? NotesError)?.errorDescription ?? "無法移到垃圾桶")
            }
        case (.sessions, CleanupRowAction.keep):
            await retention.keepSessions(ids)
            toast(Self.keptText(ids.count))
        case (.sessions, CleanupRowAction.archive):
            if let restore = await retention.archiveSessions(ids) {
                toast(SidebarViewController.archiveToastText(count: ids.count), undo: { [weak retention] in
                    restore()
                    Task { await retention?.refresh() }
                })
            }
        case (.files, CleanupRowAction.keep):
            await retention.keepFiles(ids)
            toast(Self.keptText(ids.count))
        case (.files, CleanupRowAction.trash):
            let done = await retention.trashFiles(ids)
            toast(done > 0 ? "已移到垃圾桶 · \(done) 項" : "沒有移動任何檔案")
        default:
            return
        }
        clearSelection(ids)
        onDumpNeeded?()
    }

    static func keptText(_ count: Int) -> String {
        "已保留 \(count) 項 · \(RetentionService.keepDays) 天內不再建議"
    }

    // MARK: Condense (D32)

    /// `交給 Claude 濃縮…`: the selected notes into the card (AI OFF ones left out with the toast).
    func openCondense(_ ids: [String]) async {
        guard let condense else {
            condenseOpen = true
            return
        }
        guard !condense.isRunning else { return }
        let longNotes = Set((retention?.candidates.notes ?? []).compactMap { c -> NoteID? in
            if case .longNote = c.reason { return c.id }
            return nil
        })
        await condense.prepare(ids.compactMap(NoteID.init(rawValue:)), longNotes: longNotes)
        if !condense.excluded.isEmpty { toast(CondenseRunner.offExcludedText) }
        condenseOpen = !condense.sources.isEmpty
        lastAction = ("condense", tab.rawValue, condense.sources.count)
        onDumpNeeded?()
    }

    /// `[✻ 產生摘要]` / `[重新產生]`.
    func generate() {
        guard let condense else { return }
        condense.generate(account: currentAccount, model: currentModel)
        startTicker()
        onDumpNeeded?()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let condense = self.condense else { return }
                self.ticks += 1
                if !condense.isRunning {
                    self.onDumpNeeded?()
                    return
                }
            }
        }
    }

    /// `[建立摘要並封存原稿]`.
    func applyCondense() async {
        guard let condense else {
            toast("mock 模式不會變更任何東西")
            return
        }
        switch await condense.apply() {
        case .success(let applied):
            condenseOpen = false
            selection[.notes] = []
            toast(CondenseRunner.appliedToast(applied), undo: { [weak condense, weak retention] in
                Task {
                    await condense?.undo(applied)
                    await retention?.refresh()
                }
            })
            await retention?.refresh()
        case .failure(let refusal):
            toast(refusal.message)
        }
        onDumpNeeded?()
    }

    /// `[捨棄]`: the preview goes and the card closes; nothing changed.
    func discardCondense() {
        condense?.discard()
        condense?.reset()
        condenseOpen = false
        onDumpNeeded?()
    }

    // MARK: Dump

    /// `cleanup {counts, digest, condense, shown, tab, rows, selected, lastAction}`.
    var dumpObject: [String: Any] {
        var object: [String: Any] = [
            "shown": isActive, "tab": tab.rawValue, "rows": page.model.rows.map(\.id), "selected": Array(selection[tab] ?? []).sorted(),
            "condenseOpen": condenseOpen,
        ]
        if let retention {
            object["counts"] = retention.countsDump
            object["digest"] = retention.digestDump
        } else {
            object["counts"] = ["notes": 8, "sessions": 5, "files": 2, "total": 15]
        }
        object["condense"] = condense?.dumpObject ?? ["state": "idle", "previewChars": 0]
        if let action = lastAction { object["lastAction"] = ["kind": action.kind, "tab": action.tab, "count": action.count] }
        return object
    }
}
