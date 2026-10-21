import CoddCore
import Foundation
import CoddUI

/// The ⌘K quick switch's results (QuickSwitch artboard, D14). Pure: built from a query and a
/// snapshot of what can be switched to, ranked with CoddCore's `FuzzyMatcher`.
///
/// - Sessions (≤ 8): CODD and external, ranked by title, then by location (`group / project`,
///   half weight). Empty query: NEEDS YOU first, then the most recently viewed, then sidebar order.
/// - Notes (≤ 5, M4 I1b): active notes ranked by title, then by `#tag`s (half weight); row
///   `打卡頁 RWD 跑版紀錄` · `note · #rwd #punch` · `10:05`. Empty query: the 3 most recently updated.
/// - Projects (≤ 5): known ones (`n live · group`; transient ones `外部`), then `.claude.json`
///   folders CODD does not know (`未加入 · 來自 ~/.claude.json`, `+ 加入`); by name, then path (half
///   weight). Not listed for an empty query.
/// - Actions (≤ 6): `在 <project> 新增 session` and `在 <project> 開啟終端機` for the highlighted (or
///   best) session or project, then `切換帳號到 #2 藍鵲` for the first account in R7 order that can be
///   switched to (QuickSwitch artboard; M3), then the §3 list and the other accounts matched by
///   title (a few common ones when empty).
struct QuickSwitchModel: Equatable {
    enum Section: String, Equatable, CaseIterable {
        case sessions, notes, projects, actions

        var title: String {
            switch self {
            case .sessions: "Sessions"
            case .notes: "Notes"
            case .projects: "Projects"
            case .actions: "Actions"
            }
        }

        var limit: Int {
            switch self {
            case .sessions: 8
            case .notes: 5
            case .projects: 5
            case .actions: 6
            }
        }

        /// Notes listed with an empty query (the most recently updated).
        static let recentNotes = 3
    }

    enum Action: Equatable {
        case newSessionIn(path: String, name: String)
        case openTerminalIn(path: String, name: String)
        case newSession, newShellSession, addProjectFolder, newGroup, toggleSidebar, bottomTerminal, composer, newShellTab
        case status, settings
        /// The ⌘N sheet on `接續先前對話` (I6), found by typing (not in the empty-query list).
        case resumeConversation
        /// `切換帳號到 #2 藍鵲` with `5h 剩 98% · 1w 剩 46%` (a user switch, D5).
        case switchAccount(id: AccountID, name: String, quota: String)

        var title: String {
            switch self {
            case .newSessionIn(_, let name): "在 \(name) 新增 session"
            case .openTerminalIn(_, let name): "在 \(name) 開啟終端機"
            case .newSession: "新增 session…"
            case .newShellSession: "新增 Shell session…"
            case .addProjectFolder: "加入專案資料夾…"
            case .newGroup: "新增群組"
            case .toggleSidebar: "隱藏 / 顯示側欄"
            case .bottomTerminal: "下方終端機"
            case .composer: "Composer"
            case .newShellTab: "新增終端機"
            case .status: "STATUS"
            case .settings: "設定…"
            case .resumeConversation: "接續先前對話…"
            case .switchAccount(_, let name, _): "切換帳號到 \(name)"
            }
        }

        /// The right-hand hint (`⌘N`, `$ zsh`).
        var hint: String? {
            switch self {
            case .newSessionIn, .newSession: "⌘N"
            case .openTerminalIn: "$ zsh"
            case .toggleSidebar: "⌘\\"
            case .bottomTerminal: "⌘J"
            case .composer: "⌘L"
            case .newShellTab: "⌘T"
            case .settings: "⌘,"
            case .resumeConversation: "claude --resume"
            case .switchAccount(_, _, let quota): quota
            case .newShellSession, .addProjectFolder, .newGroup, .status: nil
            }
        }

        /// The §3 list after the contextual two.
        static let general: [Action] = [.newSession, .newShellSession, .resumeConversation, .addProjectFolder, .newGroup,
                                        .toggleSidebar, .bottomTerminal, .composer, .newShellTab, .status, .settings]
        /// With an empty query.
        static let common: [Action] = [.newSession, .newShellSession, .bottomTerminal, .composer]
    }

    enum Item: Equatable {
        case session(SessionID)
        /// A note by its id (opening it switches to NOTES and selects it).
        case note(String)
        case project(ProjectID)
        /// A `.claude.json` folder CODD does not know (`+ 加入`).
        case suggestion(String)
        case action(Action)
    }

    struct Row: Equatable {
        var item: Item
        var section: Section
        var title: String
        /// Matched characters of `title` (UTF-16 ranges) drawn in amber.
        var spans: [TextSpan]
        /// Dim text before the title (a project's parent folder `orb-toolkit-suite/`).
        var prefix: String?
        /// `藍鵲·網站 / orb-toolkit-frontend`, `3 live · 藍鵲 · 網站`, `未加入 · 來自 ~/.claude.json`.
        var detail: String
        /// The group square before the detail.
        var detailTag: TagColor?
        /// The session's own tag square before the title.
        var tag: TagColor?
        var glyph: String
        var state: SessionState?
        var unreachable = false
        /// Duration start (sessions; nil hides the duration).
        var since: Date?
        /// `⌘9` (sessions) or the action's hint.
        var shortcut: String?
        /// `+ 加入` (suggestions).
        var chip: String?
        var score = 0
    }

    struct Group: Equatable {
        var section: Section
        var rows: [Row]
    }

    /// What can be switched to (built by `Input.make` from the stores).
    struct Input {
        struct Session {
            var id: SessionID
            var title: String
            var location: String
            var groupColor: TagColor?
            var tag: TagColor?
            var state: SessionState
            var unreachable: Bool
            var since: Date
            var number: Int?
            var external: Bool
            var projectID: ProjectID
            var kind: SessionKind
        }

        struct Project {
            var id: ProjectID
            var name: String
            var path: String
            var groupName: String?
            var groupColor: TagColor?
            var live: Int
            var transient: Bool
        }

        struct Suggestion {
            var path: String
            var name: String
        }

        /// An active note (M4 I1b), newest update first in `notes`.
        struct Note {
            var id: String
            var title: String
            /// Without `#`.
            var tags: [String]
            /// `note`, `prompt`, `scratch` (the sub line's first word).
            var kind: String
            /// `10:05` today, else `10/12` (formatted by the app's notes clock).
            var time: String
        }

        /// An account a user switch can go to (not the active one, not disabled, not the pseudo one).
        struct Account {
            var id: AccountID
            var name: String
            /// `5h 剩 98% · 1w 剩 46%`.
            var quota: String
        }

        /// Sidebar order.
        var sessions: [Session] = []
        /// Sidebar order.
        var projects: [Project] = []
        var suggestions: [Suggestion] = []
        /// Active notes, most recently updated first.
        var notes: [Note] = []
        /// Switchable accounts in R7 order.
        var accounts: [Account] = []
        /// Most recently viewed first (the shown session first).
        var viewed: [SessionID] = []
        var currentSessionID: SessionID?
    }

    var query: String
    var groups: [Group]

    var rows: [Row] { groups.flatMap(\.rows) }
    var count: Int { groups.reduce(0) { $0 + $1.rows.count } }

    // MARK: Building

    /// - Parameter context: the project the contextual actions are about (the highlighted session's
    ///   or project's); nil uses the best match, else the shown session's project.
    static func build(query rawQuery: String, input: Input, context: ProjectID? = nil) -> QuickSwitchModel {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = sessionRows(query: query, input: input)
        let notes = noteRows(query: query, input: input)
        let projects = query.isEmpty ? [] : projectRows(query: query, input: input)
        let contextProject = context.flatMap { id in input.projects.first { $0.id == id } }
            ?? bestProject(query: query, sessions: sessions, projects: projects, input: input)
        let actions = actionRows(query: query, context: contextProject, accounts: input.accounts)
        var groups: [Group] = []
        if !sessions.isEmpty { groups.append(Group(section: .sessions, rows: sessions)) }
        if !notes.isEmpty { groups.append(Group(section: .notes, rows: notes)) }
        if !projects.isEmpty { groups.append(Group(section: .projects, rows: projects)) }
        if !actions.isEmpty { groups.append(Group(section: .actions, rows: actions)) }
        return QuickSwitchModel(query: query, groups: groups)
    }

    /// Title first; the location counts half (a strong location match still beats a weak title one).
    static func score(_ query: String, primary: String, secondary: String) -> (score: Int, spans: [TextSpan])? {
        let first = FuzzyMatcher.match(query, in: primary)
        let second = secondary.isEmpty ? nil : FuzzyMatcher.match(query, in: secondary)
        switch (first, second) {
        case let (a?, b?): return a.score >= b.score / 2 ? (a.score, a.spans) : (b.score / 2, [])
        case let (a?, nil): return (a.score, a.spans)
        case let (nil, b?): return (b.score / 2, [])
        case (nil, nil): return nil
        }
    }

    private static func sessionRow(_ s: Input.Session, score: Int, spans: [TextSpan]) -> Row {
        let style = s.unreachable ? StateStyle.unreachable : StateStyle.of(s.state)
        let showsDuration = s.state != .shell && s.state != .stopped
        return Row(item: .session(s.id), section: .sessions, title: s.title, spans: spans, prefix: nil, detail: s.location,
                   detailTag: s.groupColor, tag: s.tag, glyph: style.glyph, state: s.state, unreachable: s.unreachable,
                   since: showsDuration ? s.since : nil, shortcut: s.number.flatMap { $0 <= 9 ? "⌘\($0)" : nil }, chip: nil,
                   score: score)
    }

    private static func sessionRows(query: String, input: Input) -> [Row] {
        let limit = Section.sessions.limit
        guard !query.isEmpty else {
            var ordered: [Input.Session] = input.sessions.filter { $0.state.needsAttention }
            var seen = Set(ordered.map(\.id))
            let byID = Dictionary(input.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in input.viewed where id != input.currentSessionID {
                if let session = byID[id], seen.insert(id).inserted { ordered.append(session) }
            }
            for session in input.sessions where session.id != input.currentSessionID && seen.insert(session.id).inserted {
                ordered.append(session)
            }
            return ordered.prefix(limit).map { sessionRow($0, score: 0, spans: []) }
        }
        var scored: [(row: Row, order: Int)] = []
        for (order, session) in input.sessions.enumerated() {
            guard let match = score(query, primary: session.title, secondary: session.location) else { continue }
            scored.append((sessionRow(session, score: match.score, spans: match.spans), order))
        }
        return scored.sorted { $0.row.score != $1.row.score ? $0.row.score > $1.row.score : $0.order < $1.order }
            .prefix(limit).map(\.row)
    }

    /// QuickSwitch artboard `.mh Notes`: the title with its matched characters amber, the sub
    /// `note · #rwd #punch`, the time on the right.
    private static func noteRow(_ note: Input.Note, score: Int, spans: [TextSpan]) -> Row {
        let tags = note.tags.map { "#" + $0 }.joined(separator: " ")
        let detail = tags.isEmpty ? note.kind : "\(note.kind) · \(tags)"
        return Row(item: .note(note.id), section: .notes, title: note.title, spans: spans, prefix: nil, detail: detail, detailTag: nil,
                   tag: nil, glyph: "", state: nil, since: nil, shortcut: note.time, chip: nil, score: score)
    }

    private static func noteRows(query: String, input: Input) -> [Row] {
        guard !query.isEmpty else {
            return input.notes.prefix(Section.recentNotes).map { noteRow($0, score: 0, spans: []) }
        }
        var scored: [(row: Row, order: Int)] = []
        for (order, note) in input.notes.enumerated() {
            let tags = note.tags.map { "#" + $0 }.joined(separator: " ")
            guard let match = score(query, primary: note.title, secondary: tags) else { continue }
            scored.append((noteRow(note, score: match.score, spans: match.spans), order))
        }
        return scored.sorted { $0.row.score != $1.row.score ? $0.row.score > $1.row.score : $0.order < $1.order }
            .prefix(Section.notes.limit).map(\.row)
    }

    /// `orb-toolkit-suite/` for `/…/orb-toolkit-suite/orb-toolkit-frontend`.
    static func parentPrefix(_ path: String) -> String? {
        let parts = PathFormat.abbreviateHome(path).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let parent = parts[parts.count - 2]
        return parent == "~" ? nil : "\(parent)/"
    }

    private static func projectRows(query: String, input: Input) -> [Row] {
        var scored: [(row: Row, order: Int)] = []
        for (order, project) in input.projects.enumerated() {
            guard let match = score(query, primary: project.name, secondary: project.path) else { continue }
            var detail: String
            if project.transient {
                detail = project.live > 0 ? "\(project.live) live · 外部" : "外部"
            } else {
                detail = "\(project.live) live"
                if let group = project.groupName { detail += " · \(group)" }
            }
            scored.append((Row(item: .project(project.id), section: .projects, title: project.name, spans: match.spans,
                               prefix: parentPrefix(project.path), detail: detail, detailTag: project.groupColor, tag: nil,
                               glyph: "", state: nil, since: nil, shortcut: nil, chip: nil, score: match.score), order))
        }
        let base = input.projects.count
        for (index, suggestion) in input.suggestions.enumerated() {
            guard let match = score(query, primary: suggestion.name, secondary: suggestion.path) else { continue }
            scored.append((Row(item: .suggestion(suggestion.path), section: .projects, title: suggestion.name, spans: match.spans,
                               prefix: parentPrefix(suggestion.path), detail: "未加入 · 來自 ~/.claude.json", detailTag: nil,
                               tag: nil, glyph: "", state: nil, since: nil, shortcut: nil, chip: "+ 加入", score: match.score),
                           base + index))
        }
        return scored.sorted { $0.row.score != $1.row.score ? $0.row.score > $1.row.score : $0.order < $1.order }
            .prefix(Section.projects.limit).map(\.row)
    }

    /// The project of the best session row, else the best project row; with an empty query the
    /// shown session's. A query that matched nothing has no context (`// 沒有符合的結果`).
    private static func bestProject(query: String, sessions: [Row], projects: [Row], input: Input) -> Input.Project? {
        let sessionProject: (SessionID) -> ProjectID? = { id in input.sessions.first { $0.id == id }?.projectID }
        if case .session(let id)? = sessions.first?.item, let pid = sessionProject(id) {
            return input.projects.first { $0.id == pid }
        }
        if case .project(let pid)? = projects.first?.item { return input.projects.first { $0.id == pid } }
        if query.isEmpty, let current = input.currentSessionID, let pid = sessionProject(current) {
            return input.projects.first { $0.id == pid }
        }
        return nil
    }

    private static func actionRows(query: String, context: Input.Project?, accounts: [Input.Account]) -> [Row] {
        var rows: [Row] = []
        if let context {
            for action in [Action.newSessionIn(path: context.path, name: context.name), .openTerminalIn(path: context.path, name: context.name)] {
                rows.append(actionRow(action, spans: []))
            }
        }
        let switches = accounts.map { Action.switchAccount(id: $0.id, name: $0.name, quota: $0.quota) }
        if query.isEmpty {
            rows += switches.prefix(1).map { actionRow($0, spans: []) }
            rows += Action.common.map { actionRow($0, spans: []) }
        } else {
            var scored: [(Row, Int)] = []
            for (order, action) in (Action.general + switches).enumerated() {
                guard let match = FuzzyMatcher.match(query, in: action.title) else { continue }
                var row = actionRow(action, spans: match.spans)
                row.score = match.score
                scored.append((row, order))
            }
            let matched = scored.sorted { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }.map(\.0)
            // The artboard offers the R7-first switchable account after the contextual actions even
            // when the query is about something else (`打卡` → `切換帳號到 #2 藍鵲`).
            if let first = switches.first, !matched.contains(where: { $0.item == .action(first) }) {
                rows.append(actionRow(first, spans: []))
            }
            rows += matched
        }
        return Array(rows.prefix(Section.actions.limit))
    }

    private static func actionRow(_ action: Action, spans: [TextSpan]) -> Row {
        Row(item: .action(action), section: .actions, title: action.title, spans: spans, prefix: nil, detail: "", detailTag: nil,
            tag: nil, glyph: ">", state: nil, since: nil, shortcut: action.hint, chip: nil)
    }

    // MARK: ⌘⏎

    /// What ⌘⏎ does with a row (D14): a CODD session opens with its ⌘J panel, an external only
    /// opens, a project opens its shell; everything else does what ⏎ does.
    enum CommandEnter: Equatable {
        case openWithPanel(SessionID)
        case open(SessionID)
        case projectShell(ProjectID)
        case same
    }

    static func commandEnter(_ item: Item, input: Input) -> CommandEnter {
        switch item {
        case .session(let id):
            return input.sessions.first { $0.id == id }?.external == true ? .open(id) : .openWithPanel(id)
        case .project(let id):
            return .projectShell(id)
        case .note, .suggestion, .action:
            return .same
        }
    }

    /// The `palette` state dump entry's rows.
    var dumpRows: [[String: Any]] {
        rows.map { ["section": $0.section.rawValue, "title": ($0.prefix ?? "") + $0.title, "detail": $0.detail] }
    }
}

extension QuickSwitchModel.Input {
    /// From the stores: sessions and projects in sidebar order, the ⌘1–9 numbers, `.claude.json`
    /// folders CODD does not know.
    @MainActor
    static func make(store: any SessionStore, shell: ShellState, recent: [RecentProject], accounts: (any AccountStore)? = nil,
                     notes: [Note] = []) -> Self {
        var input = Self()
        input.notes = notes
        if let accounts, !accounts.isSwitching {
            input.accounts = accounts.accounts.filter { $0.id != accounts.activeAccountID && !$0.isPseudo && !$0.isDisabled }.map {
                Account(id: $0.id, name: $0.displayName, quota: "5h 剩 \($0.fiveHour.valueText) · 1w 剩 \($0.week.valueText)")
            }
        }
        let snapshot = SidebarSnapshotBuilder.build(store: store, mode: shell.sidebarMode, filter: shell.filterText)
        var numbers: [SessionID: Int] = [:]
        for (index, id) in snapshot.sessionOrder.enumerated() where numbers[id] == nil { numbers[id] = index + 1 }
        var seen = Set<SessionID>()
        var knownPaths = Set<String>()
        for group in store.groups {
            for pid in group.projectIDs {
                guard let project = store.project(pid) else { continue }
                knownPaths.insert(HolderSessionStore.standardize(project.cwd))
                let sessions = project.sessionIDs.compactMap { store.session($0) }
                input.projects.append(Project(id: project.id, name: project.name, path: project.cwd,
                                              groupName: group.isUngrouped ? nil : group.name,
                                              groupColor: group.isUngrouped ? nil : group.color,
                                              live: sessions.filter { $0.state.isLive }.count, transient: project.isTransient))
                for session in sessions where seen.insert(session.id).inserted {
                    let location = group.isUngrouped ? project.name : "\(group.shortName) / \(project.name)"
                    input.sessions.append(Session(id: session.id, title: session.title, location: location,
                                                  groupColor: group.isUngrouped ? nil : group.color, tag: session.tag,
                                                  state: session.state, unreachable: session.unreachableSince != nil,
                                                  since: session.unreachableSince ?? session.stateSince, number: numbers[session.id],
                                                  external: session.external, projectID: project.id, kind: session.kind))
                }
            }
        }
        // Sidebar order (NEEDS YOU first) for sessions; the tree walk above fills in the rest.
        let order = Dictionary(snapshot.sessionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        input.sessions = input.sessions.enumerated().sorted { lhs, rhs in
            switch (order[lhs.element.id], order[rhs.element.id]) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        input.suggestions = recent.filter { !knownPaths.contains(HolderSessionStore.standardize($0.path)) }
            .map { Suggestion(path: $0.path, name: $0.name) }
        input.viewed = shell.viewedSessionIDs
        input.currentSessionID = shell.currentSessionID
        return input
    }
}
