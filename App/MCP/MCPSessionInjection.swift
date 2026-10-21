import CoddCore
import CoddHooks
import Foundation

/// What a claude launch did about MCP (D18), for the dump's `mcp.sessionConfigs` and the log:
/// the server name and the file, never the token.
struct MCPSessionConfig: Equatable, Sendable {
    /// `codd`, `codd-desktop`, …; nil when the user registered this endpoint themselves.
    var serverName: String?
    /// `<sessionDir>/mcp.json`; nil without a per-session file.
    var file: String?
    /// The user's own config already points `codd` at this endpoint (the session is an external
    /// caller then; no file, no allow rules).
    var registeredOurs: Bool
}

/// D18: the per-session MCP decision for one claude launch, made off the main actor.
///
/// The server name avoids every name the session's own MCP configuration defines: the global
/// config Claude reads (`<claudeDir>/../.claude.json`, or `<CLAUDE_CONFIG_DIR>/.claude.json` for a
/// pinned session, whose path carries an e-mail slug and is never logged) and `<cwd>/.mcp.json`,
/// names only. The scan is cached for 10 s while both files keep their size and mtime, so a burst
/// of launches reads a multi-megabyte `.claude.json` once.
actor MCPNameCache {
    private struct Stamp: Equatable {
        var size: Int64
        var mtime: TimeInterval
    }

    private struct Entry {
        var stamps: [Stamp?]
        var at: ContinuousClock.Instant
        var existing: MCPServerNameResolver.Existing
    }

    static let lifetime: Duration = .seconds(10)
    private var entries: [String: Entry] = [:]
    /// Scans that actually read the files (tests check the cache).
    private(set) var scans = 0

    /// `claudeJSON` nil: only `<cwd>/.mcp.json` is scanned.
    func existing(claudeJSON: URL?, cwd: String) -> MCPServerNameResolver.Existing {
        let projectJSON = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".mcp.json", isDirectory: false)
        let key = (claudeJSON?.path ?? "-") + "\u{1F}" + cwd
        let stamps = [claudeJSON.flatMap { Self.stamp($0.path) }, Self.stamp(projectJSON.path)]
        let now = ContinuousClock.now
        if let entry = entries[key], entry.stamps == stamps, now - entry.at < Self.lifetime { return entry.existing }
        scans += 1
        let existing = MCPServerNameResolver.scan(claudeJSON: claudeJSON, cwd: cwd, projectMCPJSON: projectJSON)
        if entries.count > 64 { entries.removeAll() }
        entries[key] = Entry(stamps: stamps, at: now, existing: existing)
        return existing
    }

    private static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Stamp(size: Int64(info.st_size),
                     mtime: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }
}

enum MCPSessionInjection {
    /// The launch's MCP part: the config to write (nil: none) and what the dump records.
    struct Decision: Sendable, Equatable {
        var config: MCPLaunchConfig?
        var record: MCPSessionConfig
    }

    /// The global config Claude reads for this launch: `<configDir>/.claude.json` when the session
    /// runs with its own `CLAUDE_CONFIG_DIR`, else `<claudeDir>/../.claude.json`.
    static func globalConfig(configDir: String?, claudeDirectory: ClaudeDirectory) -> URL {
        if let configDir {
            return URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent(".claude.json", isDirectory: false)
        }
        return MCPService.globalConfigURL(claudeDirectory: claudeDirectory)
    }

    /// Resolves the name (D18) and applies it to `settings`: UserPromptSubmit to `/hooks/prompt`
    /// in both cases; with a per-session file also `permissions.allow` for the read tools.
    /// - Parameter readsGlobalConfig: the global config may be read (false on a test data root whose path
    ///   resolves into the real home: it is then treated as absent, D37).
    static func decide(sessionID: UUID, cwd: String, token: String, settings: inout ClaudeHookSettings, globalConfig: URL,
                       readsGlobalConfig: Bool, directory: String, names: MCPNameCache) async -> Decision {
        let port = settings.endpoint.port
        let ourURL = HookEndpoint(port: port, path: "/mcp").url
        let existing = await names.existing(claudeJSON: readsGlobalConfig ? globalConfig : nil, cwd: cwd)
        settings.promptPath = "/hooks/prompt"
        switch MCPServerNameResolver.resolve(existing, ourURL: ourURL) {
        case .inject(let name):
            settings.permissionsAllow = MCPLaunchConfig.allowRules(serverName: name)
            let config = MCPLaunchConfig(serverName: name, port: port, token: MCPAuth.sessionToken(hookToken: token, sessionID: sessionID),
                                         sessionID: sessionID)
            return Decision(config: config, record: MCPSessionConfig(serverName: name, file: directory + "/" + HolderLauncher.mcpConfigName,
                                                                     registeredOurs: false))
        case .userRegisteredOurs:
            settings.permissionsAllow = []
            return Decision(config: nil, record: MCPSessionConfig(serverName: nil, file: nil, registeredOurs: true))
        }
    }
}
