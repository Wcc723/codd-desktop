import Foundation

/// Layout intents of the real store: the same semantics as `MockSessionStore` (so the sidebar
/// behaves identically in both modes), and every change is saved to layout.json (debounced).
extension HolderSessionStore {
    private var ungrouped: GroupVM? { groups.last { $0.isUngrouped } }
    private var userGroups: [GroupVM] { groups.filter { !$0.isUngrouped } }

    /// Externals never move, and CODD sessions stay ahead of them (`index` is clamped).
    func moveSessions(_ ids: [SessionID], toIndex index: Int, inProject projectID: ProjectID) {
        guard let project = projectsByID[projectID] else { return }
        let moving = ids.filter { sessionsByID[$0] != nil && project.sessionIDs.contains($0) }
        let coddCount = project.sessionIDs.prefix { externalByID[$0] == nil }.count
        let moved = ListMove.apply(project.sessionIDs, moving: moving, to: min(index, coddCount))
        guard moved != project.sessionIDs else { return }
        project.sessionIDs = moved
        scheduleLayoutSave()
    }

    /// Transient projects never move; saved ones stay ahead of them in 未分類.
    func moveProjects(_ ids: [ProjectID], toGroup groupID: GroupID, atIndex index: Int) {
        guard let target = group(groupID) else { return }
        let moving = ids.filter { projectsByID[$0].map { !$0.isTransient } ?? false }
        guard !moving.isEmpty else { return }
        let arranged = ListMove.apply(target.projectIDs, moving: moving, to: index)
        for g in groups where g.id != groupID {
            let rest = g.projectIDs.filter { !moving.contains($0) }
            if rest != g.projectIDs { g.projectIDs = rest }
        }
        if arranged != target.projectIDs { target.projectIDs = arranged }
        keepTransientLast(target)
        for id in moving { if let p = projectsByID[id], p.groupID != groupID { p.groupID = groupID } }
        scheduleLayoutSave()
    }

    func moveGroups(_ ids: [GroupID], toIndex index: Int) {
        let users = userGroups
        let order = ListMove.apply(users.map(\.id), moving: ids.filter { id in users.contains { $0.id == id } }, to: index)
        let reordered = order.compactMap { id in users.first { $0.id == id } } + (ungrouped.map { [$0] } ?? [])
        guard reordered.map(\.id) != groups.map(\.id) else { return }
        groups = reordered
        scheduleLayoutSave()
    }

    func setCollapsed(_ collapsed: Bool, group id: GroupID) {
        guard let g = group(id), g.isCollapsed != collapsed else { return }
        g.isCollapsed = collapsed
        scheduleLayoutSave()
    }

    func setCollapsed(_ collapsed: Bool, project id: ProjectID) {
        guard let p = projectsByID[id], p.isCollapsed != collapsed else { return }
        p.isCollapsed = collapsed
        scheduleLayoutSave()
    }

    /// Group ids are lowercase UUIDs: they are layout.json's `ProjectGroup.id`.
    @discardableResult
    func addGroup(name: String, color: TagColor?) -> GroupID {
        let id = LayoutMapping.id(UUID())
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "新群組" : String(trimmed.prefix(80))
        groups = userGroups + [GroupVM(id: id, name: title, shortName: LayoutMapping.shortName(title), color: color, projectIDs: [])]
            + (ungrouped.map { [$0] } ?? [])
        scheduleLayoutSave()
        return id
    }

    func deleteGroup(_ id: GroupID) {
        guard let g = group(id), !g.isUngrouped, let bucket = ungrouped else { return }
        for pid in g.projectIDs { projectsByID[pid]?.groupID = bucket.id }
        bucket.projectIDs += g.projectIDs
        keepTransientLast(bucket)
        groups.removeAll { $0.id == id }
        scheduleLayoutSave()
    }

    func renameGroup(_ id: GroupID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let g = group(id), !g.isUngrouped, !trimmed.isEmpty, g.name != trimmed else { return }
        g.name = String(trimmed.prefix(80))
        g.shortName = LayoutMapping.shortName(g.name)
        scheduleLayoutSave()
    }

    func setGroupColor(_ color: TagColor?, group id: GroupID) {
        guard let g = group(id), !g.isUngrouped, g.color != color else { return }
        g.color = color
        scheduleLayoutSave()
    }

    func setTag(_ tag: TagColor?, sessions ids: [SessionID]) {
        var changed = false
        for id in ids { if let s = sessionsByID[id], s.tag != tag { s.tag = tag; changed = true } }
        if changed { scheduleLayoutSave() }
    }

    func setPinned(_ pinned: Bool, sessions ids: [SessionID]) {
        var list = pinnedSessionIDs
        for id in ids {
            guard let s = sessionsByID[id] else { continue }
            if s.isPinned != pinned { s.isPinned = pinned }
            if pinned, !list.contains(id) { list.append(id) }
            if !pinned { list.removeAll { $0 == id } }
        }
        guard list != pinnedSessionIDs else { return }
        pinnedSessionIDs = list
        scheduleLayoutSave()
    }

    // MARK: Projects

    /// Adds the folder as a project (nil when it does not exist). An existing project of that
    /// folder is returned as is.
    @discardableResult
    func addProject(path: String, groupID: GroupID?) -> ProjectID? {
        let cwd = Self.standardize(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            report("找不到資料夾：\(cwd)")
            return nil
        }
        if let existing = project(forPath: cwd) {
            // D6: the folder of an external becomes a saved project, externals included.
            promoteTransient(existing, into: groupID)
            return existing.id
        }
        let project = addProjectVM(path: cwd, groupID: groupID)
        scheduleLayoutSave()
        return project.id
    }

    var canAddProjects: Bool { true }

    /// 新增專案 / ⌘O / folders dropped from Finder: each folder through `addProject` (so the
    /// validation, the naming and the transient promotion are the same), then the new ones move
    /// to `index` of `groupID` in drop order. A folder that already is a saved project (also
    /// through a link) stays where it is; the same folder twice in one call counts once.
    @discardableResult
    func addProjects(paths: [String], toGroup groupID: GroupID?, atIndex index: Int?) -> [ProjectAddition] {
        let target = groupID.flatMap(group)
        var results: [ProjectAddition] = []
        var added: [ProjectID] = []
        var seen = Set<ProjectID>()
        for path in paths {
            let cwd = Self.standardize(path)
            if let existing = project(forPath: cwd), !existing.isTransient {
                if seen.insert(existing.id).inserted { results.append(ProjectAddition(path: cwd, projectID: existing.id, added: false)) }
                continue
            }
            guard let id = addProject(path: cwd, groupID: target?.id) else {
                results.append(ProjectAddition(path: cwd, projectID: nil, added: false))
                continue
            }
            guard seen.insert(id).inserted else { continue }
            added.append(id)
            results.append(ProjectAddition(path: cwd, projectID: id, added: true))
        }
        if let target, let index, !added.isEmpty { moveProjects(added, toGroup: target.id, atIndex: index) }
        if !added.isEmpty { log("added projects=\(added.count) group=\(target?.id ?? "-") index=\(index.map(String.init) ?? "-")") }
        return results
    }

    func renameProject(_ id: ProjectID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project = projectsByID[id], !trimmed.isEmpty, project.name != trimmed else { return }
        project.name = String(trimmed.prefix(120))
        projectRecords[id]?.name = project.name
        scheduleLayoutSave()
    }

    /// Removes a project and every session in it (running holders are ended: the caller asked).
    /// A transient project is not removable (it lives as long as its externals). Externals of a
    /// removed project are placed again (a transient project of their folder).
    func removeProject(_ id: ProjectID) {
        guard let project = projectsByID[id], !project.isTransient else { return }
        let hadExternals = project.sessionIDs.contains { externalByID[$0] != nil }
        let sessions = project.sessionIDs.filter { externalByID[$0] == nil } + archivedByID.values.filter { $0.projectID == id }.map(\.id)
        removeSessions(sessions)
        for g in groups where g.projectIDs.contains(id) { g.projectIDs.removeAll { $0 == id } }
        projectsByID[id] = nil
        projectRecords[id] = nil
        scheduleLayoutSave()
        if hadExternals { scheduleExternalRefresh() }
    }

    // MARK: Archive

    /// Hides sessions from the tree (holders keep running); the returned action restores them.
    func archive(_ ids: [SessionID]) -> @MainActor () -> Void {
        struct Removed { let id: SessionID; let projectID: ProjectID; let index: Int; let pinIndex: Int? }
        var removed: [Removed] = []
        for id in ids {
            // `sessionsByID` only: externals are never archived.
            guard let s = sessionsByID[id], let p = projectsByID[s.projectID],
                  let index = p.sessionIDs.firstIndex(of: id) else { continue }
            removed.append(Removed(id: id, projectID: p.id, index: index, pinIndex: pinnedSessionIDs.firstIndex(of: id)))
        }
        let now = clock.now()
        for r in removed {
            archivedByID[r.id] = sessionsByID[r.id]
            removeFromTree(r.id)
            // D20: an archived session's deferred stop is dropped (its holder keeps running, as archive does).
            pendingStops.remove(r.id)
            projectsByID[r.projectID]?.archivedCount += 1
            // M4 D30: the ring clock counts from here, also before the next relaunch reads layout.json.
            if records[r.id] != nil, records[r.id]?.archivedAt == nil { records[r.id]?.archivedAt = now }
        }
        if !removed.isEmpty { scheduleLayoutSave() }
        return { [weak self] in
            guard let self else { return }
            for r in removed.reversed() {
                guard let s = self.archivedByID.removeValue(forKey: r.id) else { continue }
                self.records[r.id]?.archivedAt = nil
                self.sessionsByID[r.id] = s
                if let p = self.projectsByID[r.projectID] {
                    self.insertCODDSession(r.id, in: p, at: r.index)
                    p.archivedCount = max(0, p.archivedCount - 1)
                }
                if let pin = r.pinIndex { self.pinnedSessionIDs.insert(r.id, at: min(pin, self.pinnedSessionIDs.count)) }
            }
            self.scheduleLayoutSave()
        }
    }

    func archivedSession(_ id: SessionID) -> SessionVM? { archivedByID[id] }

    /// `還原「…」` / `全部還原` (D19): back into the project after its CODD sessions (pins kept).
    func unarchive(_ ids: [SessionID]) {
        var restored = 0
        for id in ids {
            guard let session = archivedByID[id], let project = projectsByID[session.projectID] else { continue }
            archivedByID[id] = nil
            records[id]?.archivedAt = nil
            sessionsByID[id] = session
            insertCODDSession(id, in: project)
            project.archivedCount = max(0, project.archivedCount - 1)
            if session.isPinned, !pinnedSessionIDs.contains(id) { pinnedSessionIDs.append(id) }
            restored += 1
        }
        guard restored > 0 else { return }
        log("unarchived sessions=\(restored)")
        scheduleLayoutSave()
    }

    /// Most recently active first.
    func archivedSessions(inProject id: ProjectID) -> [SessionVM] {
        archivedByID.values.filter { $0.projectID == id }.sorted { ($0.stateSince, $0.id) > ($1.stateSince, $1.id) }
    }

    /// Drops a session from its project, the pins and the session table (not from `runtimes`).
    func removeFromTree(_ id: SessionID) {
        guard let s = sessionsByID[id] else { return }
        projectsByID[s.projectID]?.sessionIDs.removeAll { $0 == id }
        pinnedSessionIDs.removeAll { $0 == id }
        sessionsByID[id] = nil
    }
}
