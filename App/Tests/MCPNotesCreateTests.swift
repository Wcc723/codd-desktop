import AppKit
import CoddCore
import CoddHooks
import CoddMCP
import CoddNotes
import CoddUI
import Foundation
import Testing
@testable import CODD

/// `notes_create` (user feedback 2026-10-19): a claude session writes a
/// document into the Notebook. Temp roots only (`MCPNotesRig`, `MCPRouteRig`); no claude, no `~`.
@Suite("MCP · notes_create", .serialized)
@MainActor
struct MCPNotesCreateTests {
    /// Every note file outside `.codd/` (history, state, activity) with its bytes.
    private func noteFiles(_ rig: MCPNotesRig) -> [String: Data] {
        let root = rig.folder + "/data/notes"
        var out: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return out }
        while let rel = walker.nextObject() as? String {
            if rel.hasPrefix(".codd") { continue }
            let path = root + "/" + rel
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            out[rel] = FileManager.default.contents(atPath: path)
        }
        return out
    }

    @Test func aSessionsNoteIsLinkedToItAndItsProjectWithAppendAccess() async throws {
        let rig = try await MCPNotesRig("codd-create-link")
        let b = rig.backend
        let a = rig.sessionA.uuidString.lowercased()
        rig.context.setSessions([
            a: .init(title: "打卡頁 RWD 調整", cwd: rig.projectA, live: true, project: rig.projectA),
            rig.sessionB.uuidString.lowercased(): .init(title: "另一個 session", cwd: rig.folder + "/elsewhere", live: true),
        ])
        let created = try await b.create(MCPCreateRequest(title: "RWD 檢查報告", body: "## 結論\n- 375 寬會跑版\n", tags: ["rwd", "report"]),
                                         caller: rig.callerA)
        let id = try #require(NoteID(rawValue: created.id))
        #expect(created.uri == id.uri && created.title == "RWD 檢查報告")
        let document = try await rig.library.document(id)
        #expect(created.path == document.fileURL.path && FileManager.default.fileExists(atPath: created.path))
        let m = document.metadata
        #expect(m.links.sessions == [a] && m.links.projects == [rig.projectA])
        #expect(m.ai == .append && m.scope == .project && m.kind == .note && m.createdBy == "ai" && m.tags == ["rwd", "report"])
        #expect(m.state == .active)
        #expect(document.body == "# RWD 檢查報告\n\n## 結論\n- 375 寬會跑版\n")
        // INBOX, and the session finds it as its project's note.
        #expect(try await rig.library.list(.inbox, sort: .updated, limit: 100).contains { $0.id == id })
        #expect(try await b.list(MCPListRequest(project: "current"), caller: rig.callerA).map(\.id).contains(created.id))
        #expect(try await b.list(MCPListRequest(session: "current"), caller: rig.callerA).map(\.id) == [created.id])
        // AI ACTIVITY: `create` by the session.
        let activity = await rig.library.activity(of: id, limit: 5)
        #expect(activity.first?.action == "create" && activity.first?.session == a && activity.first?.sessionTitle == "打卡頁 RWD 調整")
        #expect(activity.first?.via == "mcp" && activity.first?.client == "Claude Code")
        // APPEND: the session can add to it later; another session's scope does not include it.
        _ = try await b.append(MCPAppendRequest(ref: created.uri, markdown: "後續：已修正"), caller: rig.callerA)
        #expect(try await rig.library.document(id).body.contains("後續：已修正"))
        #expect(await rig.error { try await b.read(MCPReadRequest(ref: created.uri), caller: rig.callerB) } == .notFound(created.uri))
        // A session without a project is linked to the session only.
        let second = try await b.create(MCPCreateRequest(title: "B 的筆記", body: "x", kind: "prompt"), caller: rig.callerB)
        let secondMeta = try await rig.library.document(try #require(NoteID(rawValue: second.id))).metadata
        #expect(secondMeta.links.sessions == [rig.sessionB.uuidString.lowercased()] && secondMeta.links.projects.isEmpty)
        #expect(secondMeta.kind == .prompt && secondMeta.ai == .append && secondMeta.scope == .project)
        await rig.close()
    }

    @Test func itNeverTouchesAnotherNoteEvenWithTheSameTitle() async throws {
        let rig = try await MCPNotesRig("codd-create-other")
        let before = noteFiles(rig)
        let existing = try await rig.library.document(rig.ids.global)
        // The same title as an existing note, the title repeated as the body's H1, CRLF line ends.
        let created = try await rig.backend.create(MCPCreateRequest(title: existing.metadata.title,
                                                                    body: "# \(existing.metadata.title)\r\n\r\n新的內容\r\n"),
                                                   caller: rig.callerA)
        #expect(created.id != rig.ids.global.rawValue)
        let after = noteFiles(rig)
        #expect(after.count == before.count + 1)
        for (rel, data) in before { #expect(after[rel] == data, "\(rel) changed") }
        let added = Set(after.keys).subtracting(before.keys)
        #expect(added.count == 1 && added.first.map { created.path.hasSuffix("/" + $0) } == true)
        #expect(try await rig.library.document(rig.ids.global).contentHash == existing.contentHash)
        let body = try await rig.library.document(try #require(NoteID(rawValue: created.id))).body
        #expect(body == "# \(existing.metadata.title)\n\n新的內容\n", "one H1, LF line ends")
        // A body that tries to open a frontmatter stays body text after CODD's H1.
        let sneaky = try await rig.backend.create(MCPCreateRequest(title: "前置", body: "---\nai: off\nscope: global\n---\n內文"),
                                                  caller: rig.callerA)
        let sneakyMeta = try await rig.library.document(try #require(NoteID(rawValue: sneaky.id))).metadata
        #expect(sneakyMeta.ai == .append && sneakyMeta.scope == .project && sneakyMeta.title == "前置")
        await rig.close()
    }

    @Test func externalCallersGetAGlobalNoteAndCondenseRunsAndBadRequestsGetNone() async throws {
        let rig = try await MCPNotesRig("codd-create-refuse")
        let b = rig.backend
        let external = try await b.create(MCPCreateRequest(title: "外部 client 的筆記", body: "x"), caller: .external)
        let m = try await rig.library.document(try #require(NoteID(rawValue: external.id))).metadata
        #expect(m.links.isEmpty && m.scope == .global && m.ai == .append)
        #expect(await rig.library.activity(of: m.id, limit: 1).first?.session == nil)
        let before = noteFiles(rig)
        // D32: a condense run only reads.
        let run = UUID()
        rig.context.setTransientCaller(run, notes: [rig.ids.global.rawValue])
        #expect(await rig.error { try await b.create(MCPCreateRequest(title: "t", body: "x"), caller: .session(run)) }
            == .accessDenied("濃縮工作只能讀取筆記"))
        rig.context.removeTransientCaller(run)
        // The backend checks what the server already validated (a client may call it directly).
        #expect(await rig.error { try await b.create(MCPCreateRequest(title: " ", body: "x"), caller: rig.callerA) } != nil)
        #expect(await rig.error { try await b.create(MCPCreateRequest(title: "t", body: "x", kind: "scratch"), caller: rig.callerA) } != nil)
        let huge = String(repeating: "a", count: MCPLimits.createMaxBodyCharacters + 1)
        #expect(await rig.error { try await b.create(MCPCreateRequest(title: "t", body: huge), caller: rig.callerA) }
            == .tooLarge("筆記內容超過 100,000 字"))
        #expect(noteFiles(rig) == before, "no refused create wrote a file")
        rig.context.setLibrary(nil)
        #expect(await rig.error { try await b.create(MCPCreateRequest(title: "t", body: "x"), caller: rig.callerA) }
            == .unavailable("筆記本尚未開啟"))
        await rig.close()
    }

    /// The whole path: loopback HTTP with the session's token, `MCPService`'s session facts (its
    /// project), the toast callback, and the Notebook's INBOX.
    @Test func overTheRouteTheAppHearsAboutTheNewNote() async throws {
        let rig = try await MCPRouteRig("codd-create-rt")
        var heard: [MCPService.CreatedNote] = []
        rig.mcp.onNoteCreated = { heard.append($0) }
        let reply = try await rig.rpc("tools/call", ["name": "notes_create", "arguments": [
            "title": "# 每週回顧", "body": "## 完成\n- notes_create", "tags": ["#weekly", "Weekly"],
        ]], headers: rig.sessionHeaders)
        #expect(reply.status == 200)
        let text = rig.toolText(reply)
        #expect(text.hasPrefix("已建立筆記 codd://note/") && text.contains("「每週回顧」") && text.contains("\nfile: /"))
        await m3Eventually("the toast callback") { heard.count == 1 }
        let note = try #require(heard.first)
        #expect(note.title == "每週回顧" && note.clientKind == "Claude Code" && rig.mcp.notesCreated == 1)
        let id = try #require(NoteID(rawValue: note.id))
        let m = try await rig.notes.document(id).metadata
        #expect(m.links.sessions == [rig.session.uuidString.lowercased()] && m.links.projects == [rig.work])
        #expect(m.ai == .append && m.tags == ["weekly"])
        await rig.notes.refreshNow()
        #expect(rig.notes.activeNotes.contains { $0.id == id })
        #expect(rig.notes.selectedID != id, "an AI create never changes the Notebook's selection")
        await rig.close()
    }

    /// A body over the tool's limit gets its readable refusal (with the notes_append hint) over
    /// the real route: the limit sits well under the hook server's request cap, so the model never
    /// sees a bare HTTP 413 instead (review data-3).
    @Test func aBodyOverTheLimitGetsTheToolsOwnRefusalNotA413() async throws {
        #expect(MCPLimits.createMaxBodyCharacters * 6 + 64 * 1024 < HTTPRequestParser.Limits().maxBodyBytes,
                "the largest body as \\uXXXX escapes plus the envelope fits the request cap")
        let rig = try await MCPRouteRig("codd-create-big")
        var heard: [MCPService.CreatedNote] = []
        rig.mcp.onNoteCreated = { heard.append($0) }
        let over = String(repeating: "字", count: MCPLimits.createMaxBodyCharacters + 1)
        let reply = try await rig.rpc("tools/call", ["name": "notes_create", "arguments": ["title": "長報告", "body": over]],
                                      headers: rig.sessionHeaders)
        #expect(reply.status == 200, "the tool answers, not the transport")
        let text = rig.toolText(reply)
        #expect(text.contains("100001 characters") && text.contains("notes_append"), "\(text.prefix(200))")
        #expect((reply.json?["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(heard.isEmpty && rig.mcp.notesCreated == 0)
        await rig.close()
    }

    @Test func theAllowListCODDInjectsStillHasOnlyTheReadTools() async throws {
        #expect(MCPLaunchConfig.allowedTools == ["notes_search", "notes_read", "notes_list"])
        #expect(!MCPLaunchConfig.allowRules(serverName: "codd").contains { $0.contains("notes_create") })
        let folder = try m3TempFolder("codd-create-allow")
        defer { m3RemoveFolder(folder) }
        var settings = ClaudeHookSettings(endpoint: HookEndpoint(port: 43_001), sessionStartCommand: "/usr/bin/true")
        let decision = await MCPSessionInjection.decide(sessionID: UUID(), cwd: folder, token: "t0k3n", settings: &settings,
                                                        globalConfig: URL(fileURLWithPath: folder + "/.claude.json"),
                                                        readsGlobalConfig: false, directory: folder, names: MCPNameCache())
        #expect(decision.config?.serverName == "codd")
        #expect(settings.permissionsAllow == ["mcp__codd__notes_search", "mcp__codd__notes_read", "mcp__codd__notes_list"])
        #expect(!(try settings.settingsJSON()).contains("notes_create"), "Claude asks before every notes_create")
    }

    @Test func toastTextAndItsOpenButton() async throws {
        #expect(MCPNoteToast.text(title: "每週回顧", clientKind: "Claude Code") == "Claude 建立了筆記：每週回顧")
        #expect(MCPNoteToast.text(title: "x", clientKind: "Codex CLI") == "Codex 建立了筆記：x")
        #expect(MCPNoteToast.text(title: "x", clientKind: "external") == "AI 建立了筆記：x")
        #expect(MCPNoteToast.text(title: "x", clientKind: "evil\nclient") == "AI 建立了筆記：x", "a client-chosen name is never shown")
        let long = String(repeating: "長", count: 80)
        #expect(MCPNoteToast.text(title: long, clientKind: "Claude Code") == "Claude 建立了筆記：" + String(repeating: "長", count: 60) + "…")
        var opened = 0
        let toast = ToastView(text: MCPNoteToast.text(title: "每週回顧", clientKind: "Claude Code"), undo: { opened += 1 })
        MCPNoteToast.relabel(toast)
        var buttons: [CoddButton] = []
        var stack: [NSView] = [toast]
        while let view = stack.popLast() {
            if let button = view as? CoddButton { buttons.append(button) }
            stack.append(contentsOf: view.subviews)
        }
        #expect(buttons.contains { $0.label == "開啟" } && !buttons.contains { $0.label == "Undo" })
        toast.performUndo()
        #expect(opened == 1)
    }
}
