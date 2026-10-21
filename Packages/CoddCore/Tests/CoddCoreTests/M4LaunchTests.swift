import Darwin
import Foundation
import Testing
@testable import CoddCore

private let sid = UUID(uuidString: "7C1E9A04-5B2D-4E8F-9A31-0C6D2E4F8B17") ?? UUID()
private let base: [String: String] = ["HOME": "/Users/synthetic", "USER": "synthetic", "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
private let login: [String: String] = ["PATH": "/Users/synthetic/.local/bin:/usr/bin:/bin", "LANG": "zh_TW.UTF-8"]
private let allow = ["mcp__codd__notes_search", "mcp__codd__notes_read", "mcp__codd__notes_list"]

private func hooks(promptPath: String? = nil, permissions: [String] = [],
                   statusLine: StatusLineInjection? = nil) -> ClaudeHookSettings {
    ClaudeHookSettings(endpoint: HookEndpoint(port: 47821), sessionStartCommand: "/opt/codd/codd-hook", statusLine: statusLine,
                       promptPath: promptPath, permissionsAllow: permissions)
}

private func m3Hooks(statusLine: StatusLineInjection? = nil) -> ClaudeHookSettings {
    ClaudeHookSettings(endpoint: HookEndpoint(port: 47821), sessionStartCommand: "/opt/codd/codd-hook", statusLine: statusLine)
}

private func profile(_ id: String) throws -> LaunchProfile {
    try #require(LaunchProfile.builtIn.first { $0.id == id })
}

private func builder(_ settings: ClaudeHookSettings?) -> LaunchBuilder {
    LaunchBuilder(hooks: settings, isExecutable: { ["/Users/synthetic/.local/bin/claude", "/bin/zsh"].contains($0) })
}

/// The M3 UserPromptSubmit group and the M4 one with the prompt route (compact, sorted keys).
private let m3Prompt = #""UserPromptSubmit":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}]"#
private let m4Prompt = #""UserPromptSubmit":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":3,"type":"http","url":"http://127.0.0.1:47821/hooks/prompt"}]}]"#
private let m4Permissions = #""permissions":{"allow":["mcp__codd__notes_search","mcp__codd__notes_read","mcp__codd__notes_list"]}"#

@Suite("M4 hook settings: prompt route and permissions")
struct M4HookSettingsTests {
    @Test func defaultsKeepTheM3Bytes() throws {
        #expect(try hooks().settingsJSON() == m3Hooks().settingsJSON())
        #expect(hooks().promptPath == nil && hooks().permissionsAllow.isEmpty && hooks().promptTimeoutSeconds == 3)
        #expect(try m3Hooks().settingsJSON().contains(m3Prompt))
        #expect(hooks().promptURL == "http://127.0.0.1:47821/hooks")
        // Blank prompt paths are no prompt path.
        #expect(try hooks(promptPath: "  ").settingsJSON() == m3Hooks().settingsJSON())
    }

    @Test func promptRouteAndPermissionsChangeOnlyTheirParts() throws {
        let m3 = try m3Hooks().settingsJSON()
        let m4 = try hooks(promptPath: "/hooks/prompt", permissions: allow).settingsJSON()
        // Everything else is byte for byte M3's: one handler replaced, one member added.
        let expected = String(m3.replacingOccurrences(of: m3Prompt, with: m4Prompt).dropLast()) + "," + m4Permissions + "}"
        #expect(m4 == expected)
        let parsed = try #require(JSONValue.parse(Data(m4.utf8)))
        #expect(parsed["permissions"] == .object(["allow": .array(allow.map(JSONValue.string))]))
        let handler = try #require(parsed["hooks"]?["UserPromptSubmit"]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
        #expect(handler["url"] == "http://127.0.0.1:47821/hooks/prompt")
        #expect(handler["timeout"] == 3)
        // The other twelve http events and SessionStart keep /hooks.
        for event in ClaudeHookSettings.httpEvents where event != .userPromptSubmit {
            let h = try #require(parsed["hooks"]?[event.rawValue]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
            #expect(h["url"] == "http://127.0.0.1:47821/hooks", "\(event)")
        }
        #expect(parsed["hooks"]?["SessionStart"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["args"]
            == .array(["session-start", "--url", "http://127.0.0.1:47821/hooks"].map(JSONValue.string)))
    }

    @Test func eachPartAlone() throws {
        let m3 = try m3Hooks().settingsJSON()
        #expect(try hooks(promptPath: "/hooks/prompt").settingsJSON() == m3.replacingOccurrences(of: m3Prompt, with: m4Prompt))
        #expect(try hooks(permissions: allow).settingsJSON() == String(m3.dropLast()) + "," + m4Permissions + "}")
        // A path without its slash, and a custom timeout.
        var custom = hooks(promptPath: "hooks/prompt")
        custom.promptTimeoutSeconds = 4
        let h = try #require(JSONValue.parse(Data(try custom.settingsJSON().utf8))?["hooks"]?["UserPromptSubmit"]?.arrayValue?
            .first?["hooks"]?.arrayValue?.first)
        #expect(h["url"] == "http://127.0.0.1:47821/hooks/prompt" && h["timeout"] == 4)
    }

    @Test func withAStatusLinePermissionsSortBetween() throws {
        let injection = StatusLineInjection(command: "/x/codd-statusline")
        let json = try hooks(promptPath: "/hooks/prompt", permissions: allow, statusLine: injection).settingsJSON()
        let parsed = try #require(JSONValue.parse(Data(json.utf8)))
        #expect(parsed.objectValue?.keys.sorted() == ["hooks", "permissions", "statusLine"])
        #expect(json.contains(m4Permissions + #","statusLine":"#))
        #expect(parsed["statusLine"] == JSONValue.parse(Data(try m3Hooks(statusLine: injection).settingsJSON().utf8))?["statusLine"])
    }
}

@Suite("M4 per-session MCP config")
struct MCPLaunchConfigTests {
    let config = MCPLaunchConfig(port: 47821, token: String(repeating: "ab", count: 32), sessionID: sid)

    func mode(_ path: String) -> mode_t {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    @Test func jsonIsTheDocumentedShape() throws {
        #expect(config.serverName == "codd")
        #expect(config.url == "http://127.0.0.1:47821/mcp")
        let json = String(decoding: try config.jsonData(), as: UTF8.self)
        #expect(json == #"{"mcpServers":{"codd":{"headers":{"X-CODD-Session":"7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17","X-CODD-Token":"\#(String(repeating: "ab", count: 32))"},"type":"http","url":"http://127.0.0.1:47821/mcp"}}}"#)
        var other = config
        other.serverName = "codd-desktop-2"
        #expect(JSONValue.parse(try other.jsonData())?["mcpServers"]?.objectValue?.keys.sorted() == ["codd-desktop-2"])
    }

    @Test func writesAtomicallyWithMode0600() throws {
        let tmp = try TempDir("codd-mcp-config")
        defer { tmp.remove() }
        let file = tmp.file("mcp.json")
        let old = umask(0o022)
        defer { umask(old) }
        try config.write(to: file)
        #expect(mode(file.path) == 0o600)
        #expect(try Data(contentsOf: file) == config.jsonData())
        // A rewrite replaces it (no temp files left), mode kept even when the file was loosened.
        chmod(file.path, 0o644)
        var next = config
        next.port = 43001
        try next.write(to: file)
        #expect(mode(file.path) == 0o600)
        #expect(JSONValue.parse(try Data(contentsOf: file))?["mcpServers"]?["codd"]?["url"] == "http://127.0.0.1:43001/mcp")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["mcp.json"])
    }

    @Test func refusesAMissingParent() throws {
        let tmp = try TempDir("codd-mcp-config")
        defer { tmp.remove() }
        let file = tmp.file("sessions/abc/mcp.json")
        #expect(throws: MCPLaunchConfig.WriteError.missingDirectory(tmp.file("sessions/abc").path)) { try config.write(to: file) }
        #expect(!FileManager.default.fileExists(atPath: tmp.file("sessions").path))
    }

    @Test func allowRules() {
        #expect(MCPLaunchConfig.allowRules(serverName: "codd") == allow)
        #expect(MCPLaunchConfig.allowRules(serverName: "codd-desktop-2").first == "mcp__codd-desktop-2__notes_search")
        // Claude's own normalisation of server names in tool names.
        #expect(MCPLaunchConfig.allowRules(serverName: "my server.x").first == "mcp__my_server_x__notes_search")
    }
}

@Suite("M4 MCP server name resolver")
struct MCPServerNameResolverTests {
    let ours = "http://127.0.0.1:47821/mcp"
    let secret = "SECRET-HEADER-VALUE-0123"

    func write(_ json: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    @Test func absentOrUnreadableFilesGiveCodd() throws {
        let tmp = try TempDir("codd-names")
        defer { tmp.remove() }
        let none = MCPServerNameResolver.scan(claudeJSON: tmp.file("missing.json"), cwd: "/synthetic", projectMCPJSON: nil)
        #expect(none == .init())
        #expect(MCPServerNameResolver.resolve(none, ourURL: ours) == .inject(name: "codd"))
        try write("not json", tmp.file("bad.json"))
        #expect(MCPServerNameResolver.scan(claudeJSON: tmp.file("bad.json"), cwd: "/x", projectMCPJSON: tmp.file("bad.json")) == .init())
        try write("[1,2]", tmp.file("array.json"))
        #expect(MCPServerNameResolver.scan(claudeJSON: tmp.file("array.json"), cwd: "/x", projectMCPJSON: nil) == .init())
        #expect(MCPServerNameResolver.scan(claudeJSON: nil, cwd: "/x", projectMCPJSON: nil) == .init())
    }

    @Test func otherServersAreNamesOnly() throws {
        let tmp = try TempDir("codd-names")
        defer { tmp.remove() }
        let file = tmp.file("claude.json")
        try write(#"{"numStartups":3,"mcpServers":{"github":{"type":"http","url":"https://x.example/mcp","headers":{"Authorization":"Bearer \#(secret)"}},"fs":{"command":"npx","env":{"TOKEN":"\#(secret)"}}},"projects":{"/other":{"mcpServers":{"elsewhere":{}}}}}"#, file)
        let existing = MCPServerNameResolver.scan(claudeJSON: file, cwd: "/synthetic", projectMCPJSON: nil)
        #expect(existing == .init(names: ["github", "fs"], coddURL: nil))
        #expect(!String(describing: existing).contains(secret))
        #expect(MCPServerNameResolver.resolve(existing, ourURL: ours) == .inject(name: "codd"))
    }

    @Test func ourOwnRegistrationIsRecognised() throws {
        let tmp = try TempDir("codd-names")
        defer { tmp.remove() }
        let file = tmp.file("claude.json")
        try write(#"{"mcpServers":{"codd":{"type":"http","url":"http://LOCALHOST:47821/mcp/","headers":{"X-CODD-Token":"\#(secret)"}}}}"#, file)
        let existing = MCPServerNameResolver.scan(claudeJSON: file, cwd: "/synthetic", projectMCPJSON: nil)
        #expect(existing.names == ["codd"])
        #expect(existing.coddURL == "http://LOCALHOST:47821/mcp/")
        #expect(!String(describing: existing).contains(secret))
        #expect(MCPServerNameResolver.resolve(existing, ourURL: ours) == .userRegisteredOurs)
        // Another port is not ours.
        #expect(MCPServerNameResolver.resolve(existing, ourURL: "http://127.0.0.1:43001/mcp") == .inject(name: "codd-desktop"))
    }

    @Test func aForeignCoddMovesUsAside() throws {
        let tmp = try TempDir("codd-names")
        defer { tmp.remove() }
        let file = tmp.file("claude.json")
        try write(#"{"mcpServers":{"codd":{"command":"/usr/local/bin/codd-other"}}}"#, file)
        let foreign = MCPServerNameResolver.scan(claudeJSON: file, cwd: "/synthetic", projectMCPJSON: nil)
        #expect(foreign == .init(names: ["codd"], coddURL: nil))
        #expect(MCPServerNameResolver.resolve(foreign, ourURL: ours) == .inject(name: "codd-desktop"))
        // codd-desktop taken too, and its -2.
        #expect(MCPServerNameResolver.resolve(.init(names: ["codd", "codd-desktop"]), ourURL: ours) == .inject(name: "codd-desktop-2"))
        #expect(MCPServerNameResolver.resolve(.init(names: ["codd", "codd-desktop", "codd-desktop-2"], coddURL: "http://x/mcp"),
                                              ourURL: ours) == .inject(name: "codd-desktop-3"))
        // codd-desktop taken but codd free: codd.
        #expect(MCPServerNameResolver.resolve(.init(names: ["codd-desktop"]), ourURL: ours) == .inject(name: "codd"))
    }

    @Test func projectScopesIncludingTheRealpathKeyAndMCPJSON() throws {
        let tmp = try TempDir("codd-names")
        defer { tmp.remove() }
        // A cwd reached through a symlink: Claude keys projects by the physical path.
        let real = tmp.file("real-project")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tmp.file("link-project")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let realPath = try #require(Darwin.realpath(link.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let file = tmp.file("claude.json")
        try write(#"{"mcpServers":{"top":{}},"projects":{"\#(realPath)":{"mcpServers":{"local":{},"codd":{"type":"http","url":"http://127.0.0.1:47821/mcp"}}},"\#(link.path)":{"mcpServers":{"logical":{}}}}}"#, file)
        try write(#"{"mcpServers":{"fromproject":{"command":"x"},"codd":{"url":"http://elsewhere/mcp"}}}"#, real.appendingPathComponent(".mcp.json"))
        let existing = MCPServerNameResolver.scan(claudeJSON: file, cwd: link.path, projectMCPJSON: link.appendingPathComponent(".mcp.json"))
        #expect(existing.names == ["top", "local", "codd", "logical", "fromproject"])
        // Local scope wins over the project's .mcp.json.
        #expect(existing.coddURL == "http://127.0.0.1:47821/mcp")
        #expect(MCPServerNameResolver.resolve(existing, ourURL: ours) == .userRegisteredOurs)
        // Without the local entry, .mcp.json's codd (foreign) decides.
        let projectOnly = MCPServerNameResolver.scan(claudeJSON: nil, cwd: link.path, projectMCPJSON: link.appendingPathComponent(".mcp.json"))
        #expect(projectOnly == .init(names: ["fromproject", "codd"], coddURL: "http://elsewhere/mcp"))
        #expect(MCPServerNameResolver.resolve(projectOnly, ourURL: ours) == .inject(name: "codd-desktop"))
    }

    /// A `.claude.json` of a heavy user is a few MB (project history); the scan runs per launch
    /// (I2a caches it by mtime). Synthetic 10 MB file, generous bound, number printed.
    @Test func scanOfALargeFileIsFast() throws {
        let tmp = try TempDir("codd-names")
        defer { tmp.remove() }
        var projects: [String] = []
        let filler = String(repeating: "x", count: 900)
        for i in 0..<10_000 {
            projects.append(#""/synthetic/p\#(i)":{"allowedTools":[],"history":[{"display":"\#(filler)"}],"mcpServers":{"s\#(i % 7)":{}}}"#)
        }
        let json = #"{"mcpServers":{"github":{"url":"https://x"}},"projects":{"# + projects.joined(separator: ",")
            + #","/synthetic/target":{"mcpServers":{"codd":{"url":"http://127.0.0.1:47821/mcp"}}}}}"#
        let file = tmp.file("claude.json")
        try write(json, file)
        let clock = ContinuousClock()
        let start = clock.now
        let existing = MCPServerNameResolver.scan(claudeJSON: file, cwd: "/synthetic/target", projectMCPJSON: nil)
        let elapsed = clock.now - start
        print("PERF name scan of a \(json.utf8.count / 1_000_000) MB .claude.json: \(elapsed)")
        #expect(existing == .init(names: ["github", "codd"], coddURL: "http://127.0.0.1:47821/mcp"))
        #expect(elapsed < .seconds(2))
    }

    @Test func urlNormalisation() {
        #expect(MCPServerNameResolver.normalized("HTTP://LocalHost:47821/mcp/") == "http://127.0.0.1:47821/mcp")
        #expect(MCPServerNameResolver.normalized(" http://127.0.0.1:47821/mcp ") == "http://127.0.0.1:47821/mcp")
        #expect(MCPServerNameResolver.normalized("http://127.0.0.1:47821/MCP") != MCPServerNameResolver.normalized(ours))
        #expect(MCPServerNameResolver.normalized("http://localhost.evil:47821/mcp") == "http://localhost.evil:47821/mcp")
    }
}

@Suite("M4 launch argv with --mcp-config")
struct M4LaunchBuilderTests {
    let path = "/Users/synthetic/Library/Application Support/CODD/sessions/7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17/mcp.json"

    func argv(_ request: LaunchRequest, settings: ClaudeHookSettings? = hooks(promptPath: "/hooks/prompt", permissions: allow)) throws -> [String] {
        try builder(settings).build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "tok").argv
    }

    /// `--mcp-config <path>` is immediately followed by `--settings`.
    func expectPlacement(_ argv: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let i = try #require(argv.firstIndex(of: "--mcp-config"), sourceLocation: sourceLocation)
        #expect(argv[i + 1] == path, sourceLocation: sourceLocation)
        #expect(argv[i + 2] == "--settings", sourceLocation: sourceLocation)
        #expect(argv.filter { $0 == "--mcp-config" }.count == 1, sourceLocation: sourceLocation)
    }

    @Test func newResumeAndRestart() throws {
        let p = try profile("claude-default")
        let new = LaunchRequest(profile: p, cwd: "/synthetic/project", sessionId: sid, name: "修正登入 API 401", model: "opus-5.5",
                                permissionMode: .acceptEdits, mcpConfigPath: path)
        let a = try argv(new)
        try expectPlacement(a)
        #expect(Array(a.prefix(11)) == ["/Users/synthetic/.local/bin/claude", "--session-id", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
                                        "--model", "opus-5.5", "--permission-mode", "acceptEdits", "-n", "修正登入 API 401",
                                        "--mcp-config", path])
        #expect(a.count == 13)
        let resume = LaunchRequest(profile: p, cwd: "/p", sessionId: sid, mode: .resume, resumeClaudeSessionId: "9d2f0b15-6c3e-4f9a-8b42-1d7e3f5a9c28",
                                   mcpConfigPath: path)
        let r = try argv(resume)
        try expectPlacement(r)
        #expect(Array(r.prefix(3)) == ["/Users/synthetic/.local/bin/claude", "--resume", "9d2f0b15-6c3e-4f9a-8b42-1d7e3f5a9c28"])
        // RESTART: a new launch id, mode new.
        let fresh = UUID(uuidString: "11111111-2222-4333-8444-555555555555") ?? UUID()
        let restart = LaunchRequest(profile: p, cwd: "/p", sessionId: fresh, mcpConfigPath: path)
        let s = try argv(restart)
        try expectPlacement(s)
        #expect(s[1...2] == ["--session-id", "11111111-2222-4333-8444-555555555555"])
        // The token never reaches argv.
        #expect(!a.joined(separator: " ").contains("tok"))
    }

    @Test func profileExtrasFollowIncludingTheirOwnMCPConfig() throws {
        let rc = try profile("claude-rc")
        let a = try argv(LaunchRequest(profile: rc, cwd: "/p", sessionId: sid, mcpConfigPath: path))
        try expectPlacement(a)
        #expect(a.last == "--remote-control")
        let own = LaunchProfile(id: "x", name: "x", kind: .claude, extraArguments: ["--mcp-config", "/Users/synthetic/mine.json", "--verbose"])
        let b = try argv(LaunchRequest(profile: own, cwd: "/p", sessionId: sid, mcpConfigPath: path))
        let i = try #require(b.firstIndex(of: "--mcp-config"))
        #expect(b[i + 1] == path && b[i + 2] == "--settings")
        #expect(Array(b.suffix(3)) == ["--mcp-config", "/Users/synthetic/mine.json", "--verbose"])
        #expect(b.filter { $0 == "--mcp-config" }.count == 2)
    }

    @Test func withoutHooksOrPathTheArgvIsM3s() throws {
        let p = try profile("claude-default")
        let withPath = LaunchRequest(profile: p, cwd: "/p", sessionId: sid, mcpConfigPath: path)
        let none = try argv(withPath, settings: nil)
        #expect(none == ["/Users/synthetic/.local/bin/claude", "--session-id", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"])
        let m3 = try builder(m3Hooks()).build(LaunchRequest(profile: p, cwd: "/p", sessionId: sid),
                                               baseEnvironment: base, loginEnvironment: login, hookToken: "t").argv
        #expect(!m3.contains("--mcp-config"))
        #expect(m3.suffix(2).first == "--settings")
        // Shells never get it.
        let shell = try builder(m3Hooks()).build(LaunchRequest(profile: try profile("zsh"), cwd: "/p", sessionId: sid, mcpConfigPath: path),
                                                  baseEnvironment: base, loginEnvironment: login, hookToken: "t").argv
        #expect(!shell.contains("--mcp-config"))
    }

    @Test(arguments: ["relative/mcp.json", "--evil", "", "/bad\u{0}path"])
    func invalidPathsAreRefused(_ bad: String) throws {
        let request = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sid, mcpConfigPath: bad)
        #expect(throws: LaunchBuildError.invalidValue(flag: "--mcp-config", value: bad)) { try argv(request) }
    }
}
