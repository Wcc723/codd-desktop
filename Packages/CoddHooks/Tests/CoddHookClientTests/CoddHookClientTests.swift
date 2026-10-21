import Testing
@testable import CoddHookClient

@Suite("Loopback URL")
struct LoopbackURLTests {
    @Test func accepted() throws {
        let a = try #require(LoopbackURL("http://127.0.0.1:47821/hooks"))
        #expect(a == LoopbackURL(authority: "127.0.0.1:47821", port: 47821, target: "/hooks"))
        let b = try #require(LoopbackURL("HTTP://LocalHost:8080"))
        #expect(b == LoopbackURL(authority: "localhost:8080", port: 8080, target: "/"))
        let c = try #require(LoopbackURL("http://localhost/x?y=1#frag"))
        #expect(c == LoopbackURL(authority: "localhost", port: 80, target: "/x?y=1"))
        let d = try #require(LoopbackURL("http://127.0.0.1:1?q"))
        #expect(d.target == "/?q")
    }

    @Test(arguments: [
        "", "http://", "https://127.0.0.1:47821/hooks", "http://example.com/hooks", "http://127.0.0.2:1/",
        "http://[::1]:47821/", "http://user@127.0.0.1:47821/", "http://127.0.0.1:/", "http://127.0.0.1:0/",
        "http://127.0.0.1:65536/", "http://127.0.0.1:12a/", "http://127.0.0.1.evil.example/", "http://localhost.:1/",
        "http://127.0.0.1:1/a b", "ftp://127.0.0.1/", "127.0.0.1:47821/hooks", "http://0.0.0.0:1/",
    ])
    func refused(_ s: String) {
        #expect(LoopbackURL(s) == nil)
    }
}

@Suite("codd-hook command")
struct HookCommandTests {
    let env: [String: String] = [
        "CODD_HOOK_TOKEN": String(repeating: "ab", count: 32),
        "CODD_SESSION_ID": "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
    ]

    func lookup(_ e: [String: String]) -> (String) -> String? { { e[$0] } }

    @Test func argumentParsing() {
        let a = HookCommand(arguments: ["codd-hook", "session-start", "--url", "http://127.0.0.1:1/hooks"], environment: lookup([:]))
        #expect(a == HookCommand(eventHint: "session-start", url: "http://127.0.0.1:1/hooks"))
        let b = HookCommand(arguments: ["codd-hook", "--verbose", "--url=http://localhost:2/", "setup", "extra"], environment: lookup([:]))
        #expect(b == HookCommand(eventHint: "setup", url: "http://localhost:2/"))
        let c = HookCommand(arguments: ["codd-hook"], environment: lookup(["CODD_HOOK_URL": "http://127.0.0.1:3/hooks"]))
        #expect(c == HookCommand(eventHint: nil, url: "http://127.0.0.1:3/hooks"))
        let d = HookCommand(arguments: ["codd-hook", "x", "--url"], environment: lookup(["CODD_HOOK_URL": "http://127.0.0.1:3/"]))
        #expect(d.url == "http://127.0.0.1:3/") // a dangling --url falls back to the environment
    }

    @Test func requestBytes() throws {
        let command = HookCommand(eventHint: "session-start", url: "http://127.0.0.1:47821/hooks")
        let (url, bytes) = try command.request(environment: lookup(env), body: .bytes(Array("{}".utf8))).get()
        #expect(url.port == 47821)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text == "POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nContent-Type: application/json\r\n"
            + "X-CODD-Token: \(env["CODD_HOOK_TOKEN"]!)\r\nX-CODD-Session: \(env["CODD_SESSION_ID"]!)\r\n"
            + "Content-Length: 2\r\nConnection: close\r\nUser-Agent: codd-hook/1\r\n\r\n{}")
    }

    @Test func skips() {
        let ok = HookCommand(eventHint: nil, url: "http://127.0.0.1:1/hooks")
        func skip(_ c: HookCommand, _ e: [String: String], _ body: StdinBody = .bytes([0x7B, 0x7D])) -> HookCommand.Skip? {
            if case .failure(let s) = c.request(environment: lookup(e), body: body) { return s }
            return nil
        }
        #expect(skip(HookCommand(eventHint: nil, url: nil), env) == .missingURL)
        #expect(skip(HookCommand(eventHint: nil, url: "http://example.com/"), env) == .notLoopbackURL)
        #expect(skip(ok, [:]) == .missingToken)
        #expect(skip(ok, ["CODD_HOOK_TOKEN": "a\r\nX: y", "CODD_SESSION_ID": "s"]) == .missingToken)
        #expect(skip(ok, ["CODD_HOOK_TOKEN": "t"]) == .missingSession)
        #expect(skip(ok, ["CODD_HOOK_TOKEN": "t", "CODD_SESSION_ID": "s\n"]) == .missingSession)
        #expect(skip(ok, env, .bytes([])) == .emptyBody)
        #expect(skip(ok, env, .tooLarge) == .bodyTooLarge)
        #expect(skip(ok, env, .timedOut) == .stdinTimedOut)
        #expect(skip(ok, env) == nil)
    }
}

@Suite("Response scanner")
struct ResponseScannerTests {
    func scan(_ s: String, eof: Bool = false, isHead: Bool = false) -> ResponseScanner.Result {
        ResponseScanner.scan(Array(s.utf8), eof: eof, isHead: isHead)
    }

    @Test func responses() {
        #expect(scan("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") == .complete(.init(status: 204, body: [])))
        #expect(scan("HTTP/1.1 204 No Content\r\n") == .needMore)
        #expect(scan("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n") == .complete(.init(status: 204, body: [])))
        #expect(scan("HTTP/1.1 100 Continue\r\n\r\n") == .needMore)
        #expect(scan("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab") == .needMore)
        #expect(scan("HTTP/1.1 200 OK\r\ncontent-length: 4\r\n\r\nabcdEXTRA") == .complete(.init(status: 200, body: Array("abcd".utf8))))
        #expect(scan("HTTP/1.1 200 OK\r\n\r\nto-eof", eof: false) == .needMore)
        #expect(scan("HTTP/1.1 200 OK\r\n\r\nto-eof", eof: true) == .complete(.init(status: 200, body: Array("to-eof".utf8))))
        #expect(scan("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", isHead: true) == .complete(.init(status: 200, body: [])))
        #expect(scan("SSH-2.0-OpenSSH\r\n\r\n") == .malformed)
        // Bare LF heads; without a length the body runs to EOF.
        #expect(scan("HTTP/1.0 401 Unauthorized\n\n") == .needMore)
        #expect(scan("HTTP/1.0 401 Unauthorized\n\n", eof: true) == .complete(.init(status: 401, body: [])))
    }

    @Test func deadline() {
        let d = MonotonicDeadline.after(milliseconds: 50)
        #expect(!d.hasPassed)
        #expect(d.pollTimeout > 0 && d.pollTimeout <= 50)
        let past = MonotonicDeadline(nanoseconds: 0)
        #expect(past.hasPassed)
        #expect(past.pollTimeout == 0)
    }
}
