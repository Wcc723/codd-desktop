import Foundation

/// A user-defined group of projects (SPEC §2: Group → Project → Session, one level of groups).
///
/// Named `ProjectGroup` (not `Group`) so app code can import SwiftUI and CoddCore together.
public struct ProjectGroup: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ColorTag
    /// Manual order among groups (never reshuffled by state).
    public var order: Int
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, color: ColorTag = .none, order: Int, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.collapsed = collapsed
    }
}

/// A project = one working directory. Inherits its group's color unless overridden.
public struct Project: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// `nil` = ungrouped (`未分類 UNGROUPED`).
    public var groupId: UUID?
    public var name: String
    /// Absolute path of the cwd.
    public var path: String
    /// Manual order within the group.
    public var order: Int
    public var colorOverride: ColorTag?
    public var pinned: Bool
    /// Collapsed in the sidebar tree (a view preference, kept with the layout so it survives relaunch).
    public var collapsed: Bool

    public init(id: UUID = UUID(), groupId: UUID? = nil, name: String, path: String, order: Int,
                colorOverride: ColorTag? = nil, pinned: Bool = false, collapsed: Bool = false) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.path = path
        self.order = order
        self.colorOverride = colorOverride
        self.pinned = pinned
        self.collapsed = collapsed
    }

    /// The color to draw: the override, else the group's color.
    public func effectiveColor(group: ProjectGroup?) -> ColorTag {
        colorOverride ?? group?.color ?? .none
    }
}

/// Session kinds (SPEC §2).
public enum SessionKind: String, Sendable, Codable, CaseIterable {
    /// `claude` CLI in a PTY.
    case claude
    /// A plain shell in the project's cwd (glyph `$`).
    case shell
}

/// A persisted session row. Runtime state (hooks, registry, holder) is not stored here except the
/// last known state for the `stopped` / restore view.
public struct SessionRecord: Sendable, Equatable, Identifiable {
    /// The CODD session id. For claude sessions it is also the initial `--session-id`, the holder's
    /// `--session` and the hook `X-CODD-Session` value.
    public var id: UUID
    /// The current Claude session id (changes after /clear or a fork); `nil` for shells.
    public var claudeSessionId: String?
    public var projectId: UUID
    public var kind: SessionKind
    /// Last title learned from Claude (hook / statusline / transcript).
    public var title: String?
    /// User rename; wins over everything.
    public var titleOverride: String?
    public var color: ColorTag
    public var pinned: Bool
    /// Manual order within the project.
    public var order: Int
    public var createdAt: Date
    public var lastState: SessionState?
    public var lastStateAt: Date?
    /// Holder socket path while a holder is known to run.
    public var holderSocket: String?
    public var launchProfileId: String?
    public var model: String?
    public var permissionMode: String?
    /// cswap account number when the session is pinned to an account (`cswap run`); `nil` = global.
    public var accountNumber: Int?
    public var archivedAt: Date?
    /// Last time the user looked at the session. Decides DONE (finished unseen) vs IDLE after a
    /// relaunch, so a turn the user already read does not come back as DONE.
    public var lastViewedAt: Date?

    public init(
        id: UUID = UUID(), claudeSessionId: String? = nil, projectId: UUID, kind: SessionKind,
        title: String? = nil, titleOverride: String? = nil, color: ColorTag = .none, pinned: Bool = false,
        order: Int, createdAt: Date, lastState: SessionState? = nil, lastStateAt: Date? = nil,
        holderSocket: String? = nil, launchProfileId: String? = nil, model: String? = nil,
        permissionMode: String? = nil, accountNumber: Int? = nil, archivedAt: Date? = nil, lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.claudeSessionId = claudeSessionId
        self.projectId = projectId
        self.kind = kind
        self.title = title
        self.titleOverride = titleOverride
        self.color = color
        self.pinned = pinned
        self.order = order
        self.createdAt = createdAt
        self.lastState = lastState
        self.lastStateAt = lastStateAt
        self.holderSocket = holderSocket
        self.launchProfileId = launchProfileId
        self.model = model
        self.permissionMode = permissionMode
        self.accountNumber = accountNumber
        self.archivedAt = archivedAt
        self.lastViewedAt = lastViewedAt
    }

    /// Title priority (critic.md C10, app side): user override > learned title > fallback.
    public func displayTitle(fallback: String) -> String {
        JSText.nonBlankTrimmed(titleOverride) ?? JSText.nonBlankTrimmed(title) ?? fallback
    }
}

// MARK: - Codable (tolerant: missing optional fields take defaults, unknown keys are ignored)

extension ProjectGroup: Codable {
    enum CodingKeys: String, CodingKey { case id, name, color, order, collapsed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.lenient(String.self, forKey: .name) ?? ""
        color = c.lenient(ColorTag.self, forKey: .color) ?? .none
        order = c.lenient(Int.self, forKey: .order) ?? 0
        collapsed = c.lenient(Bool.self, forKey: .collapsed) ?? false
    }
}

extension Project: Codable {
    enum CodingKeys: String, CodingKey { case id, groupId, name, path, order, colorOverride, pinned, collapsed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        groupId = c.lenient(UUID.self, forKey: .groupId)
        name = c.lenient(String.self, forKey: .name) ?? ""
        path = try c.decode(String.self, forKey: .path)
        order = c.lenient(Int.self, forKey: .order) ?? 0
        colorOverride = c.lenient(ColorTag.self, forKey: .colorOverride)
        pinned = c.lenient(Bool.self, forKey: .pinned) ?? false
        collapsed = c.lenient(Bool.self, forKey: .collapsed) ?? false
    }
}

extension SessionRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case id, claudeSessionId, projectId, kind, title, titleOverride, color, pinned, order, createdAt,
             lastState, lastStateAt, holderSocket, launchProfileId, model, permissionMode, accountNumber, archivedAt,
             lastViewedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        claudeSessionId = c.lenient(String.self, forKey: .claudeSessionId)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        kind = c.lenient(SessionKind.self, forKey: .kind) ?? .claude
        title = c.lenient(String.self, forKey: .title)
        titleOverride = c.lenient(String.self, forKey: .titleOverride)
        color = c.lenient(ColorTag.self, forKey: .color) ?? .none
        pinned = c.lenient(Bool.self, forKey: .pinned) ?? false
        order = c.lenient(Int.self, forKey: .order) ?? 0
        createdAt = c.lenient(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastState = c.lenient(SessionState.self, forKey: .lastState)
        lastStateAt = c.lenient(Date.self, forKey: .lastStateAt)
        holderSocket = c.lenient(String.self, forKey: .holderSocket)
        launchProfileId = c.lenient(String.self, forKey: .launchProfileId)
        model = c.lenient(String.self, forKey: .model)
        permissionMode = c.lenient(String.self, forKey: .permissionMode)
        accountNumber = c.lenient(Int.self, forKey: .accountNumber)
        archivedAt = c.lenient(Date.self, forKey: .archivedAt)
        lastViewedAt = c.lenient(Date.self, forKey: .lastViewedAt)
    }
}
