import Foundation
import Observation
import CoddUI

/// In-memory `SessionStore` seeded with SPEC §5. Intents mutate the model the way the real
/// store will (so the UI paths are exercised), but nothing touches disk, PTYs or `claude`.
@MainActor @Observable
final class MockSessionStore: SessionStore {
    private(set) var groups: [GroupVM]
    private(set) var pinnedSessionIDs: [SessionID]
    var host: HostSummary
    let clock: DisplayClock

    private var sessionsByID: [SessionID: SessionVM]
    /// Archived sessions (kept for `unarchive` and `封存 n ▸`).
    @ObservationIgnored private var archivedByID: [SessionID: SessionVM] = [:]
    @ObservationIgnored private var projectsByID: [ProjectID: ProjectVM]
    @ObservationIgnored private var nextGroupNumber = 1

    /// - Parameter shiftClock: true = show the SPEC numbers at launch (mock clock starts at
    ///   2026-10-15 10:42); false = real wall clock (tests that build their own dates).
    init(shiftClock: Bool = true) {
        let layout = MockData.layout()
        groups = layout.groups
        pinnedSessionIDs = layout.pinned
        host = MockData.host
        clock = DisplayClock(offset: shiftClock ? MockData.referenceDate.timeIntervalSinceNow : 0)
        sessionsByID = Dictionary(uniqueKeysWithValues: layout.sessions.map { ($0.id, $0) })
        projectsByID = Dictionary(uniqueKeysWithValues: layout.projects.map { ($0.id, $0) })
    }

    var allSessions: [SessionVM] { Array(sessionsByID.values) }

    func group(_ id: GroupID) -> GroupVM? { groups.first { $0.id == id } }
    func project(_ id: ProjectID) -> ProjectVM? { projectsByID[id] }
    func session(_ id: SessionID) -> SessionVM? { sessionsByID[id] }

    private var ungrouped: GroupVM? { groups.last { $0.isUngrouped } }
    private var userGroups: [GroupVM] { groups.filter { !$0.isUngrouped } }

    // MARK: Layout intents

    func moveSessions(_ ids: [SessionID], toIndex index: Int, inProject projectID: ProjectID) {
        guard let project = projectsByID[projectID] else { return }
        // A session's cwd is fixed: only sessions already in this project can move; externals
        // never move and stay after the CODD sessions (D6).
        let own = ids.filter { project.sessionIDs.contains($0) && sessionsByID[$0]?.external == false }
        let coddCount = project.sessionIDs.prefix { sessionsByID[$0]?.external != true }.count
        let moved = ListMove.apply(project.sessionIDs, moving: own, to: min(index, coddCount))
        if moved != project.sessionIDs { project.sessionIDs = moved }
    }

    func moveProjects(_ ids: [ProjectID], toGroup groupID: GroupID, atIndex index: Int) {
        guard let target = group(groupID) else { return }
        let moving = ids.filter { projectsByID[$0] != nil }
        // The index refers to the target list as the user saw it (before the move).
        let arranged = ListMove.apply(target.projectIDs, moving: moving, to: index)
        for g in groups where g.id != groupID {
            let rest = g.projectIDs.filter { !moving.contains($0) }
            if rest != g.projectIDs { g.projectIDs = rest }
        }
        if arranged != target.projectIDs { target.projectIDs = arranged }
        for id in moving { if let p = projectsByID[id], p.groupID != groupID { p.groupID = groupID } }
    }

    func moveGroups(_ ids: [GroupID], toIndex index: Int) {
        let users = userGroups
        let order = ListMove.apply(users.map(\.id), moving: ids.filter { id in users.contains { $0.id == id } }, to: index)
        let reordered = order.compactMap { id in users.first { $0.id == id } } + (ungrouped.map { [$0] } ?? [])
        if reordered.map(\.id) != groups.map(\.id) { groups = reordered }
    }

    func setCollapsed(_ collapsed: Bool, group id: GroupID) {
        if let g = group(id), g.isCollapsed != collapsed { g.isCollapsed = collapsed }
    }

    func setCollapsed(_ collapsed: Bool, project id: ProjectID) {
        if let p = projectsByID[id], p.isCollapsed != collapsed { p.isCollapsed = collapsed }
    }

    @discardableResult
    func addGroup(name: String, color: TagColor?) -> GroupID {
        var id = "group-\(nextGroupNumber)"
        while group(id) != nil { nextGroupNumber += 1; id = "group-\(nextGroupNumber)" }
        nextGroupNumber += 1
        let g = GroupVM(id: id, name: name, shortName: name, color: color, projectIDs: [])
        var list = userGroups
        list.append(g)
        groups = list + (ungrouped.map { [$0] } ?? [])
        return id
    }

    func deleteGroup(_ id: GroupID) {
        guard let g = group(id), !g.isUngrouped, let bucket = ungrouped else { return }
        for pid in g.projectIDs { projectsByID[pid]?.groupID = bucket.id }
        bucket.projectIDs += g.projectIDs
        groups.removeAll { $0.id == id }
    }

    func renameGroup(_ id: GroupID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let g = group(id), !trimmed.isEmpty, g.name != trimmed else { return }
        g.name = trimmed
        g.shortName = trimmed.replacingOccurrences(of: " · ", with: "·")
    }

    func setGroupColor(_ color: TagColor?, group id: GroupID) {
        if let g = group(id), !g.isUngrouped, g.color != color { g.color = color }
    }

    // MARK: Session intents

    func renameSession(_ id: SessionID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = sessionsByID[id], !trimmed.isEmpty, s.title != trimmed else { return }
        s.title = trimmed
    }

    func setTag(_ tag: TagColor?, sessions ids: [SessionID]) {
        for id in ids { if let s = sessionsByID[id], s.tag != tag { s.tag = tag } }
    }

    func setPinned(_ pinned: Bool, sessions ids: [SessionID]) {
        var list = pinnedSessionIDs
        for id in ids {
            guard let s = sessionsByID[id] else { continue }
            if s.isPinned != pinned { s.isPinned = pinned }
            if pinned, !list.contains(id) { list.append(id) }
            if !pinned { list.removeAll { $0 == id } }
        }
        if list != pinnedSessionIDs { pinnedSessionIDs = list }
    }

    func archive(_ ids: [SessionID]) -> @MainActor () -> Void {
        struct Removed { let session: SessionVM; let projectID: ProjectID; let index: Int; let pinIndex: Int? }
        var removed: [Removed] = []
        for id in ids {
            guard let s = sessionsByID[id], !s.external, let p = projectsByID[s.projectID],
                  let index = p.sessionIDs.firstIndex(of: id) else { continue }
            removed.append(Removed(session: s, projectID: p.id, index: index, pinIndex: pinnedSessionIDs.firstIndex(of: id)))
        }
        for r in removed {
            projectsByID[r.projectID]?.sessionIDs.removeAll { $0 == r.session.id }
            pinnedSessionIDs.removeAll { $0 == r.session.id }
            sessionsByID[r.session.id] = nil
            archivedByID[r.session.id] = r.session
        }
        for r in removed { projectsByID[r.projectID]?.archivedCount += 1 }
        return { [weak self] in
            guard let self else { return }
            for r in removed.reversed() {
                guard self.archivedByID.removeValue(forKey: r.session.id) != nil else { continue }
                self.sessionsByID[r.session.id] = r.session
                if let p = self.projectsByID[r.projectID] {
                    p.sessionIDs.insert(r.session.id, at: min(r.index, p.sessionIDs.count))
                    p.archivedCount = max(0, p.archivedCount - 1)
                }
                if let pin = r.pinIndex { self.pinnedSessionIDs.insert(r.session.id, at: min(pin, self.pinnedSessionIDs.count)) }
            }
        }
    }

    func unarchive(_ ids: [SessionID]) {
        for id in ids {
            guard let s = archivedByID.removeValue(forKey: id), let p = projectsByID[s.projectID] else { continue }
            sessionsByID[id] = s
            let coddCount = p.sessionIDs.prefix { sessionsByID[$0]?.external != true }.count
            p.sessionIDs.insert(id, at: coddCount)
            p.archivedCount = max(0, p.archivedCount - 1)
            if s.isPinned, !pinnedSessionIDs.contains(id) { pinnedSessionIDs.append(id) }
        }
    }

    func archivedSessions(inProject id: ProjectID) -> [SessionVM] {
        archivedByID.values.filter { $0.projectID == id }.sorted { ($0.stateSince, $0.id) > ($1.stateSince, $1.id) }
    }

    func stop(_ ids: [SessionID]) {
        for id in ids {
            guard let s = sessionsByID[id], !s.external, s.state.isLive else { continue }
            transition(s, to: .stopped)
        }
    }

    func resume(_ id: SessionID) {
        guard let s = sessionsByID[id], !s.external, !s.state.isLive else { return }
        transition(s, to: .starting)
        s.startedAt = clock.now()
        settleLater(s, to: .idle)
    }

    func restart(_ id: SessionID) {
        guard let s = sessionsByID[id], !s.external else { return }
        transition(s, to: .starting)
        s.startedAt = clock.now()
        s.contextPercent = s.kind == .claude ? 100 : nil
        s.costUSD = s.kind == .claude ? 0 : nil
        settleLater(s, to: s.kind == .claude ? .idle : .shell)
    }

    /// Mock: nothing on disk; the session just leaves (never an external or a live one).
    @discardableResult
    func deleteHistory(_ id: SessionID) async -> Bool {
        guard let s = sessionsByID[id], !s.external, !s.state.isLive else { return false }
        removeSessions([id])
        return true
    }

    func removeSessions(_ ids: [SessionID]) {
        for id in ids {
            guard let s = sessionsByID[id] ?? archivedByID[id], !s.external else { continue }
            projectsByID[s.projectID]?.sessionIDs.removeAll { $0 == id }
            pinnedSessionIDs.removeAll { $0 == id }
            sessionsByID[id] = nil
            archivedByID[id] = nil
        }
    }

    func renameProject(_ id: ProjectID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = projectsByID[id], !trimmed.isEmpty, p.name != trimmed else { return }
        p.name = trimmed
    }

    func removeProject(_ id: ProjectID) {
        guard let p = projectsByID[id] else { return }
        removeSessions(p.sessionIDs + archivedByID.values.filter { $0.projectID == id }.map(\.id))
        // Mock only: its externals go with it (the real store places them again).
        for sid in p.sessionIDs where sessionsByID[sid]?.external == true { sessionsByID[sid] = nil }
        for g in groups where g.projectIDs.contains(id) { g.projectIDs.removeAll { $0 == id } }
        projectsByID[id] = nil
    }

    func answer(_ id: SessionID, key: String) {
        guard let s = sessionsByID[id], !s.external, s.state == .waiting else { return }
        if key == "esc" {
            transition(s, to: .idle)
        } else {
            let tool = s.waitingReason == .question ? "Write" : (s.tool ?? "Bash")
            transition(s, to: .busy)
            s.tool = tool
        }
    }

    func markSeen(_ id: SessionID) {
        if let s = sessionsByID[id], s.state == .done { s.state = .idle }
    }

    // MARK: Helpers

    private func transition(_ s: SessionVM, to state: SessionState) {
        s.state = state
        s.stateSince = clock.now()
        if state != .waiting {
            s.waitingReason = nil
            if !s.answerOptions.isEmpty { s.answerOptions = [] }
        }
        if state != .error { s.errorReason = nil }
        if state != .busy && state != .waiting { s.tool = nil }
        if state != .waiting && state != .error && s.kind == .claude { s.detail = nil }
    }

    /// Mock only: a resumed / restarted session reaches its resting state shortly after.
    private func settleLater(_ s: SessionVM, to state: SessionState) {
        let id = s.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, let s = self.sessionsByID[id], s.state == .starting else { return }
            self.transition(s, to: state)
        }
    }
}

/// Moving a subset of a list to an index expressed in the ORIGINAL list (the index a drop
/// indicator shows, NSOutlineView semantics). Order among moved items is preserved.
enum ListMove {
    static func apply<T: Equatable>(_ list: [T], moving: [T], to index: Int) -> [T] {
        let moved = list.filter { moving.contains($0) } + moving.filter { !list.contains($0) }
        guard !moved.isEmpty else { return list }
        let clamped = max(0, min(index, list.count))
        let before = list[..<clamped].filter { moving.contains($0) }.count
        var rest = list.filter { !moving.contains($0) }
        rest.insert(contentsOf: moved, at: max(0, min(rest.count, clamped - before)))
        return rest
    }
}
