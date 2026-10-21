import AppKit
import CoddDialogsUI
import CoddNotebookUI
import CoddNotes
import CoddUI

/// The compare sheet's data (D8): the note's snapshots, the texts loaded so far (`current` = the
/// editor's text) and the two sides shown.
struct HistoryCompareState: Equatable {
    static let currentID = "current"

    var noteID: NoteID
    /// Newest first (C1 `history(of:)`).
    var snapshots: [NoteSnapshotInfo]
    var texts: [String: String]
    /// The older side: what `還原這一版` restores.
    var fromID: String
    var toID: String

    func snapshot(_ id: String) -> NoteSnapshotInfo? { snapshots.first { $0.id == id } }
}

/// M4 I1b: the Notebook's menus and metadata (D15, D20, D29, D34), COPY REF (D39 pasteboard),
/// archive / trash / restore with UNDO, the link and tag pickers, the info panel's actions and
/// the HISTORY compare sheet. Every frontmatter change saves the editor first and hands the new
/// file hash back to it (`NoteEditorController.adopt`), so the next autosave never conflicts.
extension NotesAreaViewController {
    func wireFeatures() {
        chrome.onAIAccess = { [weak self] access in
            Task { await self?.applyChange(.ai(NotebookPresenter.noteAccess(access)), label: "ai") }
        }
        chrome.onScope = { [weak self] id in Task { await self?.setScope(id) } }
        chrome.onCopyRef = { [weak self] form in Task { await self?.copyReference(form) } }
        chrome.onMore = { [weak self] action in Task { await self?.perform(action) } }
        chrome.onCrumb = { [weak self] in self?.noteList.window?.makeFirstResponder(self?.noteList) }
        chrome.infoPanel.onOpenLink = { [weak self] link in self?.openLink(link) }
        chrome.infoPanel.onAddLink = { [weak self] in self?.presentLinkPicker() }
        chrome.infoPanel.onSelectHistory = { [weak self] id in self?.selectHistory(id) }
        chrome.infoPanel.onCompare = { [weak self] in Task { await self?.presentHistoryCompare() } }
        chrome.infoPanel.onOpenAsset = { [weak self] id in self?.openAsset(id) }
        chrome.infoPanel.onTogglePin = { [weak self] in Task { await self?.togglePin() } }
        let chips = editor.chipsRow
        chips.onAddTag = { [weak self] tag in Task { await self?.applyChange(.addTag(tag), label: "addTag") } }
        chips.onRemoveTag = { [weak self] tag in Task { await self?.applyChange(.removeTag(tag), label: "removeTag") } }
        chips.onTagClick = { [weak self] _ in self?.presentTagEditor() }
        chips.onOpenProject = { [weak self] path in self?.service.selectList(.project(path)) }
        editor.onEditAnnotations = { [weak self] path in Task { await self?.annotate(path) } }
    }

    // MARK: Metadata

    /// One frontmatter change of the shown note: the editor is saved first, the file rewritten by
    /// C1 (only the changed lines, D2), the new hash adopted. A refusal (an unparsable
    /// frontmatter, a note in TRASH) becomes a toast in C1's words.
    @discardableResult
    func applyChange(_ change: MetadataChange, label: String) async -> Bool {
        guard let id = editor.noteID else {
            showToast(NotebookCopy.unsavedReason)
            return false
        }
        await editor.flush()
        do {
            let document = try await service.update(id, change)
            editor.adopt(document)
            lastAction = (label, id.rawValue, true, nil)
            refreshPickers(document.metadata)
            onDumpNeeded?()
            return true
        } catch {
            let message = Self.message(error)
            lastAction = (label, id.rawValue, false, message)
            showToast(message)
            onDumpNeeded?()
            return false
        }
    }

    /// The scope menu: `global`, or a project path (it becomes the primary project, linked).
    func setScope(_ id: String) async {
        if id == NotebookScopeOption.globalID {
            await applyChange(.scope(.global, primaryProject: nil), label: "scope")
        } else {
            await applyChange(.scope(.project, primaryProject: id), label: "scope")
        }
    }

    func togglePin() async {
        guard let metadata = editor.document?.metadata else {
            showToast(NotebookCopy.unsavedReason)
            return
        }
        await applyChange(.pinned(!metadata.pinned), label: "pinned")
    }

    /// The ⋯ menu.
    func perform(_ action: NotebookMoreAction) async {
        switch action {
        case .togglePin:
            await togglePin()
        case .kind(let kind):
            if editor.noteID == nil {
                editor.setDraftKind(NotebookPresenter.noteKind(kind))
            } else {
                await applyChange(.kind(NotebookPresenter.noteKind(kind)), label: "kind")
            }
        case .archive:
            await archiveShown()
        case .unarchive:
            await lifecycle("unarchive", toast: "已取消封存") { try await self.service.unarchive($0) }
        case .trash:
            await trashShown()
        case .restore:
            await lifecycle("restore", toast: "已從垃圾桶還原") { try await self.service.restore($0) }
        case .revealInFinder:
            // D39: a user's choice only; background runs never reveal (the closure logs that).
            if let url = editor.document?.fileURL { editor.revealFile(url) }
        case .toggleSource:
            editor.toggleMode()
        case .copyID:
            guard let id = editor.noteID else { return }
            pasteboard.write(id.rawValue, userAction: true)
            showToast("已複製 ID \(id.rawValue)")
        }
    }

    // MARK: Archive / trash / restore (D29)

    /// A list row's right-click menu (`NotebookPresenter.rowActions`): the ⋯ menu's paths for any
    /// row, the shown note or another one.
    func rowAction(_ id: NoteID, _ action: String) async {
        switch action {
        case "pin": await toggleRowPin(id)
        case "archive": await archive(id)
        case "unarchive": await lifecycle("unarchive", toast: "已取消封存", id: id) { try await self.service.unarchive($0) }
        case "trash": await trash(id)
        case "restore": await lifecycle("restore", toast: "已從垃圾桶還原", id: id) { try await self.service.restore($0) }
        default: break
        }
    }

    /// A row's 釘選 / 取消釘選. The shown note goes through the ⋯ menu's path (the editor adopts it).
    private func toggleRowPin(_ id: NoteID) async {
        if editor.noteID == id { return await togglePin() }
        guard let summary = service.rows.first(where: { $0.id == id }) ?? service.search?.hits.first(where: { $0.summary.id == id })?.summary
        else { return }
        do {
            _ = try await service.update(id, .pinned(!summary.metadata.pinned))
            lastAction = ("pinned", id.rawValue, true, nil)
            await service.refreshNow()
            onDumpNeeded?()
        } catch {
            fail("pinned", id, error)
        }
    }

    /// ⋯ › 封存: the note goes to ARCHIVE (`archivedBy: user`), the editor moves on, `[UNDO]`
    /// brings it back.
    func archiveShown() async {
        guard let id = editor.noteID else { return }
        await archive(id)
    }

    /// 封存 of the shown note or of a row: a shown note is saved first and the editor moves on.
    private func archive(_ id: NoteID) async {
        let index = shownIndex(of: id)
        let shown = editor.noteID == id
        if shown { await editor.flush() }
        do {
            try await service.archive(id)
            lastAction = ("archive", id.rawValue, true, nil)
            await leave(id, near: index)
            showToast("已封存", undo: { [weak self] in
                Task { await self?.undoLifecycle(id, reveal: shown) { try await $0.service.unarchive(id) } }
            })
        } catch {
            fail("archive", id, error)
        }
    }

    /// ⋯ › 移到垃圾桶: CODD's TRASH (restorable until the purge, D29), `[UNDO]` restores.
    func trashShown() async {
        guard let id = editor.noteID else { return }
        await trash(id)
    }

    /// 移到垃圾桶 of the shown note or of a row: a shown note is saved first and the editor moves on.
    private func trash(_ id: NoteID) async {
        let index = shownIndex(of: id)
        let shown = editor.noteID == id
        if shown { await editor.flush() }
        do {
            try await service.trash(id)
            lastAction = ("trash", id.rawValue, true, nil)
            await leave(id, near: index)
            let days = NotesService.policy(preferences.preferences).0.trashPurgeDays
            let text = "✕ 已移到垃圾桶 · \(days) 天後永久刪除"
            showToast(text, undo: { [weak self] in
                Task { await self?.undoLifecycle(id, reveal: shown) { try await $0.service.restore(id) } }
            })
        } catch {
            fail("trash", id, error)
        }
    }

    /// 取消封存 / 還原: the note stays shown (its file moved or its frontmatter changed: the
    /// editor takes the new document). A row that is not shown only leaves the list.
    private func lifecycle(_ label: String, toast: String, id row: NoteID? = nil, _ body: (NoteID) async throws -> Void) async {
        guard let id = row ?? editor.noteID else { return }
        let shown = editor.noteID == id
        if shown { await editor.flush() }
        do {
            try await body(id)
            lastAction = (label, id.rawValue, true, nil)
            if shown {
                if let document = try? await service.document(id) { editor.adopt(document) }
            } else {
                await service.refreshNow()
            }
            showToast(toast)
            onDumpNeeded?()
        } catch {
            fail(label, id, error)
        }
    }

    /// `[UNDO]` of 封存 / 移到垃圾桶: the change is reverted. The note is shown again when it was
    /// the shown one; a row closed from its menu only comes back to the list.
    private func undoLifecycle(_ id: NoteID, reveal: Bool = true, _ body: (NotesAreaViewController) async throws -> Void) async {
        do {
            try await body(self)
            lastAction = ("undo", id.rawValue, true, nil)
            await service.refreshNow()
            if editor.noteID == id, let document = try? await service.document(id) {
                editor.adopt(document)
            } else if reveal {
                self.reveal(id)
            }
            onDumpNeeded?()
        } catch {
            fail("undo", id, error)
        }
    }

    private func fail(_ label: String, _ id: NoteID, _ error: any Error) {
        let message = Self.message(error)
        lastAction = (label, id.rawValue, false, message)
        showToast(message)
        onDumpNeeded?()
    }

    /// Where the shown note is in the shown list (search hits during a search).
    private func shownIndex(of id: NoteID) -> Int? {
        if !service.searchText.isEmpty { return service.search?.hits.firstIndex { $0.summary.id == id } }
        return service.rows.firstIndex { $0.id == id }
    }

    /// The shown note left the shown list: the editor shows its neighbour (the row now at its
    /// place), else the list's comment.
    private func leave(_ id: NoteID, near index: Int?) async {
        await service.refreshNow()
        guard editor.noteID == id else { return }
        let ids = service.searchText.isEmpty ? service.rows.map(\.id) : (service.search?.hits.map(\.summary.id) ?? [])
        let remaining = ids.filter { $0 != id }
        if remaining.count == ids.count, ids.contains(id) { return }
        if !remaining.isEmpty {
            open(remaining[min(index ?? 0, remaining.count - 1)], focus: false)
        } else {
            await editor.show(nil, placeholder: service.counts.inbox == 0 ? NotebookCopy.noNotesEmpty : Self.pickNoteText)
        }
        onDumpNeeded?()
    }

    // MARK: COPY REF (D15, §3.6)

    /// Copies one form of the shown note. `userAction` false (DEBUG `-codd-notes-copy-ref`)
    /// computes the text for the dump and never touches a pasteboard; a user's copy goes through
    /// `CoddPasteboard` (D39: the private pasteboard in background runs). Nil when refused.
    @discardableResult
    func copyReference(_ form: NotebookRefForm, userAction: Bool = true) async -> String? {
        guard let id = editor.noteID, let set = referenceSet(), let kind = NoteReferenceForm.Kind(rawValue: form.rawValue) else {
            showToast(NotebookCopy.unsavedReason)
            return nil
        }
        if let refusal = set.refusal(kind) {
            showToast(refusal)
            lastCopyRef = (form.rawValue, refusal, 0, "refused")
            onDumpNeeded?()
            return nil
        }
        let text: String
        if kind == .markdown {
            await editor.flush()
            do {
                text = try await service.copyMarkdown(id)
            } catch {
                showToast(Self.message(error))
                return nil
            }
        } else {
            guard let value = set.form(kind)?.text else { return nil }
            text = value
        }
        // Form 5 carries the note's URL token.
        let target = userAction ? pasteboard.write(text, userAction: true, concealed: kind == .url).rawValue : "none"
        // Never a note's text in the dump: the Markdown copy is reported by its size only.
        let shown = kind == .markdown ? "（全文 Markdown）" : NoteReferenceSet.masked(text, kind: kind)
        lastCopyRef = (form.rawValue, shown, text.count, target)
        if userAction {
            showToast(kind == .markdown ? "已複製全文 Markdown" : "已複製 \(set.form(kind)?.display ?? "")")
        }
        HolderSessionStore.printLog("notes copy-ref id=\(id.rawValue) form=\(form.rawValue) chars=\(text.count) target=\(target)")
        onDumpNeeded?()
        return text
    }

    // MARK: Links and tags (pickers)

    /// `+ 連結 session / 專案` (info panel): CODD claude sessions and layout projects; picking a
    /// linked one unlinks it.
    func presentLinkPicker() {
        guard let metadata = editor.document?.metadata else { return }
        pickerPresenter.dismiss()
        let view = LinkPickerView(model: linkPickerModel(metadata))
        view.onPick = { [weak self] link in
            self?.pickerPresenter.dismiss()
            Task { await self?.toggleLink(link) }
        }
        view.onCancel = { [weak self] in self?.pickerPresenter.dismiss() }
        linkPicker = view
        let x = max(8, chrome.infoPanel.frame.minX - LinkPickerView.preferredWidth - 8)
        pickerPresenter.present(view, at: CGPoint(x: x, y: NoteEditorChromeView.topBarHeight + 8), in: chrome) { [weak self, weak view] in
            if let self, self.linkPicker === view { self.linkPicker = nil }
        }
    }

    func linkPickerModel(_ metadata: NoteMetadata) -> LinkPickerModel {
        let p = presenter()
        var sessions: [LinkPickerSession] = []
        let codd = store.allSessions.filter { $0.kind == .claude && !$0.external }
            .sorted { ($0.state.isLive ? 0 : 1, $1.stateSince) < ($1.state.isLive ? 0 : 1, $0.stateSince) }
        for session in codd {
            sessions.append(LinkPickerSession(id: session.id.lowercased(), title: session.title, state: NotebookPresenter.state(session.state),
                                              project: store.project(session.projectID)?.name ?? ""))
        }
        for id in metadata.links.sessions where !sessions.contains(where: { $0.id == id.lowercased() }) {
            sessions.append(LinkPickerSession(id: id.lowercased(), title: "session \(id.prefix(8))", state: .stopped, project: ""))
        }
        var projects: [LinkPickerProject] = []
        for option in p.scopeOptions(metadata, resolve: { self.resolve($0) }) where option.isProject {
            projects.append(LinkPickerProject(id: option.id, name: option.title, tag: option.tag))
        }
        var linked = Set(metadata.links.sessions.map { NotebookLink.session(id: $0.lowercased()) })
        linked.formUnion(metadata.links.projects.map { NotebookLink.project(id: $0) })
        return LinkPickerModel(sessions: sessions, projects: projects, linked: linked)
    }

    func toggleLink(_ link: NotebookLink) async {
        guard let metadata = editor.document?.metadata else { return }
        switch link {
        case .session(let id):
            let linked = metadata.links.sessions.contains { $0.lowercased() == id.lowercased() }
            await applyChange(linked ? .unlinkSession(id) : .linkSession(id), label: linked ? "unlinkSession" : "linkSession")
        case .project(let path):
            let linked = metadata.links.projects.contains(path)
            await applyChange(linked ? .unlinkProject(path) : .linkProject(path), label: linked ? "unlinkProject" : "linkProject")
        }
    }

    /// A tag chip: the tag editor (TAGS · 標籤) with the notebook's other tags as suggestions.
    func presentTagEditor() {
        guard let metadata = editor.document?.metadata, editor.chipsRow.model.allowsAddTag else { return }
        pickerPresenter.dismiss()
        let view = TagEditorView(model: tagEditorModel(metadata))
        view.onAdd = { [weak self] tag in Task { await self?.applyChange(.addTag(tag), label: "addTag") } }
        view.onRemove = { [weak self] tag in Task { await self?.applyChange(.removeTag(tag), label: "removeTag") } }
        view.onDone = { [weak self] in self?.pickerPresenter.dismiss() }
        tagEditor = view
        let chips = editor.chipsRow
        let rect = chrome.convert(chips.bounds, from: chips)
        pickerPresenter.present(view, at: CGPoint(x: max(8, rect.minX), y: rect.maxY + 4), in: chrome) { [weak self, weak view] in
            if let self, self.tagEditor === view { self.tagEditor = nil }
        }
    }

    func tagEditorModel(_ metadata: NoteMetadata) -> TagEditorModel {
        let own = Set(metadata.tags.map { $0.lowercased() })
        return TagEditorModel(tags: metadata.tags, suggestions: service.knownTags.filter { !own.contains($0.lowercased()) })
    }

    /// An open picker follows the note's new links / tags.
    private func refreshPickers(_ metadata: NoteMetadata) {
        linkPicker?.update(linkPickerModel(metadata))
        tagEditor?.update(tagEditorModel(metadata))
    }

    // MARK: Info panel

    func openLink(_ link: NotebookLink) {
        switch link {
        case .session(let id):
            if let session = store.session(id) ?? store.allSessions.first(where: { $0.id.lowercased() == id.lowercased() }) {
                onOpenSession?(session.id)
            }
        case .project(let path):
            service.selectList(.project(path))
        }
    }

    /// A HISTORY row: the version `[比較]` compares with the current text.
    func selectHistory(_ id: String) {
        selectedHistoryID = selectedHistoryID == id ? nil : id
        refreshChrome()
    }

    /// An ASSETS thumbnail: the editor scrolls to that image's line.
    func openAsset(_ id: String) {
        if !editor.revealImage(named: (id as NSString).lastPathComponent) {
            showToast("這張圖片沒有出現在內文裡")
        }
    }

    /// The decoded display image of one of the note's images (the ASSETS thumbnails).
    func thumbnail(named name: String) -> NSImage? {
        for path in editor.imagePaths where (path as NSString).lastPathComponent == name {
            if let image = editor.images.image(for: path) { return image }
        }
        return nil
    }

    // MARK: HISTORY compare (D8)

    /// The compare sheet's data: from = the clicked HISTORY row, else the newest snapshot whose
    /// text differs from the editor's; to = the current text.
    func makeHistoryCompare() async -> HistoryCompareState? {
        guard let id = editor.noteID else { return nil }
        let snapshots = (try? await service.history(of: id)) ?? []
        guard !snapshots.isEmpty, editor.noteID == id else { return nil }
        let current = editor.text
        var texts = [HistoryCompareState.currentID: current]
        var from = selectedHistoryID.flatMap { selected in snapshots.first { $0.id == selected }?.id }
        if from == nil {
            for snapshot in snapshots {
                guard let text = try? await service.snapshotText(snapshot, of: id) else { continue }
                texts[snapshot.id] = text
                if text != current {
                    from = snapshot.id
                    break
                }
            }
        }
        let fromID = from ?? snapshots[0].id
        if texts[fromID] == nil, let snapshot = snapshots.first(where: { $0.id == fromID }) {
            texts[fromID] = (try? await service.snapshotText(snapshot, of: id)) ?? ""
        }
        return HistoryCompareState(noteID: id, snapshots: snapshots, texts: texts, fromID: fromID, toID: HistoryCompareState.currentID)
    }

    /// The sheet's model (pure).
    func historyModel(_ state: HistoryCompareState) -> HistoryCompareModel {
        let p = presenter()
        var versions = [HistoryVersionOption(id: HistoryCompareState.currentID, title: "目前的內容")]
        for (index, snapshot) in state.snapshots.enumerated() {
            let label = NotebookPresenter.historyLabel(snapshot, isOldest: index == state.snapshots.count - 1 && state.snapshots.count > 1)
            versions.append(HistoryVersionOption(id: snapshot.id, title: "\(p.shortStamp(snapshot.takenAt)) · \(label)"))
        }
        let old = state.texts[state.fromID] ?? ""
        let new = state.texts[state.toID] ?? ""
        let lines = Self.diffLines(old: old, new: new)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        var reason: String?
        if state.snapshot(state.fromID) == nil {
            reason = "左邊選一個較早的版本"
        } else if old == state.texts[HistoryCompareState.currentID] {
            reason = "這一版與目前的內容相同"
        }
        return HistoryCompareModel(versions: versions, fromID: state.fromID, toID: state.toID, lines: lines,
                                   summary: lines.isEmpty ? "相同" : "−\(removed) +\(added)", restoreEnabled: reason == nil,
                                   restoreDisabledReason: reason)
    }

    func presentHistoryCompare() async {
        guard historySheet == nil, let window = view.window else { return }
        guard let state = await makeHistoryCompare() else {
            showToast("還沒有其他版本")
            return
        }
        guard historySheet == nil else { return }
        let sheetView = HistoryCompareView(model: historyModel(state))
        sheetView.onSelectFrom = { [weak self] id in Task { await self?.selectHistorySide(from: id) } }
        sheetView.onSelectTo = { [weak self] id in Task { await self?.selectHistorySide(to: id) } }
        sheetView.onRestore = { [weak self] in
            guard let self, let state = self.historySheet?.state else { return }
            self.closeHistorySheet()
            Task { await self.restoreVersion(state.fromID) }
        }
        sheetView.onClose = { [weak self] in self?.closeHistorySheet() }
        historySheet = (DialogPresenter.presentSheet(sheetView, on: window), sheetView, state)
    }

    private func selectHistorySide(from: String? = nil, to: String? = nil) async {
        guard var state = historySheet?.state else { return }
        if let from { state.fromID = from }
        if let to { state.toID = to }
        for id in [state.fromID, state.toID] where state.texts[id] == nil {
            if let snapshot = state.snapshot(id) { state.texts[id] = (try? await service.snapshotText(snapshot, of: state.noteID)) ?? "" }
        }
        guard let sheet = historySheet else { return }
        historySheet = (sheet.window, sheet.view, state)
        sheet.view.update(historyModel(state))
    }

    func closeHistorySheet() {
        guard let sheet = historySheet else { return }
        historySheet = nil
        DialogPresenter.dismiss(sheet.window)
    }

    /// `還原這一版`: the editor is saved, C1 snapshots the current file (`還原前`) and writes the
    /// snapshot's body; the editor shows it as one undoable step.
    @discardableResult
    func restoreVersion(_ snapshotID: String) async -> Bool {
        guard let id = editor.noteID else { return false }
        await editor.flush()
        do {
            let snapshots = try await service.history(of: id)
            guard let snapshot = snapshots.first(where: { $0.id == snapshotID }) else { return false }
            let document = try await service.restoreSnapshot(snapshot, of: id)
            editor.applyRestored(document)
            selectedHistoryID = nil
            lastAction = ("restoreVersion", id.rawValue, true, nil)
            showToast("已還原 \(presenter().shortStamp(snapshot.takenAt)) 的版本")
            onDumpNeeded?()
            return true
        } catch {
            fail("restoreVersion", id, error)
            return false
        }
    }

    // MARK: Helpers

    func showToast(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        editor.documentView.showToast(text, undo: undo)
    }

    /// C1's 繁體中文 error text.
    static func message(_ error: any Error) -> String {
        (error as? NotesError)?.errorDescription ?? error.localizedDescription
    }
}
