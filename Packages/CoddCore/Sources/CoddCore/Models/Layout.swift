import Foundation

/// The persisted sidebar layout: groups, projects and sessions with their manual order.
public struct Layout: Sendable, Equatable {
    /// Current on-disk format version.
    public static let currentVersion = 1

    public var groups: [ProjectGroup]
    public var projects: [Project]
    public var sessions: [SessionRecord]

    public init(groups: [ProjectGroup] = [], projects: [Project] = [], sessions: [SessionRecord] = []) {
        self.groups = groups
        self.projects = projects
        self.sessions = sessions
    }

    public static let empty = Layout()

    /// Groups in manual order.
    public var orderedGroups: [ProjectGroup] {
        groups.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// Projects of a group (`nil` = ungrouped) in manual order.
    public func projects(inGroup groupId: UUID?) -> [Project] {
        projects.filter { $0.groupId == groupId }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// Non-archived sessions of a project in manual order.
    public func sessions(inProject projectId: UUID) -> [SessionRecord] {
        sessions.filter { $0.projectId == projectId && $0.archivedAt == nil }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    /// The project whose path equals `path` after standardization (`~`, `.`/`..`, trailing `/`).
    public func project(forPath path: String) -> Project? {
        let wanted = Self.standardize(path)
        return projects.first { Self.standardize($0.path) == wanted }
    }

    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Moves a session to `index` within its own project (sessions never change project) and
    /// renumbers that project's sessions 0…n-1.
    public mutating func moveSession(_ id: UUID, toIndex index: Int) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        var ordered = sessions(inProject: s.projectId).map(\.id)
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: min(max(0, index), ordered.count))
        for (n, sid) in ordered.enumerated() {
            if let j = sessions.firstIndex(where: { $0.id == sid }) { sessions[j].order = n }
        }
    }

    /// Moves a project into `groupId` (`nil` = ungrouped) at `index`, renumbering the target group.
    public mutating func moveProject(_ id: UUID, toGroup groupId: UUID?, index: Int) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].groupId = groupId
        var ordered = projects(inGroup: groupId).map(\.id)
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: min(max(0, index), ordered.count))
        for (n, pid) in ordered.enumerated() {
            if let j = projects.firstIndex(where: { $0.id == pid }) { projects[j].order = n }
        }
    }

    /// Moves a group to `index` among groups.
    public mutating func moveGroup(_ id: UUID, toIndex index: Int) {
        var ordered = orderedGroups.map(\.id)
        guard ordered.contains(id) else { return }
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: min(max(0, index), ordered.count))
        for (n, gid) in ordered.enumerated() {
            if let j = groups.firstIndex(where: { $0.id == gid }) { groups[j].order = n }
        }
    }
}

extension Layout: Codable {
    enum CodingKeys: String, CodingKey { case version, groups, projects, sessions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = (c.lenient(LossyArray<ProjectGroup>.self, forKey: .groups))?.elements ?? []
        projects = (c.lenient(LossyArray<Project>.self, forKey: .projects))?.elements ?? []
        sessions = (c.lenient(LossyArray<SessionRecord>.self, forKey: .sessions))?.elements ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(groups, forKey: .groups)
        try c.encode(projects, forKey: .projects)
        try c.encode(sessions, forKey: .sessions)
    }
}
