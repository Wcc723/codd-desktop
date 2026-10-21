import CoddHookClient
import Foundation
import Testing
@testable import CoddHooks

@Suite("Status-line request policy")
struct StatusLinePolicyTests {
    let policy = HookRequestPolicy(token: testToken, port: 47821)
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    func head(method: String = "POST", target: String = "/statusline", _ fields: [(String, String)],
              framing: HTTPBodyFraming = .length(80)) -> HTTPRequestHead {
        HTTPRequestHead(method: method, target: target, version: .http11,
                        headers: HTTPHeaders(fields.map { HTTPField(name: $0.0, value: $0.1) }), framing: framing)
    }

    var good: [(String, String)] { [("Host", "127.0.0.1:47821"), ("X-CODD-Token", testToken)] }

    @Test func sessionIsOptional() {
        #expect(policy.route(head(good)) == .statusLine(sessionID: nil))
        #expect(policy.route(head(good + [("X-CODD-Session", sid)])) == .statusLine(sessionID: UUID(uuidString: sid)!))
        // Case-insensitive names, an uppercase id, localhost, and a query are all fine.
        let lower = [("host", "LOCALHOST:47821"), ("x-codd-token", testToken), ("x-codd-session", sid.uppercased())]
        #expect(policy.route(head(target: "/statusline?x=1", lower)) == .statusLine(sessionID: UUID(uuidString: sid)!))
    }

    @Test(arguments: ["", "not-a-uuid", "{7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17}", "7c1e9a045b2d4e8f9a310c6d2e4f8b17",
                      "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b1g"])
    func presentSessionMustBeAUUID(_ value: String) {
        #expect(policy.route(head(good + [("X-CODD-Session", value)])) == .reject(.badRequest))
    }

    @Test func duplicatedSessionIsRefused() {
        let h = head(good + [("X-CODD-Session", sid), ("X-CODD-Session", sid)])
        #expect(policy.route(h) == .reject(.badRequest))
        #expect(HookRequestPolicy.rejectionReason(.badRequest, h) == "X-CODD-Session repeated or not a UUID")
    }

    @Test func tokenIsRequired() {
        let host = [("Host", "127.0.0.1:47821")]
        #expect(policy.route(head(host)) == .reject(.unauthorized))
        #expect(policy.route(head(host + [("X-CODD-Token", String(repeating: "cd", count: 32))])) == .reject(.unauthorized))
        #expect(policy.route(head(host + [("X-CODD-Token", testToken.uppercased())])) == .reject(.unauthorized))
        #expect(policy.route(head(host + [("X-CODD-Token", String(testToken.dropLast()))])) == .reject(.unauthorized))
        #expect(policy.route(head(good + [("X-CODD-Token", testToken)])) == .reject(.unauthorized)) // duplicated
        // The token is checked before the session: an unauthenticated caller learns nothing more.
        #expect(policy.route(head(host + [("X-CODD-Session", "junk")])) == .reject(.unauthorized))
    }

    @Test func originAndHostAreCheckedFirst() {
        #expect(policy.route(head(good + [("Origin", "http://evil.example")])) == .reject(.forbidden))
        #expect(policy.route(head(good + [("Origin", "null")], framing: .none)) == .reject(.forbidden))
        for host in ["evil.example:47821", "127.0.0.1", "127.0.0.1:47822", "localhost"] {
            let fields = [("Host", host), ("X-CODD-Token", testToken)]
            #expect(policy.route(head(fields)) == .reject(.forbidden), "\(host)")
        }
    }

    @Test func methodsAndPaths() {
        #expect(policy.route(head(method: "GET", good, framing: .none)) == .reject(.methodNotAllowed))
        #expect(policy.route(head(method: "PUT", good)) == .reject(.methodNotAllowed))
        #expect(HookRequestPolicy.allowedMethods(for: "/statusline") == "POST")
        #expect(policy.route(head(target: "/statusline/", good)) == .reject(.notFound))
        #expect(policy.route(head(target: "/StatusLine", good)) == .reject(.notFound))
    }

    @Test func bodyLengthIsRequiredAndBounded() {
        #expect(policy.route(head(good, framing: .none)) == .reject(.lengthRequired))
        #expect(policy.route(head(good, framing: .length(65_536))) == .statusLine(sessionID: nil))
        #expect(policy.route(head(good, framing: .length(65_537))) == .reject(.payloadTooLarge))
        #expect(policy.route(head(good, framing: .chunked)) == .statusLine(sessionID: nil))
        #expect(HookRequestPolicy.rejectionReason(.payloadTooLarge, head(good, framing: .length(65_537)))
            == "body over 65536 bytes on /statusline")
        // The same length is fine on /hooks (1 MiB there), which still needs its session.
        let hook = good + [("X-CODD-Session", sid)]
        #expect(policy.route(head(target: "/hooks", hook, framing: .length(500_000))) == .hook(sessionID: UUID(uuidString: sid)!))
        #expect(policy.route(head(target: "/hooks", good)) == .reject(.badRequest))
    }

    @Test func wireConstantsMatchTheCLI() {
        #expect(HookRequestPolicy.statusLineMaxBodyBytes == StatusLineCommand.maxReportBytes)
        #expect(HookRequestPolicy.statusLinePath == StatusLineWireNames.path)
        #expect(HookRequestPolicy.statusLineMaxBodyBytes == 64 * 1024)
    }
}
