import Testing
@testable import CoddHooks

@Suite("HTTP request parser")
struct HTTPParserTests {
    /// Feeds `chunks` one by one; returns the events, or the error status.
    func parse(_ chunks: [[UInt8]], limits: HTTPRequestParser.Limits = .init()) -> Result<[HTTPRequestParser.Event], HTTPParseError> {
        var parser = HTTPRequestParser(limits: limits)
        var events: [HTTPRequestParser.Event] = []
        do {
            for chunk in chunks {
                parser.append(chunk)
                while let e = try parser.next() { events.append(e) }
            }
        } catch {
            return .failure(error)
        }
        return .success(events)
    }

    func parse(_ text: String, limits: HTTPRequestParser.Limits = .init()) -> Result<[HTTPRequestParser.Event], HTTPParseError> {
        parse([Array(text.utf8)], limits: limits)
    }

    func status(_ text: String, limits: HTTPRequestParser.Limits = .init()) -> HTTPStatus? {
        if case .failure(let e) = parse(text, limits: limits) { return e.status }
        return nil
    }

    func head(_ events: [HTTPRequestParser.Event]) -> HTTPRequestHead? {
        for e in events { if case .head(let h) = e { return h } }
        return nil
    }

    func body(_ events: [HTTPRequestParser.Event]) -> [UInt8]? {
        for e in events { if case .body(let b) = e { return b } }
        return nil
    }

    let simple = "POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nX-CODD-Token: t\r\nContent-Length: 11\r\n\r\nhello world"

    @Test func simplePost() throws {
        let events = try parse(simple).get()
        #expect(events.count == 2)
        let h = try #require(head(events))
        #expect(h.method == "POST")
        #expect(h.target == "/hooks")
        #expect(h.path == "/hooks")
        #expect(h.version == .http11)
        #expect(h.framing == .length(11))
        #expect(h.headers.single("host") == "127.0.0.1:47821")
        #expect(h.headers.single("x-codd-token") == "t")
        #expect(body(events) == Array("hello world".utf8))
    }

    @Test func everySplitPointGivesTheSameResult() throws {
        let bytes = Array(simple.utf8)
        let expected = try parse(simple).get()
        for i in 1..<bytes.count {
            #expect(try parse([Array(bytes[..<i]), Array(bytes[i...])]).get() == expected, "split at \(i)")
        }
        // Byte by byte.
        #expect(try parse(bytes.map { [$0] }).get() == expected)
    }

    @Test func headIsReportedBeforeTheBodyArrives() throws {
        var parser = HTTPRequestParser()
        parser.append(Array("POST /hooks HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8))
        guard case .head(let h)? = try parser.next() else { Issue.record("no head"); return }
        #expect(h.framing == .length(4))
        #expect(try parser.next() == nil)
        parser.append(Array("cd".utf8))
        #expect(try parser.next() == .body(Array("abcd".utf8)))
        #expect(parser.isComplete)
    }

    @Test func oversizedContentLengthIsRejectedBeforeTheBody() {
        #expect(status("POST /hooks HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n") == .payloadTooLarge)
        // Exactly the limit is fine.
        #expect(status("POST /hooks HTTP/1.1\r\nContent-Length: 1048576\r\n\r\n") == nil)
        #expect(status("POST /hooks HTTP/1.1\r\nContent-Length: 99999999999999\r\n\r\n") == .payloadTooLarge)
    }

    @Test func oversizedHead() {
        let big = "GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 17 * 1024) + "\r\n\r\n"
        #expect(status(big) == .headerFieldsTooLarge)
        // Without a terminator the limit still applies (slow-loris with endless headers).
        #expect(status("GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 17 * 1024)) == .headerFieldsTooLarge)
        let many = "GET / HTTP/1.1\r\n" + (0..<101).map { "X-\($0): v\r\n" }.joined() + "\r\n"
        #expect(status(many) == .headerFieldsTooLarge)
    }

    @Test(arguments: [
        "abc", "-1", "+5", "0x10", "1, 2", "", "1.5", "１２",
    ])
    func badContentLength(_ value: String) {
        #expect(status("POST /hooks HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n") == .badRequest)
    }

    @Test func contentLengthEdgeCases() throws {
        // Conflicting duplicates are rejected; identical ones are one value.
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc") == .badRequest)
        #expect(head(try parse("POST / HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc").get())?.framing == .length(3))
        #expect(head(try parse("POST / HTTP/1.1\r\nContent-Length: 3, 3\r\n\r\nabc").get())?.framing == .length(3))
        #expect(head(try parse("POST / HTTP/1.1\r\nContent-Length:   3  \r\n\r\nabc").get())?.framing == .length(3))
        // Both framings at once is the request-smuggling shape.
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n") == .badRequest)
        // No length at all: no body (the policy answers 411 for POST /hooks).
        #expect(head(try parse("POST / HTTP/1.1\r\nHost: x\r\n\r\n").get())?.framing == HTTPBodyFraming.none)
    }

    @Test func chunkedBody() throws {
        let text = "POST /hooks HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: v\r\n\r\n"
        let events = try parse(text).get()
        #expect(head(events)?.framing == .chunked)
        #expect(body(events) == Array("hello world".utf8))
        let bytes = Array(text.utf8)
        #expect(try parse(bytes.map { [$0] }).get() == events)
        // Uppercase hex, bare LF line ends.
        #expect(body(try parse("POST / HTTP/1.1\nTransfer-Encoding: Chunked\n\nA\n0123456789\n0\n\n").get()) == Array("0123456789".utf8))
    }

    @Test func chunkedErrors() {
        let h = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(status(h + "zz\r\n") == .badRequest)
        #expect(status(h + "3\r\nabcd\r\n") == .badRequest) // data longer than the size
        #expect(status(h + "123456789\r\n") == .badRequest) // > 8 hex digits
        #expect(status(h + "100001\r\n") == .payloadTooLarge)
        #expect(status("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n") == .notImplemented)
        #expect(status("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n") == .badRequest)
        let limits = HTTPRequestParser.Limits(maxBodyBytes: 8)
        #expect(status(h + "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n", limits: limits) == .payloadTooLarge)
    }

    @Test func pipelinedSecondRequestIsIgnored() throws {
        var parser = HTTPRequestParser()
        parser.append(Array((simple + "POST /hooks HTTP/1.1\r\nContent-Length: 2\r\n\r\nxx").utf8))
        var events: [HTTPRequestParser.Event] = []
        while let e = try parser.next() { events.append(e) }
        #expect(events.count == 2)
        #expect(body(events) == Array("hello world".utf8))
        #expect(parser.isComplete)
        #expect(parser.trailingByteCount > 0)
        parser.append(Array("more".utf8))
        #expect(try parser.next() == nil)
    }

    @Test func requestLineErrors() {
        #expect(status("GARBAGE\r\n\r\n") == .badRequest)
        #expect(status("GET  / HTTP/1.1\r\n\r\n") == .badRequest) // double space
        #expect(status("GET / HTTP/2.0\r\n\r\n") == .versionNotSupported)
        #expect(status("GET / HTTX/1.1\r\n\r\n") == .badRequest)
        #expect(status("G(T / HTTP/1.1\r\n\r\n") == .badRequest)
    }

    @Test func headerSyntax() throws {
        #expect(status("GET / HTTP/1.1\r\nHost: a\r\n  folded\r\n\r\n") == .badRequest) // obs-fold
        #expect(status("GET / HTTP/1.1\r\nHost : a\r\n\r\n") == .badRequest) // space before colon
        #expect(status("GET / HTTP/1.1\r\nNoColon\r\n\r\n") == .badRequest)
        #expect(status("GET / HTTP/1.1\r\nX: a\u{01}b\r\n\r\n") == .badRequest)
        #expect(status("GET / HTTP/1.1\r\nX: a\rb\r\n\r\n") == .badRequest) // bare CR
        // Bare LF, leading empty lines and HTTP/1.0 are accepted.
        let h = try #require(head(try parse("\r\n\nGET /health HTTP/1.0\nHost: h\n\n").get()))
        #expect(h.version == .http10)
        #expect(h.headers.single("HOST") == "h")
    }

    @Test func expectContinue() throws {
        let h = try #require(head(try parse("POST / HTTP/1.1\r\nExpect: 100-Continue\r\nContent-Length: 1\r\n\r\n").get()))
        #expect(h.expectsContinue)
        let old = try #require(head(try parse("POST / HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n").get()))
        #expect(!old.expectsContinue)
    }

    @Test func responseSerialization() {
        #expect(String(decoding: HTTPResponse.empty(.noContent).serialized(), as: UTF8.self)
            == "HTTP/1.1 204 No Content\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
        #expect(String(decoding: HTTPResponse.empty(.continue).serialized(), as: UTF8.self) == "HTTP/1.1 100 Continue\r\n\r\n")
        let health = HTTPResponse(status: .ok, body: HookRequestPolicy.healthBody)
        #expect(String(decoding: health.serialized(), as: UTF8.self).hasSuffix("Content-Length: 24\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{\"ok\":true,\"app\":\"codd\"}"))
        #expect(!String(decoding: health.serialized(omitBody: true), as: UTF8.self).contains("{"))
    }
}
