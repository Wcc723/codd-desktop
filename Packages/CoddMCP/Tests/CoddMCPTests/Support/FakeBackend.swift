import Foundation
import Synchronization
@testable import CoddMCP

/// Records every call and answers from canned values. `failure` makes every throwing method
/// throw it (an `MCPBackendError` or any other error).
final class FakeBackend: MCPNotesBackend {
    enum Call: Sendable, Equatable {
        case search(MCPSearchRequest, MCPCaller)
        case list(MCPListRequest, MCPCaller)
        case read(MCPReadRequest, MCPCaller)
        case append(MCPAppendRequest, MCPCaller)
        case write(MCPWriteRequest, MCPCaller)
        case create(MCPCreateRequest, MCPCaller)
        case resources(MCPCaller)
        case readResource(String, MCPCaller)
        case prompt(String, MCPCaller)
    }

    struct Canned: Sendable {
        var hits: [MCPNoteHit] = [Fixture.hit]
        var content = MCPNoteContent(text: Fixture.noteText)
        var resources: [MCPResourceEntry] = [Fixture.resource]
        var resourceText = Fixture.noteText
        var promptText = Fixture.noteText
        var writeEnabled = false
        var failure: (any Error & Sendable)?
        /// notes_search answers with one hit per query, titled after it (concurrency test).
        var echoQuery = false
    }

    let canned: Canned
    private let recorded = Mutex<[Call]>([])

    init(_ canned: Canned = Canned()) { self.canned = canned }

    var calls: [Call] { recorded.withLock { $0 } }

    private func record(_ call: Call) throws {
        recorded.withLock { $0.append(call) }
        if let failure = canned.failure { throw failure }
    }

    func search(_ r: MCPSearchRequest, caller: MCPCaller) async throws -> [MCPNoteHit] {
        try record(.search(r, caller))
        if canned.echoQuery {
            var hit = Fixture.hit
            hit.title = r.query
            hit.id = "echo-" + r.query
            return [hit]
        }
        return canned.hits
    }

    func list(_ r: MCPListRequest, caller: MCPCaller) async throws -> [MCPNoteHit] {
        try record(.list(r, caller))
        return canned.hits
    }

    func read(_ r: MCPReadRequest, caller: MCPCaller) async throws -> MCPNoteContent {
        try record(.read(r, caller))
        return canned.content
    }

    func append(_ r: MCPAppendRequest, caller: MCPCaller) async throws -> MCPWriteResult {
        try record(.append(r, caller))
        return MCPWriteResult(id: "ai-append-note", uri: "codd://note/ai-append-note",
                              text: "已附加到 codd://note/ai-append-note（### AI 附加 · 10:12）")
    }

    func write(_ r: MCPWriteRequest, caller: MCPCaller) async throws -> MCPWriteResult {
        try record(.write(r, caller))
        return MCPWriteResult(id: "ai-append-note", uri: "codd://note/ai-append-note", text: "")
    }

    func create(_ r: MCPCreateRequest, caller: MCPCaller) async throws -> MCPCreateResult {
        try record(.create(r, caller))
        return MCPCreateResult(id: "ai-report-x7k2", uri: "codd://note/ai-report-x7k2", title: r.title,
                               path: "/tmp/codd-test/notes/2026-10-17-\(r.title).md")
    }

    func resources(caller: MCPCaller) async throws -> [MCPResourceEntry] {
        try record(.resources(caller))
        return canned.resources
    }

    func readResource(uri: String, caller: MCPCaller) async throws -> String {
        try record(.readResource(uri, caller))
        return canned.resourceText
    }

    func promptNote(id: String, caller: MCPCaller) async throws -> String {
        try record(.prompt(id, caller))
        return canned.promptText
    }

    func capabilities(caller: MCPCaller) async -> MCPBackendCapabilities {
        MCPBackendCapabilities(writeEnabled: canned.writeEnabled)
    }
}

/// A thrown error that is not an MCPBackendError.
struct Boom: Error, Sendable {}

/// Made-up design data (the SPEC §5 sample note), never anything from this machine.
enum Fixture {
    static let session = UUID(uuidString: "7C1E9A04-5B3D-4F0E-9A52-3D6C1B2E8F10")!
    static let caller = MCPCaller.session(session)
    static let timeZone = TimeZone(identifier: "Asia/Taipei")!
    /// 2026-10-17 12:00:00 +08:00.
    static let now = Date(timeIntervalSince1970: 1_792_209_600)
    /// 2026-10-15 10:05:44 +08:00.
    static let updated = Date(timeIntervalSince1970: 1_792_029_944)

    static let noteText = """
        # 打卡頁 RWD 跑版紀錄
        codd://note/rwd-punch-k7x2 · NOTE · #rwd #punch · updated 2026-10-15 10:05 · AI READ
        file: /tmp/codd-test/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md

        ## 問題
        iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。
        """

    static let hit = MCPNoteHit(
        id: "rwd-punch-k7x2", uri: "codd://note/rwd-punch-k7x2", title: "打卡頁 RWD 跑版紀錄", kind: "note",
        tags: ["rwd", "punch"], updated: updated, snippet: "iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；\n橫向時表格溢出。",
        path: "/tmp/codd-test/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md", state: "active")

    static let resource = MCPResourceEntry(uri: "codd://note/rwd-punch-k7x2", name: "打卡頁 RWD 跑版紀錄",
                                           lastModified: updated)

    static func server(_ backend: FakeBackend = FakeBackend(), version: String = "0.4.0-test") -> MCPServer {
        MCPServer(info: MCPServerInfo(version: version), backend: backend, clock: { now }, timeZone: timeZone)
    }
}
