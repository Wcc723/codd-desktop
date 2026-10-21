import CoddCore
import CoddHooks
import CoddMCP
import CoddNotes
import Darwin
import Foundation
import Testing
@testable import CODD

/// D18 per-session injection: argv placement, the 0600 file and its token, the settings, the name
/// resolution (a pinned session's own `.claude.json` too), the cache, and a real launch through
/// the store with 自動掛載 MCP ON and OFF. Temp roots; the "claude" is a shell script that records
/// its argv and runs `cat`.
@Suite("M4 MCP · per-session injection (D18)", .serialized)
@MainActor
struct M4MCPLaunchTests {
    private func settings(port: UInt16 = 43_001) -> ClaudeHookSettings {
        ClaudeHookSettings(endpoint: HookEndpoint(port: port), sessionStartCommand: "/usr/bin/true")
    }

    @Test func argvPutsTheConfigRightBeforeSettingsAndStartWritesIt0600() throws {
        let folder = try m3TempFolder("codd-i2a-argv")
        defer { m3RemoveFolder(folder) }
        let root = CoddDataRoot(path: folder + "/r")
        // A holder that cannot be spawned: start() fails right after writing the session's files.
        let launcher = HolderLauncher(holderExecutable: folder + "/no-holder", root: root, claudePathOverride: folder + "/fake-claude")
        let uuid = UUID()
        let config = MCPLaunchConfig(port: 43_001, token: MCPAuth.sessionToken(hookToken: "t0k3n", sessionID: uuid), sessionID: uuid)
        let plan = try launcher.planClaude(sessionID: uuid, cwd: folder, options: ClaudeLaunchOptions(), hooks: (settings(), "t0k3n"), mcp: config)
        let file = root.sessionDirectory(uuid.uuidString.lowercased()) + "/mcp.json"
        let index = try #require(plan.argv.firstIndex(of: "--mcp-config"))
        #expect(plan.argv[index + 1] == file)
        #expect(plan.argv[index + 2] == "--settings", "--mcp-config is variadic: an option must follow its value")
        #expect(plan.mcpConfigFile == file && plan.mcpConfig == config)
        #expect(!plan.argv.joined(separator: " ").contains(config.token), "the token never goes into argv")
        #expect(plan.environment.values.allSatisfy { !$0.contains(config.token) }, "nor into the environment")
        // start() creates the directory 0700 and writes the file 0600 before the holder runs.
        #expect(throws: HolderStartError.self) { try launcher.start(plan) }
        var info = stat()
        #expect(stat(file, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(root.sessionDirectory(uuid.uuidString.lowercased()), &info) == 0 && info.st_mode & 0o777 == 0o700)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let server = try #require((json["mcpServers"] as? [String: Any])?["codd"] as? [String: Any])
        #expect(server["type"] as? String == "http" && server["url"] as? String == "http://127.0.0.1:43001/mcp")
        let headers = try #require(server["headers"] as? [String: String])
        #expect(headers["X-CODD-Session"] == uuid.uuidString.lowercased())
        #expect(headers["X-CODD-Token"] == MCPAuth.sessionToken(hookToken: "t0k3n", sessionID: uuid))
        // Without hooks there is no MCP (it lives on the hook port), and a launch without a config
        // removes a stale file.
        let bare = try launcher.planClaude(sessionID: uuid, cwd: folder, options: ClaudeLaunchOptions(), hooks: nil, mcp: config)
        #expect(!bare.argv.contains("--mcp-config") && bare.mcpConfig == nil)
        #expect(throws: HolderStartError.self) { try launcher.start(bare) }
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func namesAvoidTheUsersOwnCoddAndAPinnedSessionReadsItsProfile() async throws {
        let folder = try m3TempFolder("codd-i2a-name")
        defer { m3RemoveFolder(folder) }
        let root = CoddDataRoot(path: folder + "/r")
        let claude = ClaudeDirectory(path: folder + "/home/.claude")
        let work = folder + "/work"
        let profile = folder + "/profile"
        for dir in [root.path, claude.path, work, profile] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let logs = LockedLines()
        let store = HolderSessionStore(root: root, launcher: HolderLauncher(holderExecutable: "/usr/bin/false", root: root), claudeDirectory: claude) {
            logs.append($0)
        }
        let global = folder + "/home/.claude.json"
        let uuid = UUID()
        func decide(_ options: ClaudeLaunchOptions = ClaudeLaunchOptions()) async -> (MCPSessionInjection.Decision, ClaudeHookSettings) {
            var s = settings()
            let decision = await store.mcpDecision(uuid.uuidString.lowercased(), uuid: uuid, cwd: work, options: options, setup: &s, token: "t0k3n")
            return (decision, s)
        }
        func servers(_ entries: String) -> String { #"{"numStartups":3,"mcpServers":{\#(entries)}}"# }
        // Nothing defined: `codd`, the prompt route and the read tools' allow rules.
        var (decision, s) = await decide()
        #expect(decision.record.serverName == "codd" && decision.config?.serverName == "codd")
        #expect(s.promptPath == "/hooks/prompt" && s.permissionsAllow == ["mcp__codd__notes_search", "mcp__codd__notes_read", "mcp__codd__notes_list"])
        let json = try s.settingsJSON()
        #expect(json.contains(#""url":"http://127.0.0.1:43001/hooks/prompt""#) && json.contains(#""permissions":{"allow":["mcp__codd__notes_search""#))
        // The user has another server called codd: `codd-desktop`.
        try servers(#""codd":{"type":"http","url":"http://example.com/mcp"}"#).write(toFile: global, atomically: true, encoding: .utf8)
        (decision, s) = await decide()
        #expect(decision.record.serverName == "codd-desktop" && s.permissionsAllow.first == "mcp__codd-desktop__notes_search")
        // The user registered this endpoint as codd themselves: no file, no allow rules, prompt route on.
        try servers(#""codd":{"type":"http","url":"http://localhost:43001/mcp/"}"#).write(toFile: global, atomically: true, encoding: .utf8)
        (decision, s) = await decide()
        #expect(decision.config == nil && decision.record.registeredOurs && s.permissionsAllow.isEmpty && s.promptPath == "/hooks/prompt")
        // A pinned session reads `<CLAUDE_CONFIG_DIR>/.claude.json`, not the default one.
        try servers(#""codd":{"type":"stdio","command":"x"}"#).write(toFile: profile + "/.claude.json", atomically: true, encoding: .utf8)
        try servers("").write(toFile: global, atomically: true, encoding: .utf8)
        var pinned = ClaudeLaunchOptions()
        pinned.claudeConfigDir = profile
        (decision, _) = await decide(pinned)
        #expect(decision.record.serverName == "codd-desktop", "the profile's own codd counts")
        try servers(#""codd":{"type":"stdio","command":"x"}"#).write(toFile: global, atomically: true, encoding: .utf8)
        try servers("").write(toFile: profile + "/.claude.json", atomically: true, encoding: .utf8)
        (decision, _) = await decide(pinned)
        #expect(decision.record.serverName == "codd", "the default config does not apply to a pinned session")
        // `<cwd>/.mcp.json` (project scope) counts too.
        try servers(#""codd":{"command":"x"}"#).write(toFile: work + "/.mcp.json", atomically: true, encoding: .utf8)
        (decision, _) = await decide(pinned)
        #expect(decision.record.serverName == "codd-desktop")
        let text = logs.values.joined(separator: "\n")
        #expect(!text.contains(profile), "a pinned session's profile path is never logged")
        #expect(!text.contains("t0k3n") && !text.contains(MCPAuth.sessionToken(hookToken: "t0k3n", sessionID: uuid)))
    }

    @Test func nameScansAreCachedWhileTheFilesStayTheSame() async throws {
        let folder = try m3TempFolder("codd-i2a-cache")
        defer { m3RemoveFolder(folder) }
        let file = URL(fileURLWithPath: folder + "/claude.json")
        try #"{"mcpServers":{"a":{}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let cache = MCPNameCache()
        #expect(await cache.existing(claudeJSON: file, cwd: folder).names == ["a"])
        #expect(await cache.existing(claudeJSON: file, cwd: folder).names == ["a"])
        #expect(await cache.scans == 1)
        try #"{"mcpServers":{"a":{},"codd":{}}}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(await cache.existing(claudeJSON: file, cwd: folder).names == ["a", "codd"], "a changed file is read again")
        #expect(await cache.scans == 2)
    }

    @Test func aRealLaunchGetsTheConfigAndOffKeepsTheM3Argv() async throws {
        let folder = try m3TempFolder("codd-i2a-run")
        let root = CoddDataRoot(path: folder + "/r")
        let claude = ClaudeDirectory(path: folder + "/home/.claude")
        let work = folder + "/work"
        for dir in [root.path, claude.path + "/sessions", work] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // The "claude": records its argv (NUL-separated) and stays up like a session.
        let fake = folder + "/fake-claude"
        try "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"\(folder)/argv.$$\"\nexec /bin/cat\n".write(toFile: fake, atomically: true, encoding: .utf8)
        chmod(fake, 0o755)
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, claudePathOverride: fake)
        launcher.coddHookPath = "/usr/bin/true"
        let pipeline = HookPipeline(dataRoot: root.url, claudeDirectory: claude, port: 0, portRange: HookPipeline.testPortRange) { _ in }
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: pipeline) { _ in }
        store.processAncestors = { _ in [1] }
        store.autoAttachMCP = true
        // The M4 routes are on the endpoint (MCPService installs real ones in the app).
        pipeline.setRoutes(HookRouteHandlers())
        await store.start()
        await m3Eventually("listening") { pipeline.status.isListening }
        func argvs() -> [[String]] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("argv.") }
            return names.sorted().compactMap { name in
                guard let data = FileManager.default.contents(atPath: folder + "/" + name), !data.isEmpty else { return nil }
                return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            }
        }
        func argv(of id: String) -> [String]? {
            argvs().first { args in args.firstIndex(of: "--session-id").map { args[$0 + 1] == id } ?? false }
        }
        let id = try #require(store.createSession(NewSessionRequest(cwd: work, kind: .claude)))
        await m3Eventually("first argv", timeout: .seconds(10)) { argv(of: id) != nil }
        let first = try #require(argv(of: id))
        let file = root.sessionDirectory(id) + "/mcp.json"
        let index = try #require(first.firstIndex(of: "--mcp-config"))
        #expect(first[index + 1] == file && first[index + 2] == "--settings")
        #expect(first[index + 3].contains("/hooks/prompt") && first[index + 3].contains("mcp__codd__notes_read"))
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(store.mcpSessionConfigs[id] == MCPSessionConfig(serverName: "codd", file: file, registeredOurs: false))
        // 自動掛載 MCP OFF: the next launch runs M3's argv exactly (UserPromptSubmit on /hooks, no
        // allow rules, no file).
        store.autoAttachMCP = false
        let id2 = try #require(store.createSession(NewSessionRequest(cwd: work, kind: .claude)))
        await m3Eventually("second argv", timeout: .seconds(10)) { argv(of: id2) != nil }
        let second = try #require(argv(of: id2))
        #expect(!second.contains("--mcp-config"))
        let settingsIndex = try #require(second.firstIndex(of: "--settings"))
        let config = try #require(pipeline.config)
        #expect(second[settingsIndex + 1] == (try ClaudeHookSettings(endpoint: config.endpoint, sessionStartCommand: "/usr/bin/true").settingsJSON()))
        #expect(!FileManager.default.fileExists(atPath: root.sessionDirectory(id2) + "/mcp.json"))
        #expect(store.mcpSessionConfigs[id2] == nil)
        store.stop([id, id2])
        store.shutdown()
        await pipeline.shutdown()
        m3RemoveFolder(folder)
    }
}

@Suite("M4 MCP · prompt expansion (D19)", .serialized)
@MainActor
struct M4MCPExpansionTests {
    @Test func refsExpandWithTheSystemMessageOffRefsWithoutTheirTitle() async throws {
        let rig = try await MCPNotesRig("codd-i2a-exp")
        let records = LockedLines()
        let expander = PromptExpansion(context: rig.context, report: { records.append("\($0.refs)|\($0.expanded)|\($0.late)") })
        let answer = try #require(await expander.answer(sessionID: rig.sessionA, prompt: "看一下 \(rig.ids.global.uri)"))
        #expect(answer.systemMessage == "codd：已展開 \(rig.ids.global.uri)（全域：常用指令）")
        #expect(answer.additionalContext.hasPrefix(NoteAIText.expansionHeader))
        #expect(answer.additionalContext.contains("<codd-note ref=\"\(rig.ids.global.uri)\" title=\"全域：常用指令\">"))
        let activity = await rig.library.activity(of: rig.ids.global, limit: 3)
        #expect(activity.first?.action == "expand" && activity.first?.sessionTitle == "打卡頁 RWD 調整" && activity.first?.via == "hook")
        // OFF, unknown and two notes at once.
        let mixed = try #require(await expander.answer(sessionID: rig.sessionA,
                                                       prompt: "\(rig.ids.off.uri) [[note:\(rig.ids.append.rawValue)]] codd://note/no-such-note \(rig.ids.global.uri)"))
        #expect(mixed.systemMessage?.contains("codd：已展開 2 則筆記（AI 附加測試、全域：常用指令）") == true)
        #expect(mixed.systemMessage?.contains("codd：\(rig.ids.off.uri) 無法展開（AI 存取為 OFF）") == true)
        #expect(mixed.systemMessage?.contains("codd：codd://note/no-such-note 無法展開（找不到這則筆記）") == true)
        #expect(!mixed.additionalContext.contains(MCPNotesRig.offSecret) && !mixed.additionalContext.contains(MCPNotesRig.offTitle))
        #expect(!(mixed.systemMessage ?? "").contains(MCPNotesRig.offTitle))
        // No ref, or no notebook: 204.
        #expect(await expander.answer(sessionID: rig.sessionA, prompt: "沒有引用的 prompt") == nil)
        #expect(await expander.answer(sessionID: rig.sessionA, prompt: nil) == nil)
        let closed = PromptExpansion(context: NotesMCPContext())
        #expect(await closed.answer(sessionID: rig.sessionA, prompt: rig.ids.global.uri) == nil)
        #expect(records.values.count == 2)
        await rig.close()
    }

    @Test func theContextStaysWithinTheBudget() async throws {
        let rig = try await MCPNotesRig("codd-i2a-cap")
        let long = try await rig.library.create(NewNote(title: "很長的筆記", body: "# 很長的筆記\n\n" + String(repeating: "一段很長的內容。\n", count: 4_000)))
        let expander = PromptExpansion(context: rig.context)
        let answer = try #require(await expander.answer(sessionID: rig.sessionA, prompt: "\(long.metadata.id.uri) \(rig.ids.global.uri)"))
        #expect(answer.additionalContext.count <= PromptExpansion.maxChars)
        #expect(answer.additionalContext.contains("完整內容請用 notes_read 讀取 \(long.metadata.id.uri)"))
        await rig.close()
    }

    @Test func aLateExpansionIsDroppedAndCounted() async throws {
        let rig = try await MCPNotesRig("codd-i2a-late")
        let records = LockedLines()
        let logs = LockedLines()
        let slow = PromptExpansion(context: rig.context, deadline: .milliseconds(40), report: { records.append($0.late ? "late" : "ok") },
                                   log: { logs.append($0) }, expand: { library, prompt, scope in
                                       try? await Task.sleep(for: .milliseconds(400))
                                       return await library.expansion(for: [prompt], maxChars: PromptExpansion.maxChars, imageScope: scope)
                                   })
        #expect(await slow.answer(sessionID: rig.sessionA, prompt: rig.ids.global.uri) == nil, "late: 204")
        #expect(records.values == ["late"] && logs.values.contains { $0.hasPrefix("prompt-expand late") })
        #expect(await rig.library.activity(of: rig.ids.global, limit: 3).isEmpty, "nothing was delivered, nothing recorded")
        #expect(await PromptExpansion.first(of: Task { 7 }, within: .seconds(2)) == 7)
        try? await Task.sleep(for: .milliseconds(450))
        await rig.close()
    }
}
