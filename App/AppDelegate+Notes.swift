import AppKit
import CoddFiles
import CoddHooks
import CoddNotebookUI
import CoddNotes
import CoddTextKit
import CoddUI
import UniformTypeIdentifiers

/// M4 I1a: the notebook in the app — the NOTES area, quick notes (D13), the `筆記` menu (D36),
/// `SessionVM.notesCount`, the core `notes` dump key and the DEBUG notes flags (§6).
extension AppDelegate {
    // MARK: Wiring

    /// Builds the NOTES area on the service and the editor (before the main window, which hosts it).
    func makeNotesArea() -> NotesAreaViewController {
        let area = NotesAreaViewController(service: notes, editor: noteEditor, store: sessionStore, shell: shell, preferences: preferences,
                                           recentFiles: files.recentStore, pasteboard: pasteboard)
        area.refContext = { [weak self] in self?.noteReferenceContext ?? (nil, nil) }
        area.filesMode = makeFilesMode()
        area.cleanupMode = makeCleanupMode()
        area.onOpenFolder = { [weak self] in self?.chooseFilesFolder() }
        // The Notebook's editor and the session drawer's both hear disk changes and AI writes, and
        // take each other's saves.
        NoteEditors([noteEditor, notesDrawer.editor]).attach(to: notes)
        area.onOpenSession = { [weak self] id in self?.mainWindow?.show(id) }
        #if DEBUG
        area.onDumpNeeded = { [weak self] in self?.scheduleStateDump() }
        #endif
        return area
    }

    /// Opens the notebook (after the preferences: the retention policy and default access come
    /// from them), then the notes loops and the DEBUG actions. Never blocks the sessions.
    func startNotes() {
        Task { [weak self] in
            guard let self else { return }
            if let folder = self.mockNotesFolder {
                await MockNotes.seed(into: folder)
                await MockFiles.seed(into: folder, now: self.notes.clock())
            }
            await self.notes.open()
            self.observeNotes()
            #if DEBUG
            await self.runNotesDebugActions()
            #endif
        }
    }

    /// `SessionVM.notesCount` from the notes linked to each session (real mode; the mock keeps
    /// the SPEC numbers), and the live sessions / titles the library needs (D29, §3.7 `links:`).
    private func observeNotes() {
        let notes = self.notes
        if let holders = holderStore {
            notesLoops.append(ObservationLoop(track: { () -> ([String: Int], [SessionID]) in
                (notes.linkedSessionCounts, Array(holders.sessionsByID.keys))
            }, apply: { [weak holders] counts, _ in
                for session in holders?.sessionsByID.values.map({ $0 }) ?? [] {
                    let count = counts[session.id.lowercased()] ?? 0
                    if session.notesCount != count { session.notesCount = count }
                }
            }))
            notesLoops.append(ObservationLoop(track: { () -> [String] in
                holders.sessionsByID.values.map { "\($0.id)\u{1F}\($0.title)\u{1F}\($0.state.isLive)" }.sorted()
            }, apply: { [weak holders] _ in
                guard let holders else { return }
                let sessions = Array(holders.sessionsByID.values)
                notes.setSessions(live: Set(sessions.filter { $0.state.isLive }.map { $0.id.lowercased() }),
                                  titles: Dictionary(sessions.map { ($0.id.lowercased(), $0.title) }, uniquingKeysWith: { a, _ in a }))
            }))
        }
        #if DEBUG
        if realOptions.dumpStatePath != nil {
            let editor = noteEditor
            notesLoops.append(ObservationLoop(track: { () -> String in
                "\(notes.revision)|\(notes.availability)|\(notes.search?.hits.count ?? -1)|\(notes.lastPaste?.asset ?? "")|"
                    + "\(notes.quickNote?.id?.rawValue ?? "")|\(editor.noteID?.rawValue ?? "")|\(editor.saveCount)|\(editor.diskConflict != nil)|"
                    + "\(editor.externalReloads)|\(editor.draft != nil)"
            }, apply: { [weak self] _ in self?.scheduleStateDump() }))
        }
        #endif
    }

    /// COPY REF form 5's port and token (D15): config.json's hook port and external MCP token in
    /// real mode; mock mode's made-up `127.0.0.1:47821` and a token of this run (D35).
    var noteReferenceContext: (port: Int?, mcpToken: String?) {
        if holderStore == nil { return (47821, mockMCPToken) }
        guard let config = holderStore?.hooks?.config else { return (nil, nil) }
        return (Int(config.port), config.mcpToken)
    }

    /// ⌘K NOTES (I1b): the active notes, newest first, with their row time on the notes clock.
    func paletteNotes() -> [QuickSwitchModel.Input.Note] {
        let p = NotebookPresenter(now: notes.clock(), timeZone: notes.timeZone, store: sessionStore, projects: [:])
        return notes.activeNotes.map { summary in
            let m = summary.metadata
            return QuickSwitchModel.Input.Note(id: m.id.rawValue, title: m.title, tags: m.tags, kind: m.kind.rawValue,
                                               time: p.isToday(m.updated) ? p.hourMinute(m.updated) : p.monthDay(m.updated))
        }
    }

    /// A ⌘K NOTES row: the window on NOTES (Notebook mode) with the note selected.
    func openNoteFromPalette(_ raw: String) {
        guard let id = NoteID(rawValue: raw) else { return }
        showMainWindow(nil)
        shell.area = .notes
        notesArea?.reveal(id)
    }

    // MARK: Quick note (D13)

    /// ⌘⇧N: a NOTE while NOTES shows (as `+ ⌘⇧N`), else the quick SCRATCH linked to the session on
    /// screen. Refused while an input method composes in the key window (D36).
    @objc func quickNote(_ sender: Any?) {
        guard !keyWindowHasMarkedText else { return }
        if shell.area == .notes {
            notesArea?.newNote()
            return
        }
        startQuickNote()
    }

    /// The menu bar's QUICK NOTE, the status item's 快速筆記 and ⌘⇧N outside NOTES: a SCRATCH titled
    /// `隨手記 M/D`, linked to the CODD session on screen (and its project), the window on NOTES
    /// with the caret in it. Nothing is on disk until something is typed (D3).
    func startQuickNote() {
        var links = NoteLinks()
        if shell.area == .sessions, let id = shell.currentSessionID, let session = sessionStore.session(id) {
            if !session.external { links.sessions = [id.lowercased()] }
            if let project = sessionStore.project(session.projectID), !project.isTransient { links.projects = [project.cwd] }
        }
        showMainWindow(nil)
        shell.area = .notes
        notesArea?.quickNote(links: links)
    }

    // MARK: 筆記 menu (D36)

    /// ⌘E: 原始碼 ⇄ 即時預覽 of the shown note.
    @objc func toggleNoteSource(_ sender: Any?) {
        guard canToggleNoteSource else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        noteEditor.toggleMode()
    }

    /// ⌘F: the Notebook's search field.
    @objc func searchNotes(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(searchNotes(_:))) == true else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        notesArea?.focusSearch()
    }

    /// ⌘⇧A (D10): ImageAnnotate for the image at the caret, else the note's first.
    @objc func annotateImage(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(annotateImage(_:))) == true else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        Task { await notesArea?.annotate() }
    }

    /// ⌘⇧C (D15): `codd://note/<id>` of the shown note through CoddPasteboard (D39).
    @objc func copyNoteReference(_ sender: Any?) {
        guard menuRules.isEnabled(#selector(copyNoteReference(_:))) == true else { return }
        #if DEBUG
        notesCommandRuns += 1
        #endif
        Task { await notesArea?.copyReference(.uri) }
    }

    var canToggleNoteSource: Bool {
        menuRules.isEnabled(#selector(toggleNoteSource(_:))) ?? false
    }

    /// The D36 rules for the window as it is now.
    var menuRules: MenuAreaRules {
        let tab = files.selectedTab
        return MenuAreaRules(area: shell.area, hasMarkedText: keyWindowHasMarkedText, noteShown: noteEditor.hasContent,
                             noteComposing: noteEditor.editor.isComposing, notesReady: notes.availability.isReady,
                             canAllow: mainWindow?.pane.canAllowCurrent ?? false, notesMode: notesArea?.mode ?? .notebook,
                             noteSaved: noteEditor.noteID != nil, noteHasImage: !noteEditor.imagePaths.isEmpty,
                             fileTabShown: tab != nil, fileTabHasEditor: tab?.editor != nil,
                             fileComposing: tab?.editor?.isComposing ?? false)
    }

    /// The key window's first responder has an input method composition (注音 between keys). A
    /// background run has no key window (CODD is never active): the main window's responder counts.
    var keyWindowHasMarkedText: Bool {
        let window = NSApp.keyWindow ?? mainWindow?.window
        return (window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    /// The `筆記` items' validation and 允許 ⌘⏎'s area rule (D36), nil for every other item.
    func validateNotesMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        if menuItem.action == #selector(toggleNoteSource(_:)) {
            menuItem.title = noteEditor.mode == .source ? "即時預覽" : "原始碼"
        }
        return menuRules.isEnabled(menuItem.action)
    }

    // MARK: Quit

    /// The editor's pending text and state.json at quit (bounded by the quit's own 2 s).
    func flushNotes() async {
        // An open ImageAnnotate screen keeps its edits (as ⎋ / 完成 do); the flush writes them.
        notesArea?.closeAnnotateKeepingEdits()
        await noteEditor.flushForLeaving()
        await notesDrawer.flushForLeaving()
        await notes.close()
    }

    /// Mock mode's temporary notebook goes at quit (D35).
    func removeMockNotes() {
        if let folder = mockNotesFolder { MockNotes.remove(folder) }
    }

    // MARK: Dump

    var notesDump: [String: Any] {
        NotesDump.object(service: notes, editor: noteEditor, mode: notesArea?.mode ?? .notebook, area: notesArea)
    }

    #if DEBUG
    // MARK: DEBUG flags (§6, I1a)

    /// `-codd-show notebook|note:<id>`, `-codd-notes-select`, `-codd-notes-new`, `-codd-quick-note`,
    /// `-codd-notes-type`, `-codd-notes-paste-image`, `-codd-notes-search`, `-codd-notes-rebuild`.
    func runNotesDebugActions() async {
        let o = realOptions
        guard let area = notesArea else { return }
        await waitFor(seconds: 30) { launchSessionsReady }
        let editor = noteEditor
        switch o.showKeyword {
        case "notebook"?:
            shell.area = .notes
        case "note"?:
            shell.area = .notes
            if let id = o.showArgument.flatMap(NoteID.init(rawValue:)) {
                area.reveal(id)
                await waitFor { editor.noteID == id }
            }
        case "annotate"?:
            await debugShowAnnotate(o.showArgument ?? "")
        default:
            break
        }
        if let raw = o.notesSelect {
            shell.area = .notes
            if let id = NoteID(rawValue: raw) {
                area.reveal(id)
                await waitFor { editor.noteID == id }
            }
            HolderSessionStore.printLog("debug notes-select id=\(raw) shown=\(editor.noteID?.rawValue == raw)")
        }
        if let title = o.notesNew {
            shell.area = .notes
            area.newNote(title: title)
            await waitFor { editor.draft != nil }
            HolderSessionStore.printLog("debug notes-new draft=\(editor.draft != nil)")
        }
        if o.quickNote {
            startQuickNote()
            await waitFor { editor.draft?.kind == .scratch }
            HolderSessionStore.printLog("debug quick-note draft=\(editor.draft != nil) links=\(editor.draft?.links.sessions.count ?? 0)")
        }
        if let text = o.notesType {
            if shell.area != .notes { shell.area = .notes }
            await waitFor { editor.hasContent }
            editor.type(text)
            await waitFor { editor.noteID != nil }
            HolderSessionStore.printLog("debug notes-type chars=\(text.count) id=\(editor.noteID?.rawValue ?? "-")")
        }
        if let path = o.notesPasteImage { await debugPasteImage(path) }
        if let query = o.notesSearch {
            shell.area = .notes
            notes.setSearchText(query)
            await waitFor { notes.search?.query == query }
            HolderSessionStore.printLog(String(format: "debug notes-search hits=%d ms=%.2f", notes.search?.hits.count ?? -1, notes.search?.ms ?? -1))
        }
        if o.notesRebuild {
            let report = await notes.rebuildIndex()
            HolderSessionStore.printLog("debug notes-rebuild count=\(report?.count ?? -1) ms=\(Int(report?.buildMs ?? -1))")
        }
        if o.notesType != nil || o.notesPasteImage != nil {
            // Let the autosave of what the flags typed land before the dump.
            try? await Task.sleep(for: editor.autosaveDelay + .milliseconds(300))
            await editor.flush()
        }
        await runNotesFeatureDebugActions()
        await runSendDebugActions()
        await runFilesDebugActions()
        await runCleanupDebugActions()
        scheduleStateDump()
    }

    /// I1b flags (§6): `-codd-notes-set`, `-codd-notes-copy-ref`, `-codd-notes-annotate`,
    /// `-codd-notes-archive`, `-codd-notes-trash`, then `-codd-notes-menu` (last: it stays open
    /// for the snapshot). Each one goes through the same path as the user's click.
    private func runNotesFeatureDebugActions() async {
        let o = realOptions
        guard let area = notesArea else { return }
        for spec in o.notesSet { await debugSetMetadata(spec, area: area) }
        if let spec = o.notesCopyRef {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let number = Int(parts[1]), let form = NotebookRefForm(rawValue: number), await debugShowNote(parts[0]) != nil {
                let text = await area.copyReference(form, userAction: false)
                HolderSessionStore.printLog("debug notes-copy-ref id=\(parts[0]) form=\(number) chars=\(text?.count ?? -1)")
            } else {
                HolderSessionStore.printLog("debug notes-copy-ref refused spec")
            }
        }
        if let spec = o.notesAnnotate { await debugAnnotate(spec, area: area) }
        if let raw = o.notesArchive, await debugShowNote(raw) != nil {
            await area.archiveShown()
            HolderSessionStore.printLog("debug notes-archive id=\(raw) ok=\(area.lastAction?.ok ?? false)")
        }
        if let raw = o.notesTrash, await debugShowNote(raw) != nil {
            await area.trashShown()
            HolderSessionStore.printLog("debug notes-trash id=\(raw) ok=\(area.lastAction?.ok ?? false)")
        }
        if o.notesSet.contains(where: { !$0.isEmpty }) || o.notesAnnotate != nil {
            // The autosave of an annotation block and the refresh of the counts land before the dump.
            await noteEditor.flush()
            await notes.refreshNow()
        }
        if let name = o.notesMenu {
            let menus: [String: NoteChromeMenu] = ["copy-ref": .copyRef, "ai": .ai, "scope": .scope, "send": .send, "more": .more]
            if let menu = menus[name] {
                // Drawn in place (a snapshot shows it; nothing is ordered in). The chrome takes the
                // shown note's model first (its observation loop may not have run yet).
                area.refreshChrome()
                area.chrome.menuPresenter = InlineMenuPresenter()
                area.chrome.openMenu(menu)
                HolderSessionStore.printLog("debug notes-menu \(name) open=\(area.chrome.presentedMenu != nil)")
            }
        }
    }

    /// Shows a note on NOTES (Notebook mode) and waits for the editor; nil when it does not show.
    private func debugShowNote(_ raw: String) async -> NoteID? {
        guard let id = NoteID(rawValue: raw), let area = notesArea else { return nil }
        shell.area = .notes
        if noteEditor.noteID != id {
            area.reveal(id)
            await waitFor { self.noteEditor.noteID == id && !area.hasPendingRequests }
        }
        return noteEditor.noteID == id ? id : nil
    }

    /// An image path of the shown note by its file name or as written.
    private func debugImagePath(_ asset: String) -> String? {
        noteEditor.imagePaths.first { $0 == asset || ($0 as NSString).lastPathComponent == asset }
    }

    /// `-codd-show annotate:<id>:<asset>`.
    func debugShowAnnotate(_ argument: String) async {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, await debugShowNote(parts[0]) != nil, let path = debugImagePath(parts[1]), let area = notesArea else {
            HolderSessionStore.printLog("debug show annotate: no such note or image")
            return
        }
        let opened = await area.annotate(path)
        // Mock mode reproduces the artboard's state: item 1 selected.
        if opened, holderStore == nil, let screen = area.annotateSession?.screen, screen.document.item(1) != nil { screen.selection = 1 }
        HolderSessionStore.printLog("debug show annotate image=\(parts[1]) opened=\(opened)")
    }

    /// `-codd-notes-annotate <id>:<asset>:<json file>`: the `完成` path with that block.
    private func debugAnnotate(_ spec: String, area: NotesAreaViewController) async {
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            HolderSessionStore.printLog("debug notes-annotate refused spec")
            return
        }
        if let refusal = RealModeOptions.protectedPathReason(parts[2]) {
            HolderSessionStore.printLog("debug notes-annotate refused (\(refusal))")
            return
        }
        guard let json = try? String(contentsOfFile: parts[2], encoding: .utf8), let annotations = ImageAnnotations.decode(json) else {
            HolderSessionStore.printLog("debug notes-annotate unreadable json")
            return
        }
        guard await debugShowNote(parts[0]) != nil, let path = debugImagePath(parts[1]), await area.annotate(path),
              let session = area.annotateSession else {
            HolderSessionStore.printLog("debug notes-annotate: no such note or image")
            return
        }
        let document = NoteAnnotateMapping.document(annotations, imageSize: session.screen.document.pixelSize)
        await area.finishAnnotate(document)
        HolderSessionStore.printLog("debug notes-annotate id=\(parts[0]) items=\(document.items.count) "
                                    + "annotated=\(area.lastAnnotate?.annotatedPNG ?? "-")")
    }

    /// `-codd-notes-set <id>:<key>=<value>`.
    private func debugSetMetadata(_ spec: String, area: NotesAreaViewController) async {
        guard let colon = spec.firstIndex(of: ":") else { return }
        let raw = String(spec[..<colon])
        let assignment = spec[spec.index(after: colon)...]
        guard let equals = assignment.firstIndex(of: "=") else { return }
        let key = String(assignment[..<equals]).lowercased()
        let value = String(assignment[assignment.index(after: equals)...])
        let change: MetadataChange?
        switch key {
        case "ai": change = NoteAIAccess(rawValue: value.lowercased()).map { .ai($0) }
        case "scope": change = value.lowercased() == "global" ? .scope(.global, primaryProject: nil) : .scope(.project, primaryProject: value)
        case "kind": change = NoteKind(rawValue: value.lowercased()).map { .kind($0) }
        case "pinned": change = ["yes", "true", "1"].contains(value.lowercased()) ? .pinned(true) : .pinned(false)
        case "tags": change = .tags(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        default: change = nil
        }
        guard let change, await debugShowNote(raw) != nil else {
            HolderSessionStore.printLog("debug notes-set refused key=\(key)")
            return
        }
        let ok = await area.applyChange(change, label: key)
        HolderSessionStore.printLog("debug notes-set id=\(raw) key=\(key) ok=\(ok)")
    }

    private func debugPasteImage(_ path: String) async {
        if let refusal = RealModeOptions.protectedPathReason(path) {
            HolderSessionStore.printLog("debug notes-paste-image refused (\(refusal))")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            HolderSessionStore.printLog("debug notes-paste-image unreadable name=\(url.lastPathComponent)")
            return
        }
        if shell.area != .notes { shell.area = .notes }
        await waitFor { self.noteEditor.hasContent }
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.png.identifier
        let ref = await noteEditor.paste(MarkdownPastedImage(data: data, typeIdentifier: type, suggestedName: url.lastPathComponent, fileURL: url))
        HolderSessionStore.printLog("debug notes-paste-image asset=\(ref?.relativePath ?? "-") resized=\(ref?.resized ?? false) "
                                    + "w=\(Int(ref?.pixelSize.width ?? 0)) h=\(Int(ref?.pixelSize.height ?? 0))")
    }

    /// Polls `condition` for up to `seconds` (DEBUG flags wait for async UI steps).
    func waitFor(seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
    }
    #endif
}

/// D36: menu items that share a key with another area's command or belong to one area. AppKit
/// takes the first enabled item with a key equivalent, so each pair that shares a key is made
/// mutually exclusive here (⌘⏎ 允許 only in the sessions area; ⌘E / ⌘F / ⌘⇧A / ⌘⇧C only on
/// NOTES, the editor items only in the Notebook mode), and nothing fires while an input method
/// composes. Pure (unit-tested).
struct MenuAreaRules: Equatable {
    var area: RailArea
    var hasMarkedText = false
    var noteShown = false
    var noteComposing = false
    var notesReady = false
    var canAllow = false
    /// The NOTES area's mode (Annotate covers the editor).
    var notesMode: NotesMode = .notebook
    /// The shown note is on disk (D3: a draft has no reference and no images yet).
    var noteSaved = false
    var noteHasImage = false
    /// The Files mode (I3) has a selected tab, and it is a file with its code view.
    var fileTabShown = false
    var fileTabHasEditor = false
    var fileComposing = false

    /// ⌘W belongs to the Files mode's 關閉分頁 (the window's 關閉分頁或視窗 steps aside), also
    /// while an input method composes (then neither acts).
    var closeTabOwnsCommandW: Bool { area == .notes && notesMode == .files && fileTabShown }

    func isEnabled(_ action: Selector?) -> Bool? {
        let notebook = area == .notes && notesMode == .notebook
        let filesMode = area == .notes && notesMode == .files
        let quiet = !hasMarkedText && !fileComposing
        switch action {
        case #selector(AppDelegate.saveFile(_:)):
            return filesMode && fileTabShown && quiet
        case #selector(AppDelegate.closeFileTab(_:)):
            return filesMode && fileTabShown && quiet
        case #selector(AppDelegate.filterFiles(_:)):
            return filesMode && quiet
        case #selector(AppDelegate.findInFile(_:)):
            return filesMode && fileTabHasEditor && quiet
        case #selector(AppDelegate.allowCurrentSession(_:)):
            return area == .sessions && canAllow
        case #selector(AppDelegate.quickNote(_:)):
            return !hasMarkedText
        case #selector(AppDelegate.toggleNoteSource(_:)):
            return notebook && noteShown && !noteComposing && !hasMarkedText
        case #selector(AppDelegate.searchNotes(_:)):
            return notebook && notesReady && !hasMarkedText
        case #selector(AppDelegate.annotateImage(_:)):
            return notebook && noteSaved && noteHasImage && !noteComposing && !hasMarkedText
        case #selector(AppDelegate.copyNoteReference(_:)):
            return area == .notes && noteSaved && !noteComposing && !hasMarkedText
        default:
            return nil
        }
    }
}
