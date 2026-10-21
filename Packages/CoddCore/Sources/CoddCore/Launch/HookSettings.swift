import Foundation

/// Where CODD's hook sink listens (coddd, or the app in degraded mode).
public struct HookEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var path: String

    public init(port: UInt16, host: String = "127.0.0.1", path: String = "/hooks") {
        self.host = host
        self.port = port
        self.path = path
    }

    /// `http://127.0.0.1:<port>/hooks`.
    public var url: String { "http://\(host):\(port)\(path)" }
}

/// Environment variable names shared by the launch builder, the hook settings and `codd-hook`.
public enum CoddEnvironmentName {
    /// The CODD session UUID (sent as `X-CODD-Session`).
    public static let sessionId = "CODD_SESSION_ID"
    /// The per-install hook token (sent as `X-CODD-Token`).
    public static let hookToken = "CODD_HOOK_TOKEN"
    /// `http://127.0.0.1:<port>/hooks`; `codd-statusline` derives its `/statusline` URL from it.
    /// Set by the app's holder launcher (its `extra` environment), not by ``LaunchBuilder``.
    public static let hookURL = "CODD_HOOK_URL"
    /// Base64 of the user's own status-line command, chained by `codd-statusline` (D8). Kept out of
    /// argv: `ps` shows argv to every local user.
    public static let statusLineChain = "CODD_STATUSLINE_CHAIN"
}

/// HTTP header names on hook requests.
public enum CoddHookHeader {
    public static let token = "X-CODD-Token"
    public static let session = "X-CODD-Session"
}

/// Per-session hook injection for `claude --settings '<json>'`.
///
/// Verified against https://code.claude.com/docs/en/hooks (fetched 2026-10-15):
/// - `http` handler fields: `type`, `url`, `headers` (values interpolate `$VAR` / `${VAR}` only for
///   names listed in `allowedEnvVars`), `allowedEnvVars`, `timeout` (seconds), `onFailure`
///   (v2.1.295+, default `continue`; omitted here so older versions do not see an unknown key).
///   The body is the hook input JSON (`Content-Type: application/json`); non-2xx and connection
///   failures are non-blocking.
/// - `SessionStart` and `Setup` support only `command` and `mcp_tool`; `mcp_tool` hooks on the
///   launch-time SessionStart are skipped (no MCP client yet), so SessionStart uses a `command` hook
///   (`codd-hook`, spawned directly via `args`, no shell).
/// - Every other event used here supports `http`: UserPromptSubmit, PreToolUse, PostToolUse,
///   PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure, SessionEnd, PreCompact,
///   PostCompact, SubagentStart, SubagentStop.
/// - Identical handlers defined in several settings files run once, so a global installer that
///   writes the byte-identical handler does not double-post (critique M5). That is why the token
///   and session id are env-var references rather than literals: the token also stays out of argv
///   (`ps` shows argv to every local user).
public struct ClaudeHookSettings: Sendable, Equatable {
    /// Events delivered over `http`.
    public static let httpEvents: [HookEventName] = [
        .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest,
        .notification, .stop, .stopFailure, .sessionEnd, .preCompact, .postCompact,
        .subagentStart, .subagentStop,
    ]
    /// Events that get an explicit `"matcher": "*"` (same set as CODD web's installer; older
    /// Claude Code versions required a matcher on tool events).
    public static let matcherEvents: Set<HookEventName> = [
        .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .notification,
    ]

    public var endpoint: HookEndpoint
    /// Absolute path of the `codd-hook` CLI (SessionStart command hook).
    public var sessionStartCommand: String
    /// Extra arguments for `codd-hook` (the endpoint URL is always appended).
    public var sessionStartArguments: [String]
    /// http hook timeout in seconds. The sink answers 204 immediately; this bounds a stalled sink.
    public var httpTimeoutSeconds: Int
    /// SessionEnd shares a 1.5 s exit budget; a longer per-hook timeout would raise it.
    public var sessionEndTimeoutSeconds: Int
    public var sessionStartTimeoutSeconds: Int
    /// The per-session `statusLine` (D8); `nil` leaves the settings exactly as in M2.
    public var statusLine: StatusLineInjection?
    /// M4 D18 / D19: the path UserPromptSubmit is posted to (`/hooks/prompt`, where CODD expands
    /// `codd://note/<id>` refs and answers with `additionalContext`). `nil` keeps it on
    /// ``endpoint``'s path with ``httpTimeoutSeconds``, byte for byte as in M3.
    public var promptPath: String?
    /// The UserPromptSubmit timeout while ``promptPath`` is set: the server answers within 1.5 s
    /// (D19), so 3 s leaves room without letting a stalled sink hold the prompt long.
    public var promptTimeoutSeconds: Int
    /// M4 D18: `permissions.allow` rules (the codd server's read tools), emitted only when
    /// non-empty. Flag settings add to the user's own rules; append / write keep Claude's prompt.
    public var permissionsAllow: [String]

    public init(endpoint: HookEndpoint, sessionStartCommand: String, sessionStartArguments: [String] = ["session-start"],
                httpTimeoutSeconds: Int = 2, sessionEndTimeoutSeconds: Int = 1, sessionStartTimeoutSeconds: Int = 5,
                statusLine: StatusLineInjection? = nil, promptPath: String? = nil, promptTimeoutSeconds: Int = 3,
                permissionsAllow: [String] = []) {
        self.endpoint = endpoint
        self.sessionStartCommand = sessionStartCommand
        self.sessionStartArguments = sessionStartArguments
        self.httpTimeoutSeconds = httpTimeoutSeconds
        self.sessionEndTimeoutSeconds = sessionEndTimeoutSeconds
        self.sessionStartTimeoutSeconds = sessionStartTimeoutSeconds
        self.statusLine = statusLine
        self.promptPath = promptPath
        self.promptTimeoutSeconds = promptTimeoutSeconds
        self.permissionsAllow = permissionsAllow
    }

    /// Where UserPromptSubmit goes: ``endpoint``'s URL, or the same host and port with
    /// ``promptPath`` (a missing leading `/` is added).
    public var promptURL: String {
        guard let promptPath = JSText.nonBlankTrimmed(promptPath) else { return endpoint.url }
        let path = promptPath.hasPrefix("/") ? promptPath : "/" + promptPath
        return HookEndpoint(port: endpoint.port, host: endpoint.host, path: path).url
    }

    /// The `{"hooks": {...}}` settings object, plus `"statusLine"` when ``statusLine`` is set and
    /// `"permissions": {"allow": [...]}` when ``permissionsAllow`` is not empty.
    public var settingsObject: JSONValue {
        var hooks: [String: JSONValue] = [:]
        hooks[HookEventName.sessionStart.rawValue] = .array([
            .object(["hooks": .array([.object([
                "type": .string("command"),
                "command": .string(sessionStartCommand),
                "args": .array((sessionStartArguments + ["--url", endpoint.url]).map(JSONValue.string)),
                "timeout": .number(Double(sessionStartTimeoutSeconds)),
            ])])]),
        ])
        for event in Self.httpEvents {
            var group: [String: JSONValue] = ["hooks": .array([httpHandler(for: event)])]
            if Self.matcherEvents.contains(event) { group["matcher"] = .string("*") }
            hooks[event.rawValue] = .array([.object(group)])
        }
        var root: [String: JSONValue] = ["hooks": .object(hooks)]
        if let statusLine { root["statusLine"] = statusLine.settingsValue }
        if !permissionsAllow.isEmpty {
            root["permissions"] = .object(["allow": .array(permissionsAllow.map(JSONValue.string))])
        }
        return .object(root)
    }

    /// Compact JSON with sorted keys, suitable as the `--settings` argument.
    public func settingsJSON() throws -> String {
        String(decoding: try settingsObject.jsonData(), as: UTF8.self)
    }

    private func httpHandler(for event: HookEventName) -> JSONValue {
        let prompt = event == .userPromptSubmit && JSText.nonBlankTrimmed(promptPath) != nil
        let timeout = prompt ? promptTimeoutSeconds : event == .sessionEnd ? sessionEndTimeoutSeconds : httpTimeoutSeconds
        return .object([
            "type": .string("http"),
            "url": .string(prompt ? promptURL : endpoint.url),
            "headers": .object([
                CoddHookHeader.token: .string("$\(CoddEnvironmentName.hookToken)"),
                CoddHookHeader.session: .string("$\(CoddEnvironmentName.sessionId)"),
            ]),
            "allowedEnvVars": .array([.string(CoddEnvironmentName.hookToken), .string(CoddEnvironmentName.sessionId)]),
            "timeout": .number(Double(timeout)),
        ])
    }
}

/// D8: the per-session `statusLine` in `--settings`. `codd-statusline` forwards Claude's
/// `rate_limits` to CODD and runs the user's own status-line command (``chainCommand``, read
/// read-only from their settings with D35 precedence), whose output reaches Claude unchanged.
///
/// Flag settings sit above local, project and user settings, so this replaces the project's own
/// `statusLine` for CODD sessions; that is why the user's command is chained rather than dropped.
public struct StatusLineInjection: Sendable, Equatable {
    /// Absolute path of the `codd-statusline` copy for this launch.
    public var command: String
    /// The user's other `statusLine` keys (`padding`, `refreshInterval`, `hideVimModeIndicator`).
    /// `type` and `command` here are ignored: they are always CODD's.
    public var extras: [String: JSONValue]
    /// The user's own command, passed base64 in ``CoddEnvironmentName/statusLineChain`` (at most
    /// ``LaunchBuilder/maxEncodedChainBytes`` encoded, else not chained).
    public var chainCommand: String?

    public init(command: String, extras: [String: JSONValue] = [:], chainCommand: String? = nil) {
        self.command = command
        self.extras = extras
        self.chainCommand = chainCommand
    }

    /// `statusLine.command`: ``command`` POSIX single-quoted. Claude runs a status line through
    /// `/bin/sh -c` (its schema has no `args`, so there is no exec form like the SessionStart
    /// hook's), and the standard data root `~/Library/Application Support/CODD` has a space; a
    /// root with `$(…)` or `;` would otherwise run as shell code on every refresh.
    public var shellCommand: String { ShellQuoting.single(command) }

    /// `{"type":"command","command":<shellCommand>, …extras}`.
    public var settingsValue: JSONValue {
        var object = extras
        object["type"] = .string("command")
        object["command"] = .string(shellCommand)
        return .object(object)
    }
}

/// POSIX shell quoting for paths CODD hands to a shell.
public enum ShellQuoting {
    /// `'…'` with each `'` written as `'\''`: the shell reads every other byte literally.
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The text of a ``single(_:)`` word with its quoting removed (`'a'\''b'` → `a'b`); text that
    /// is not one such word comes back unchanged.
    public static func unquoteSingle(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") else { return s }
        let inner = s.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
        return single(inner) == s ? inner : s
    }
}
