import AppKit
import CoddFiles
import CoddNotebookUI
import CoddNotes
import CoddUI
import Foundation

/// Maps CoddNotes data and the session store onto CoddNotebookUI's value models (the Notebook
/// artboard): formatted times, day sections, chips, the chrome's pills and the info panel. Pure
/// functions of their inputs, so the texts are unit-tested.
@MainActor
struct NotebookPresenter {
    /// A layout project as the notebook names it (BY PROJECT, chips, the scope pill).
    struct ProjectInfo: Equatable {
        var name: String
        var tag: NotebookTag?
        /// The layout project's folder as notes link it (`~`-abbreviated); nil for a path no layout
        /// project has.
        var path: String? = nil
    }

    let now: Date
    let calendar: Calendar
    let store: any SessionStore
    /// `~`-abbreviated project path → layout project (by realpath; `projectInfo(_:)` falls back to
    /// the last path component without color).
    let projects: [String: ProjectInfo]

    init(now: Date, timeZone: TimeZone, store: any SessionStore, projects: [String: ProjectInfo]) {
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.store = store
        self.projects = projects
    }

    /// Every layout project by its resolved path (`~` expanded, symlinks resolved, cached by the
    /// caller between rebuilds since it touches the file system).
    static func layoutProjects(store: any SessionStore, resolve: (String) -> String) -> [String: ProjectInfo] {
        var out: [String: ProjectInfo] = [:]
        for group in store.groups {
            for id in group.projectIDs {
                guard let project = store.project(id), !project.isTransient else { continue }
                let info = ProjectInfo(name: project.name, tag: group.isUngrouped ? nil : group.color.flatMap { NotebookTag(rawValue: $0.rawValue) },
                                       path: PathFormat.abbreviateHome(project.cwd))
                out[resolve(project.cwd)] = info
            }
        }
        return out
    }

    /// `~/x` expanded, `.` / `..` removed, symlinks resolved.
    nonisolated static func resolvePath(_ path: String) -> String {
        URL(fileURLWithPath: PathFormat.expandTilde(path)).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func projectInfo(_ path: String, resolve: (String) -> String) -> ProjectInfo {
        if let info = projects[resolve(path)] { return info }
        let name = PathFormat.lastComponent(path)
        return ProjectInfo(name: name.isEmpty ? path : name, tag: nil)
    }

    // MARK: Times

    func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: now) }

    func hourMinute(_ date: Date) -> String { ClockFormat.hourMinute(date, calendar: calendar) }

    func monthDay(_ date: Date) -> String {
        let p = calendar.dateComponents([.month, .day], from: date)
        return "\(p.month ?? 0)/\(p.day ?? 0)"
    }

    /// The day section a date falls in: `Today · 10/15`, `Yesterday`, `M/D` within the last 7 days,
    /// then `YYYY-MM` per month (local time; the view draws them uppercase).
    func dayLabel(_ date: Date) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today · \(monthDay(now))" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return monthDay(date) }
        let p = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", p.year ?? 0, p.month ?? 0)
    }

    /// Whether a section label names a single day (rows then show only the time).
    static func isDaySection(_ label: String) -> Bool { !(label.count == 7 && label.dropFirst(4).first == "-") }

    /// `昨天 18:20`, `10:05`, `10/12 09:41` (HISTORY rows, AI ACTIVITY).
    func shortStamp(_ date: Date) -> String {
        if isToday(date) { return hourMinute(date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(hourMinute(date))"
        }
        return "\(monthDay(date)) \(hourMinute(date))"
    }

    // MARK: Lists column

    func lists(counts: NotesCounts, selected: SmartList, searchText: String, projectsExpanded: Bool, filesExpanded: Bool,
               recent: [RecentFile], notesPath: String, host: HostSummary, filesReason: String? = nil, cleanupCount: Int? = nil,
               resolve: (String) -> String) -> NotebookListsModel {
        var smart: [NotebookSmartList: Int] = [:]
        smart[.inbox] = counts.inbox
        smart[.pinned] = counts.pinned
        smart[.prompts] = counts.prompts
        smart[.stale] = counts.stale
        smart[.archive] = counts.archive
        smart[.trash] = counts.trash
        var rows: [NotebookProjectRow] = []
        for (path, count) in counts.byProject {
            let info = projectInfo(path, resolve: resolve)
            rows.append(NotebookProjectRow(id: path, name: info.name, tag: info.tag, count: count))
        }
        rows.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var files: [NotebookFileRow] = []
        for file in recent.prefix(10) {
            let name = (file.path as NSString).lastPathComponent
            let hint = (file.root as NSString).lastPathComponent
            files.append(NotebookFileRow(id: file.path, name: name, rootHint: hint))
        }
        return NotebookListsModel(counts: smart, selected: Self.listID(selected), projects: rows, projectsExpanded: projectsExpanded,
                                  recentFiles: files, filesExpanded: filesExpanded, filesDisabledReason: filesReason,
                                  cleanupCount: cleanupCount, notesPath: notesPath,
                                  mcp: NotebookMCPLine(running: host.mcpRunning, clients: "\(host.mcpClients) clients"),
                                  searchText: searchText)
    }

    /// LOCAL FILES without a file editor (a rig without one).
    static let filesReason = "這裡無法開啟檔案"

    static func listID(_ list: SmartList) -> NotebookListID {
        switch list {
        case .inbox: .smart(.inbox)
        case .pinned: .smart(.pinned)
        case .prompts: .smart(.prompts)
        case .stale: .smart(.stale)
        case .archive: .smart(.archive)
        case .trash: .smart(.trash)
        case .project(let path): .project(path)
        }
    }

    static func smartList(_ id: NotebookListID) -> SmartList {
        switch id {
        case .smart(.inbox): .inbox
        case .smart(.pinned): .pinned
        case .smart(.prompts): .prompts
        case .smart(.stale): .stale
        case .smart(.archive): .archive
        case .smart(.trash): .trash
        case .project(let path): .project(path)
        }
    }

    /// The crumb / list title (`Inbox`, a project name).
    func listTitle(_ list: SmartList, resolve: (String) -> String) -> String {
        switch list {
        case .inbox: NotebookSmartList.inbox.title
        case .pinned: NotebookSmartList.pinned.title
        case .prompts: NotebookSmartList.prompts.title
        case .stale: NotebookSmartList.stale.title
        case .archive: NotebookSmartList.archive.title
        case .trash: NotebookSmartList.trash.title
        case .project(let path): projectInfo(path, resolve: resolve).name
        }
    }

    // MARK: Note list

    static func sort(_ sort: NoteSort) -> NoteListSort {
        switch sort {
        case .updated: .updated
        case .created: .created
        case .title: .title
        }
    }

    static func noteSort(_ sort: NoteListSort) -> NoteSort {
        switch sort {
        case .updated: .updated
        case .created: .created
        case .title: .title
        }
    }

    func noteList(rows summaries: [NoteSummary], list: SmartList, sort: NoteSort, selected: NoteID?, total: Int,
                  resolve: (String) -> String) -> NoteListModel {
        let title = listTitle(list, resolve: resolve)
        var sections: [NoteListSection] = []
        if sort == .title {
            sections = summaries.isEmpty ? [] : [NoteListSection(day: nil, rows: summaries.map { row($0, daySection: false) })]
        } else {
            for summary in summaries {
                let date = sort == .created ? summary.metadata.created : summary.metadata.updated
                let label = dayLabel(date)
                let daySection = Self.isDaySection(label)
                let entry = row(summary, daySection: daySection)
                if sections.last?.day == label {
                    sections[sections.count - 1].rows.append(entry)
                } else {
                    sections.append(NoteListSection(day: label, rows: [entry]))
                }
            }
        }
        let shown = summaries.count
        let end: String? = shown == 0 ? nil
            : shown >= total ? "// \(title.uppercased()) \(shown) 則 · 已全部顯示" : "// 顯示最近 \(shown) 則，共 \(total) 則"
        return NoteListModel(title: title, count: "\(total)", sort: Self.sort(sort), sections: sections, selectedID: selected?.rawValue,
                             endComment: end, emptyText: list == .inbox ? NotebookCopy.noNotesEmpty : "// 這個清單沒有筆記")
    }

    func searchList(_ search: NotesService.SearchState, selected: NoteID?) -> NoteListModel {
        let terms = Self.searchTerms(search.query)
        let rows = search.hits.map { hit -> NoteListRow in
            var entry = row(hit.summary, daySection: false)
            entry.snippet = hit.snippet
            entry.snippetHighlights = hit.highlights
            entry.titleHighlights = Self.ranges(of: terms, in: entry.title)
            return entry
        }
        return NoteListModel(title: "Search", count: "\(rows.count)", showsSort: false,
                             sections: rows.isEmpty ? [] : [NoteListSection(day: nil, rows: rows)], selectedID: selected?.rawValue,
                             endComment: rows.isEmpty ? nil : "// \(search.query) · \(rows.count) 則", emptyText: NotebookCopy.noMatchEmpty)
    }

    /// The plain terms of a query (`#tag` and quotes dropped) for title highlights.
    static func searchTerms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func ranges(of terms: [String], in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        for term in terms {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: term, options: [.caseInsensitive, .widthInsensitive], range: search)
                guard found.location != NSNotFound, found.length > 0 else { break }
                out.append(found)
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// One `.nb-nrow` (Notebook artboard; D14 `已送出 HH:mm`, §3.2 kinds).
    func row(_ summary: NoteSummary, daySection: Bool) -> NoteListRow {
        let m = summary.metadata
        let time: String
        if let sent = m.sentAt, m.kind == .prompt {
            time = "已送出 " + (isToday(sent) ? hourMinute(sent) : monthDay(sent))
        } else {
            time = daySection ? hourMinute(m.updated) : (isToday(m.updated) ? hourMinute(m.updated) : monthDay(m.updated))
        }
        var extra: String?
        if m.kind == .scratch, let at = summary.archivesAt {
            let days = max(0, Int(ceil(at.timeIntervalSince(now) / 86_400)))
            extra = "\(days)d 後封存"
        }
        var warnings: [String] = []
        if summary.flags.contains(.duplicateID) { warnings.append("ID 重複") }
        if summary.flags.contains(.unparsableFrontmatter) { warnings.append("frontmatter") }
        return NoteListRow(id: m.id.rawValue, title: m.title, time: time, snippet: summary.snippet.replacingOccurrences(of: "\n", with: " "),
                           kind: Self.badge(m), link: linkChip(m), extra: extra, ai: Self.access(m.ai), pinned: m.pinned,
                           stale: summary.staleSince != nil, warnings: warnings, actions: Self.rowActions(m))
    }

    /// A row's right-click menu: the ⋯ menu's pin and lifecycle items for that note (the user's
    /// note 2026-10-20). The ids go to `NotesAreaViewController.rowAction`.
    static func rowActions(_ m: NoteMetadata) -> [NoteRowAction] {
        switch m.state {
        case .active:
            [NoteRowAction(id: "pin", title: m.pinned ? "取消釘選" : "釘選"),
             NoteRowAction(id: "archive", title: "封存"),
             NoteRowAction(id: "trash", title: "移到垃圾桶", isDestructive: true)]
        case .archived:
            [NoteRowAction(id: "unarchive", title: "取消封存"),
             NoteRowAction(id: "trash", title: "移到垃圾桶", isDestructive: true)]
        case .trashed:
            [NoteRowAction(id: "restore", title: "還原")]
        }
    }

    static func badge(_ m: NoteMetadata) -> NotebookKindBadge {
        switch m.kind {
        case .note: .note
        case .scratch: .scratch
        case .prompt: m.isPromptDraft ? .promptDraft : .prompt
        }
    }

    static func access(_ access: NoteAIAccess) -> NotebookAIAccess {
        switch access {
        case .off: .off
        case .read: .read
        case .append: .append
        }
    }

    static func kind(_ kind: NoteKind) -> NotebookNoteKind {
        switch kind {
        case .note: .note
        case .prompt: .prompt
        case .scratch: .scratch
        }
    }

    /// The AI menu's choice as a frontmatter value (I1b).
    static func noteAccess(_ access: NotebookAIAccess) -> NoteAIAccess {
        switch access {
        case .off: .off
        case .read: .read
        case .append: .append
        }
    }

    /// ⋯ › 類型's choice as a frontmatter value (I1b).
    static func noteKind(_ kind: NotebookNoteKind) -> NoteKind {
        switch kind {
        case .note: .note
        case .prompt: .prompt
        case .scratch: .scratch
        }
    }

    static func state(_ state: SessionState) -> NotebookSessionState {
        NotebookSessionState(rawValue: state.rawValue) ?? .unknown
    }

    static func tag(_ tag: TagColor?) -> NotebookTag? { tag.flatMap { NotebookTag(rawValue: $0.rawValue) } }

    /// The row's second chip: the first linked session CODD knows, else the primary project.
    private func linkChip(_ m: NoteMetadata) -> NoteRowLinkChip? {
        for id in m.links.sessions {
            if let session = session(id) { return .session(title: session.title, state: Self.state(session.state)) }
        }
        if let path = m.links.projects.first {
            let info = projectInfo(path, resolve: Self.resolvePath)
            return .project(name: info.name, tag: info.tag)
        }
        return nil
    }

    /// A linked session by its lowercase id (store ids are compared case-insensitively).
    func session(_ id: String) -> SessionVM? {
        store.session(id) ?? store.allSessions.first { $0.id.lowercased() == id.lowercased() }
    }

    // MARK: Chrome

    /// A live CODD claude session as a send target (`orb-toolkit-frontend · busy 6m`).
    func target(_ session: SessionVM) -> NotebookSessionTarget {
        let project = store.project(session.projectID)?.name ?? ""
        let style = StateStyle.of(session)
        let detail = [project, "\(style.label.lowercased()) \(DurationFormat.compact(now.timeIntervalSince(session.stateSince)))"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return NotebookSessionTarget(id: session.id, title: session.title, state: Self.state(session.state), detail: detail,
                                     tag: Self.tag(session.tag))
    }

    /// Live CODD claude sessions (externals are never targets, D14).
    var liveTargets: [SessionVM] {
        store.allSessions.filter { $0.kind == .claude && !$0.external && $0.state.isLive }
            .sorted { $0.stateSince > $1.stateSince }
    }

    /// D14 default: the first live linked session, else the most recently viewed live one.
    func defaultTarget(links: NoteLinks?, viewed: [SessionID]) -> SessionVM? {
        let live = liveTargets
        if let links {
            for id in links.sessions {
                if let session = live.first(where: { $0.id.lowercased() == id.lowercased() }) { return session }
            }
        }
        for id in viewed {
            if let session = live.first(where: { $0.id == id }) { return session }
        }
        return nil
    }

    /// The scope menu: `Global`, the note's own projects, then the other layout projects (picking
    /// one links it as the primary project, D17 `scope: project`).
    func scopeOptions(_ m: NoteMetadata?, resolve: (String) -> String) -> [NotebookScopeOption] {
        var options = [NotebookScopeOption.global]
        var seen = Set<String>()
        for path in m?.links.projects ?? [] {
            let info = projectInfo(path, resolve: resolve)
            options.append(NotebookScopeOption(id: path, title: info.name, isProject: true, tag: info.tag))
            seen.insert(resolve(path))
        }
        let others = projects.filter { !seen.contains($0.key) && $0.value.path != nil }.map(\.value)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for info in others {
            guard let path = info.path else { continue }
            options.append(NotebookScopeOption(id: path, title: info.name, isProject: true, tag: info.tag))
        }
        return options
    }

    func saveState(_ state: NoteEditorController.SaveState) -> NoteSaveState {
        switch state {
        case .none: .unsaved
        case .saved(let at): .saved(isToday(at) ? hourMinute(at) : "\(monthDay(at)) \(hourMinute(at))")
        case .unsaved: .unsaved
        case .saving: .saving
        }
    }

    // MARK: Info panel

    func info(_ selected: NotesService.Selected, retention: (stale: Int?, archive: Int?), selectedHistory: String? = nil,
              thumbnail: (String) -> NSImage? = { _ in nil }, resolve: (String) -> String) -> NoteInfoPanelModel {
        let m = selected.document.metadata
        var links: [NoteInfoLinkRow] = []
        for id in m.links.sessions {
            if let session = session(id) {
                links.append(.session(id: id, title: session.title, state: Self.state(session.state)))
            } else {
                links.append(.session(id: id, title: "session \(id.prefix(8))", state: .stopped))
            }
        }
        for path in m.links.projects {
            let info = projectInfo(path, resolve: resolve)
            links.append(.project(id: path, name: info.name, tag: info.tag))
        }
        let activity = aiActivity(selected.activity)
        let history = selected.history.enumerated().map { index, snapshot -> NoteHistoryRow in
            let label = Self.historyLabel(snapshot, isOldest: index == selected.history.count - 1 && selected.history.count > 1)
            return NoteHistoryRow(id: snapshot.id, time: shortStamp(snapshot.takenAt), label: index == 0 ? label + " · 目前" : label,
                                  isCurrent: index == 0, isSelected: index != 0 && snapshot.id == selectedHistory)
        }
        // The images the body shows first (the artboard's ASSETS order), each group as C1 lists it.
        let images = selected.assets.filter { !$0.isOriginalCopy }.enumerated()
            .sorted { ($0.element.referenced ? 0 : 1, $0.offset) < ($1.element.referenced ? 0 : 1, $1.offset) }.map(\.element)
        let bytes = images.reduce(0) { $0 + $1.bytes }
        let thumbs = images.prefix(6).map { asset in
            let name = (asset.relativePath as NSString).lastPathComponent
            return NoteAssetThumb(id: asset.relativePath, name: name, image: thumbnail(name),
                                  orientation: asset.pixelSize.width > asset.pixelSize.height ? .landscape : .portrait)
        }
        return NoteInfoPanelModel(links: links, aiActivity: activity, historyCount: "\(selected.history.count) 版", history: history,
                                  assetsSummary: images.isEmpty ? "—" : "\(images.count) 張 · \(Self.bytes(bytes))",
                                  assets: Array(thumbs), retention: retentionRows(selected.summary, staleDays: retention.stale),
                                  pinned: m.pinned, actionsDisabledReason: m.state == .active || Self.isArchived(m.state) ? nil : Self.trashedReason)
    }

    static func isArchived(_ state: NoteState) -> Bool {
        if case .archived = state { return true }
        return false
    }

    /// The info panel's actions on a note in TRASH (restore it first).
    static let trashedReason = "這則筆記在垃圾桶：先從 ⋯ 還原"

    /// `讀取 · <session> · 10:12` and `附加 —` (the newest of each kind; D20).
    func aiActivity(_ events: [NoteActivityEvent]) -> [NoteAIActivityRow] {
        func newest(_ actions: Set<String>) -> NoteActivityEvent? { events.first { actions.contains($0.action) } }
        var rows: [NoteAIActivityRow] = []
        if let read = newest(["read", "expand", "url"]) {
            let kind: NoteAIActivityKind = read.action == "expand" ? .expand : read.action == "url" ? .url : .read
            rows.append(NoteAIActivityRow(kind: kind, who: read.sessionTitle ?? read.client ?? "AI", time: shortStamp(read.at)))
        } else {
            rows.append(NoteAIActivityRow(kind: .read))
        }
        if let write = newest(["append", "write"]) {
            rows.append(NoteAIActivityRow(kind: write.action == "write" ? .write : .append, who: write.sessionTitle ?? write.client ?? "AI",
                                          time: shortStamp(write.at)))
        } else {
            rows.append(NoteAIActivityRow(kind: .append))
        }
        return rows
    }

    static func historyLabel(_ snapshot: NoteSnapshotInfo, isOldest: Bool) -> String {
        switch snapshot.reason {
        case "ai-append"?: "AI 附加"
        case "ai-write"?: "AI 改寫"
        case "restore"?: "還原前"
        case "trash"?: "刪除前"
        case "external"?: "外部變更"
        case "condense"?: "濃縮前"
        case "unsaved"?: "未儲存的編輯"
        default: isOldest ? "建立" : "你"
        }
    }

    /// RETENTION: 最後活動, 標示 stale, 自動封存 (D29).
    func retentionRows(_ summary: NoteSummary, staleDays: Int?) -> [NoteRetentionRow] {
        var rows = [NoteRetentionRow(term: "最後活動", value: DurationFormat.ago(summary.lastActivity, now: now))]
        if let exempt = summary.exempt {
            let why: String = switch exempt {
            case .pinned: "已釘選"
            case .linkedLiveSession: "session 使用中"
            case .readByLiveSession: "session 讀取過"
            case .kept: "保留中"
            }
            rows.append(NoteRetentionRow(term: "自動封存", value: "豁免 · \(why)", ok: true))
            return rows
        }
        if summary.staleSince != nil {
            rows.append(NoteRetentionRow(term: "標示 stale", value: "已標示"))
        } else if let staleDays {
            let due = summary.lastActivity.addingTimeInterval(TimeInterval(staleDays) * 86_400)
            rows.append(NoteRetentionRow(term: "標示 stale", value: "\(max(0, Int(ceil(due.timeIntervalSince(now) / 86_400)))) 天後"))
        }
        if let at = summary.archivesAt {
            rows.append(NoteRetentionRow(term: "自動封存", value: "\(max(0, Int(ceil(at.timeIntervalSince(now) / 86_400)))) 天後"))
        } else if case .active = summary.metadata.state {
            rows.append(NoteRetentionRow(term: "自動封存", value: "不會"))
        }
        return rows
    }

    /// `1.4 MB` (binary units, like the artboard).
    static func bytes(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1024 * 1024 { return String(format: "%.1f MB", value / 1024 / 1024) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(count) B"
    }

    /// The chips row under the title (Notebook artboard `.nb-meta`).
    func chips(_ m: NoteMetadata?, draft: NoteDraft?, resolve: (String) -> String) -> NoteChipsRowModel {
        let kind: NotebookKindBadge = m.map(Self.badge) ?? (draft?.kind == .scratch ? .scratch : .note)
        let links = m?.links ?? draft?.links ?? NoteLinks()
        let session = links.sessions.lazy.compactMap { self.session($0) }.first.map(target)
        let project = links.projects.first.map { path -> NotebookScopeOption in
            let info = projectInfo(path, resolve: resolve)
            return NotebookScopeOption(id: path, title: info.name, isProject: true, tag: info.tag)
        }
        let updated: String
        if let m {
            updated = "updated " + (isToday(m.updated) ? hourMinute(m.updated) : monthDay(m.updated))
        } else {
            updated = "尚未儲存"
        }
        // Tags are a frontmatter change: only a note on disk and not in TRASH takes them (D3).
        let editable = m.map { $0.state == .active || Self.isArchived($0.state) } ?? false
        return NoteChipsRowModel(kind: kind, tags: m?.tags ?? [], session: session, project: project, updated: updated, allowsAddTag: editable)
    }
}
