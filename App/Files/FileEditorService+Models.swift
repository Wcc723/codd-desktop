import AppKit
import CoddCodeEditor
import CoddFileEditorUI
import CoddFiles
import CoddUI

/// The FileEditor artboard's models (C6 views) built from the service's state. Read inside the
/// Files mode's observation loops, so every model follows exactly the state it shows.
extension FileEditorService {
    // MARK: Tree

    func treeModel() -> FileTreeModelView? {
        guard let workspace = current else { return nil }
        _ = touchRevision
        let session = session(for: workspace)
        var git: FileTreeGitHead?
        if let status = workspace.status, workspace.isRepo {
            git = FileTreeGitHead(branch: status.branch ?? "(detached)", ahead: status.ahead, behind: status.behind,
                                  modified: workspace.changedPaths.count)
        }
        let newest = workspace.touches.values.max { $0.at < $1.at }
        let rows: [FileTreeRow]
        var currentID: String?
        if workspace.filter.trimmingCharacters(in: .whitespaces).isEmpty {
            rows = flatten(workspace, folder: "", depth: 0)
            currentID = selectedRowID(workspace)
        } else {
            rows = workspace.filterResults.map { relative in fileRow(workspace, relative: relative, depth: 0, hint: true) }
            currentID = workspace.filterResults.indices.contains(workspace.filterIndex) ? workspace.filterResults[workspace.filterIndex] : nil
        }
        var line: FileTreeSessionLine?
        if let session {
            let touched = workspace.touches.values.filter { $0.session.lowercased() == session.id.lowercased() }
            let last = touched.max { $0.at < $1.at }
            let style = StateStyle.of(session)
            let detail = "AI 改 \(touched.count)" + (last.map { " · \(hourMinute($0.at))" } ?? "")
            line = FileTreeSessionLine(lamp: style.glyph, lampColor: style.color, tag: session.tag?.color, title: session.title, detail: detail)
        }
        return FileTreeModelView(project: workspace.name, git: git, aiCount: workspace.touches.count,
                                 aiColor: newest.flatMap { store.session($0.session)?.tag?.color }, filter: workspace.filter,
                                 recent: recentRows(workspace), recentCollapsed: workspace.recentCollapsed, rows: rows,
                                 projectCollapsed: workspace.projectCollapsed, currentID: currentID,
                                 footPath: PathFormat.short(PathFormat.abbreviateHome(workspace.rootPath)), session: line)
    }

    /// The row of the open file (`.cur`).
    private func selectedRowID(_ workspace: FilesWorkspace) -> String? {
        guard let tab = workspace.selectedTab else { return nil }
        if tab.noteID != nil { return tab.id }
        guard let url = tab.url else { return nil }
        return workspace.relativePath(url.path)
    }

    /// The expanded folders' rows, depth first in the tree's order (names only, D24).
    func flatten(_ workspace: FilesWorkspace, folder: String, depth: Int) -> [FileTreeRow] {
        guard let entries = workspace.children[folder] else { return [] }
        var rows: [FileTreeRow] = []
        for entry in entries {
            if entry.isOverflow {
                rows.append(FileTreeRow(entry: entry, depth: depth))
                continue
            }
            let relative = entry.relativePath
            let ignored = FileTreeModel.isIgnored(relative, in: workspace.ignored)
            if entry.isDirectory {
                let expanded = workspace.expanded.contains(relative)
                var row = FileTreeRow(entry: entry, depth: depth, expanded: expanded,
                                      containsChanges: !ignored && workspace.folderContainsChanges(relative))
                row.ignored = ignored
                rows.append(row)
                if expanded { rows += flatten(workspace, folder: relative, depth: depth + 1) }
            } else {
                var row = fileRow(workspace, relative: relative, depth: depth, hint: false)
                row.ignored = ignored
                rows.append(row)
            }
        }
        return rows
    }

    /// A file row with its `M` badge and `AI` chip (`hint`: the folder after the name, for ⌘P and
    /// RECENT).
    func fileRow(_ workspace: FilesWorkspace, relative: String, depth: Int, hint: Bool) -> FileTreeRow {
        let name = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        return FileTreeRow(id: relative, name: name, depth: depth, dirHint: hint ? (folder.isEmpty ? "/" : folder) : nil,
                           modified: workspace.change(relative) != nil, ai: aiChip(workspace.touches[relative]))
    }

    /// D26: the session's tag color, a bone outline when it has none.
    func aiChip(_ touch: AITouch?) -> AIChip? {
        guard let touch else { return nil }
        return AIChip(color: store.session(touch.session)?.tag?.color)
    }

    /// RECENT: the recent files of this root (newest first) and the open note tabs, at most 8.
    func recentRows(_ workspace: FilesWorkspace) -> [FileTreeRow] {
        var dated: [(Date, FileTreeRow)] = []
        for item in recent {
            guard let relative = workspace.relativePath(item.path), !relative.isEmpty else { continue }
            dated.append((item.openedAt, fileRow(workspace, relative: relative, depth: 0, hint: true)))
        }
        for tab in workspace.tabs where tab.noteID != nil {
            dated.append((tab.openedAt, FileTreeRow(id: tab.id, name: tab.title + ".md", dirHint: "notebook")))
        }
        return dated.sorted { $0.0 > $1.0 }.prefix(8).map(\.1)
    }

    // MARK: Tabs

    func tabsModel() -> EditorTabStripModel? {
        guard let workspace = current else { return nil }
        _ = touchRevision
        let tabs = workspace.tabs.map { tab -> EditorTab in
            if let note = tab.noteID {
                // The note autosaves (I1a): its dot follows the editor's save state.
                let saving = noteEditor.map { $0.saveState == .unsaved || $0.saveState == .saving } ?? false
                let dirty = noteEditor?.noteID == note && saving
                return EditorTab(id: tab.id, title: tab.title + ".md", isNote: true, isDirty: dirty, isPreview: tab.isPreview)
            }
            return EditorTab(id: tab.id, title: tab.title, isDirty: tab.isDirty, isPreview: tab.isPreview, ai: aiChip(touch(of: tab)))
        }
        return EditorTabStripModel(tabs: tabs, selectedID: workspace.selectedTabID, session: sessionPill(workspace))
    }

    /// `● ▪ 打卡頁 RWD 調整 Edit · 6m ⌘9` while the root is a CODD session's cwd.
    func sessionPill(_ workspace: FilesWorkspace) -> EditorSessionPill? {
        guard let session = session(for: workspace) else { return nil }
        let style = StateStyle.of(session)
        let since = DurationFormat.compact(max(0, store.clock.now().timeIntervalSince(session.stateSince)))
        let detail = session.tool.map { "\($0) · \(since)" } ?? since
        return EditorSessionPill(lamp: style.glyph, lampColor: style.color, tag: session.tag?.color, title: session.title, detail: detail,
                                 shortcut: sessionNumber(session.id).flatMap { $0 <= 9 ? "⌘\($0)" : nil })
    }

    // MARK: Toolbar

    func toolbarModel() -> EditorToolbarModel? {
        guard let workspace = current, let tab = workspace.selectedTab else { return nil }
        if tab.noteID != nil {
            return EditorToolbarModel(crumbs: [EditorCrumb("notebook", kind: .folder), EditorCrumb(tab.title + ".md", kind: .file)])
        }
        let relative = tab.url.flatMap { workspace.relativePath($0.path) } ?? tab.title
        guard let state = tab.state else {
            return EditorToolbarModel(crumbs: EditorCrumb.path(relative))
        }
        let options = baselines(of: tab)
        let aiStart = state.aiBaseline.map { hourMinute($0.at) }
        var titles = EditorToolbarModel.baselineTitles(lastSave: hourMinute(state.savedAt), aiStart: aiStart)
        if options.contains(.disk) { titles.append("基準：磁碟上的版本") }
        let enabled = options.map { $0 != .head || workspace.isRepo || !workspace.gitLoaded }
        return EditorToolbarModel(crumbs: EditorCrumb.path(relative), aiChangeCount: tab.showAI ? tab.hunks.count : nil,
                                  showAIChanges: tab.showAI, baselines: titles, baselineEnabled: enabled,
                                  selectedBaseline: options.firstIndex(of: tab.baseline) ?? 0)
    }

    // MARK: Banner (D25)

    func bannerModel() -> DiskChangeBannerModel? {
        guard let tab = current?.selectedTab, let state = tab.state, let pending = state.pendingDisk else { return nil }
        let session = pending.aiSession.map { store.session($0)?.title ?? "Claude session" }
        return .fileChanged(aiSession: session, time: session == nil ? nil : hourMinute(pending.at), showsUnsaved: state.isDirty,
                            canReload: state.canReload)
    }

    // MARK: Status items

    func statusModel() -> EditorStatusModel? {
        guard let workspace = current else { return nil }
        let branch = workspace.isRepo ? workspace.status?.branch : nil
        let ahead = workspace.status?.ahead ?? 0
        let session = session(for: workspace).map { (tag: $0.tag?.color, title: $0.title) }
        guard let tab = workspace.selectedTab else {
            return EditorStatusModel(branch: branch, ahead: ahead, session: session, encoding: "—", lineEnding: "—", language: "—",
                                     indentation: "—", saved: .none)
        }
        if tab.noteID != nil, let editor = noteEditor {
            let saved: EditorStatusModel.Saved
            switch editor.saveState {
            case .saved(let date): saved = .saved(hourMinute(date))
            case .unsaved, .saving: saved = .dirty
            case .none: saved = .none
            }
            return EditorStatusModel(branch: branch, ahead: ahead, session: session, line: editor.caret.line, column: editor.caret.column,
                                     language: "Markdown", saved: saved)
        }
        guard let state = tab.state else {
            return EditorStatusModel(branch: branch, ahead: ahead, session: session, encoding: "—", lineEnding: "—", language: "—",
                                     indentation: "—", saved: .none)
        }
        let saved: EditorStatusModel.Saved = state.decoded.readOnly ? .readOnly : (state.isDirty ? .dirty : .saved(hourMinute(state.savedAt)))
        let language = tab.plainMode ? CodeLanguage.plain.displayName : tab.language.displayName
        return EditorStatusModel(decoded: state.decoded, branch: branch, ahead: ahead, session: session, line: tab.caret.line,
                                 column: tab.caret.column, language: language, saved: saved)
    }
}
