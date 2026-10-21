import Foundation

/// A request to start (or resume) one session.
public struct LaunchRequest: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// `--session-id <uuid>`: a new conversation with a pre-assigned id.
        case new
        /// `--resume <id>`: continue a persisted conversation (reboot → resume). The id is
        /// ``LaunchRequest/resumeClaudeSessionId``, else ``LaunchRequest/sessionId``.
        case resume
    }

    public var profile: LaunchProfile
    public var cwd: String
    /// The CODD session id (also the Claude `--session-id` for new claude sessions).
    public var sessionId: UUID
    public var mode: Mode
    /// ``Mode/resume`` only: the Claude conversation to resume. Pass the CURRENT Claude session id
    /// (the latest hook `session_id`, ``SessionRecord/claudeSessionId``): after `/clear`, `/branch`
    /// or an in-session `/resume` it differs from the CODD ``sessionId``, and resuming the CODD id
    /// would reopen the conversation from before that point. `nil` = ``sessionId``.
    public var resumeClaudeSessionId: String?
    /// `-n <name>` (claude only); blank = omitted.
    public var name: String?
    /// Overrides the profile's default model.
    public var model: String?
    /// Overrides the profile's default permission mode.
    public var permissionMode: PermissionMode?
    /// D12 account pin (claude only): `CLAUDE_CONFIG_DIR` for the session, a cswap session profile
    /// (`CswapStateAccount.sessionProfile.path`, the exact string `AccountKey` hashes). Must be
    /// absolute; it wins over a profile's own `CLAUDE_CONFIG_DIR` and removes the auth-override
    /// variables (``LaunchBuilder/authOverrideNames``) like `cswap run`. Never log it (it contains
    /// the e-mail slug, D31).
    public var claudeConfigDir: String?
    /// M4 D18 (claude only): the session's `<sessionDir>/mcp.json` (``MCPLaunchConfig``), passed as
    /// `--mcp-config <path>` right before `--settings`. Must be absolute. Ignored without hook
    /// settings (``LaunchBuilder/hooks`` nil): CODD's MCP server lives on the hook port, so there
    /// is no MCP when hooks are off (the caller logs it).
    public var mcpConfigPath: String?

    public init(profile: LaunchProfile, cwd: String, sessionId: UUID, mode: Mode = .new,
                resumeClaudeSessionId: String? = nil, name: String? = nil,
                model: String? = nil, permissionMode: PermissionMode? = nil, claudeConfigDir: String? = nil,
                mcpConfigPath: String? = nil) {
        self.profile = profile
        self.cwd = cwd
        self.sessionId = sessionId
        self.mode = mode
        self.resumeClaudeSessionId = resumeClaudeSessionId
        self.name = name
        self.model = model
        self.permissionMode = permissionMode
        self.claudeConfigDir = claudeConfigDir
        self.mcpConfigPath = mcpConfigPath
    }
}

/// The holder's child: argv (argv[0] is an absolute path), exact environment, cwd.
public struct LaunchSpec: Sendable, Equatable {
    public var argv: [String]
    public var environment: [String: String]
    public var cwd: String
    /// Exactly the variables the M3 launch adds (``CoddEnvironmentName/statusLineChain``,
    /// `CLAUDE_CONFIG_DIR` of an account pin), already applied to ``environment``. The app builds
    /// holder environments itself (ShellEnvironment), so it merges these into its `extra`.
    public var coddEnvironment: [String: String] = [:]
    /// Names removed from ``environment`` (the auth overrides of a pinned session); the app drops
    /// them from its own environment too.
    public var removedNames: Set<String> = []

    public init(argv: [String], environment: [String: String], cwd: String,
                coddEnvironment: [String: String] = [:], removedNames: Set<String> = []) {
        self.argv = argv
        self.environment = environment
        self.cwd = cwd
        self.coddEnvironment = coddEnvironment
        self.removedNames = removedNames
    }

    /// The holder `--env-file` bytes for ``environment``.
    public func environmentFile() throws -> Data {
        try EnvironmentFile.encode(environment)
    }
}

public enum LaunchBuildError: Error, Equatable {
    case relativeCwd(String)
    case executableNotFound(String)
    /// A profile extra argument collides with a flag the builder owns.
    case reservedArgument(String)
    /// Model / permission mode must be a single token that does not look like a flag.
    case invalidValue(flag: String, value: String)
    case invalidShell(String)
}

/// Builds the child argv + environment for a launch (SPEC §5 command preview:
/// `claude --session-id 7c1e9a04-… --model opus-5.5 --permission-mode acceptEdits -n "…"`, plus
/// `--mcp-config <sessionDir>/mcp.json` (M4, when given), `--settings '<hooks json>'` and the
/// profile's extra flags). `--model` appears only when the request or the profile names a model:
/// the built-in profiles name none, so by default Claude Code's own `model` setting applies.
public struct LaunchBuilder: Sendable {
    /// Flags the builder sets itself; profiles may not pass them.
    public static let reservedFlags: Set<String> = [
        "--session-id", "-r", "--resume", "-c", "--continue", "--fork-session", "--settings",
        "-n", "--name", "--model", "--permission-mode",
    ]
    public static let nameMax = 200
    /// claude_swap/session.py `AUTH_OVERRIDE_ENV_VARS`: variables that make claude bypass the
    /// account's OAuth login, so a pinned session would silently run on another identity (D12).
    public static let authOverrideNames: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    ]
    /// The encoded chain must stay well below the environment limits of the holder and claude.
    public static let maxEncodedChainBytes = 16 * 1024

    public var environmentBuilder: SpawnEnvironmentBuilder
    public var hooks: ClaudeHookSettings?
    /// Whether a path is an executable file (injectable for tests).
    public var isExecutable: @Sendable (String) -> Bool

    public init(environmentBuilder: SpawnEnvironmentBuilder = SpawnEnvironmentBuilder(),
                hooks: ClaudeHookSettings?,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.environmentBuilder = environmentBuilder
        self.hooks = hooks
        self.isExecutable = isExecutable
    }

    /// - Parameters:
    ///   - baseEnvironment: the app's environment.
    ///   - loginEnvironment: captured login-shell environment (`nil` → defaults).
    ///   - hookToken: per-install hook token (claude sessions only).
    public func build(_ request: LaunchRequest, baseEnvironment: [String: String],
                      loginEnvironment: [String: String]?, hookToken: String) throws -> LaunchSpec {
        guard request.cwd.hasPrefix("/") else { throw LaunchBuildError.relativeCwd(request.cwd) }
        let isClaude = request.profile.kind == .claude
        var env = environmentBuilder.build(
            base: baseEnvironment, login: loginEnvironment, sessionId: request.sessionId,
            hookToken: isClaude ? hookToken : nil, overrides: request.profile.environment)

        // M3: CODD's own additions, applied after the profile's environment so they win.
        var codd: [String: String] = [:]
        var removed: Set<String> = []
        if isClaude {
            if let chain = hooks?.statusLine?.chainCommand, let encoded = Self.encodedChain(chain) {
                codd[CoddEnvironmentName.statusLineChain] = encoded
            }
            if let dir = request.claudeConfigDir {
                guard dir.hasPrefix("/"), !dir.contains("\0") else {
                    throw LaunchBuildError.invalidValue(flag: "CLAUDE_CONFIG_DIR", value: dir)
                }
                codd["CLAUDE_CONFIG_DIR"] = dir
                removed = Self.authOverrideNames
            }
        }
        for name in removed { env[name] = nil }
        env.merge(codd) { _, ours in ours }

        let argv: [String]
        switch request.profile.kind {
        case .claude:
            argv = try claudeArguments(request, path: env["PATH"] ?? "", home: env["HOME"] ?? NSHomeDirectory())
        case .shell:
            let shell = request.profile.shellPath ?? env["SHELL"] ?? "/bin/zsh"
            guard shell.hasPrefix("/"), isExecutable(shell) else { throw LaunchBuildError.invalidShell(shell) }
            argv = [shell, "-l"]
        }
        return LaunchSpec(argv: argv, environment: env, cwd: request.cwd, coddEnvironment: codd, removedNames: removed)
    }

    /// Base64 of the command's UTF-8, or `nil` when it is blank or encodes to more than
    /// ``maxEncodedChainBytes`` (then the user's status line is not chained).
    static func encodedChain(_ command: String) -> String? {
        guard !JSText.trim(command).isEmpty else { return nil }
        let encoded = Data(command.utf8).base64EncodedString()
        return encoded.utf8.count <= maxEncodedChainBytes ? encoded : nil
    }

    private func claudeArguments(_ request: LaunchRequest, path: String, home: String) throws -> [String] {
        for arg in request.profile.extraArguments {
            let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if Self.reservedFlags.contains(flag) { throw LaunchBuildError.reservedArgument(arg) }
        }
        let uuid = request.sessionId.uuidString.lowercased()
        var argv = [try resolveClaude(path: path, home: home)]
        switch request.mode {
        case .new:
            argv += ["--session-id", uuid]
        case .resume:
            let id = JSText.nonBlankTrimmed(request.resumeClaudeSessionId) ?? uuid
            guard Self.isClaudeSessionId(id) else { throw LaunchBuildError.invalidValue(flag: "--resume", value: id) }
            argv += ["--resume", id]
        }
        if let model = JSText.nonBlankTrimmed(request.model ?? request.profile.defaultModel) {
            try Self.validateToken(model, flag: "--model")
            argv += ["--model", model]
        }
        if let mode = request.permissionMode ?? request.profile.defaultPermissionMode, mode != .default {
            try Self.validateToken(mode.rawValue, flag: "--permission-mode")
            argv += ["--permission-mode", mode.rawValue]
        }
        if let name = Self.cleanName(request.name) {
            // A leading "-" would be parsed as a flag; the `=` form keeps it a value.
            argv += name.hasPrefix("-") ? ["--name=\(name)"] : ["-n", name]
        }
        if let hooks {
            // `--mcp-config <configs...>` is variadic (claude 2.1.302 takes every following
            // non-option argument as another config), so it goes directly before `--settings`, an
            // option that ends the list. A profile's own `--mcp-config` stays in its extras.
            if let path = request.mcpConfigPath {
                guard path.hasPrefix("/"), !path.contains("\0") else {
                    throw LaunchBuildError.invalidValue(flag: "--mcp-config", value: path)
                }
                argv += ["--mcp-config", path]
            }
            argv += ["--settings", try hooks.settingsJSON()]
        }
        argv += request.profile.extraArguments
        return argv
    }

    /// `claude` on the session PATH, else `~/.local/bin/claude` (the native installer's link).
    func resolveClaude(path: String, home: String) throws -> String {
        for dir in path.split(separator: ":") where dir.hasPrefix("/") {
            let candidate = dir.hasSuffix("/") ? "\(dir)claude" : "\(dir)/claude"
            if isExecutable(candidate) { return candidate }
        }
        let fallback = "\(home)/.local/bin/claude"
        if isExecutable(fallback) { return fallback }
        throw LaunchBuildError.executableNotFound("claude")
    }

    /// session-insights.js `CLAUDE_SESSION_ID_RE` (`^[A-Za-z0-9-]{1,128}$`), and no leading `-` (it
    /// would be parsed as a flag).
    static func isClaudeSessionId(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && !id.hasPrefix("-") && id.utf8.allSatisfy {
            $0 == 0x2D || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
        }
    }

    static func validateToken(_ value: String, flag: String) throws {
        let ok = !value.hasPrefix("-") && !value.unicodeScalars.contains {
            JSText.isWhitespace($0) || $0.value < 0x20 || $0.value == 0x7F
        }
        if !ok { throw LaunchBuildError.invalidValue(flag: flag, value: value) }
    }

    /// Control characters removed, whitespace collapsed, at most ``nameMax`` code points.
    static func cleanName(_ name: String?) -> String? {
        name.flatMap { JSText.cleanText($0, max: nameMax) }
    }
}
