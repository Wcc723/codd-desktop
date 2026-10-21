import AppKit
import CoddDialogsUI
import CoddNotebookUI
import CoddNotes

/// M4 I2b: notes to sessions (D14) from the Notebook and the session pane's `✎ NOTES` drawer, the
/// Claude Code / Codex registrations (D22) and the external MCP token's rotation (D23), the
/// `registration` dump key and the DEBUG flags of this step (§6).
extension AppDelegate {
    // MARK: Wiring

    /// The send path and the drawer on the main window's pane (after the window exists).
    func wireSending(_ window: MainWindowController) {
        let sending = noteSending
        sending.editor = noteEditor
        sending.composer = { [weak window] in window?.pane.composer }
        sending.send = { [weak window] input, target in window?.pane.sendInput(input, to: target) ?? false }
        sending.revealComposer = { [weak window] id in window?.pane.revealComposer(for: id) }
        // Post-M4 (review attachments-6): drafts made with 插入全文 name annotated copies in the cache.
        let notes = sending.notes
        window.pane.composer.annotatedCopies = AnnotatedCopies(folder: notes.annotatedFolder.path) { [weak notes] text in
            await notes?.restoreAnnotatedCopies(in: text)
        }
        #if DEBUG
        sending.onChange = { [weak self] in self?.scheduleStateDump() }
        #endif
        notesArea?.sending = sending
        let drawer = notesDrawer
        drawer.view.onClose = { [weak window, weak drawer] in
            guard let id = drawer?.sessionID else { return }
            window?.pane.setNotesDrawer(open: false, for: id)
        }
        drawer.view.onOpenNote = { [weak self] raw in self?.openNoteFromPalette(raw) }
        drawer.view.onInsertRef = { [weak self] raw in self?.sendFromDrawer(.ref, raw) }
        drawer.view.onSendFull = { [weak self] raw in self?.sendFromDrawer(.submit, raw) }
        drawer.view.onNewNote = { [weak self, weak drawer] in
            guard let id = drawer?.sessionID else { return }
            self?.startLinkedNote(for: id)
        }
        drawer.view.onQuickNote = { [weak self] in self?.startQuickNote() }
        // The drawer editor's messages while its document is off screen (review data-1).
        drawer.onToastElsewhere = { [weak self] text in self?.showDrawerEditorToast(text) }
        window.pane.notesDrawer = drawer
    }

    /// A drawer card's `插入引用` / `送出全文`: to the session whose drawer it is, the toast in the
    /// main window.
    private func sendFromDrawer(_ action: NoteSending.Action, _ raw: String) {
        guard let id = NoteID(rawValue: raw), let session = notesDrawer.sessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.noteSending.perform(action, note: id, to: session)
            _ = self.mainWindow?.showToast(self.noteSending.toast(for: outcome), undo: nil)
            // The card a draft now references gets its amber border.
            self.notesDrawer.rebuild()
        }
    }

    /// The drawer's `+ 新筆記（連結此 session）`: a NOTE linked to the session and its project, shown
    /// on NOTES with the caret in its title (on disk at its first typing, D3).
    func startLinkedNote(for id: SessionID) {
        var links = NoteLinks()
        if let session = sessionStore.session(id), !session.external {
            links.sessions = [id.lowercased()]
            if let project = sessionStore.project(session.projectID), !project.isTransient { links.projects = [project.cwd] }
        }
        showMainWindow(nil)
        shell.area = .notes
        notesArea?.newLinkedNote(links: links)
    }

    // MARK: Registrations (D22)

    /// A REGISTRATIONS / 註冊 row's button (STATUS, Settings): Claude Code plans and opens dialog B,
    /// Codex opens its snippet; a disabled reason that reached here (a stale model) is a toast.
    func mcpRegistrationPressed(_ id: String, on target: NSWindow?) {
        guard let registration = mcpRegistration else { NSSound.beep(); return }
        switch id {
        case "claude-code":
            if let reason = registration.claudeCodeReason {
                _ = mainWindow?.showToast(reason, undo: nil)
                return
            }
            presentMCPRegistration(MCPRegistrationRows.claudeCodeKind(mcpService?.claudeCode ?? .unknown,
                                                                      exposed: mcpService?.claudeCodeExposed ?? false), on: target)
        case "codex":
            presentCodexSnippet(on: target)
        default:
            break
        }
    }

    /// Dialog B for a registration plan over `target` (the main window when nil).
    func presentMCPRegistration(_ kind: MCPRegistrationService.Kind, on target: NSWindow?) {
        guard registrationDialog == nil, let registration = mcpRegistration else { return }
        if target == nil { showMainWindow(nil) }
        guard let window = target ?? mainWindow?.window else { return }
        let dialog = MCPRegistrationDialog(service: registration, kind: kind)
        dialog.onToast = { [weak self] text in _ = self?.mainWindow?.showToast(text, undo: nil) }
        dialog.onFinish = { [weak self] in
            self?.registrationDialog = nil
            self?.refreshRegistrationSurfaces()
        }
        registrationDialog = dialog
        Task { await dialog.present(on: window) }
    }

    /// `註冊到 Codex`: the `config.toml` snippet with `[複製]` (D39: through `CoddPasteboard`) and
    /// `[關閉]`; CODD never writes `~/.codex`.
    func presentCodexSnippet(on target: NSWindow?) {
        guard codexSheet == nil, let registration = mcpRegistration else { return }
        guard let snippet = registration.codexSnippet() else {
            _ = mainWindow?.showToast(registration.codexReason ?? SettingsInfoBuilder.noServer, undo: nil)
            return
        }
        if target == nil { showMainWindow(nil) }
        guard let window = target ?? mainWindow?.window else { return }
        let view = SnippetDialogView(title: MCPRegistrationService.codexTitle, message: MCPRegistrationService.codexMessage, snippet: snippet,
                                     onCopy: { [weak self] in self?.copyCodexSnippet() },
                                     onClose: { [weak self] in self?.closeCodexSnippet() })
        codexSheet = (DialogPresenter.presentSheet(view, on: window), view)
    }

    /// `[複製]`: the snippet (it carries the external token) only through the D39 pasteboard rule.
    func copyCodexSnippet() {
        guard let sheet = codexSheet else { return }
        pasteboard.write(sheet.view.snippet, userAction: true, concealed: true)
        sheet.view.markCopied()
        HolderSessionStore.printLog("mcp codex-snippet copied")
    }

    func closeCodexSnippet() {
        guard let sheet = codexSheet else { return }
        codexSheet = nil
        DialogPresenter.dismiss(sheet.window)
    }

    // MARK: Token rotation (D23)

    /// `[輪替]` (STATUS, Settings): a confirmation sheet first (registered clients must register
    /// again, old note URLs stop working), then the rotation.
    func confirmRotateMCPToken(on target: NSWindow?) {
        guard let registration = mcpRegistration, registration.canRotate else { NSSound.beep(); return }
        if target == nil { showMainWindow(nil) }
        guard let window = target ?? mainWindow?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = MCPRegistrationService.rotateQuestion
        alert.informativeText = MCPRegistrationService.rotateDetail
        alert.addButton(withTitle: "輪替")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.rotateMCPToken() }
        }
    }

    /// The rotation itself (the confirmation's `[輪替]`, DEBUG `-codd-mcp-rotate`).
    func rotateMCPToken() async {
        guard let registration = mcpRegistration else { return }
        let error = await registration.rotateToken()
        _ = mainWindow?.showToast(error ?? "已輪替 MCP token · 已註冊的 client 需要重新註冊", undo: nil)
        refreshRegistrationSurfaces()
    }

    /// STATUS and Settings show the new registration state at once.
    func refreshRegistrationSurfaces() {
        statusController?.rebuild()
        settings?.coordinator.refreshInfo()
        notesArea?.refreshChrome()
        refreshOnboardingRegistration()
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    // MARK: Dump

    /// §6 `registration {claudeCode {state, plan {added, removed}, applied {backup}}, tokenRotatedAt}`.
    var registrationDump: [String: Any]? { mcpRegistration?.dumpObject }

    #if DEBUG
    // MARK: DEBUG flags (§6, I2b)

    /// `-codd-show split`, `-codd-notes-send <id>:ref|full|submit`; then (real mode)
    /// `-codd-mcp-register-plan claude-code|remove` (+ `-codd-mcp-register-apply YES`) and
    /// `-codd-mcp-rotate YES`, in that order.
    func runSendDebugActions() async {
        let o = realOptions
        if o.showKeyword == "split" { await debugShowSplit() }
        if let spec = o.notesSend { await debugNotesSend(spec) }
        await runRegistrationDebugActions()
    }

    /// The Split artboard: the shown session with its drawer open; in mock mode s9 with the
    /// composer's draft (`… 參考 codd://note/rwd-punch-k7x2`) and the bottom terminal.
    private func debugShowSplit() async {
        if holderStore == nil { shell.currentSessionID = "s9" }
        shell.area = .sessions
        await waitFor(seconds: 10) { self.shell.currentSessionID != nil }
        guard let id = shell.currentSessionID, let main = mainWindow else {
            HolderSessionStore.printLog("debug show split: no session")
            return
        }
        main.show(id)
        try? await Task.sleep(for: .milliseconds(200))
        main.pane.setNotesDrawer(open: true, for: id)
        if holderStore == nil {
            let draft = "iPhone SE 寬度下的打卡按鈕改成固定在底部，參考 codd://note/\(MockNotes.n1ID)"
            if main.pane.composer.draftReferences(id).isEmpty { main.pane.composer.appendToDraft(draft, for: id) }
            if !shell.pane(for: id).composerOpen { shell.setComposerOpen(true, in: id) }
            if !shell.pane(for: id).panelOpen { main.pane.toggleBottomTerminal() }
            main.pane.surface.focus()
        }
        let builds = notesDrawer.builds
        notesDrawer.rebuild()
        await waitFor(seconds: 5) { self.notesDrawer.builds > builds }
        HolderSessionStore.printLog("debug show split session=\(id) drawer=\(main.pane.isNotesDrawerShown) "
                                    + "cards=\(notesDrawer.view.model.cards.count)")
    }

    /// `-codd-notes-send <id>:ref|full|submit` to the shown CODD claude session, once it runs (and,
    /// for submit, once its PTY streams past STARTING, like `-codd-composer-send`).
    private func debugNotesSend(_ spec: String) async {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let note = NoteID(rawValue: parts[0]), let action = NoteSending.Action(rawValue: parts[1].lowercased()) else {
            HolderSessionStore.printLog("debug notes-send refused spec")
            return
        }
        func shownClaude() -> SessionVM? {
            guard let id = shell.currentSessionID, let session = sessionStore.session(id), session.kind == .claude,
                  !session.external, session.state.isLive else { return nil }
            return session
        }
        await waitFor(seconds: 15) { shownClaude() != nil }
        guard let session = shownClaude() else {
            HolderSessionStore.printLog("debug notes-send no live claude session shown")
            return
        }
        if action == .submit {
            let id = session.id
            await waitFor(seconds: 10) {
                self.sessionStore.session(id)?.state != .starting && (self.holderStore?.connection(for: id)?.phase ?? .connected) == .connected
            }
            // Let the child switch on bracketed paste and raw mode before the paste.
            try? await Task.sleep(for: .milliseconds(800))
        }
        await notes.refreshNow()
        let outcome = await noteSending.perform(action, note: note, to: session.id)
        let name: String = switch outcome {
        case .inserted: "inserted"
        case .sent: "sent"
        case .refused(let reason): "refused(\(reason))"
        }
        HolderSessionStore.printLog("debug notes-send id=\(note.rawValue) action=\(action.rawValue) outcome=\(name)")
        scheduleStateDump()
    }

    /// `-codd-mcp-register-plan`, `-codd-mcp-register-apply`, `-codd-mcp-rotate`: the dialog's path
    /// without the dialog, once the hook server listens with its MCP routes.
    private func runRegistrationDebugActions() async {
        let o = realOptions
        guard let registration = mcpRegistration, o.mcpRegisterPlan != nil || o.mcpRotate else { return }
        await waitFor(seconds: 15) { (self.mcpService?.running ?? false) && self.holderStore?.hooks?.config?.mcpToken != nil }
        await mcpService?.refreshRegistrations()
        if let name = o.mcpRegisterPlan {
            let kind: MCPRegistrationService.Kind = name == "remove" ? .remove : .register
            switch await registration.plan(kind) {
            case .success(let plan):
                HolderSessionStore.printLog("debug mcp-register-plan action=\(kind.rawValue) added=\(plan.addedLines) "
                                            + "removed=\(plan.removedLines) upToDate=\(plan.upToDate)")
                if o.mcpRegisterApply {
                    switch await registration.apply(plan) {
                    case .success(let result):
                        HolderSessionStore.printLog("debug mcp-register-apply wrote=\(result.wrote) backup=\(result.backup?.lastPathComponent ?? "-")")
                    case .failure(let failure):
                        HolderSessionStore.printLog("debug mcp-register-apply failed (\(MCPRegistrationService.errorKind(failure)))")
                    }
                }
            case .failure(let failure):
                HolderSessionStore.printLog("debug mcp-register-plan failed (\(MCPRegistrationService.errorKind(failure)))")
            }
        }
        if o.mcpRotate {
            await rotateMCPToken()
            HolderSessionStore.printLog("debug mcp-rotate rotated=\(registration.tokenRotatedAt != nil) "
                                        + "state=\(MCPService.registrationName(mcpService?.claudeCode ?? .unknown))")
        }
        scheduleStateDump()
    }
    #endif
}
