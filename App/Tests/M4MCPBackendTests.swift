import CoddHooks
import CoddMCP
import CoddNotes
import Foundation
import Testing
@testable import CODD

/// A notebook on a temp folder for the MCP backend (M4 I2a): a `NotesLibrary` opened directly, the
/// request path's context with made-up CODD sessions, and the notes every D17 rule needs. Nothing
/// here starts a claude or touches `~`.
final class MCPNotesRig: Sendable {
    static let taipei = TimeZone(identifier: "Asia/Taipei")!

    let folder: String
    let library: NotesLibrary
    let context: NotesMCPContext
    let backend: NotesMCPBackend
    /// Session A works in `projectA`; session B is linked to `linked`; neither sees `projectB`.
    let sessionA = UUID()
    let sessionB = UUID()
    let projectA: String
    let projectB: String

    struct IDs: Sendable {
        var global: NoteID
        var off: NoteID
        var projectA: NoteID
        var projectB: NoteID
        var linked: NoteID
        var append: NoteID
        var archived: NoteID
        var trashed: NoteID
    }

    let ids: IDs
    static let offSecret = "OFF-SECRET-77"
    static let offTitle = "不給 AI 的秘密"

    init(_ prefix: String) async throws {
        folder = try m3TempFolder(prefix)
        projectA = folder + "/work/a"
        projectB = folder + "/work/b"
        for dir in [projectA, projectB] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let trash = folder + "/trash"
        let library = NotesLibrary(root: URL(fileURLWithPath: folder + "/data/notes", isDirectory: true),
                               indexURL: URL(fileURLWithPath: folder + "/data/notes-index.sqlite"),
                               annotatedFolder: URL(fileURLWithPath: folder + "/data/cache/annotated", isDirectory: true),
                               policy: .defaults, defaultAccess: .read,
                               trash: { url in
                                   try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
                                   try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: trash + "/" + url.lastPathComponent + "-\(UUID())"))
                               }, timeZone: Self.taipei)
        _ = try await library.open()
        self.library = library
        context = NotesMCPContext(timeZone: Self.taipei)
        context.setLibrary(library)
        context.setSessions([
            sessionA.uuidString.lowercased(): .init(title: "打卡頁 RWD 調整", cwd: projectA, live: true),
            sessionB.uuidString.lowercased(): .init(title: "另一個 session", cwd: folder + "/elsewhere", live: true),
        ])
        backend = NotesMCPBackend(context: context)
        let (projectA, projectB, sessionB) = (self.projectA, self.projectB, self.sessionB)
        func make(_ title: String, _ body: String, ai: NoteAIAccess = .read, scope: NoteScope = .global, tags: [String] = [],
                  links: NoteLinks = NoteLinks()) async throws -> NoteID {
            try await library.create(NewNote(title: title, body: "# \(title)\n\n\(body)\n", tags: tags, links: links, ai: ai, scope: scope))
                .metadata.id
        }
        let global = try await make("全域：常用指令", "打卡 共用的內容", tags: ["cmd"])
        let off = try await make(Self.offTitle, "這裡有 \(Self.offSecret) 打卡", ai: .off)
        let a = try await make("專案 A 的打卡筆記", "打卡頁 A 專案", scope: .project, tags: ["rwd"], links: NoteLinks(projects: [projectA]))
        let b = try await make("專案 B 的筆記", "打卡 B 專案", scope: .project, links: NoteLinks(projects: [projectB]))
        let linked = try await make("連到 session B", "打卡 連結", scope: .project,
                                    links: NoteLinks(sessions: [sessionB.uuidString.lowercased()], projects: [projectB]))
        let append = try await make("AI 附加測試", "可以附加", ai: .append)
        let archived = try await make("已封存的打卡", "打卡 舊的")
        try await library.archive([archived], by: .user)
        let trashed = try await make("垃圾桶裡的打卡", "打卡 丟掉")
        try await library.trash([trashed])
        ids = IDs(global: global, off: off, projectA: a, projectB: b, linked: linked, append: append, archived: archived, trashed: trashed)
    }

    func close() async {
        await library.close()
        try? FileManager.default.removeItem(atPath: folder)
    }

    var callerA: MCPCaller { .session(sessionA) }
    var callerB: MCPCaller { .session(sessionB) }

    @MainActor
    func error(_ body: () async throws -> some Any) async -> MCPBackendError? {
        do {
            _ = try await body()
            return nil
        } catch let error as MCPBackendError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }
}

@Suite("M4 MCP · backend access and scope (D17)", .serialized)
@MainActor
struct M4MCPBackendTests {
    @Test func offNotesAreInvisibleEverywhere() async throws {
        let rig = try await MCPNotesRig("codd-i2a-off")
        let b = rig.backend
        for caller in [MCPCaller.external, rig.callerA, rig.callerB] {
            let hits = try await b.search(MCPSearchRequest(query: MCPNotesRig.offSecret), caller: caller)
            #expect(hits.isEmpty, "search never finds the OFF note")
            let all = try await b.search(MCPSearchRequest(query: "打卡", limit: 20), caller: caller)
            #expect(!all.contains { $0.id == rig.ids.off.rawValue })
            let list = try await b.list(MCPListRequest(includeArchived: true, limit: 50), caller: caller)
            #expect(!list.contains { $0.id == rig.ids.off.rawValue })
            let resources = try await b.resources(caller: caller)
            #expect(!resources.contains { $0.uri == rig.ids.off.uri })
            #expect(await rig.error { try await b.read(MCPReadRequest(ref: rig.ids.off.uri), caller: caller) } == .notFound(rig.ids.off.uri))
            #expect(await rig.error { try await b.readResource(uri: rig.ids.off.uri, caller: caller) } == .notFound(rig.ids.off.uri))
            #expect(await rig.error { try await b.promptNote(id: rig.ids.off.rawValue, caller: caller) } == .notFound(rig.ids.off.rawValue))
            #expect(await rig.error {
                try await b.append(MCPAppendRequest(ref: rig.ids.off.rawValue, markdown: "x"), caller: caller)
            } == .notFound(rig.ids.off.rawValue), "even the append refusal looks like an unknown note")
        }
        // An OFF note in the trash is still unknown, never `trashed`.
        try await rig.library.trash([rig.ids.off])
        #expect(await rig.error { try await b.read(MCPReadRequest(ref: rig.ids.off.rawValue), caller: .external) } == .notFound(rig.ids.off.rawValue))
        // The note URL route too.
        let url = await NoteURLResponder(context: rig.context).respond(rig.ids.off.rawValue)
        #expect(url.status == 404 && url.body.isEmpty)
        await rig.close()
    }

    @Test func projectScopeFollowsTheCallersFolderAndLinks() async throws {
        let rig = try await MCPNotesRig("codd-i2a-scope")
        let b = rig.backend
        func ids(_ caller: MCPCaller, scope: MCPSearchRequest.Scope = .all) async throws -> Set<String> {
            Set(try await b.search(MCPSearchRequest(query: "打卡", scope: scope, limit: 20), caller: caller).map(\.id))
        }
        let a = try await ids(rig.callerA)
        #expect(a.contains(rig.ids.global.rawValue) && a.contains(rig.ids.projectA.rawValue))
        #expect(!a.contains(rig.ids.projectB.rawValue) && !a.contains(rig.ids.linked.rawValue), "project B is outside session A's folder")
        let linked = try await ids(rig.callerB)
        #expect(linked.contains(rig.ids.linked.rawValue), "a note linked to the session is visible to it")
        #expect(!linked.contains(rig.ids.projectA.rawValue) && !linked.contains(rig.ids.projectB.rawValue))
        let external = try await ids(.external)
        #expect(external == Set([rig.ids.global, rig.ids.projectA, rig.ids.projectB, rig.ids.linked].map(\.rawValue)),
                "external callers see every visible active note")
        // A session CODD does not know (no facts yet) sees the global notes only.
        let stranger = try await ids(.session(UUID()))
        #expect(stranger == [rig.ids.global.rawValue])
        // `scope: project` only narrows.
        #expect(try await ids(rig.callerA, scope: .project) == [rig.ids.projectA.rawValue])
        #expect(try await ids(rig.callerB, scope: .project) == [rig.ids.linked.rawValue])
        #expect(try await ids(.external, scope: .project).isEmpty, "an external caller has no project of its own")
        // A sub-folder of the project is inside it (realpath of both sides).
        let sub = rig.projectA + "/src"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        rig.context.setSessions([rig.sessionA.uuidString.lowercased(): .init(title: "子資料夾", cwd: sub, live: true)])
        #expect(try await ids(rig.callerA).contains(rig.ids.projectA.rawValue))
        // Reading an out-of-scope note by ref is an unknown ref.
        #expect(await rig.error { try await b.read(MCPReadRequest(ref: rig.ids.projectB.uri), caller: rig.callerA) }
            == .notFound(rig.ids.projectB.uri))
        await rig.close()
    }

    @Test func archivedOnlyWithTheFlagAndTrashedOrPurgedAreRefused() async throws {
        let rig = try await MCPNotesRig("codd-i2a-life")
        let b = rig.backend
        let plain = try await b.search(MCPSearchRequest(query: "打卡", limit: 20), caller: .external).map(\.id)
        #expect(!plain.contains(rig.ids.archived.rawValue) && !plain.contains(rig.ids.trashed.rawValue))
        let withArchived = try await b.search(MCPSearchRequest(query: "打卡", includeArchived: true, limit: 20), caller: .external)
        #expect(withArchived.first { $0.id == rig.ids.archived.rawValue }?.state == "archived")
        #expect(!withArchived.contains { $0.id == rig.ids.trashed.rawValue })
        let listed = try await b.list(MCPListRequest(includeArchived: true, limit: 50), caller: .external).map(\.id)
        #expect(listed.contains(rig.ids.archived.rawValue))
        #expect(!(try await b.list(MCPListRequest(limit: 50), caller: .external)).contains { $0.id == rig.ids.archived.rawValue })
        // An archived note is still readable by ref.
        let archived = try await b.read(MCPReadRequest(ref: rig.ids.archived.uri), caller: .external)
        #expect(archived.text.contains("已封存的打卡"))
        guard case .trashed(let id, let purgeAt)? = await rig.error({ try await b.read(MCPReadRequest(ref: rig.ids.trashed.rawValue), caller: .external) }) else {
            Issue.record("trashed")
            await rig.close()
            return
        }
        #expect(id == rig.ids.trashed.rawValue && purgeAt != nil)
        try await rig.library.purge([rig.ids.trashed])
        #expect(await rig.error { try await b.read(MCPReadRequest(ref: rig.ids.trashed.rawValue), caller: .external) }
            == .purged(id: rig.ids.trashed.rawValue))
        #expect(await rig.error { try await b.read(MCPReadRequest(ref: "no-such-note"), caller: .external) } == .notFound("no-such-note"))
        await rig.close()
    }

    @Test func readOnlyAppendAndWriteFollowTheNotesAccess() async throws {
        let rig = try await MCPNotesRig("codd-i2a-write")
        let b = rig.backend
        // READ: append refused with C1's text.
        #expect(await rig.error { try await b.append(MCPAppendRequest(ref: rig.ids.global.rawValue, markdown: "不行"), caller: rig.callerA) }
            == .accessDenied("這則筆記的 AI 存取是 READ，不能附加"))
        // APPEND: the block, a snapshot first, the activity with the session's title.
        let original = try await rig.library.document(rig.ids.append).body
        let result = try await b.append(MCPAppendRequest(ref: rig.ids.append.uri, markdown: "AI 寫的一行", heading: "回報"), caller: rig.callerA)
        #expect(result.text == "已附加到 \(rig.ids.append.uri)（### 回報）")
        let document = try await rig.library.document(rig.ids.append)
        #expect(document.body.contains("<!-- codd:ai-append session=\"打卡頁 RWD 調整\""))
        #expect(document.body.contains("### 回報\nAI 寫的一行"))
        // The text before the append is in HISTORY (C1 skips a snapshot identical to the newest one).
        let history = try await rig.library.history(of: rig.ids.append)
        var kept: [String] = []
        for snapshot in history { kept.append(try await rig.library.snapshotText(snapshot, of: rig.ids.append)) }
        #expect(kept.contains(original))
        let activity = await rig.library.activity(of: rig.ids.append, limit: 5)
        #expect(activity.first?.action == "append" && activity.first?.sessionTitle == "打卡頁 RWD 調整" && activity.first?.via == "mcp")
        // notes_write only while AI 可寫入 is ON.
        #expect(await b.capabilities(caller: rig.callerA).writeEnabled == false)
        #expect(await rig.error { try await b.write(MCPWriteRequest(ref: rig.ids.append.rawValue, markdown: "全部換掉"), caller: rig.callerA) }
            != nil)
        rig.context.writeEnabled = true
        #expect(await b.capabilities(caller: rig.callerA).writeEnabled)
        _ = try await b.write(MCPWriteRequest(ref: rig.ids.append.rawValue, markdown: "全部換掉"), caller: rig.callerA)
        #expect(try await rig.library.document(rig.ids.append).body == "# AI 附加測試\n\n全部換掉\n")
        #expect(await rig.error { try await b.write(MCPWriteRequest(ref: rig.ids.global.rawValue, markdown: "x"), caller: rig.callerA) }
            == .accessDenied("這則筆記的 AI 存取是 READ，不能改寫"))
        await rig.close()
    }

    @Test func readPagesTextAttachesImagesAndRecordsTheRead() async throws {
        let rig = try await MCPNotesRig("codd-i2a-read")
        let b = rig.backend
        let png = try M4NotebookCoreFlowTests.png(width: 300, height: 200)
        let asset = try await rig.library.saveAsset(png, typeHint: "public.png", for: rig.ids.global, resizeLongEdge: 2576, keepOriginal: false)
        let doc = try await rig.library.document(rig.ids.global)
        let long = String(repeating: "很長的一段文字。", count: 2_000)
        _ = try await rig.library.save(rig.ids.global, body: doc.body + "\n![截圖](\(asset.markdownPath))\n\n\(long)\n", basedOn: doc.contentHash)
        let first = try await b.read(MCPReadRequest(ref: "[[note:\(rig.ids.global.rawValue)]]", maxChars: 1_000), caller: rig.callerA)
        #expect(first.truncated && first.nextOffset != nil && (first.totalChars ?? 0) > 10_000)
        #expect(first.text.hasPrefix("# 全域：常用指令\ncodd://note/\(rig.ids.global.rawValue) · NOTE · #cmd"))
        #expect(first.images.count == 1 && first.images.first?.mimeType == "image/png")
        let noImages = try await b.read(MCPReadRequest(ref: rig.ids.global.rawValue, maxChars: 1_000, includeImages: false), caller: rig.callerA)
        #expect(noImages.images.isEmpty && noImages.extraImagePaths.count == 1 && noImages.extraImagePaths[0].hasSuffix(".png"))
        let next = try await b.read(MCPReadRequest(ref: rig.ids.global.rawValue, offset: first.nextOffset ?? 0, maxChars: 1_000),
                                    caller: rig.callerA)
        #expect(!next.text.isEmpty && next.text != first.text)
        let activity = await rig.library.activity(of: rig.ids.global, limit: 5)
        #expect(activity.first?.action == "read" && activity.first?.session == rig.sessionA.uuidString.lowercased())
        #expect(activity.first?.client == "Claude Code" && activity.first?.sessionTitle == "打卡頁 RWD 調整")
        await rig.close()
    }

    /// CODE-4: `notes_read` attaches an image a note links only from the notes root or the calling
    /// session's folder; prompt expansion sizes only those. Any other image is named, not attached.
    @Test func imagesOutsideTheNotebookOrTheSessionFolderAreNamedOnly() async throws {
        let rig = try await MCPNotesRig("codd-i2a-scope")
        let b = rig.backend
        let png = try M4NotebookCoreFlowTests.png(width: 300, height: 200)
        let inA = rig.projectA + "/shot.png", inB = rig.projectB + "/shot.png"
        for path in [inA, inB] { try png.write(to: URL(fileURLWithPath: path)) }
        let doc = try await rig.library.document(rig.ids.global)
        _ = try await rig.library.save(rig.ids.global, body: doc.body + "\n![a](\(inA))\n\n![b](\(inB))\n", basedOn: doc.contentHash)
        let note = NoteAIText.notAttachedNote
        let a = try await b.read(MCPReadRequest(ref: rig.ids.global.rawValue), caller: rig.callerA)
        #expect(a.images.map(\.path) == [inA] && a.extraImagePaths.isEmpty, "session A gets its own folder's image only")
        #expect(a.text.contains("[image] \(inA) (300×200)") && a.text.contains("[image] \(inB) \(note)"))
        for caller in [MCPCaller.external, rig.callerB] {
            let other = try await b.read(MCPReadRequest(ref: rig.ids.global.rawValue), caller: caller)
            #expect(other.images.isEmpty && other.extraImagePaths.isEmpty)
            #expect(other.text.contains("[image] \(inA) \(note)") && other.text.contains("[image] \(inB) \(note)"))
        }
        let resource = try await b.readResource(uri: rig.ids.global.uri, caller: .external)
        #expect(!resource.contains("(300×200)"), "resources name them the same way")
        let expanded = try #require(await PromptExpansion(context: rig.context).answer(sessionID: rig.sessionA, prompt: rig.ids.global.uri))
        #expect(expanded.additionalContext.contains("[image] \(inA) (300×200)"))
        #expect(expanded.additionalContext.contains("[image] \(inB) \(note)"))
        await rig.close()
    }

    @Test func listFiltersBySessionProjectKindAndCurrent() async throws {
        let rig = try await MCPNotesRig("codd-i2a-list")
        let b = rig.backend
        let current = try await b.list(MCPListRequest(project: "current"), caller: rig.callerA).map(\.id)
        #expect(current == [rig.ids.projectA.rawValue])
        let linked = try await b.list(MCPListRequest(session: "current"), caller: rig.callerB).map(\.id)
        #expect(linked == [rig.ids.linked.rawValue])
        let byPath = try await b.list(MCPListRequest(project: rig.projectB), caller: .external).map(\.id)
        #expect(Set(byPath) == [rig.ids.projectB.rawValue, rig.ids.linked.rawValue])
        #expect(await rig.error { try await b.list(MCPListRequest(session: "current"), caller: .external) }
            == .invalid(NotesMCPBackend.currentSessionOnly))
        #expect(try await b.list(MCPListRequest(kind: "prompt"), caller: .external).isEmpty)
        #expect(try await b.list(MCPListRequest(days: 1), caller: .external).count == 5)
        let tagged = try await b.search(MCPSearchRequest(query: "", tags: ["rwd"]), caller: .external).map(\.id)
        #expect(tagged == [rig.ids.projectA.rawValue], "an empty query with tags lists by tag")
        await rig.close()
    }
}
