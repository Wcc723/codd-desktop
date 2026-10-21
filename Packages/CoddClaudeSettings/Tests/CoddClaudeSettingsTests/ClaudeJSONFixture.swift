import Foundation
@testable import CoddClaudeSettings

/// Made-up `~/.claude.json`-shaped files (nothing is copied from a real machine), laid out like
/// Claude's `JSON.stringify(x, null, 2)`: no trailing newline, two-space indent. They carry what
/// a byte-for-byte edit must survive: CJK keys and values, `1e21`, `-0`, `1.0`, a 20-digit
/// integer, escapes, nested arrays, project-scope `mcpServers`, stdio and http user servers.
enum ClaudeJSONFixture {
    static let ourURL = "http://127.0.0.1:47821/mcp"
    static let token = String(repeating: "a1", count: 32)
    static let oldToken = String(repeating: "c3", count: 32)
    /// Values that must never reach a diff line.
    static let stdioSecret = "made-up-env-secret-7f1e"
    static let httpSecret = "Bearer made-up-header-secret-9b2d"

    static func s(_ v: String) -> OrderedJSON { .string(v) }
    static func n(_ v: String) -> OrderedJSON { .number(v) }
    static func obj(_ members: [(String, OrderedJSON)]) -> OrderedJSON { .object(members.map { (key: $0.0, value: $0.1) }) }

    static var stdioServer: OrderedJSON {
        obj([("type", s("stdio")), ("command", s("/usr/local/bin/pencil-like")), ("args", .array([s("--app"), s("desktop")])),
             ("env", obj([("PENCIL_API_KEY", s(stdioSecret))]))])
    }

    static var httpServer: OrderedJSON {
        obj([("type", s("http")), ("url", s("https://stitch-like.example.invalid/mcp")),
             ("headers", obj([("Authorization", s(httpSecret))]))])
    }

    static var defaultServers: [(String, OrderedJSON)] { [("pencil-like", stdioServer), ("stitch-like", httpServer)] }

    static func ours(token: String = token, url: String = ourURL) -> OrderedJSON {
        obj([("type", s("http")), ("url", s(url)), ("headers", obj([("X-CODD-Token", s(token))]))])
    }

    static func project(_ i: Int) -> OrderedJSON {
        var members: [(String, OrderedJSON)] = [
            ("allowedTools", .array([])),
            ("mcpContextUris", .array([])),
            ("mcpServers", i % 10 == 0 ? obj([("local-\(i)", obj([("type", s("stdio")), ("command", s("node")),
                                                                     ("args", .array([s("server.js")]))]))]) : obj([])),
            ("enabledMcpjsonServers", .array([])),
            ("hasTrustDialogAccepted", .bool(i % 3 != 0)),
            ("projectOnboardingSeenCount", n("\(i % 5)")),
            ("lastCost", n("1.0")),
            ("lastAPIDuration", n("12345678901234567890")),
            ("lastTotalInputTokens", n("1e21")),
            ("lastLinesRemoved", n("-0")),
            ("描述", s("打卡頁 RWD 調整與注音輸入法測試 #\(i)")),
            ("exampleFiles", .array([s("src/頁面/punch-\(i).vue"), s("README.md")])),
            ("nested", .array([.array([n("1"), .array([n("2"), .array([n("3"), .array([])])])]),
                               obj([("深", obj([("層", .array([.bool(true), .bool(false), .null]))]))])])),
            ("escaped", s("tab\there \"quoted\" \\ back /slash \u{01} 換行\n結束")),
        ]
        if i % 7 == 0 { members.append(("lastSessionId", s("00000000-0000-4000-8000-\(String(format: "%012d", i))"))) }
        return obj(members)
    }

    /// The root: members before `mcpServers` (with `projects` grown to about `projectBytes`),
    /// `mcpServers` (left out when `servers` is nil), members after it.
    static func root(servers: [(String, OrderedJSON)]? = defaultServers, projectBytes: Int = 4_000) -> OrderedJSON {
        var projects: [(String, OrderedJSON)] = []
        var size = 0
        var i = 0
        while size < projectBytes || projects.isEmpty {
            let value = project(i)
            size += value.serialized(indent: "  ").utf8.count + 48
            projects.append(("/Users/fixture/Projects/專案-\(String(format: "%05d", i))", value))
            i += 1
        }
        var members: [(String, OrderedJSON)] = [
            ("numStartups", n("412")),
            ("installMethod", s("native")),
            ("autoUpdates", .bool(true)),
            ("tipsHistory", obj([("new-user-warmup", n("7")), ("memory-command", n("31"))])),
            ("projects", obj(projects)),
        ]
        if let servers { members.append(("mcpServers", obj(servers))) }
        members += [
            ("userID", s("0f3c9b6e2d1a4c5b8e7f6a5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b")),
            ("oauthAccount", obj([("accountUuid", s("11111111-2222-4333-8444-555555555555")),
                                  ("emailAddress", s("fixture@example.invalid")), ("organizationName", s("範例組織"))])),
            ("cachedStatsigGates", obj([("tengu_example_gate", .bool(true))])),
            ("lastReleaseNotesSeen", s("2.1.302")),
        ]
        return obj(members)
    }

    static func text(servers: [(String, OrderedJSON)]? = defaultServers, projectBytes: Int = 4_000) -> String {
        root(servers: servers, projectBytes: projectBytes).serialized(indent: "  ")
    }

    /// About 2 MB, generated once per test run.
    static let large: Data = Data(text(projectBytes: 2_000_000).utf8)

    /// The file without its top-level `mcpServers` member (and the separator before it): what
    /// must stay byte-identical across a registration.
    static func outsideMember(_ data: Data) -> Data {
        data.withUnsafeBytes { raw -> Data in
            let b = raw.bindMemory(to: UInt8.self)
            guard let root = JSONSpans.object(b, at: JSONSpans.skipWhitespace(b, 0)) else { return data }
            guard root.members.contains(where: { $0.key == "mcpServers" }) else { return data }
            var out = Data(UnsafeBufferPointer(rebasing: b[0..<root.start]))
            out.append(contentsOf: JSONObjectEdit.removing(b, object: root) { root.members[$0].key != "mcpServers" })
            out.append(UnsafeBufferPointer(rebasing: b[root.end..<b.count]))
            return out
        }
    }

    /// The parsed top-level `mcpServers`.
    static func servers(_ data: Data) throws -> OrderedJSON? {
        try OrderedJSON.parse(data)["mcpServers"]
    }
}
