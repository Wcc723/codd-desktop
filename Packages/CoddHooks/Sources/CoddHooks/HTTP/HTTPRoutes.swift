import CoddCore
import Foundation

/// Who called `POST /mcp`.
public enum MCPRouteCaller: Sendable, Hashable {
    /// A CODD session (`X-CODD-Session` + its derived token, from its per-session `mcp.json`).
    case session(UUID)
    /// A client holding the external MCP token (a registration, curl).
    case external
}

/// A request handed to a route handler (`/mcp`, `/n/…`), complete with its body.
public struct HTTPRouteRequest: Sendable, Equatable {
    public var method: String
    /// The path without its query.
    public var path: String
    /// The decoded query (`+` as space, `%XX`); the first value wins for a repeated name.
    public var query: [String: String]
    /// Header fields in arrival order, names as received.
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]

    public init(method: String, path: String, query: [String: String] = [:], headers: [(name: String, value: String)] = [],
                body: [UInt8] = []) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Every value of the header `name` (ASCII case-insensitive).
    public func values(_ name: String) -> [String] {
        headers.compactMap { ASCIIText.equalsIgnoringCase($0.name, name) ? $0.value : nil }
    }

    /// The value of `name` when it occurs exactly once.
    public func header(_ name: String) -> String? {
        let v = values(name)
        return v.count == 1 ? v[0] : nil
    }

    public static func == (a: HTTPRouteRequest, b: HTTPRouteRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.query == b.query && a.body == b.body
            && a.headers.count == b.headers.count && zip(a.headers, b.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

/// What a route handler answers. The server adds `Content-Length`, `Cache-Control: no-store` and
/// `Connection: close`; handler headers named `Content-Length`, `Content-Type`, `Connection` or
/// `Transfer-Encoding`, and any header with a control character, are dropped.
public struct HTTPRouteResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String?
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]

    public init(status: Int, contentType: String? = nil, headers: [(name: String, value: String)] = [], body: [UInt8] = []) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    /// A response with only a status (no body).
    public static func status(_ code: Int) -> HTTPRouteResponse {
        HTTPRouteResponse(status: code)
    }

    /// `application/json` with `body`.
    public static func json(_ body: [UInt8], status: Int = 200) -> HTTPRouteResponse {
        HTTPRouteResponse(status: status, contentType: "application/json", body: body)
    }

    public static func == (a: HTTPRouteResponse, b: HTTPRouteResponse) -> Bool {
        a.status == b.status && a.contentType == b.contentType && a.body == b.body
            && a.headers.count == b.headers.count && zip(a.headers, b.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

/// The prompt handler's answer for `/hooks/prompt` (D19).
public struct PromptHookAnswer: Sendable, Equatable {
    /// Added to the turn by Claude (`hookSpecificOutput.additionalContext`).
    public var additionalContext: String
    /// Shown to the user by Claude (`systemMessage`, the `⎿ codd：已展開 …` line); omitted when nil.
    public var systemMessage: String?

    public init(additionalContext: String, systemMessage: String? = nil) {
        self.additionalContext = additionalContext
        self.systemMessage = systemMessage
    }

    /// `{"hookSpecificOutput":{"additionalContext":…,"hookEventName":"UserPromptSubmit"},"systemMessage":…}`:
    /// compact UTF-8 JSON, sorted keys, slashes unescaped (Claude requires a body that starts with
    /// `{` and is valid hook output).
    public func jsonBody() -> [UInt8] {
        var object: [String: JSONValue] = [
            "hookSpecificOutput": .object([
                "hookEventName": .string(HookEventName.userPromptSubmit.rawValue),
                "additionalContext": .string(additionalContext),
            ]),
        ]
        if let systemMessage { object["systemMessage"] = .string(systemMessage) }
        return Array((try? JSONValue.object(object).jsonData()) ?? Data("{}".utf8))
    }
}
