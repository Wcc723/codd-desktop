import Darwin
import Foundation

/// M4 D18: the per-session `<sessionDir>/mcp.json` passed as `claude --mcp-config <path>`.
///
/// `{"mcpServers":{"codd":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"X-CODD-Session":"<uuid>","X-CODD-Token":"<token>"}}}}`
///
/// The token is a literal (``token``: CoddHooks `MCPAuth.sessionToken(hookToken:sessionID:)`), not
/// `${CODD_HOOK_TOKEN}`: claude 2.1.302 never expands credential-looking variables toward a remote
/// MCP server (it reads them as empty). That is why the file is 0600 and written atomically, and
/// why the token never appears in argv, logs or dumps. The config only adds a server:
/// `--strict-mcp-config` is never used for sessions, so the user's own servers still start.
public struct MCPLaunchConfig: Sendable, Equatable {
    /// `codd`, or `codd-desktop[-n]` when the user's config already has another `codd`
    /// (``MCPServerNameResolver``).
    public var serverName: String
    /// The hook server's port (MCP shares it).
    public var port: UInt16
    /// The per-session token, sent as `X-CODD-Token`.
    public var token: String
    /// The CODD session, sent as `X-CODD-Session` (lowercase, the form the token is derived over).
    public var sessionID: UUID

    public static let defaultServerName = "codd"
    /// The read-only tools a session may call without a permission prompt (D18). `notes_append` /
    /// `notes_write` keep Claude's normal prompt.
    public static let allowedTools = ["notes_search", "notes_read", "notes_list"]

    public enum WriteError: Error, Equatable {
        /// The session directory does not exist (the caller creates it with the right mode).
        case missingDirectory(String)
        case write(String)
    }

    public init(serverName: String = MCPLaunchConfig.defaultServerName, port: UInt16, token: String, sessionID: UUID) {
        self.serverName = serverName
        self.port = port
        self.token = token
        self.sessionID = sessionID
    }

    /// `http://127.0.0.1:<port>/mcp`.
    public var url: String { HookEndpoint(port: port, path: "/mcp").url }

    /// The file's JSON value.
    public var jsonValue: JSONValue {
        .object(["mcpServers": .object([serverName: .object([
            "type": .string("http"),
            "url": .string(url),
            "headers": .object([
                CoddHookHeader.token: .string(token),
                CoddHookHeader.session: .string(sessionID.uuidString.lowercased()),
            ]),
        ])])])
    }

    /// Compact JSON with sorted keys and unescaped slashes (§3.8).
    public func jsonData() throws -> Data {
        try jsonValue.jsonData()
    }

    /// Writes ``jsonData()`` to `file` atomically (temp file + `F_FULLFSYNC` + rename) with mode
    /// 0600. The parent directory must exist: creating the session directory (0700) is the
    /// launcher's job, so a wrong path can never create stray folders.
    public func write(to file: URL) throws {
        let dir = file.deletingLastPathComponent().path
        var st = stat()
        guard stat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw WriteError.missingDirectory(dir) }
        let data = try jsonData()
        do {
            try AtomicFile.write(data, to: file, permissions: 0o600)
        } catch {
            throw WriteError.write(String(describing: error))
        }
        // The umask can only narrow the temp file's mode; set it exactly.
        if stat(file.path, &st) == 0, st.st_mode & 0o777 != 0o600 { _ = chmod(file.path, 0o600) }
    }

    /// `permissions.allow` rules for the read tools of `serverName`:
    /// `mcp__<name>__notes_search`, `…__notes_read`, `…__notes_list`.
    public static func allowRules(serverName: String) -> [String] {
        let name = toolPrefixName(serverName)
        return allowedTools.map { "mcp__\(name)__\($0)" }
    }

    /// Claude builds MCP tool names as `mcp__<server>__<tool>` with every character of the server
    /// name outside `[A-Za-z0-9_-]` replaced by `_`; CODD's names (`codd`, `codd-desktop-2`) are
    /// unchanged by it.
    static func toolPrefixName(_ serverName: String) -> String {
        String(String.UnicodeScalarView(serverName.unicodeScalars.map { s in
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: return s
            default: return "_"
            }
        }))
    }
}

/// M4 D18: picks the server name for a session's ``MCPLaunchConfig`` from the user's own MCP
/// configuration, read only and names only.
///
/// Claude merges servers from the global config (`<claudeDir>/../.claude.json`, or
/// `<CLAUDE_CONFIG_DIR>/.claude.json` for a pinned session): its top-level `mcpServers` (user
/// scope) and `projects[<cwd>].mcpServers` (local scope), plus `<cwd>/.mcp.json` (project scope). A
/// `--mcp-config` server with a name already taken would shadow or be shadowed by the user's, so
/// CODD avoids every taken name. Only member names are collected; the one value read is the `url`
/// string of an existing `codd` entry (to recognise the user's own registration of CODD, D22).
/// Header values, commands and environments of other servers are never looked at, returned or
/// logged, and neither is the path of a pinned session's file (it carries an e-mail slug).
public enum MCPServerNameResolver {
    public struct Existing: Sendable, Equatable {
        /// Every server name defined in the scanned scopes.
        public var names: Set<String>
        /// The `url` of the effective `codd` entry (local scope over project scope over user
        /// scope, Claude's precedence); `nil` when there is none or it has no string `url`.
        public var coddURL: String?

        public init(names: Set<String> = [], coddURL: String? = nil) {
            self.names = names
            self.coddURL = coddURL
        }
    }

    public enum Resolution: Sendable, Equatable {
        /// Write the per-session config with this server name.
        case inject(name: String)
        /// The user registered this CODD endpoint as `codd` themselves: no per-session file (the
        /// session is then an external caller of the MCP server).
        case userRegisteredOurs
    }

    /// Files above this are not parsed (a `.claude.json` is a few MB at most).
    public static let maxFileBytes = 64 << 20
    /// The name used when `codd` belongs to another server.
    public static let fallbackName = "codd-desktop"

    /// Scans `claudeJSON` (top-level and `projects[cwd]` / `projects[realpath(cwd)]`) and
    /// `projectMCPJSON` (`mcpServers`). A missing, unreadable, oversized or invalid file
    /// contributes nothing. Blocking file I/O: call it off the main actor.
    public static func scan(claudeJSON: URL?, cwd: String, projectMCPJSON: URL?) -> Existing {
        var names = Set<String>()
        var user: String?, local: String?, project: String?
        if let claudeJSON, let root = readObject(claudeJSON) {
            if let servers = root["mcpServers"] as? [String: Any] {
                names.formUnion(servers.keys)
                user = coddURL(in: servers)
            }
            if let projects = root["projects"] as? [String: Any] {
                var keys = [cwd]
                if let real = ReadOnlyFile.realPath(cwd), real != cwd { keys.append(real) }
                for key in keys {
                    guard let entry = projects[key] as? [String: Any],
                          let servers = entry["mcpServers"] as? [String: Any] else { continue }
                    names.formUnion(servers.keys)
                    if local == nil { local = coddURL(in: servers) }
                }
            }
        }
        if let projectMCPJSON, let root = readObject(projectMCPJSON),
           let servers = root["mcpServers"] as? [String: Any] {
            names.formUnion(servers.keys)
            project = coddURL(in: servers)
        }
        return Existing(names: names, coddURL: local ?? project ?? user)
    }

    /// `codd` when free; ``Resolution/userRegisteredOurs`` when the effective `codd` points at
    /// `ourURL` (scheme and host case, `localhost` for `127.0.0.1` and a trailing `/` ignored);
    /// otherwise the first free of `codd-desktop`, `codd-desktop-2`, `codd-desktop-3`, ….
    public static func resolve(_ existing: Existing, ourURL: String) -> Resolution {
        let primary = MCPLaunchConfig.defaultServerName
        guard existing.names.contains(primary) else { return .inject(name: primary) }
        if let url = existing.coddURL, normalized(url) == normalized(ourURL) { return .userRegisteredOurs }
        if !existing.names.contains(fallbackName) { return .inject(name: fallbackName) }
        var n = 2
        while existing.names.contains("\(fallbackName)-\(n)") { n += 1 }
        return .inject(name: "\(fallbackName)-\(n)")
    }

    /// The `url` string of a `codd` member, nothing else of it.
    private static func coddURL(in servers: [String: Any]) -> String? {
        guard let entry = servers[MCPLaunchConfig.defaultServerName] as? [String: Any] else { return nil }
        return entry["url"] as? String
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        let data: Data? = ReadOnlyFile.with(url.path) { fd, info -> Data? in
            guard info.size <= Int64(maxFileBytes), let bytes = ReadOnlyFile.read(fd, offset: 0, count: Int(info.size)) else {
                return nil
            }
            return Data(bytes)
        }
        guard let data, !data.isEmpty else { return nil }
        // Bounded nesting first: Foundation's parser recurses per level. The members read here
        // are at most four levels deep.
        let bounded = JSONNesting.pruned(data, maxDepth: JSONValue.maximumNestingDepth) ?? data
        return (try? JSONSerialization.jsonObject(with: bounded)) as? [String: Any]
    }

    /// Lowercased scheme and host part, `localhost` as `127.0.0.1`, no trailing `/`.
    static func normalized(_ url: String) -> String {
        var s = JSText.trim(url)
        while s.hasSuffix("/") { s.removeLast() }
        guard let range = s.range(of: "://") else { return s }
        let scheme = s[..<range.lowerBound].lowercased()
        let rest = s[range.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = rest[..<slash].lowercased()
        if authority == "localhost" || authority.hasPrefix("localhost:") {
            authority = "127.0.0.1" + authority.dropFirst("localhost".count)
        }
        return scheme + "://" + authority + rest[slash...]
    }
}
