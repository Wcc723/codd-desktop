import Foundation
import Testing
@testable import CoddHooks

@Suite("Hook request policy (auth matrix)")
struct HookRequestPolicyTests {
    let policy = HookRequestPolicy(token: testToken, port: 47821)
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    func head(method: String = "POST", target: String = "/hooks", _ fields: [(String, String)],
              framing: HTTPBodyFraming = .length(2)) -> HTTPRequestHead {
        HTTPRequestHead(method: method, target: target, version: .http11,
                        headers: HTTPHeaders(fields.map { HTTPField(name: $0.0, value: $0.1) }), framing: framing)
    }

    var good: [(String, String)] {
        [("Host", "127.0.0.1:47821"), ("X-CODD-Token", testToken), ("X-CODD-Session", sid)]
    }

    func replacing(_ name: String, with value: String?) -> [(String, String)] {
        var f = good.filter { $0.0 != name }
        if let value { f.append((name, value)) }
        return f
    }

    @Test func validRequest() {
        #expect(policy.route(head(good)) == .hook(sessionID: UUID(uuidString: sid)!))
        // Header names are case-insensitive; the session id may be uppercase; a query is ignored.
        let lower = [("host", "LOCALHOST:47821"), ("x-codd-token", testToken), ("x-codd-session", sid.uppercased())]
        #expect(policy.route(head(target: "/hooks?x=1", lower)) == .hook(sessionID: UUID(uuidString: sid)!))
    }

    @Test func tokenChecks() {
        #expect(policy.route(head(replacing("X-CODD-Token", with: nil))) == .reject(.unauthorized))
        #expect(policy.route(head(replacing("X-CODD-Token", with: String(repeating: "cd", count: 32)))) == .reject(.unauthorized))
        #expect(policy.route(head(replacing("X-CODD-Token", with: String(testToken.dropLast())))) == .reject(.unauthorized))
        #expect(policy.route(head(replacing("X-CODD-Token", with: testToken + "x"))) == .reject(.unauthorized))
        #expect(policy.route(head(replacing("X-CODD-Token", with: ""))) == .reject(.unauthorized))
        #expect(policy.route(head(good + [("X-CODD-Token", testToken)]))  == .reject(.unauthorized)) // duplicated
        #expect(policy.route(head(replacing("X-CODD-Token", with: testToken.uppercased()))) == .reject(.unauthorized))
    }

    @Test func originAlwaysForbidden() {
        for origin in ["http://evil.example", "null", "http://127.0.0.1:47821", ""] {
            #expect(policy.route(head(good + [("Origin", origin)])) == .reject(.forbidden), "\(origin)")
        }
        // Even for /health.
        #expect(policy.route(head(method: "GET", target: "/health", [("Host", "127.0.0.1:47821"), ("Origin", "x")], framing: .none))
            == .reject(.forbidden))
    }

    @Test(arguments: ["evil.example", "127.0.0.1", "127.0.0.1:47822", "localhost", "[::1]:47821", "127.0.0.2:47821",
                      "127.0.0.1:47821.evil.example", "0.0.0.0:47821"])
    func hostMustBeLoopbackWithPort(_ host: String) {
        #expect(policy.route(head(replacing("Host", with: host))) == .reject(.forbidden))
    }

    @Test func hostMissingOrDuplicated() {
        #expect(policy.route(head(replacing("Host", with: nil))) == .reject(.forbidden))
        #expect(policy.route(head(good + [("Host", "127.0.0.1:47821")])) == .reject(.forbidden))
    }

    @Test(arguments: ["", "not-a-uuid", "{7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17}", "7c1e9a045b2d4e8f9a310c6d2e4f8b17",
                      "urn:uuid:7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b1g",
                      " 7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b1"])
    func sessionMustBeUUID(_ value: String) {
        #expect(policy.route(head(replacing("X-CODD-Session", with: value))) == .reject(.badRequest))
    }

    @Test func sessionMissingOrDuplicated() {
        #expect(policy.route(head(replacing("X-CODD-Session", with: nil))) == .reject(.badRequest))
        #expect(policy.route(head(good + [("X-CODD-Session", sid)])) == .reject(.badRequest))
    }

    @Test func routesAndMethods() {
        #expect(policy.route(head(method: "GET", good, framing: .none)) == .reject(.methodNotAllowed))
        #expect(policy.route(head(method: "PUT", good)) == .reject(.methodNotAllowed))
        #expect(policy.route(head(target: "/hook", good)) == .reject(.notFound))
        #expect(policy.route(head(target: "/hooks/", good)) == .reject(.notFound))
        #expect(policy.route(head(target: "*", good)) == .reject(.notFound))
        #expect(policy.route(head(method: "POST", target: "/health", good)) == .reject(.methodNotAllowed))
        #expect(HookRequestPolicy.allowedMethods(for: "/hooks") == "POST")
        // Unauthenticated callers learn nothing beyond 401 (the route check comes first, the token second).
        #expect(policy.route(head(target: "/hooks", [("Host", "127.0.0.1:47821")])) == .reject(.unauthorized))
    }

    @Test func lengthRequired() {
        #expect(policy.route(head(good, framing: .none)) == .reject(.lengthRequired))
        #expect(policy.route(head(good, framing: .chunked)) == .hook(sessionID: UUID(uuidString: sid)!))
    }

    @Test func healthNeedsNoToken() {
        let h = [("Host", "localhost:47821")]
        #expect(policy.route(head(method: "GET", target: "/health", h, framing: .none)) == .health(headOnly: false))
        #expect(policy.route(head(method: "HEAD", target: "/health", h, framing: .none)) == .health(headOnly: true))
    }

    @Test func constantTimeEquals() {
        #expect(HookRequestPolicy.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        #expect(!HookRequestPolicy.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        #expect(!HookRequestPolicy.constantTimeEquals([1, 2], [1, 2, 0]))
        #expect(!HookRequestPolicy.constantTimeEquals([], [0]))
        #expect(HookRequestPolicy.constantTimeEquals([], []))
    }
}
