import CoddCore
import Foundation

/// CoddCore's persisted session row (the bare name clashes with CoddHolderClient's discovery
/// record in files that import both).
typealias LayoutSessionRecord = CoddCore.SessionRecord

/// `<dataRoot>/layout.json` ↔ the real store's view models: groups, projects and sessions with
/// their manual order, names, colors, pins, collapse state, archive, and the facts a relaunch
/// needs (kind, current Claude session id for RESUME, launch options, last state, last viewed).
@MainActor
enum LayoutMapping {
    static let ungroupedID: GroupID = "ungrouped"

    /// What `model(from:)` rebuilds. Sessions not in `tree` are archived.
    struct Model {
        var groups: [GroupVM]
        var projects: [ProjectID: ProjectVM]
        var sessions: [SessionID: SessionVM]
        var archived: [SessionID: SessionVM]
        var records: [SessionID: LayoutSessionRecord]
        var projectRecords: [ProjectID: Project]
        var pinned: [SessionID]
    }

    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    static func ungroupedGroup(projectIDs: [ProjectID] = []) -> GroupVM {
        GroupVM(id: ungroupedID, name: "未分類", shortName: "未分類", color: nil, projectIDs: projectIDs, isUngrouped: true)
    }

    /// `藍鵲 · 網站` → `藍鵲·網站` (breadcrumbs).
    static func shortName(_ name: String) -> String { name.replacingOccurrences(of: " · ", with: "·") }

    static func tag(_ color: ColorTag) -> TagColor? { TagColor(rawValue: color.rawValue) }
    static func color(_ tag: TagColor?) -> ColorTag { tag.flatMap { ColorTag(rawValue: $0.rawValue) } ?? ColorTag.none }

    /// View models for a loaded layout. States are placeholders (`stopped` / `exited`) until the
    /// store merged what the holders report. Sessions of a project that no longer exists are
    /// dropped; projects of a missing group land in the ungrouped bucket.
    static func model(from layout: Layout) -> Model {
        var groups: [GroupVM] = []
        var projects: [ProjectID: ProjectVM] = [:]
        var sessions: [SessionID: SessionVM] = [:]
        var archived: [SessionID: SessionVM] = [:]
        var records: [SessionID: LayoutSessionRecord] = [:]
        var projectRecords: [ProjectID: Project] = [:]
        let knownGroups = Set(layout.groups.map(\.id))

        func makeProject(_ p: Project, groupID: GroupID) -> ProjectVM {
            let pid = id(p.id)
            let all = layout.sessions.filter { $0.projectId == p.id }
            let live = layout.sessions(inProject: p.id)
            let vm = ProjectVM(id: pid, name: p.name.isEmpty ? HolderSessionStore.projectName(cwd: p.path) : p.name, cwd: p.path,
                               groupID: groupID, sessionIDs: live.map { id($0.id) },
                               archivedCount: all.count - live.count, isCollapsed: p.collapsed)
            projectRecords[pid] = p
            for record in all {
                let sid = id(record.id)
                records[sid] = record
                let session = SessionVM(id: sid, projectID: pid, kind: record.kind == .shell ? .shell : .claude,
                                        title: record.displayTitle(fallback: record.kind == .shell ? "zsh" : "claude"),
                                        state: record.kind == .shell ? .exited : .stopped,
                                        stateSince: record.lastStateAt ?? record.createdAt)
                session.tag = tag(record.color)
                session.isPinned = record.pinned
                session.claudeSessionID = record.kind == .claude ? record.claudeSessionId ?? sid : nil
                if record.archivedAt == nil { sessions[sid] = session } else { archived[sid] = session }
            }
            projects[pid] = vm
            return vm
        }

        for group in layout.orderedGroups {
            let gid = id(group.id)
            let members = layout.projects(inGroup: group.id).map { makeProject($0, groupID: gid) }
            groups.append(GroupVM(id: gid, name: group.name, shortName: shortName(group.name), color: tag(group.color),
                                  projectIDs: members.map(\.id), isCollapsed: group.collapsed))
        }
        let loose = layout.projects.filter { $0.groupId.map { !knownGroups.contains($0) } ?? true }
            .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        let ungrouped = loose.map { makeProject($0, groupID: ungroupedID) }
        groups.append(ungroupedGroup(projectIDs: ungrouped.map(\.id)))

        // Pins in tree order (the layout keeps a flag, not the pin order).
        var pinned: [SessionID] = []
        for group in groups {
            for pid in group.projectIDs {
                for sid in projects[pid]?.sessionIDs ?? [] where sessions[sid]?.isPinned == true { pinned.append(sid) }
            }
        }
        return Model(groups: groups, projects: projects, sessions: sessions, archived: archived, records: records,
                     projectRecords: projectRecords, pinned: pinned)
    }

    /// The layout for the current model. Each session's state is recorded too, but state changes
    /// alone never schedule a save (they are written with the next save and at quit). Transient
    /// projects (D6) and sessions without a record (externals) are never written.
    static func layout(groups: [GroupVM], projects: [ProjectID: ProjectVM], sessions: [SessionID: SessionVM],
                       archived: [SessionID: SessionVM], records: [SessionID: LayoutSessionRecord],
                       projectRecords: [ProjectID: Project], now: Date) -> Layout {
        var outGroups: [ProjectGroup] = []
        var outProjects: [Project] = []
        var outSessions: [LayoutSessionRecord] = []
        for (groupIndex, group) in groups.filter({ !$0.isUngrouped }).enumerated() {
            guard let uuid = UUID(uuidString: group.id) else { continue }
            outGroups.append(ProjectGroup(id: uuid, name: group.name, color: color(group.color), order: groupIndex,
                                          collapsed: group.isCollapsed))
        }
        for group in groups {
            let groupUUID = group.isUngrouped ? nil : UUID(uuidString: group.id)
            let saved = group.projectIDs.filter { projects[$0]?.isTransient == false }
            for (projectIndex, pid) in saved.enumerated() {
                guard let project = projects[pid], let uuid = UUID(uuidString: pid) else { continue }
                var record = projectRecords[pid] ?? Project(id: uuid, name: project.name, path: project.cwd, order: 0)
                record.groupId = groupUUID
                record.name = project.name
                record.path = project.cwd
                record.order = projectIndex
                record.collapsed = project.isCollapsed
                outProjects.append(record)
                let live = project.sessionIDs.compactMap { sid in sessions[sid].map { (sid, $0, false) } }
                let hidden = archived.filter { $0.value.projectID == pid }.sorted { $0.key < $1.key }.map { ($0.key, $0.value, true) }
                for (order, entry) in (live + hidden).enumerated() {
                    let (sid, vm, isArchived) = entry
                    guard var row = records[sid] else { continue }
                    row.projectId = uuid
                    row.order = order
                    row.color = color(vm.tag)
                    row.pinned = vm.isPinned
                    row.kind = vm.kind == .shell ? .shell : .claude
                    if let state = persistedState(vm) {
                        row.lastState = state
                        row.lastStateAt = vm.stateSince
                    }
                    if isArchived, row.archivedAt == nil { row.archivedAt = now }
                    if !isArchived { row.archivedAt = nil }
                    outSessions.append(row)
                }
            }
        }
        return Layout(groups: outGroups, projects: outProjects, sessions: outSessions)
    }

    /// The CoddCore state a row is remembered with (for the stopped / restore view).
    static func persistedState(_ vm: SessionVM) -> CoddCore.SessionState? {
        switch vm.state {
        case .waiting: .waiting(CoddCore.WaitingReason(rawValue: vm.waitingReason?.rawValue ?? "") ?? .other)
        case .error: .error(.unknown)
        case .done: .done
        case .busy: .busy
        case .compacting: .compacting
        case .idle: .idle
        case .starting: .starting
        case .unknown: .unknown
        case .shell: .shell
        case .exited: .exited(code: vm.exitCode)
        case .stopped: .stopped
        }
    }
}

/// Writes layout.json off the main actor: debounced, atomic (CoddCore `AtomicFile` via
/// `LayoutStore`), skipped when nothing changed, never over a file from a newer CODD.
@MainActor
final class LayoutSaver {
    let fileURL: URL
    private let store: LayoutStore
    private let queue = DispatchQueue(label: CoddIdentity.label("layout"), qos: .utility)
    private var task: Task<Void, Never>?
    private var lastSaved: Layout?
    /// A newer CODD wrote the file: this build never replaces it.
    private(set) var isReadOnly = false
    private let log: @MainActor (String) -> Void

    static let delay: Duration = .milliseconds(400)

    init(fileURL: URL, log: @escaping @MainActor (String) -> Void) {
        self.fileURL = fileURL
        store = LayoutStore(fileURL: fileURL)
        self.log = log
    }

    enum Loaded: Sendable {
        case layout(Layout)
        /// Unreadable: moved aside (path), a fresh layout starts.
        case corrupt(String?)
        /// Written by a newer CODD (version): never overwritten. M5 D14: shown read-only with
        /// what this version's decoder reads of it (nil: nothing decodes, the sidebar is empty).
        case newer(Int, Layout?)
    }

    /// Blocking: call off the main actor.
    nonisolated static func load(_ url: URL) -> Loaded {
        let store = LayoutStore(fileURL: url)
        do {
            return .layout(try store.load())
        } catch LayoutStoreError.unsupportedVersion(let version) {
            return .newer(version, try? store.loadNewerReadOnly())
        } catch {
            return .corrupt(try? store.moveAside().path)
        }
    }

    /// The layout to show for a load result (nil: start empty).
    nonisolated static func shown(_ result: Loaded) -> Layout? {
        switch result {
        case .layout(let layout): layout
        case .newer(_, let layout): layout
        case .corrupt: nil
        }
    }

    func loaded(_ result: Loaded) {
        switch result {
        case .layout(let layout): lastSaved = layout
        case .corrupt(let aside): log("error layout.json unreadable, moved to \(aside ?? "-")")
        case .newer(let version, let layout):
            isReadOnly = true
            log("error layout.json is version \(version) (newer CODD): "
                + (layout == nil ? "not readable here, not saving" : "shown read-only, not saving"))
        }
    }

    /// Saves `make()` after a short delay (coalesces bursts like a drag or a rename).
    func schedule(_ make: @escaping @MainActor () -> Layout) {
        guard !isReadOnly else { return }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.write(make())
        }
    }

    /// Writes now and waits (app quit).
    func flush(_ layout: Layout) {
        task?.cancel()
        task = nil
        write(layout)
        queue.sync {}
    }

    private func write(_ layout: Layout) {
        guard !isReadOnly, layout != lastSaved else { return }
        lastSaved = layout
        let store = self.store
        queue.async {
            do {
                try store.save(layout)
            } catch {
                HolderSessionStore.printLog("error cannot save layout.json: \(error)")
            }
        }
    }
}
