import AppKit
import CoddUI

/// Native NSMenu context menus (Liquid Glass chrome; Phosphor only in the swatch row) and the
/// session / group actions they trigger. Acting on a selected row acts on the whole selection.
extension SidebarViewController: SidebarOutlineActions {
    func contextMenu(forRow row: Int) -> NSMenu? {
        guard let kind = kind(atRow: row) else { return nil }
        switch kind {
        case .session(let clicked, _):
            // D6: an external row has its own small menu (nothing of it can be changed from CODD);
            // a selection mixing both acts on the CODD sessions only.
            if let session = store.session(clicked), session.external { return externalMenu(session) }
            let ids = targetSessions(clickedRow: row).filter { store.session($0)?.external == false }
            return sessionMenu(ids, row: row)
        case .group(let id): return groupMenu(id, row: row)
        case .project(let id): return projectMenu(id)
        default: return nil
        }
    }

    /// The same session menu for the pane's `⋯` button (uses the tree row when visible).
    func menu(forSession id: SessionID) -> NSMenu? {
        var row = outline.row(forItem: item(for: .session(id, .tree)))
        if row < 0, let mirror = snapshot.allNodes().map(\.node).first(where: { $0.sessionID == id }) {
            row = outline.row(forItem: item(for: mirror))
        }
        return row >= 0 ? contextMenu(forRow: row) : nil
    }

    // MARK: Session menu

    private func sessionMenu(_ ids: [SessionID], row: Int) -> NSMenu? {
        let sessions = ids.compactMap(store.session)
        guard let first = sessions.first else { return nil }
        let single = sessions.count == 1
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: single ? "Session · \(first.title)" : "已選 \(sessions.count) 個 session"))

        let rename = action("✎  重新命名", key: "\r", modifiers: []) { [weak self] in self?.beginRename(row: row) }
        rename.isEnabled = single
        menu.addItem(rename)

        let swatches = NSMenuItem()
        swatches.view = SwatchMenuItemView(current: single ? first.tag : nil) { [weak self] tag in
            self?.store.setTag(tag, sessions: ids)
        }
        menu.addItem(swatches)

        let allPinned = sessions.allSatisfy(\.isPinned)
        menu.addItem(action(allPinned ? "取消釘選" : "釘選到 PINNED", key: "p") { [weak self] in
            self?.store.setPinned(!allPinned, sessions: ids)
        })
        let resume = action("⟲  接續對話 resume") { [weak self] in self?.store.resume(first.id) }
        resume.isEnabled = single && !first.state.isLive && first.kind == .claude
        // SidebarStates B: a running session cannot be resumed; the key column says why.
        if single, first.state.isLive, first.kind == .claude { resume.badge = NSMenuItemBadge(string: "執行中") }
        menu.addItem(resume)
        let restart = action("↻  重新開始（新對話）") { [weak self] in self?.store.restart(first.id) }
        restart.isEnabled = single
        menu.addItem(restart)
        let terminal = action("↗  在 Terminal.app 開啟") { [weak self] in self?.openInTerminal(first.projectID) }
        terminal.isEnabled = single
        menu.addItem(terminal)
        let resumeCommand = action("$  複製 resume 指令") { Self.copy("claude --resume \(first.claudeSessionID ?? first.id)") }
        resumeCommand.isEnabled = single && first.kind == .claude
        menu.addItem(resumeCommand)
        menu.addItem(action(single ? "複製 session ID" : "複製 \(sessions.count) 個 session ID") {
            Self.copy(ids.joined(separator: "\n"))
        })

        menu.addItem(.separator())
        menu.addItem(action("封存", key: "\u{8}") { [weak self] in self?.archive(ids) })
        let stop = action("■  停止", key: ".", danger: true) { [weak self] in self?.confirmStop(ids) }
        stop.isEnabled = sessions.contains { $0.state.isLive }
        menu.addItem(stop)
        menu.addItem(.separator())
        let remove = action(single ? "✕  移除 session…" : "✕  移除 \(sessions.count) 個 session…", danger: true) { [weak self] in
            self?.confirmRemove(ids)
        }
        menu.addItem(remove)
        let delete = action("✕  刪除對話紀錄…", danger: true) { [weak self] in self?.confirmDeleteHistory(first.id) }
        // D23: a CODD claude session that is not running and whose conversation no other claude
        // runs. A shell has no conversation (`✕ 移除 session…` is its item).
        let inUse = single && first.kind == .claude && !first.state.isLive && store.isConversationInUse(first.id)
        delete.isEnabled = single && first.kind == .claude && !first.state.isLive && !inUse
        delete.badge = NSMenuItemBadge(string: inUse ? "執行中" : "需輸入名稱確認")
        menu.addItem(delete)
        return menu
    }

    /// SidebarStates B for an external row: `複製 session ID` (its Claude session id),
    /// `$  複製 resume 指令`, `↗  在 Terminal.app 開啟`.
    private func externalMenu(_ session: SessionVM) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Session · \(session.title)"))
        let claudeID = session.externalInfo?.claudeSessionID ?? session.claudeSessionID
        let copyID = action("複製 session ID") { if let claudeID { Self.copy(claudeID) } }
        copyID.isEnabled = claudeID != nil
        menu.addItem(copyID)
        let resume = action("$  複製 resume 指令") { if let claudeID { Self.copy("claude --resume \(claudeID)") } }
        resume.isEnabled = claudeID != nil
        menu.addItem(resume)
        let projectID = session.projectID
        menu.addItem(action("↗  在 Terminal.app 開啟") { [weak self] in self?.openInTerminal(projectID) })
        return menu
    }

    // MARK: Group / project menus

    /// SidebarStates D: `重新命名 ⏎` · color row · `+ 新增 session（此群組）…` · `全部收合` ·
    /// `清理已停止` · `刪除群組（專案移到未分類）`. Also the header's `⋯` button.
    func groupMenu(_ id: GroupID, row: Int) -> NSMenu? {
        guard let group = store.group(id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Group · \(group.name)"))
        let rename = action("✎  重新命名", key: "\r", modifiers: []) { [weak self] in self?.beginRename(row: row) }
        rename.isEnabled = !group.isUngrouped
        menu.addItem(rename)
        if !group.isUngrouped {
            let swatches = NSMenuItem()
            swatches.view = SwatchMenuItemView(current: group.color) { [weak self] color in
                self?.store.setGroupColor(color, group: id)
            }
            menu.addItem(swatches)
        }
        if let onNewSession {
            menu.addItem(action("+  新增 session（此群組）…") {
                var form = NewSessionForm()
                form.groupID = group.isUngrouped ? nil : id
                onNewSession(form)
            })
        }
        menu.addItem(action("▾  全部收合") { [weak self] in self?.collapseProjects(of: id) })
        let stopped = stoppedSessions(inGroup: id)
        let cleanup = action(stopped.isEmpty ? "清理已停止" : "清理已停止 (\(stopped.count))") { [weak self] in self?.cleanupStopped(inGroup: id) }
        cleanup.isEnabled = !stopped.isEmpty
        menu.addItem(cleanup)
        menu.addItem(.separator())
        let delete = action("✕  刪除群組（專案移到未分類）", danger: true) { [weak self] in self?.store.deleteGroup(id) }
        delete.isEnabled = !group.isUngrouped
        menu.addItem(delete)
        return menu
    }

    private func projectMenu(_ id: ProjectID) -> NSMenu? {
        guard let project = store.project(id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Project · \(project.name)"))
        if project.isTransient {
            // D6: a folder only externals run in: it can be added (keeping them) or its path copied.
            menu.addItem(action("+  加入為專案") { [weak self] in self?.store.promoteTransient(id) })
            menu.addItem(action("複製路徑") { Self.copy(PathFormat.expandTilde(project.cwd)) })
            return menu
        }
        if let onNewSession {
            for (title, kind) in [("+  新增 Claude session…", SessionKind.claude), ("+  新增 Shell session…", .shell)] {
                menu.addItem(action(title) {
                    var form = NewSessionForm()
                    form.path = project.cwd
                    form.kind = kind
                    onNewSession(form)
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(action("✎  重新命名…") { [weak self] in self?.renameProject(id) })
        menu.addItem(action("↗  在 Terminal.app 開啟") { [weak self] in self?.openInTerminal(id) })
        menu.addItem(action("複製路徑") { Self.copy(PathFormat.expandTilde(project.cwd)) })
        if let restore = ArchiveRestoreMenuModel.make(project: id, store: store) {
            // D19: `封存 n ▸` → `還原「…」` per archived session, then `全部還原`.
            menu.addItem(.separator())
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for entry in restore.entries {
                submenu.addItem(action(entry.title) { [weak self] in self?.restore([entry.id]) })
            }
            submenu.addItem(.separator())
            let all = restore.entries.map(\.id)
            submenu.addItem(action(ArchiveRestoreMenuModel.restoreAllTitle) { [weak self] in self?.restore(all) })
            let parent = NSMenuItem(title: restore.title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(action("✕  移除專案…", danger: true) { [weak self] in self?.confirmRemoveProject(id) })
        return menu
    }

    // MARK: Actions

    func hoverDidChange(row: Int) { hoverCard.hoverChanged(row: row) }
    func outlineMouseMoved() { hoverCard.mouseMoved() }
    func outlineInteracted(scroll: Bool) {
        hoverCard.dismissForInteraction(scroll: scroll)
    }

    func beginRenameSelected() {
        let rows = outline.selectedRowIndexes
        guard rows.count == 1, let row = rows.first else { return }
        beginRename(row: row)
    }

    func archiveSelected() {
        archive(targetSessions(clickedRow: outline.selectedRow))
    }

    func beginRename(row: Int) {
        guard let kind = kind(atRow: row) else { return }
        switch kind {
        case .session(let id, _):
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView,
                  let session = store.session(id) else { return }
            // An external's title is Claude's (registry `name`): not renamed from CODD.
            guard !session.external else { NSSound.beep(); return }
            cell.setRenaming(true)
            renamer.begin(in: cell, frame: cell.titleFrame, text: session.title, font: Typeface.mono(12.5),
                          commit: { [weak self] text in self?.store.renameSession(id, to: text) },
                          onEnd: { [weak cell] in cell?.setRenaming(false) })
        case .group(let id):
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? GroupHeaderCellView,
                  let group = store.group(id), !group.isUngrouped else { return }
            cell.setRenaming(true)
            renamer.begin(in: cell, frame: cell.nameFrame, text: group.name, font: Typeface.mono(11),
                          commit: { [weak self] text in self?.store.renameGroup(id, to: text) },
                          onEnd: { [weak cell] in cell?.setRenaming(false) })
        default:
            break
        }
    }

    /// The toast counts what was archived: externals are never archived (D6).
    func archive(_ ids: [SessionID]) {
        let archivable = Self.archivable(ids, in: store)
        guard !archivable.isEmpty else {
            if !ids.isEmpty { NSSound.beep() }
            return
        }
        let undo = store.archive(archivable)
        showToast(Self.archiveToastText(count: archivable.count), undo: undo, countdown: Self.archiveUndoSeconds)
    }

    /// SidebarStates C: the archive UNDO toast counts down from 5 s.
    static let archiveUndoSeconds = 5

    /// `還原「…」` / `全部還原`: back into the project (after its CODD sessions), shown.
    func restore(_ ids: [SessionID]) {
        store.unarchive(ids)
        applyNow()
        if ids.count == 1, let id = ids.first, store.session(id) != nil {
            let row = outline.row(forItem: item(for: .session(id, .tree)))
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
    }

    /// The CODD sessions among `ids` (each once).
    static func archivable(_ ids: [SessionID], in store: any SessionStore) -> [SessionID] {
        var seen = Set<SessionID>()
        return ids.filter { id in store.session(id).map { !$0.external } ?? false && seen.insert(id).inserted }
    }

    static func archiveToastText(count: Int) -> String { "✕ \(count) 個 session 已封存" }

    func stop(_ ids: [SessionID]) { store.stop(ids) }

    /// `停止` (menu, ⌘., selection bar): asks first (`要停止「…」嗎？`) when something still runs;
    /// externals are never stopped from CODD. Beeps when nothing could be stopped.
    func confirmStop(_ ids: [SessionID]) {
        let sessions = ids.compactMap(store.session).filter { !$0.external && $0.state.isLive }
        guard !sessions.isEmpty else { NSSound.beep(); return }
        let targets = sessions.map(\.id)
        guard let window = view.window, window.attachedSheet == nil else { NSSound.beep(); return }
        let text = Self.stopConfirmation(sessions)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.info
        let stop = alert.addButton(withTitle: "停止")
        stop.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        Task { @MainActor [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            self?.store.stop(targets)
        }
    }

    /// The stop sheet's text (tests).
    static func stopConfirmation(_ sessions: [SessionVM]) -> (message: String, info: String) {
        let message = sessions.count == 1 ? "要停止「\(sessions[0].title)」嗎？" : "要停止 \(sessions.count) 個 session 嗎？"
        let info: String
        if sessions.allSatisfy({ $0.kind == .claude }) {
            info = "只會結束 claude 的程式，對話紀錄還在，之後可以用 RESUME 接續。"
        } else if sessions.allSatisfy({ $0.kind == .shell }) {
            info = "shell 與其中執行的程式會結束，之後可以用 RESTART 重新開始。"
        } else {
            info = "程式會結束；claude 的對話紀錄還在，之後可以接續。"
        }
        return (message, info)
    }

    func collapseProjects(of id: GroupID) {
        guard let group = store.group(id) else { return }
        for pid in group.projectIDs {
            store.setCollapsed(true, project: pid)
            let it = item(for: .project(pid))
            if outline.isItemExpanded(it) { outline.animator().collapseItem(it) }
        }
        refreshBlockEdges()
    }

    private func openInTerminal(_ projectID: ProjectID) {
        guard let project = store.project(projectID) else { return }
        let path = PathFormat.expandTilde(project.cwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showToast("找不到資料夾：\(project.cwd)", undo: nil)
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Removing asks first; when a session still runs, its process and holder end with it.
    func confirmRemove(_ ids: [SessionID]) {
        let sessions = ids.compactMap(store.session)
        guard let window = view.window, let first = sessions.first else { return }
        let running = sessions.filter(\.state.isLive)
        let alert = NSAlert()
        alert.alertStyle = running.isEmpty ? .warning : .critical
        alert.messageText = sessions.count == 1 ? "從 CODD 移除「\(first.title)」？" : "從 CODD 移除 \(sessions.count) 個 session？"
        var info = "Claude 的對話紀錄（~/.claude）不會刪除。"
        if !running.isEmpty {
            info = "\(running.count) 個 session 還在執行：移除會結束它的程式與 holder。" + info
        }
        alert.informativeText = info
        let remove = alert.addButton(withTitle: running.isEmpty ? "移除" : "結束並移除")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        Task { @MainActor [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            if let current = self?.shell.currentSessionID, ids.contains(current) { self?.shell.currentSessionID = nil }
            self?.store.removeSessions(ids)
        }
    }

    private func confirmRemoveProject(_ id: ProjectID) {
        guard let window = view.window, let project = store.project(id) else { return }
        let sessions = project.sessionIDs.compactMap(store.session)
        let running = sessions.filter(\.state.isLive).count
        let alert = NSAlert()
        alert.alertStyle = running == 0 ? .warning : .critical
        alert.messageText = "從 CODD 移除專案「\(project.name)」？"
        var info = "資料夾本身與 Claude 的對話紀錄不會刪除。"
        if !sessions.isEmpty { info = "其中 \(sessions.count) 個 session 會一起移除" + (running > 0 ? "（\(running) 個執行中，會被結束）。" : "。") + info }
        alert.informativeText = info
        let remove = alert.addButton(withTitle: running == 0 ? "移除" : "結束並移除")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        Task { @MainActor [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            if let current = self?.shell.currentSessionID, project.sessionIDs.contains(current) { self?.shell.currentSessionID = nil }
            self?.store.removeProject(id)
        }
    }

    private func renameProject(_ id: ProjectID) {
        guard let window = view.window, let project = store.project(id) else { return }
        let alert = NSAlert()
        alert.messageText = "重新命名專案"
        alert.informativeText = project.cwd
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = project.name
        alert.accessoryView = field
        alert.addButton(withTitle: "重新命名")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        Task { @MainActor [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            self?.store.renameProject(id, to: field.stringValue)
        }
    }

    /// D23: the transcript goes to the Trash after typing the session name (SidebarStates B).
    private func confirmDeleteHistory(_ id: SessionID) {
        guard let window = view.window, let session = store.session(id), !session.external, session.kind == .claude else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "刪除「\(session.title)」的對話紀錄？"
        alert.informativeText = "對話紀錄會移到垃圾桶（可從垃圾桶還原），之後無法在 CODD 接續。請輸入 session 名稱確認。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = session.title
        alert.accessoryView = field
        let delete = alert.addButton(withTitle: "移到垃圾桶")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        let title = session.title
        Task { @MainActor [weak self] in
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return }
            guard field.stringValue.trimmingCharacters(in: .whitespaces) == title else {
                self?.showToast("名稱不符，未刪除", undo: nil)
                return
            }
            guard let store = self?.store, await store.deleteHistory(id) else { return }
            if let self, self.shell.currentSessionID == id { self.shell.currentSessionID = nil }
            self?.showToast("✕ 對話紀錄已移到垃圾桶", undo: nil)
        }
    }

    // MARK: Helpers

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], danger: Bool = false,
                        handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if danger {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: Palette.danger,
            ])
        }
        return item
    }
}

/// D19 `封存 n ▸` submenu of a project: `還原「<title>」` per archived session (most recently active
/// first), then `全部還原`. Nil when the project has no archived session to restore.
struct ArchiveRestoreMenuModel: Equatable {
    struct Entry: Equatable {
        var id: SessionID
        var title: String
    }

    static let restoreAllTitle = "全部還原"
    var title: String
    var entries: [Entry]

    @MainActor
    static func make(project id: ProjectID, store: any SessionStore) -> ArchiveRestoreMenuModel? {
        let archived = store.archivedSessions(inProject: id)
        guard !archived.isEmpty else { return nil }
        return ArchiveRestoreMenuModel(title: "封存 \(archived.count)",
                                       entries: archived.map { Entry(id: $0.id, title: "還原「\($0.title)」") })
    }
}
