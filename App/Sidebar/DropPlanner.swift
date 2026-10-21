import AppKit

/// A validated drop, in model terms.
enum DropTarget: Equatable {
    /// Reorder sessions inside their own project (cwd is fixed).
    case sessions(project: ProjectID, index: Int)
    /// Move projects into a group (same group = reorder).
    case projects(group: GroupID, index: Int)
    /// Reorder user groups; index counts user groups only (ungrouped stays last).
    case groups(index: Int)
    /// Folders from Finder become projects in `group` at `index`; a nil group = where 新增專案 puts
    /// them (the drop was not over a group).
    case folders(group: GroupID?, index: Int?)
}

/// A drop plan: the model target plus the outline position to show the gap at.
struct DropPlan: Equatable {
    var target: DropTarget
    /// Outline parent / child index to retarget the drop to (`nil` parent = root).
    var parent: NodeKind?
    var childIndex: Int
}

/// One visible outline row as a pointer drop sees it (outline coordinates, y grows downward).
struct DropRow: Equatable, Sendable {
    var node: NodeKind
    /// 0 = root (the outline's `level(forRow:)`).
    var depth: Int
    var minY: CGFloat
    var maxY: CGFloat
}

/// Where the pointer is during a drag: the outline's visible rows top to bottom and the pointer's y.
///
/// AppKit's own proposal is "on the row" for the middle of every row and names the deepest row
/// under the pointer, so planning from it alone turned most mouse drops into no-ops (a session
/// dropped on the next one landed before it, i.e. where it already was) or refusals (a project
/// over another project's sessions). The pointer planner instead takes the dragged level's
/// block under the pointer (a project with its visible sessions, a group with everything in it)
/// and drops before it in its upper half, after it in its lower half.
struct DropPointer: Equatable, Sendable {
    var rows: [DropRow]
    var y: CGFloat

    /// The row under the pointer; above the first row counts as the first, below the last as none.
    var hoveredIndex: Int? {
        guard let first = rows.first else { return nil }
        if y < first.minY { return 0 }
        return rows.firstIndex { y >= $0.minY && y < $0.maxY }
    }

    /// The nearest row at or above `index`'s ancestry (itself first) whose node matches.
    func ancestorIndex(of index: Int, matching: (NodeKind) -> Bool) -> Int? {
        guard rows.indices.contains(index) else { return nil }
        if matching(rows[index].node) { return index }
        var depth = rows[index].depth
        var i = index
        while i > 0, depth > 0 {
            i -= 1
            guard rows[i].depth < depth else { continue }
            depth = rows[i].depth
            if matching(rows[i].node) { return i }
        }
        return nil
    }

    /// Whether the pointer is in the upper half of the row at `index` together with its visible descendants.
    func inUpperHalf(ofBlockAt index: Int) -> Bool {
        var end = index
        while end + 1 < rows.count, rows[end + 1].depth > rows[index].depth { end += 1 }
        return y < (rows[index].minY + rows[end].maxY) / 2
    }
}

/// Sidebar drag rules (SPEC §2): sessions reorder only within their project, projects move
/// between groups, groups reorder among groups; folders dropped from Finder become projects.
/// Pure (reads the snapshot, the store and, for mouse drags, the pointer).
@MainActor
enum DropPlanner {
    // MARK: Mouse drags (the pointer decides)

    /// The drop for the pointer's position (what `validateDrop` / `acceptDrop` use for a mouse drag).
    static func plan(dragged: [NodeKind], pointer: DropPointer, snapshot: SidebarSnapshot, store: any SessionStore) -> DropPlan? {
        guard let first = dragged.first else { return nil }
        switch first {
        case .session(_, .tree): return planSessions(dragged, pointer: pointer, snapshot: snapshot, store: store)
        case .project: return planProjects(dragged, pointer: pointer, snapshot: snapshot, store: store)
        case .group: return planGroups(dragged, pointer: pointer, snapshot: snapshot, store: store)
        default: return nil
        }
    }

    /// A folder drop from Finder. Over a group header: into that group after its projects; over
    /// a project (or its sessions): before / after it; anywhere else (or without a pointer: the
    /// STATE view, an active filter): where 新增專案 puts a new project.
    static func planFolders(pointer: DropPointer?, snapshot: SidebarSnapshot, store: any SessionStore) -> DropPlan {
        let elsewhere = DropPlan(target: .folders(group: nil, index: nil), parent: nil, childIndex: -1)
        guard let pointer, let hovered = pointer.hoveredIndex else { return elsewhere }
        guard let slot = projectSlot(pointer: pointer, hovered: hovered, from: [], snapshot: snapshot, store: store) else { return elsewhere }
        return DropPlan(target: .folders(group: slot.group, index: slot.index), parent: .group(slot.group), childIndex: slot.index)
    }

    private static func planSessions(_ dragged: [NodeKind], pointer: DropPointer, snapshot: SidebarSnapshot,
                                     store: any SessionStore) -> DropPlan? {
        guard let projectID = commonProject(dragged, store: store), let hovered = pointer.hoveredIndex else { return nil }
        let projectNode = NodeKind.project(projectID)
        let kids = snapshot.childrenOf(projectNode)
        let index: Int
        switch pointer.rows[hovered].node {
        case projectNode:
            // The project's own head: the top of its list.
            index = 0
        case .session(_, .tree) where kids.contains(pointer.rows[hovered].node):
            let position = kids.firstIndex(of: pointer.rows[hovered].node) ?? 0
            index = position + (pointer.inUpperHalf(ofBlockAt: hovered) ? 0 : 1)
        default:
            // Another project's rows, a section, a group head: sessions never leave their cwd.
            return nil
        }
        let i = min(index, coddRows(kids, store: store))
        return DropPlan(target: .sessions(project: projectID, index: i), parent: projectNode, childIndex: i)
    }

    private static func planProjects(_ dragged: [NodeKind], pointer: DropPointer, snapshot: SidebarSnapshot,
                                     store: any SessionStore) -> DropPlan? {
        guard savedProjects(dragged, store: store), let hovered = pointer.hoveredIndex else { return nil }
        let from = Set(dragged.compactMap { node -> GroupID? in
            if case .project(let id) = node { return store.project(id)?.groupID }
            return nil
        })
        guard let slot = projectSlot(pointer: pointer, hovered: hovered, from: from, snapshot: snapshot, store: store) else { return nil }
        return DropPlan(target: .projects(group: slot.group, index: slot.index), parent: .group(slot.group), childIndex: slot.index)
    }

    /// Where a project dropped at the pointer goes: another group's head = after its saved
    /// projects (`移入`), the head of the group the dragged projects are in = its top (a reorder);
    /// a project's block = before it (upper half) or after it (lower half).
    private static func projectSlot(pointer: DropPointer, hovered: Int, from: Set<GroupID>, snapshot: SidebarSnapshot,
                                    store: any SessionStore) -> (group: GroupID, index: Int)? {
        if case .group(let groupID) = pointer.rows[hovered].node, store.group(groupID) != nil {
            return (groupID, from == [groupID] ? 0 : savedRows(groupID, snapshot: snapshot, store: store))
        }
        guard let anchorRow = pointer.ancestorIndex(of: hovered, matching: { if case .project = $0 { true } else { false } }),
              case .project(let anchor) = pointer.rows[anchorRow].node, let groupID = store.project(anchor)?.groupID,
              let position = snapshot.childrenOf(.group(groupID)).firstIndex(of: .project(anchor)) else { return nil }
        let index = position + (pointer.inUpperHalf(ofBlockAt: anchorRow) ? 0 : 1)
        return (groupID, min(index, savedRows(groupID, snapshot: snapshot, store: store)))
    }

    private static func planGroups(_ dragged: [NodeKind], pointer: DropPointer, snapshot: SidebarSnapshot,
                                   store: any SessionStore) -> DropPlan? {
        guard userGroups(dragged, store: store) else { return nil }
        let root = snapshot.childrenOf(nil)
        let positions = userGroupPositions(root, store: store)
        guard let firstPosition = positions.first, let lastPosition = positions.last else { return nil }
        var rootIndex = lastPosition + 1
        if let hovered = pointer.hoveredIndex {
            if let groupRow = pointer.ancestorIndex(of: hovered, matching: { if case .group = $0 { true } else { false } }),
               case .group(let id) = pointer.rows[groupRow].node, let position = root.firstIndex(of: .group(id)) {
                // 未分類 stays last: anywhere over it means "after the last user group".
                let ungrouped = store.group(id)?.isUngrouped ?? false
                rootIndex = ungrouped ? position : position + (pointer.inUpperHalf(ofBlockAt: groupRow) ? 0 : 1)
            } else if pointer.ancestorIndex(of: hovered, matching: { if case .section = $0 { true } else { false } }) != nil {
                // NEEDS YOU / PINNED sit above the groups: the top of the user groups.
                rootIndex = firstPosition
            }
        }
        rootIndex = max(firstPosition, min(rootIndex, lastPosition + 1))
        let userIndex = positions.filter { $0 < rootIndex }.count
        return DropPlan(target: .groups(index: userIndex), parent: nil, childIndex: rootIndex)
    }

    // MARK: Proposal drags (AppKit's parent / index; data-source tests and callers without a pointer)

    static func plan(dragged: [NodeKind], parent: NodeKind?, index: Int, snapshot: SidebarSnapshot,
                     store: any SessionStore) -> DropPlan? {
        guard let first = dragged.first else { return nil }
        switch first {
        case .session(_, .tree): return planSessions(dragged, parent: parent, index: index, snapshot: snapshot, store: store)
        case .project: return planProjects(dragged, parent: parent, index: index, snapshot: snapshot, store: store)
        case .group: return planGroups(dragged, parent: parent, index: index, snapshot: snapshot, store: store)
        default: return nil
        }
    }

    private static func planSessions(_ dragged: [NodeKind], parent: NodeKind?, index: Int, snapshot: SidebarSnapshot,
                                     store: any SessionStore) -> DropPlan? {
        guard let projectID = commonProject(dragged, store: store) else { return nil }
        let projectNode = NodeKind.project(projectID)
        let kids = snapshot.childrenOf(projectNode)
        // D6: externals sit after the CODD rows; a drop never lands among (or below) them.
        let coddRows = coddRows(kids, store: store)
        switch parent {
        case .project(projectID)?:
            let i = min(index < 0 ? kids.count : min(index, kids.count), coddRows)
            return DropPlan(target: .sessions(project: projectID, index: i), parent: projectNode, childIndex: i)
        case .session(let other, .tree)?:
            guard store.session(other)?.projectID == projectID, let position = kids.firstIndex(of: .session(other, .tree)) else { return nil }
            let i = min(position, coddRows)
            return DropPlan(target: .sessions(project: projectID, index: i), parent: projectNode, childIndex: i)
        default:
            return nil
        }
    }

    private static func planProjects(_ dragged: [NodeKind], parent: NodeKind?, index: Int, snapshot: SidebarSnapshot,
                                     store: any SessionStore) -> DropPlan? {
        guard savedProjects(dragged, store: store) else { return nil }
        switch parent {
        case .group(let groupID)?:
            let count = snapshot.childrenOf(.group(groupID)).count
            let i = min(index < 0 ? count : min(index, count), savedRows(groupID, snapshot: snapshot, store: store))
            return DropPlan(target: .projects(group: groupID, index: i), parent: .group(groupID), childIndex: i)
        case .project(let other)?:
            guard let groupID = store.project(other)?.groupID,
                  let position = snapshot.childrenOf(.group(groupID)).firstIndex(of: .project(other)) else { return nil }
            let i = min(position + 1, savedRows(groupID, snapshot: snapshot, store: store))
            return DropPlan(target: .projects(group: groupID, index: i), parent: .group(groupID), childIndex: i)
        default:
            return nil
        }
    }

    private static func planGroups(_ dragged: [NodeKind], parent: NodeKind?, index: Int, snapshot: SidebarSnapshot,
                                   store: any SessionStore) -> DropPlan? {
        guard userGroups(dragged, store: store) else { return nil }
        let root = snapshot.childrenOf(nil)
        let positions = userGroupPositions(root, store: store)
        guard let firstPosition = positions.first, let lastPosition = positions.last else { return nil }
        var rootIndex: Int
        switch parent {
        case nil:
            rootIndex = index < 0 ? lastPosition + 1 : index
        case .group(let id)?:
            guard let position = root.firstIndex(of: .group(id)) else { return nil }
            rootIndex = position
        default:
            return nil
        }
        rootIndex = max(firstPosition, min(rootIndex, lastPosition + 1))
        let userIndex = positions.filter { $0 < rootIndex }.count
        return DropPlan(target: .groups(index: userIndex), parent: nil, childIndex: rootIndex)
    }

    // MARK: Shared rules

    /// The one project every dragged tree session (never an external) belongs to.
    private static func commonProject(_ dragged: [NodeKind], store: any SessionStore) -> ProjectID? {
        var projectIDs = Set<ProjectID>()
        for node in dragged {
            guard case .session(let id, .tree) = node, let s = store.session(id), !s.external else { return nil }
            projectIDs.insert(s.projectID)
        }
        return projectIDs.count == 1 ? projectIDs.first : nil
    }

    /// D6: the CODD rows ahead of a project's externals.
    private static func coddRows(_ kids: [NodeKind], store: any SessionStore) -> Int {
        kids.prefix { node in node.sessionID.flatMap(store.session).map { !$0.external } ?? false }.count
    }

    /// Only saved projects move (a transient one is not CODD's until it is added).
    private static func savedProjects(_ dragged: [NodeKind], store: any SessionStore) -> Bool {
        dragged.allSatisfy { node in
            if case .project(let id) = node { return store.project(id)?.isTransient == false }
            return false
        }
    }

    /// Saved projects stay ahead of the transient ones at the end of 未分類.
    private static func savedRows(_ groupID: GroupID, snapshot: SidebarSnapshot, store: any SessionStore) -> Int {
        snapshot.childrenOf(.group(groupID)).prefix { node in
            if case .project(let id) = node { return store.project(id)?.isTransient == false }
            return false
        }.count
    }

    private static func userGroups(_ dragged: [NodeKind], store: any SessionStore) -> Bool {
        !dragged.isEmpty && dragged.allSatisfy { node in
            if case .group(let id) = node, let g = store.group(id) { return !g.isUngrouped }
            return false
        }
    }

    private static func userGroupPositions(_ root: [NodeKind], store: any SessionStore) -> [Int] {
        root.indices.filter { i in
            if case .group(let id) = root[i], store.group(id)?.isUngrouped == false { return true }
            return false
        }
    }
}

/// Folders dragged in from Finder (or another app's file list).
@MainActor
enum FolderDrop {
    /// The file URLs on a drag pasteboard (non-file URLs are ignored).
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }
    }

    /// The folders among `urls` as 新增專案 stores them (standardized paths, each once). Plain
    /// files and packages (an `.app` is a file to the user) are left out; a link to a folder counts.
    static func folderPaths(_ urls: [URL], isFolder: @MainActor (String) -> Bool = FolderDrop.isFolder) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in urls where url.isFileURL {
            let path = HolderSessionStore.standardize(url.path)
            guard seen.insert(path).inserted, isFolder(path) else { continue }
            out.append(path)
        }
        return out
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return !NSWorkspace.shared.isFilePackage(atPath: path)
    }
}
