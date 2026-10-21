import CoddCore
import Foundation
import Testing
@testable import CoddHooks

let testMCPToken = String(repeating: "cd", count: 32)

@Suite("M4 MCP auth tokens")
struct MCPAuthTests {
    let session = UUID(uuidString: "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")!

    /// Vectors computed independently (Python `hmac.new(key, msg, sha256)`).
    @Test func knownAnswers() {
        #expect(MCPAuth.sessionToken(hookToken: testToken, sessionID: session)
            == "c5d2af6c186256766294aa48eb45798cc18a2784f9e3ef7d31e49a5c82b2cd5c")
        // The uuid is lowercased before hashing, whatever spelling the UUID came from.
        #expect(MCPAuth.sessionToken(hookToken: testToken, sessionID: UUID(uuidString: session.uuidString.uppercased())!)
            == MCPAuth.sessionToken(hookToken: testToken, sessionID: session))
        #expect(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "rwd-punch-k7x2") == "52dfa49b63257cb76c461cba")
        #expect(MCPAuth.sessionToken(hookToken: "", sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
            == "81cd8eb9948bd1eebb25358e3730a8a19d81aefd1533d343624ceda59d3c9bd0")
    }

    @Test func tokensDifferPerSessionAndNoteAndKey() {
        let other = UUID()
        #expect(MCPAuth.sessionToken(hookToken: testToken, sessionID: session) != MCPAuth.sessionToken(hookToken: testToken, sessionID: other))
        #expect(MCPAuth.sessionToken(hookToken: testToken, sessionID: session)
            != MCPAuth.sessionToken(hookToken: testMCPToken, sessionID: session))
        #expect(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "a") != MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "b"))
        #expect(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "a").count == 24)
    }

    @Test func makeTokenAndChecks() {
        let a = MCPAuth.makeToken(), b = MCPAuth.makeToken()
        #expect(a != b && HookConfig.isValidToken(a) && HookConfig.isValidToken(b))
        let t = MCPAuth.sessionToken(hookToken: testToken, sessionID: session)
        #expect(MCPAuth.isValidSessionToken(t, hookToken: testToken, sessionID: session))
        #expect(!MCPAuth.isValidSessionToken(t.uppercased(), hookToken: testToken, sessionID: session))
        #expect(!MCPAuth.isValidSessionToken(String(t.dropLast()), hookToken: testToken, sessionID: session))
        let n = MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "x")
        #expect(MCPAuth.isValidNoteURLToken(n, mcpToken: testMCPToken, noteID: "x"))
        #expect(!MCPAuth.isValidNoteURLToken(n, mcpToken: nil, noteID: "x"))
        #expect(!MCPAuth.isValidNoteURLToken(n, mcpToken: "", noteID: "x"))
        #expect(!MCPAuth.isValidNoteURLToken(n, mcpToken: testMCPToken, noteID: "y"))
    }

    @Test func promptAnswerJSON() throws {
        let with = PromptHookAnswer(additionalContext: "<codd-note id=\"a\">\n# 打卡頁 RWD\n</codd-note>",
                                    systemMessage: "codd：已展開 codd://note/a（打卡頁 RWD · 2 張圖片）")
        let text = String(decoding: with.jsonBody(), as: UTF8.self)
        #expect(text.hasPrefix("{"))
        #expect(text.contains("codd://note/a")) // slashes unescaped
        #expect(text == #"{"hookSpecificOutput":{"additionalContext":"<codd-note id=\"a\">\n# 打卡頁 RWD\n</codd-note>","hookEventName":"UserPromptSubmit"},"systemMessage":"codd：已展開 codd://note/a（打卡頁 RWD · 2 張圖片）"}"#)
        let without = String(decoding: PromptHookAnswer(additionalContext: "ctx").jsonBody(), as: UTF8.self)
        #expect(without == #"{"hookSpecificOutput":{"additionalContext":"ctx","hookEventName":"UserPromptSubmit"}}"#)
        let parsed = try #require(JSONValue.parse(Data(with.jsonBody())))
        #expect(parsed["hookSpecificOutput"]?["hookEventName"] == "UserPromptSubmit")
    }
}

@Suite("M4 request policy: /mcp, /hooks/prompt, /n/")
struct M4PolicyTests {
    let policy = HookRequestPolicy(token: testToken, port: 47821, mcpToken: testMCPToken)
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"
    var uuid: UUID { UUID(uuidString: sid)! }
    var sessionToken: String { MCPAuth.sessionToken(hookToken: testToken, sessionID: uuid) }
    let host = ("Host", "127.0.0.1:47821")

    func head(_ method: String = "POST", _ target: String = "/mcp", _ fields: [(String, String)],
              framing: HTTPBodyFraming = .length(2)) -> HTTPRequestHead {
        HTTPRequestHead(method: method, target: target, version: .http11,
                        headers: HTTPHeaders(fields.map { HTTPField(name: $0.0, value: $0.1) }), framing: framing)
    }

    // MARK: /mcp

    enum Auth: CaseIterable {
        case sessionRight, sessionWrong, sessionOtherUUID, sessionWithExternalToken, sessionNotUUID, sessionRepeated
        case externalHeader, externalBearer, externalBearerLowercase, externalBoth, externalBothDiffer
        case externalBasic, hookTokenAsExternal, missing, sessionHeaderOnly
    }

    func fields(_ auth: Auth) -> [(String, String)] {
        let other = MCPAuth.sessionToken(hookToken: testToken, sessionID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
        switch auth {
        case .sessionRight: return [("X-CODD-Session", sid), ("X-CODD-Token", sessionToken)]
        case .sessionWrong: return [("X-CODD-Session", sid), ("X-CODD-Token", String(repeating: "0", count: 64))]
        case .sessionOtherUUID: return [("X-CODD-Session", sid), ("X-CODD-Token", other)]
        case .sessionWithExternalToken: return [("X-CODD-Session", sid), ("X-CODD-Token", testMCPToken)]
        case .sessionNotUUID: return [("X-CODD-Session", "nope"), ("X-CODD-Token", sessionToken)]
        case .sessionRepeated: return [("X-CODD-Session", sid), ("X-CODD-Session", sid), ("X-CODD-Token", sessionToken)]
        case .externalHeader: return [("X-CODD-Token", testMCPToken)]
        case .externalBearer: return [("Authorization", "Bearer \(testMCPToken)")]
        case .externalBearerLowercase: return [("authorization", "bearer  \(testMCPToken) ")]
        case .externalBoth: return [("X-CODD-Token", testMCPToken), ("Authorization", "Bearer \(testMCPToken)")]
        case .externalBothDiffer: return [("X-CODD-Token", testMCPToken), ("Authorization", "Bearer \(testToken)")]
        case .externalBasic: return [("Authorization", "Basic \(testMCPToken)")]
        case .hookTokenAsExternal: return [("X-CODD-Token", testToken)]
        case .missing: return []
        case .sessionHeaderOnly: return [("X-CODD-Session", sid)]
        }
    }

    func expected(_ auth: Auth) -> HookRoute {
        switch auth {
        case .sessionRight: return .mcp(caller: .session(uuid))
        case .externalHeader, .externalBearer, .externalBearerLowercase, .externalBoth: return .mcp(caller: .external)
        default: return .reject(.unauthorized)
        }
    }

    @Test(arguments: Auth.allCases)
    func mcpAuthKinds(_ auth: Auth) {
        #expect(policy.route(head("POST", "/mcp", [host] + fields(auth))) == expected(auth), "\(auth)")
        // Never a fallback: the same headers without an MCP token configured.
        let noExternal = HookRequestPolicy(token: testToken, port: 47821)
        let r = noExternal.route(head("POST", "/mcp", [host] + fields(auth)))
        #expect(r == (auth == .sessionRight ? .mcp(caller: .session(uuid)) : .reject(.unauthorized)), "\(auth)")
    }

    @Test(arguments: [
        ("http://127.0.0.1:47821", true), ("http://localhost:47821", true), ("HTTP://LOCALHOST:47821", true),
        ("http://evil.example", false), ("null", false), ("", false), ("http://127.0.0.1:47822", false),
        ("https://127.0.0.1:47821", false), ("http://127.0.0.1:47821/", false), ("http://127.0.0.1", false),
    ])
    func mcpOrigins(_ origin: String, _ allowed: Bool) {
        let r = policy.route(head("POST", "/mcp", [host, ("Origin", origin)] + fields(.externalHeader)))
        #expect(r == (allowed ? .mcp(caller: .external) : .reject(.forbidden)), "\(origin)")
    }

    @Test func mcpOriginRepeatedAndHosts() {
        let twice = [host, ("Origin", "http://127.0.0.1:47821"), ("Origin", "http://127.0.0.1:47821")] + fields(.externalHeader)
        #expect(policy.route(head("POST", "/mcp", twice)) == .reject(.forbidden))
        for bad in ["evil.example:47821", "127.0.0.1", "127.0.0.1:1", "[::1]:47821"] {
            #expect(policy.route(head("POST", "/mcp", [("Host", bad)] + fields(.sessionRight))) == .reject(.forbidden), "\(bad)")
        }
        #expect(policy.route(head("POST", "/mcp", fields(.sessionRight))) == .reject(.forbidden)) // no Host
        #expect(policy.route(head("POST", "/mcp", [("Host", "LOCALHOST:47821")] + fields(.sessionRight))) == .mcp(caller: .session(uuid)))
    }

    @Test func mcpMethodsFramingAndQuery() {
        for method in ["GET", "DELETE", "PUT", "HEAD"] {
            #expect(policy.route(head(method, "/mcp", [host] + fields(.sessionRight), framing: .none)) == .reject(.methodNotAllowed))
        }
        // The method is checked before auth: an unauthenticated GET is 405 too (what Claude's
        // transport probes for a server stream).
        #expect(policy.route(head("GET", "/mcp", [host], framing: .none)) == .reject(.methodNotAllowed))
        #expect(HookRequestPolicy.allowedMethods(for: "/mcp") == "POST")
        #expect(policy.route(head("POST", "/mcp", [host] + fields(.sessionRight), framing: .none)) == .reject(.lengthRequired))
        // Auth comes before the length.
        #expect(policy.route(head("POST", "/mcp", [host], framing: .none)) == .reject(.unauthorized))
        #expect(policy.route(head("POST", "/mcp", [host] + fields(.sessionRight), framing: .chunked)) == .mcp(caller: .session(uuid)))
        #expect(policy.route(head("POST", "/mcp?x=1", [host] + fields(.externalHeader))) == .mcp(caller: .external))
        #expect(policy.route(head("POST", "/mcp/", [host] + fields(.externalHeader))) == .reject(.notFound))
    }

    @Test func mcpRejectionReasonsNeverQuoteATokenOrSecret() {
        let cases: [([(String, String)], String)] = [
            (fields(.sessionWrong), "wrong MCP session token"),
            (fields(.sessionNotUUID), "X-CODD-Session not a UUID"),
            (fields(.sessionRepeated), "X-CODD-Session repeated"),
            (fields(.sessionHeaderOnly), "MCP session token missing"),
            (fields(.hookTokenAsExternal), "wrong MCP token"),
            (fields(.externalBasic), "Authorization is not a Bearer token"),
            (fields(.missing), "MCP token missing"),
            ([("X-CODD-Token", "a"), ("X-CODD-Token", "b")], "token header repeated"),
        ]
        for (f, reason) in cases {
            let h = head("POST", "/mcp", [host] + f)
            #expect(policy.route(h) == .reject(.unauthorized))
            let text = policy.rejectionReason(.unauthorized, h)
            #expect(text == reason)
            #expect(!text.contains(testToken) && !text.contains(testMCPToken) && !text.contains(sessionToken))
        }
        #expect(HookRequestPolicy(token: testToken, port: 47821).rejectionReason(.unauthorized, head("POST", "/mcp", [host] + fields(.externalHeader)))
            == "external MCP token not set")
        #expect(policy.rejectionReason(.forbidden, head("POST", "/mcp", [host, ("Origin", "http://evil.example")]))
            == #"Origin not allowed ("http://evil.example")"#)
        #expect(policy.rejectionReason(.forbidden, head("POST", "/mcp", [("Host", "x:1")])) == #"Host not allowed ("x:1")"#)
    }

    // MARK: /hooks/prompt

    var hookFields: [(String, String)] { [host, ("X-CODD-Token", testToken), ("X-CODD-Session", sid)] }

    @Test func promptRouteIsExactlyTheHooksAuth() {
        #expect(policy.route(head("POST", "/hooks/prompt", hookFields)) == .promptHook(sessionID: uuid))
        #expect(policy.route(head("POST", "/hooks/prompt?x=1", hookFields)) == .promptHook(sessionID: uuid))
        #expect(policy.route(head("POST", "/hooks/prompt", hookFields + [("Origin", "http://127.0.0.1:47821")])) == .reject(.forbidden))
        #expect(policy.route(head("POST", "/hooks/prompt", [("Host", "evil:47821")] + hookFields.dropFirst())) == .reject(.forbidden))
        #expect(policy.route(head("GET", "/hooks/prompt", hookFields, framing: .none)) == .reject(.methodNotAllowed))
        #expect(HookRequestPolicy.allowedMethods(for: "/hooks/prompt") == "POST")
        #expect(policy.route(head("POST", "/hooks/prompt", [host, ("X-CODD-Session", sid)])) == .reject(.unauthorized))
        // The MCP tokens are not hook tokens.
        #expect(policy.route(head("POST", "/hooks/prompt", [host, ("X-CODD-Token", testMCPToken), ("X-CODD-Session", sid)]))
            == .reject(.unauthorized))
        #expect(policy.route(head("POST", "/hooks/prompt", [host, ("X-CODD-Token", testToken)])) == .reject(.badRequest))
        #expect(policy.route(head("POST", "/hooks/prompt", hookFields, framing: .none)) == .reject(.lengthRequired))
        #expect(policy.route(head("POST", "/hooks/prompt/", hookFields)) == .reject(.notFound))
    }

    @Test func existingRoutesWithAQueryAreUnchanged() {
        // M1–M3 behaviour: the query is ignored on /hooks, /statusline and /health.
        #expect(policy.route(head("POST", "/hooks?x=1", hookFields)) == .hook(sessionID: uuid))
        #expect(policy.route(head("POST", "/statusline?t=1", [host, ("X-CODD-Token", testToken)])) == .statusLine(sessionID: nil))
        #expect(policy.route(head("GET", "/health?x", [host], framing: .none)) == .health(headOnly: false))
        // Origin is still refused there, even an allowed MCP origin.
        #expect(policy.route(head("POST", "/hooks", hookFields + [("Origin", "http://127.0.0.1:47821")])) == .reject(.forbidden))
        #expect(policy.route(head("GET", "/health", [host, ("Origin", "http://127.0.0.1:47821")], framing: .none)) == .reject(.forbidden))
        // MCP tokens do not open /hooks.
        #expect(policy.route(head("POST", "/hooks", [host, ("X-CODD-Token", testMCPToken), ("X-CODD-Session", sid)])) == .reject(.unauthorized))
        #expect(policy.route(head("POST", "/hooks", [host, ("X-CODD-Token", sessionToken), ("X-CODD-Session", sid)])) == .reject(.unauthorized))
    }

    // MARK: /n/

    func noteToken(_ id: String) -> String { MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: id) }

    @Test func noteURLs() {
        let id = "rwd-punch-k7x2"
        let t = noteToken(id)
        #expect(policy.route(head("GET", "/n/\(id).md?t=\(t)", [host], framing: .none)) == .noteURL(id: id, token: t))
        #expect(policy.route(head("GET", "/n/\(id).md?x=1&t=\(t)", [("Host", "localhost:47821")], framing: .none)) == .noteURL(id: id, token: t))
        // Wrong, missing, repeated, another note's token, no MCP token: 404 like an unknown note.
        for target in ["/n/\(id).md?t=\(noteToken("other"))", "/n/\(id).md", "/n/\(id).md?t=", "/n/\(id).md?t=\(t)&t=\(t)",
                       "/n/\(id).md?T=\(t)", "/n/\(id).md?t=\(t.uppercased())"] {
            #expect(policy.route(head("GET", target, [host], framing: .none)) == .reject(.notFound), "\(target)")
        }
        #expect(HookRequestPolicy(token: testToken, port: 47821).route(head("GET", "/n/\(id).md?t=\(t)", [host], framing: .none))
            == .reject(.notFound))
        // Host rule as /hooks, and no Origin at all.
        #expect(policy.route(head("GET", "/n/\(id).md?t=\(t)", [("Host", "evil.example:47821")], framing: .none)) == .reject(.forbidden))
        #expect(policy.route(head("GET", "/n/\(id).md?t=\(t)", [("Host", "127.0.0.1")], framing: .none)) == .reject(.forbidden))
        #expect(policy.route(head("GET", "/n/\(id).md?t=\(t)", [host, ("Origin", "http://127.0.0.1:47821")], framing: .none))
            == .reject(.forbidden))
        #expect(policy.route(head("POST", "/n/\(id).md?t=\(t)", [host])) == .reject(.methodNotAllowed))
        #expect(HookRequestPolicy.allowedMethods(for: "/n/\(id).md") == "GET")
        #expect(policy.rejectionReason(.notFound, head("GET", "/n/\(id).md?t=bad", [host], framing: .none))
            == "note URL token wrong or MCP token not set")
        #expect(policy.rejectionReason(.notFound, head("GET", "/n/\(id).md", [host], framing: .none)) == "note URL token missing")
    }

    @Test(arguments: ["/n/Bad.md", "/n/a--b.md", "/n/-a.md", "/n/a-.md", "/n/.md", "/n/a.md.md", "/n/a/b.md", "/n/a%2Db.md",
                      "/n/" + String(repeating: "a", count: 49) + ".md", "/n/a.txt", "/n/a", "/n/日記.md"])
    func noteURLShapes(_ path: String) {
        let t = noteToken(String(path.dropFirst(3).dropLast(3)))
        #expect(policy.route(head("GET", "\(path)?t=\(t)", [host], framing: .none)) == .reject(.notFound), "\(path)")
        #expect(HookRequestPolicy.noteID(fromPath: path) == nil)
    }

    @Test func noteIDsAndURLs() {
        #expect(HookRequestPolicy.noteID(fromPath: "/n/rwd-punch-k7x2.md") == "rwd-punch-k7x2")
        #expect(HookRequestPolicy.noteID(fromPath: "/n/note-dup2.md") == "note-dup2")
        #expect(HookRequestPolicy.isValidNoteID(String(repeating: "a", count: 48)))
        #expect(HookRequestPolicy.noteURL(port: 47821, noteID: "rwd-punch-k7x2", mcpToken: testMCPToken)
            == "http://127.0.0.1:47821/n/rwd-punch-k7x2.md?t=52dfa49b63257cb76c461cba")
    }

    @Test func queryParsing() {
        let items = HookRequestPolicy.queryItems("/x?a=1&b=%E6%89%93+%E5%8D%A1&&c&=v&a=2&d=%zz")
        #expect(items.map { $0.name } == ["a", "b", "c", "a", "d"])
        #expect(items.map { $0.value } == ["1", "打 卡", "", "2", "%zz"])
        #expect(HookRequestPolicy.query("/x?a=1&a=2") == ["a": "1"])
        #expect(HookRequestPolicy.queryItems("/x").isEmpty)
        #expect(HookRequestPolicy.queryItems("/x?").isEmpty)
    }
}
