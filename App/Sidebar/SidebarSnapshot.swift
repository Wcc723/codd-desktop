import Foundation

/// Sidebar sections. Tree mode uses `needsYou` + `pinned`; STATE mode uses all but `pinned`.
enum SidebarSection: String, Hashable, Sendable, CaseIterable {
    case needsYou, pinned, working, ready, idle, shell, stopped

    var title: String {
        switch self {
        case .needsYou: "◆ Needs you"
        case .pinned: "Pinned"
        case .working: "Working"
        case .ready: "Ready"
        case .idle: "Idle"
        case .shell: "Shell"
        case .stopped: "Stopped"
        }
    }

    /// The state whose glyph and color a STATE-view head draws (SidebarStates E: `● Working 4`).
    /// Nil for NEEDS YOU (its `◆` is part of the title) and PINNED.
    var glyphState: SessionState? {
        switch self {
        case .needsYou, .pinned: nil
        case .working: .busy
        case .ready: .done
        case .idle: .idle
        case .shell: .shell
        case .stopped: .exited
        }
    }

    /// STATE view sections in order, with the states each one lists (M2-PLAN I3: Working = busy,
    /// compacting, starting, unknown; Ready = done; Stopped = exited + stopped).
    static let stateSections: [SidebarSection] = [.needsYou, .working, .ready, .idle, .shell, .stopped]

    func contains(_ state: SessionState) -> Bool {
        switch self {
        case .needsYou: state.needsAttention
        case .pinned: false
        case .working: state == .busy || state == .compacting || state == .starting || state == .unknown
        case .ready: state == .done
        case .idle: state == .idle
        case .shell: state == .shell
        case .stopped: state == .exited || state == .stopped
        }
    }
}

/// Where a session row appears (the same session can be mirrored in several places).
enum SessionContext: Hashable, Sendable {
    case tree
    case needs
    case pinned
    case stateList(SidebarSection)

    var isFlat: Bool { self != .tree }

    /// STATE-view rows draw line 2 as `<lead> · ■ <project>` (SidebarStates E).
    var isStateList: Bool {
        if case .stateList = self { return true }
        return false
    }

    /// Dump name (`tree`, `needsYou`, `pinned`, or the STATE section).
    var name: String {
        switch self {
        case .tree: "tree"
        case .needs: "needsYou"
        case .pinned: "pinned"
        case .stateList(let section): section.rawValue
        }
    }
}

/// Identity of one sidebar row. Hashable value = stable identity across snapshots.
enum NodeKind: Hashable, Sendable {
    case section(SidebarSection)
    case group(GroupID)
    case project(ProjectID)
    case session(SessionID, SessionContext)
    /// `◇ 1 個待看 · …` line at the bottom of NEEDS YOU.
    case doneSummary
    /// `// 沒有執行中的 session · 封存 3` under a project without live sessions.
    case emptyProject(ProjectID)
    case addGroup
    /// The inline new-group editor that replaces `[+ 新增群組]` while it is open (SidebarStates D).
    case newGroup

    var sessionID: SessionID? {
        if case .session(let id, _) = self { return id }
        return nil
    }
}

/// Which tinted block a row belongs to (R1 group blocks, the NEEDS YOU strip).
enum BlockID: Hashable, Sendable {
    case needs
    case group(GroupID)
}

/// Immutable description of the sidebar tree. `nil` parent = root.
struct SidebarSnapshot: Equatable, Sendable {
    private(set) var children: [NodeKind?: [NodeKind]] = [:]
    private(set) var blocks: [NodeKind: BlockID] = [:]

    func childrenOf(_ parent: NodeKind?) -> [NodeKind] { children[parent] ?? [] }

    mutating func set(_ kids: [NodeKind], for parent: NodeKind?) { children[parent] = kids }
    mutating func setBlock(_ block: BlockID, for node: NodeKind) { blocks[node] = block }

    func block(of node: NodeKind) -> BlockID? { blocks[node] }

    /// Every node (pre-order) with its parent.
    func allNodes() -> [(node: NodeKind, parent: NodeKind?)] {
        var out: [(NodeKind, NodeKind?)] = []
        func walk(_ parent: NodeKind?) {
            for child in childrenOf(parent) {
                out.append((child, parent))
                walk(child)
            }
        }
        walk(nil)
        return out
    }

    func parentMap() -> [NodeKind: NodeKind?] {
        var map: [NodeKind: NodeKind?] = [:]
        for (node, parent) in allNodes() { map[node] = .some(parent) }
        return map
    }

    func contains(_ node: NodeKind) -> Bool { parentMap()[node] != nil }

    /// Unique sessions in top-to-bottom order (collapse ignored): ⌘1–9 and ⌃Tab order.
    var sessionOrder: [SessionID] {
        var seen = Set<SessionID>()
        return allNodes().compactMap { $0.node.sessionID }.filter { seen.insert($0).inserted }
    }

    /// The rows an outline shows: pre-order, children only below expanded nodes, with their depth
    /// (0 = root). The `sidebar` state dump and the drop line read the same order.
    func visibleRows(expanded: (NodeKind) -> Bool) -> [(node: NodeKind, depth: Int)] {
        var out: [(NodeKind, Int)] = []
        func walk(_ parent: NodeKind?, depth: Int) {
            for child in childrenOf(parent) {
                out.append((child, depth))
                if !childrenOf(child).isEmpty, expanded(child) { walk(child, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return out
    }
}

/// The filter field's query (`/ 篩選 session、專案…`): case-, width- and diacritic-insensitive
/// substring match on a session's title, its project's name and its group's name, in every
/// section (NEEDS YOU, PINNED, the tree and the STATE lists).
struct SidebarFilter: Sendable, Equatable {
    let query: String

    init(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { query.isEmpty }

    func matches(_ text: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// Whether a project row stays with all its sessions (its own or its group's name matches).
    @MainActor
    func matches(project: ProjectVM, store: any SessionStore) -> Bool {
        if isEmpty || matches(project.name) { return true }
        guard let group = store.group(project.groupID) else { return false }
        return matches(group.name) || matches(group.shortName)
    }

    @MainActor
    func matches(_ session: SessionVM, store: any SessionStore) -> Bool {
        if isEmpty || matches(session.title) { return true }
        guard let project = store.project(session.projectID) else { return false }
        return matches(project: project, store: store)
    }
}

/// Builds the snapshot from the store. Reads only structure + states (and titles when a
/// filter is set), so it is cheap to run inside observation tracking.
@MainActor
enum SidebarSnapshotBuilder {
    /// - Parameter addingGroup: the inline new-group editor is open (tree mode, no filter): it
    ///   takes the place of `[+ 新增群組]`.
    static func build(store: any SessionStore, mode: SidebarMode, filter: String, addingGroup: Bool = false) -> SidebarSnapshot {
        let query = SidebarFilter(filter)
        switch mode {
        case .tree: return tree(store: store, filter: query, addingGroup: addingGroup)
        case .state: return stateLists(store: store, filter: query)
        }
    }

    /// Sessions in manual tree order (group → project → session).
    static func treeOrder(store: any SessionStore) -> [SessionVM] {
        store.groups.flatMap { g in
            g.projectIDs.compactMap(store.project).flatMap { p in p.sessionIDs.compactMap(store.session) }
        }
    }

    /// NEEDS YOU in tree mode: waiting + error in tree order (never reorders the tree), filtered.
    static func needsYou(store: any SessionStore, filter: String) -> [SessionVM] {
        let query = SidebarFilter(filter)
        return treeOrder(store: store).filter { $0.state.needsAttention && query.matches($0, store: store) }
    }

    /// The unseen DONE sessions the `◇ n 個待看` line counts, filtered like NEEDS YOU.
    static func unseenDone(store: any SessionStore, filter: String) -> [SessionVM] {
        let query = SidebarFilter(filter)
        return treeOrder(store: store).filter { $0.state == .done && query.matches($0, store: store) }
    }

    /// One STATE-view section's sessions in tree order, filtered (also what its head counts).
    static func sessions(in section: SidebarSection, store: any SessionStore, filter: String) -> [SessionVM] {
        let query = SidebarFilter(filter)
        return treeOrder(store: store).filter { section.contains($0.state) && query.matches($0, store: store) }
    }

    private static func tree(store: any SessionStore, filter query: SidebarFilter, addingGroup: Bool) -> SidebarSnapshot {
        var snap = SidebarSnapshot()
        var root: [NodeKind] = []
        let ordered = treeOrder(store: store).filter { query.matches($0, store: store) }

        // NEEDS YOU mirrors waiting + error (never reorders the tree), plus the DONE line.
        let needs = ordered.filter { $0.state.needsAttention }
        let done = ordered.filter { $0.state == .done }
        if !needs.isEmpty || !done.isEmpty {
            let section = NodeKind.section(.needsYou)
            var kids = needs.map { NodeKind.session($0.id, .needs) }
            if !done.isEmpty { kids.append(.doneSummary) }
            root.append(section)
            snap.set(kids, for: section)
            snap.setBlock(.needs, for: section)
            for k in kids { snap.setBlock(.needs, for: k) }
        }

        let pinned = store.pinnedSessionIDs.filter { id in store.session(id).map { query.matches($0, store: store) } ?? false }
        if !pinned.isEmpty {
            let section = NodeKind.section(.pinned)
            root.append(section)
            snap.set(pinned.map { .session($0, .pinned) }, for: section)
        }

        for group in store.groups {
            let groupNode = NodeKind.group(group.id)
            var projectNodes: [NodeKind] = []
            for project in group.projectIDs.compactMap(store.project) {
                var sessions = project.sessionIDs.compactMap(store.session)
                if !query.isEmpty {
                    let projectMatches = query.matches(project: project, store: store)
                    if !projectMatches { sessions = sessions.filter { query.matches($0.title) } }
                    if sessions.isEmpty, !projectMatches { continue }
                }
                let projectNode = NodeKind.project(project.id)
                let kids: [NodeKind] = sessions.isEmpty ? [.emptyProject(project.id)] : sessions.map { .session($0.id, .tree) }
                projectNodes.append(projectNode)
                snap.set(kids, for: projectNode)
                snap.setBlock(.group(group.id), for: projectNode)
                for k in kids { snap.setBlock(.group(group.id), for: k) }
            }
            if !query.isEmpty, projectNodes.isEmpty { continue }
            root.append(groupNode)
            snap.set(projectNodes, for: groupNode)
            snap.setBlock(.group(group.id), for: groupNode)
        }
        if query.isEmpty { root.append(addingGroup ? .newGroup : .addGroup) }
        snap.set(root, for: nil)
        return snap
    }

    private static func stateLists(store: any SessionStore, filter query: SidebarFilter) -> SidebarSnapshot {
        var snap = SidebarSnapshot()
        let ordered = treeOrder(store: store).filter { query.matches($0, store: store) }
        var root: [NodeKind] = []
        for section in SidebarSection.stateSections {
            let kids = ordered.filter { section.contains($0.state) }.map { NodeKind.session($0.id, .stateList(section)) }
            guard !kids.isEmpty else { continue }
            let node = NodeKind.section(section)
            root.append(node)
            snap.set(kids, for: node)
            if section == .needsYou {
                snap.setBlock(.needs, for: node)
                for k in kids { snap.setBlock(.needs, for: k) }
            }
        }
        snap.set(root, for: nil)
        return snap
    }
}
