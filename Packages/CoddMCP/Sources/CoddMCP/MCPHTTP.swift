import Foundation

/// Who is calling, as the hook server authenticated it (C3): a CODD session by its per-session
/// token, or a registered external client by the external MCP token. The server never
/// authenticates anything itself; it passes the caller to the backend, which decides visibility.
public struct MCPCaller: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// A claude session CODD launched (its `X-CODD-Session` UUID).
        case session(UUID)
        /// A client registered with the external token (Claude Code user scope, Codex, …).
        case external
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public static func session(_ id: UUID) -> MCPCaller { MCPCaller(kind: .session(id)) }
    public static let external = MCPCaller(kind: .external)

    public var sessionID: UUID? {
        if case .session(let id) = kind { return id }
        return nil
    }

    public var description: String {
        switch kind {
        case .session(let id): return "session \(id.uuidString.lowercased())"
        case .external: return "external"
        }
    }
}

/// One HTTP request to `/mcp`, already framed and authenticated by the hook server. The server
/// reads only the method, the `MCP-Protocol-Version` header and the body.
public struct MCPHTTPRequest: Sendable {
    public var method: String
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]
    public var caller: MCPCaller

    public init(method: String = "POST", headers: [(name: String, value: String)] = [],
                body: [UInt8], caller: MCPCaller)
    {
        self.method = method
        self.headers = headers
        self.body = body
        self.caller = caller
    }

    /// The first value of a header, matched case-insensitively, without surrounding whitespace.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name.lowercased() == wanted }?.value
            .trimmingCharacters(in: .whitespaces)
    }
}

/// What the hook server writes back. `contentType` is nil for bodiless answers (202, 405);
/// `headers` carries extra headers only (`Allow` on 405). Never an `Mcp-Session-Id`: the server is
/// stateless, so an app relaunch never invalidates a client.
public struct MCPHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String?
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]

    public init(status: Int, contentType: String? = nil, headers: [(name: String, value: String)] = [],
                body: [UInt8] = [])
    {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: MCPHTTPResponse, rhs: MCPHTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.contentType == rhs.contentType && lhs.body == rhs.body
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    /// The body as UTF-8 text (diagnostics and tests).
    public var bodyText: String { String(decoding: body, as: UTF8.self) }

    /// 202 with no body: the answer to notifications and responses.
    public static let accepted = MCPHTTPResponse(status: 202)

    /// 405 for GET (no server-initiated stream) and DELETE (no sessions to end).
    public static let methodNotAllowed = MCPHTTPResponse(status: 405, headers: [(name: "Allow", value: "POST")])

    public static let jsonContentType = "application/json"

    static func json(_ status: Int, _ value: JSON) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, contentType: jsonContentType, body: JSONWriter.compact(value))
    }
}
