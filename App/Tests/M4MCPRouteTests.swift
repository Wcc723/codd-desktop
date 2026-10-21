import CoddCore
import CoddHooks
import CoddMCP
import CoddNotes
import Foundation
import Testing
@testable import CODD

/// The whole I2a path on a temp data root: `HookPipeline` (its own config.json, a test port) with
/// `MCPService`'s routes, the notebook (`NotesService`), and a CODD session put into an unstarted
/// store (no holder, no claude). Requests go over loopback HTTP like Claude's.
@MainActor
final class MCPRouteRig {
    let folder: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory
    let pipeline: HookPipeline
    let store: HolderSessionStore
    let notes: NotesService
    let mcp: MCPService
    let session = UUID()
    let work: String
    let logs = LockedLines()
    private(set) var port: UInt16 = 0
    private let http = URLSession(configuration: .ephemeral)

    init(_ prefix: String) async throws {
        folder = try m3TempFolder(prefix)
        root = CoddDataRoot(path: folder + "/data")
        claude = ClaudeDirectory(path: folder + "/home/.claude")
        work = folder + "/work"
        for dir in [root.path, claude.path + "/sessions", work] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let logs = self.logs
        pipeline = HookPipeline(dataRoot: root.url, claudeDirectory: claude, port: 0, portRange: HookPipeline.testPortRange) { logs.append($0) }
        store = HolderSessionStore(root: root, launcher: HolderLauncher(holderExecutable: "/usr/bin/false", root: root), claudeDirectory: claude,
                                   hooks: pipeline) { logs.append($0) }
        let locations = NotesService.locations(dataRoot: root)
        notes = NotesService(notesRoot: locations.notes, cacheFolder: locations.cache, preferences: .inMemory(),
                             trash: AppTrash(target: .folder(folder + "/trash"), log: { logs.append($0) }),
                             timeZone: MCPNotesRig.taipei, log: { logs.append($0) })
        mcp = MCPService(holders: store, notes: notes, log: { logs.append($0) })
        store.mcp = mcp
        // A live CODD claude session in `work` (what createSession would have made).
        let projectID = UUID().uuidString.lowercased()
        let id = session.uuidString.lowercased()
        store.projectsByID[projectID] = ProjectVM(id: projectID, name: "work", cwd: work, groupID: HolderSessionStore.ungroupedID,
                                                  sessionIDs: [id])
        store.sessionsByID[id] = SessionVM(id: id, projectID: projectID, title: "打卡頁 RWD 調整", state: .idle, stateSince: Date())
        mcp.start()
        await notes.open()
        await pipeline.start()
        await m3Eventually("MCP running") { self.mcp.running && self.mcp.context.library != nil }
        guard case .listening(let p) = pipeline.status else { throw CocoaError(.featureUnsupported) }
        port = p
    }

    var hookToken: String { pipeline.config?.token ?? "" }
    var mcpToken: String { pipeline.config?.mcpToken ?? "" }
    var sessionToken: String { MCPAuth.sessionToken(hookToken: hookToken, sessionID: session) }
    var sessionHeaders: [String: String] { ["X-CODD-Session": session.uuidString.lowercased(), "X-CODD-Token": sessionToken] }

    func note(_ title: String, _ body: String, ai: NoteAIAccess = .read, scope: NoteScope = .global, projects: [String] = []) async throws -> NoteID {
        try await notes.create(NewNote(title: title, body: "# \(title)\n\n\(body)\n", links: NoteLinks(projects: projects), ai: ai, scope: scope))
            .metadata.id
    }

    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    func send(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> Reply {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await http.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields { fields[String(describing: key).lowercased()] = String(describing: value) }
        return Reply(status: http.statusCode, body: data, headers: fields)
    }

    /// One JSON-RPC request to `/mcp`.
    func rpc(_ method: String, _ params: [String: Any]? = nil, id: Int = 1, headers: [String: String]) async throws -> Reply {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        var all = headers
        all["MCP-Protocol-Version"] = all["MCP-Protocol-Version"] ?? "2025-11-25"
        return try await send("POST", "/mcp", body: try JSONSerialization.data(withJSONObject: message), headers: all)
    }

    func toolText(_ reply: Reply) -> String {
        let content = (reply.json?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func close() async {
        mcp.stop()
        await pipeline.shutdown()
        await notes.close()
        m3RemoveFolder(folder)
    }
}

@Suite("M4 MCP · the routes on the hook server (D16, D19, D15, D21)", .serialized)
@MainActor
struct M4MCPRouteTests {
    @Test func sessionAndExternalTokensReachTheBackendOthersAreRefused() async throws {
        let rig = try await MCPRouteRig("codd-i2a-rt")
        let local = try await rig.note("本機專案的打卡筆記", "打卡頁 本機", scope: .project, projects: [rig.work])
        let other = try await rig.note("別的專案的打卡筆記", "打卡 其他", scope: .project, projects: [rig.folder + "/other"])
        let off = try await rig.note("關閉的打卡筆記", "打卡 OFF-ROUTE-SECRET", ai: .off)
        // server/discover → -32601 with HTTP 200 (Claude then falls back to initialize).
        let discover = try await rig.rpc("server/discover", headers: rig.sessionHeaders)
        #expect(discover.status == 200 && (discover.json?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let initialize = try await rig.rpc("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any],
                                                         "clientInfo": ["name": "claude-code", "version": "2.1.302"]], headers: rig.sessionHeaders)
        #expect(((initialize.json?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "codd")
        // The session sees its project's note, never another project's or the OFF one.
        let search = try await rig.rpc("tools/call", ["name": "notes_search", "arguments": ["query": "打卡"]], headers: rig.sessionHeaders)
        #expect(search.status == 200)
        let text = rig.toolText(search)
        #expect(text.contains(local.uri) && !text.contains(other.uri) && !text.contains(off.uri) && !text.contains("OFF-ROUTE-SECRET"))
        // The external token (X-CODD-Token or Bearer) sees every visible note.
        let external = try await rig.rpc("tools/call", ["name": "notes_search", "arguments": ["query": "打卡"]],
                                         headers: ["Authorization": "Bearer \(rig.mcpToken)"])
        #expect(external.status == 200)
        let externalText = rig.toolText(external)
        #expect(externalText.contains(local.uri) && externalText.contains(other.uri) && !externalText.contains(off.uri))
        let list = try await rig.rpc("tools/list", headers: ["X-CODD-Token": rig.mcpToken])
        let names = (((list.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        #expect(names == ["notes_search", "notes_list", "notes_read", "notes_append", "notes_create"], "notes_write only while AI 可寫入 is ON")
        // Refusals from the server: a wrong token, a session header with the hook token, a foreign Origin.
        #expect(try await rig.rpc("tools/list", headers: ["X-CODD-Token": "wrong"]).status == 401)
        #expect(try await rig.rpc("tools/list", headers: ["X-CODD-Session": rig.session.uuidString.lowercased(), "X-CODD-Token": rig.hookToken]).status == 401)
        #expect(try await rig.rpc("tools/list", headers: rig.sessionHeaders.merging(["Origin": "http://evil.example"]) { $1 }).status == 403)
        #expect(try await rig.rpc("tools/list", headers: rig.sessionHeaders.merging(["Origin": "http://127.0.0.1:\(rig.port)"]) { $1 }).status == 200)
        #expect(try await rig.send("GET", "/mcp", headers: rig.sessionHeaders).status == 405)
        // The hook token never opens /mcp as external, the MCP token never opens /hooks.
        #expect(try await rig.send("POST", "/hooks", body: Data("{}".utf8),
                                   headers: ["X-CODD-Token": rig.mcpToken, "X-CODD-Session": rig.session.uuidString.lowercased()]).status == 401)
        #expect(!rig.logs.values.joined(separator: "\n").contains(rig.mcpToken), "no token in a log line")
        await rig.close()
    }

    @Test func clientsAreLiveSessionsAndRecentExternals() async throws {
        let rig = try await MCPRouteRig("codd-i2a-cl")
        #expect(rig.mcp.clients.isEmpty && rig.store.host.mcpClients == 0)
        #expect(rig.store.host.mcpRunning && rig.store.host.mcpEndpoint == "127.0.0.1:\(rig.port)")
        func initialize(_ name: String, headers: [String: String]) async throws {
            let reply = try await rig.rpc("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any],
                                                         "clientInfo": ["name": name, "version": "1"]], headers: headers)
            #expect(reply.status == 200)
        }
        try await initialize("claude-code", headers: rig.sessionHeaders)
        await m3Eventually("the session client") { rig.mcp.clients.count == 1 }
        #expect(rig.mcp.clients.first?.title == "打卡頁 RWD 調整" && rig.mcp.clients.first?.clientKind == "Claude Code")
        try await initialize("codex-mcp-client", headers: ["X-CODD-Token": rig.mcpToken])
        await m3Eventually("the external client") { rig.mcp.clients.count == 2 }
        #expect(rig.mcp.clients.contains { $0.kind == .external && $0.clientKind == "Codex CLI" })
        #expect(rig.store.host.mcpClients == 2)
        // A second initialize of the same session is still one client (its first time kept).
        let since = rig.mcp.clients.first { $0.kind == .session }?.since
        try await initialize("claude-code", headers: rig.sessionHeaders)
        await m3Eventually("requests counted") { rig.mcp.requests >= 3 }
        #expect(rig.mcp.clients.count == 2 && rig.mcp.clients.first { $0.kind == .session }?.since == since)
        // The session stops: no longer a client. The external one expires after 30 minutes.
        rig.store.sessionsByID[rig.session.uuidString.lowercased()]?.state = .stopped
        await m3Eventually("the stopped session is gone") { rig.mcp.clients.count == 1 }
        let later = Date().addingTimeInterval(31 * 60)
        rig.mcp.now = { later }
        rig.mcp.rebuildClients()
        #expect(rig.mcp.clients.isEmpty)
        // The STATUS card and nav follow.
        let model = StatusPageData.mcpModel(rig.mcp, notesPath: "~/notes", now: Date())
        #expect(model.running && model.endpoint == "127.0.0.1:\(rig.port)" && model.clientsCount == 0 && model.note == nil)
        await rig.close()
    }

    @Test func aSessionThatInitializedBeforeARestartCountsAtItsFirstRequest() async throws {
        let rig = try await MCPRouteRig("codd-i2a-cl2")
        // No `initialize` (it went to the previous CODD): a plain request makes it a client.
        #expect(try await rig.rpc("tools/list", headers: rig.sessionHeaders).status == 200)
        await m3Eventually("the session client") { rig.mcp.clients.count == 1 }
        #expect(rig.mcp.clients.first?.kind == .session && rig.mcp.clients.first?.clientKind == "Claude Code")
        // An external request without `initialize` is still nobody (D21 needs its client name).
        #expect(try await rig.rpc("tools/list", headers: ["X-CODD-Token": rig.mcpToken]).status == 200)
        await m3Eventually("requests counted") { rig.mcp.requests >= 2 }
        #expect(rig.mcp.clients.count == 1)
        await rig.close()
    }

    @Test func aiActivityReachesTheInfoPanelLive() async throws {
        let rig = try await MCPRouteRig("codd-i2a-act")
        let id = try await rig.note("被 AI 讀的筆記", "內容")
        rig.notes.select(id)
        await m3Eventually("selected") { rig.notes.selected?.summary.id == id }
        #expect(rig.notes.selected?.activity.isEmpty == true)
        let read = try await rig.rpc("tools/call", ["name": "notes_read", "arguments": ["ref": id.uri]], headers: rig.sessionHeaders)
        #expect(read.status == 200 && rig.toolText(read).contains("被 AI 讀的筆記"))
        await m3Eventually("the read in the info panel's facts") { rig.notes.selected?.activity.first?.action == "read" }
        let p = NotebookPresenter(now: Date(), timeZone: MCPNotesRig.taipei, store: rig.store, projects: [:])
        let rows = p.aiActivity(rig.notes.selected?.activity ?? [])
        #expect(rows.first?.who == "打卡頁 RWD 調整", "讀取 · <session> · HH:mm")
        await rig.close()
    }

    @Test func promptHookExpandsRefsWithASystemMessage() async throws {
        let rig = try await MCPRouteRig("codd-i2a-pr")
        let id = try await rig.note("打卡頁 RWD 跑版紀錄", "按鈕被蓋住")
        let off = try await rig.note("私人", "ROUTE-OFF-SECRET", ai: .off)
        func prompt(_ text: String) async throws -> MCPRouteRig.Reply {
            let payload: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "c-1", "cwd": rig.work, "prompt": text,
                                          "permission_mode": "default"]
            return try await rig.send("POST", "/hooks/prompt", body: try JSONSerialization.data(withJSONObject: payload),
                                      headers: ["X-CODD-Token": rig.hookToken, "X-CODD-Session": rig.session.uuidString.lowercased()])
        }
        let reply = try await prompt("看一下 \(id.uri) 再修")
        #expect(reply.status == 200 && reply.headers["content-type"]?.hasPrefix("application/json") == true)
        let json = try #require(reply.json)
        #expect(json["systemMessage"] as? String == "codd：已展開 \(id.uri)（打卡頁 RWD 跑版紀錄）")
        let context = (json["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String ?? ""
        #expect(context.contains("<codd-note ref=\"\(id.uri)\" title=\"打卡頁 RWD 跑版紀錄\">") && context.contains("按鈕被蓋住"))
        #expect((json["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "UserPromptSubmit")
        // An OFF ref: one line, never its title or text.
        let refused = try #require(try await prompt("[[note:\(off.rawValue)]]").json)
        #expect(refused["systemMessage"] as? String == "codd：\(off.uri) 無法展開（AI 存取為 OFF）")
        let refusedText = String(describing: refused)
        #expect(!refusedText.contains("私人") && !refusedText.contains("ROUTE-OFF-SECRET"))
        // No ref: 204.
        #expect(try await prompt("一般的 prompt").status == 204)
        await m3Eventually("expansions counted") { rig.mcp.expansion.count == 2 }
        #expect(rig.mcp.expansion.lastRefs == [off.rawValue] && rig.mcp.expansion.late == 0)
        // The expansion is AI activity of the note, with the session's title (D20).
        let activity = await rig.notes.library?.activity(of: id, limit: 3) ?? []
        #expect(activity.first?.action == "expand" && activity.first?.sessionTitle == "打卡頁 RWD 調整" && activity.first?.via == "hook")
        // The prompt still reached the state engine as on /hooks.
        await m3Eventually("event counted") { rig.pipeline.eventCount >= 3 }
        await rig.close()
    }

    @Test func noteURLsServeTheCopyFormOrSayWhy() async throws {
        let rig = try await MCPRouteRig("codd-i2a-url")
        let id = try await rig.note("網址筆記", "可以用 curl 讀")
        let off = try await rig.note("不給網址", "URL-OFF-SECRET", ai: .off)
        let trashed = try await rig.note("丟掉的", "垃圾")
        try await rig.notes.trash(trashed)
        func get(_ note: NoteID, token: String? = nil) async throws -> MCPRouteRig.Reply {
            let t = token ?? MCPAuth.noteURLToken(mcpToken: rig.mcpToken, noteID: note.rawValue)
            return try await rig.send("GET", "/n/\(note.rawValue).md?t=\(t)")
        }
        let ok = try await get(id)
        #expect(ok.status == 200 && ok.headers["content-type"] == "text/markdown; charset=utf-8")
        #expect(ok.text.hasPrefix("# 網址筆記") && ok.text.contains("可以用 curl 讀") && !ok.text.contains("ai: read"), "the body without the frontmatter")
        #expect(try await get(off).status == 404)
        let gone = try await get(trashed)
        #expect(gone.status == 410 && gone.text == "這則筆記在 CODD 垃圾桶\n")
        #expect(try await get(id, token: String(repeating: "0", count: 24)).status == 404)
        #expect(try await get(NoteID(rawValue: "no-such-note")!).status == 404)
        let activity = await rig.notes.library?.activity(of: id, limit: 3) ?? []
        #expect(activity.first?.action == "url" && activity.first?.via == "url")
        await rig.close()
    }

    @Test func claudeCodeRegistrationIsReadOnlyAndFollowsTheToken() async throws {
        let rig = try await MCPRouteRig("codd-i2a-reg")
        let file = MCPService.globalConfigURL(claudeDirectory: rig.claude)
        #expect(file.path == rig.folder + "/home/.claude.json")
        await rig.mcp.refreshRegistrations()
        #expect(rig.mcp.claudeCode == .notRegistered)
        func write(url: String, token: String) throws {
            let json = #"{"mcpServers":{"other":{"type":"stdio","command":"x"},"codd":{"type":"http","url":"\#(url)","headers":{"X-CODD-Token":"\#(token)"}}}}"#
            try json.write(to: file, atomically: true, encoding: .utf8)
        }
        let ours = "http://127.0.0.1:\(rig.port)/mcp"
        try write(url: ours, token: rig.mcpToken)
        let before = try Data(contentsOf: file)
        await rig.mcp.refreshRegistrations()
        #expect(rig.mcp.claudeCode == .registered(tokenMatches: true))
        try write(url: ours, token: "rotated-away")
        await rig.mcp.refreshRegistrations()
        #expect(rig.mcp.claudeCode == .registered(tokenMatches: false))
        try write(url: "http://example.com/mcp", token: "x")
        await rig.mcp.refreshRegistrations()
        #expect(rig.mcp.claudeCode == .notRegistered, "another server under the name codd is not CODD")
        try write(url: ours, token: rig.mcpToken)
        await rig.mcp.refreshRegistrations()
        #expect(try Data(contentsOf: file) == before, "inspection never writes")
        let rows = MCPRegistrationRows.status(rig.mcp.claudeCode)
        #expect(rows.map(\.state) == ["● 已註冊", "○ 未註冊", "○ 未安裝"])
        // I2b: Claude Code (移除 while registered) and Codex are pressable; Claude Desktop is FUTURE.
        #expect(rows[0].isActionable && rows[0].actionTitle == "移除" && rows[1].isActionable && !rows[2].isActionable)
        #expect(rows[0].toolTip == nil && rows[2].chip == "FUTURE")
        await rig.close()
    }
}
