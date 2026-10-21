import Foundation

/// Claude Code `--permission-mode` values. Open set (new modes keep working).
///
/// Claude Code 2.1.300 accepts `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk` and
/// `plan` (`claude --help`); `default` is no longer a valid choice. ``default`` therefore means
/// "pass no flag" (the user's `permissions.defaultMode` applies) and ``LaunchBuilder`` omits it.
public struct PermissionMode: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// No `--permission-mode` flag (Claude's configured default applies).
    public static let `default` = PermissionMode(rawValue: "default")
    /// Ask for every permission (formerly `default`).
    public static let manual = PermissionMode(rawValue: "manual")
    public static let plan = PermissionMode(rawValue: "plan")
    public static let acceptEdits = PermissionMode(rawValue: "acceptEdits")
    public static let auto = PermissionMode(rawValue: "auto")
    public static let dontAsk = PermissionMode(rawValue: "dontAsk")
    public static let bypassPermissions = PermissionMode(rawValue: "bypassPermissions")
}

/// A reusable way to start a session (SPEC §5 launch profiles).
public struct LaunchProfile: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        case claude
        case shell
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// claude: default `--model` (request may override). nil = no flag (Claude Code's own
    /// `model` applies); the built-ins never name one, so a model here was set on purpose.
    public var defaultModel: String?
    /// claude: default `--permission-mode` (request may override).
    public var defaultPermissionMode: PermissionMode?
    /// claude: extra flags appended last (e.g. `--remote-control`). Flags the builder owns
    /// (session id, resume, settings, name, model, permission mode) are rejected.
    public var extraArguments: [String]
    /// shell: absolute shell path (`nil` = the user's `$SHELL`).
    public var shellPath: String?
    /// Extra environment (sanitized by ``SpawnEnvironmentBuilder``), e.g. `CLAUDE_CONFIG_DIR`.
    public var environment: [String: String]

    public init(id: String, name: String, kind: Kind, defaultModel: String? = nil,
                defaultPermissionMode: PermissionMode? = nil, extraArguments: [String] = [],
                shellPath: String? = nil, environment: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultModel = defaultModel
        self.defaultPermissionMode = defaultPermissionMode
        self.extraArguments = extraArguments
        self.shellPath = shellPath
        self.environment = environment
    }

    /// SPEC §5 / Settings artboard: `claude-default`, `claude-plan`, `claude-rc`, `zsh` (name = id;
    /// the command each runs is ``LaunchProfileEditing/profileCommand(_:)``).
    public static let builtIn: [LaunchProfile] = [
        LaunchProfile(id: "claude-default", name: "claude-default", kind: .claude),
        LaunchProfile(id: "claude-plan", name: "claude-plan", kind: .claude, defaultPermissionMode: .plan),
        LaunchProfile(id: "claude-rc", name: "claude-rc", kind: .claude, extraArguments: ["--remote-control"]),
        LaunchProfile(id: "zsh", name: "zsh", kind: .shell),
    ]
}
