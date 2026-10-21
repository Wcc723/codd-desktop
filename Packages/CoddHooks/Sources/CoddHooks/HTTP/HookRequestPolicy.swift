import CoddCore
import CryptoKit
import Foundation

/// What to do with a request once its head is known.
public enum HookRoute: Sendable, Equatable {
    /// An authenticated hook delivery for this CODD session: read the body, answer 204.
    case hook(sessionID: UUID)
    /// An authenticated status-line report (`codd-statusline`): read the body (at most
    /// ``HookRequestPolicy/statusLineMaxBodyBytes``), answer 204. `nil` from the global status line,
    /// which runs in claudes CODD did not start.
    case statusLine(sessionID: UUID?)
    /// `GET`/`HEAD /health`: answer ``HookRequestPolicy/healthBody`` (no token, no data).
    case health(headOnly: Bool)
    /// M4: an authenticated `POST /mcp`: read the body, answer what the MCP handler returns.
    case mcp(caller: MCPRouteCaller)
    /// M4: `POST /hooks/prompt`, authenticated like `/hooks`: read the body, yield the event, then
    /// answer with the prompt handler's `additionalContext` (or 204).
    case promptHook(sessionID: UUID)
    /// M4: `GET /n/<id>.md?t=<token>` with the note's valid URL token: answer what the note URL
    /// handler returns.
    case noteURL(id: String, token: String)
    case reject(HTTPStatus)
}

/// Routing and authentication for the hook endpoint (pure; the server applies the result).
///
/// Checks, in order: no `Origin` (browsers always send it on cross-site POSTs, so a web page can
/// never deliver a hook) → `Host` is exactly `127.0.0.1:<port>` or `localhost:<port>` (defeats DNS
/// rebinding) → route and method → token (constant time) → session id is a UUID (optional on
/// `/statusline`, but a UUID when present) → the body has a length (and, on `/statusline`, at most
/// 64 KiB). Any failure is a status code and no event. `/hooks/prompt` (M4) follows exactly these
/// rules.
///
/// `/mcp` (M4 D16) differs only in `Origin`: absent, or exactly `http://127.0.0.1:<port>` /
/// `http://localhost:<port>` (MCP clients may send their own origin; a web page cannot claim it).
/// Its auth is a session (`X-CODD-Session` once and a UUID, with `X-CODD-Token` equal to
/// ``MCPAuth/sessionToken(hookToken:sessionID:)``) or, with no session header, the external
/// ``mcpToken`` as `X-CODD-Token` or `Authorization: Bearer`; any failure is 401 (never with
/// `WWW-Authenticate`, so no client starts an OAuth flow). `/n/<id>.md` (M4 D15) takes the `Host`
/// rule and no `Origin`, `GET` only, and the note's ``MCPAuth/noteURLToken(mcpToken:noteID:)`` as
/// the query's `t`; a wrong or missing token is 404, like an unknown note.
public struct HookRequestPolicy: Sendable, Equatable {
    public static let hooksPath = "/hooks"
    public static let healthPath = "/health"
    /// Status-line reports (M3 D9).
    public static let statusLinePath = "/statusline"
    /// M4 D16: the MCP Streamable HTTP endpoint.
    public static let mcpPath = "/mcp"
    /// M4 D19: UserPromptSubmit with prompt expansion.
    public static let promptHookPath = "/hooks/prompt"
    /// M4 D15: note URLs are `/n/<id>.md?t=<token>`.
    public static let noteURLPrefix = "/n/"
    public static let noteURLSuffix = ".md"
    /// Note ids are at most this long (`[a-z0-9]+(-[a-z0-9]+)*`).
    public static let maxNoteIDLength = 48
    /// A report is the `rate_limits` member plus a few fields (`codd-statusline` drops
    /// `rate_limits` rather than exceed this).
    public static let statusLineMaxBodyBytes = 64 * 1024
    /// The `/health` body: identifies a CODD endpoint without revealing anything else.
    public static let healthBody = Array(#"{"ok":true,"app":"codd"}"#.utf8)
    /// A prober's nonce (16–128 hex digits). The answer then carries `proof`, an HMAC of it keyed
    /// with the token: anything can claim to be CODD on a loopback port, only a holder of this
    /// data root's token can prove it, and the token never leaves the process.
    public static let challengeHeader = "X-CODD-Challenge"

    /// The `/health` body for a request with `challenge` (the plain body without a valid one).
    public func healthBody(challenge: String?) -> [UInt8] {
        guard let challenge, Self.isValidChallenge(challenge) else { return Self.healthBody }
        return Array(#"{"ok":true,"app":"codd","proof":"\#(Self.proof(token: token, challenge: challenge))"}"#.utf8)
    }

    /// Lowercase hex HMAC-SHA256 of `codd-health-v1:<challenge>` keyed with the token's UTF-8.
    public static func proof(token: String, challenge: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("codd-health-v1:\(challenge)".utf8),
                                                   using: SymmetricKey(data: Data(token.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidChallenge(_ challenge: String) -> Bool {
        let bytes = Array(challenge.utf8)
        return (16...128).contains(bytes.count)
            && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) }
    }

    public var token: String
    /// The port the listener is bound to (used for the `Host` check).
    public var port: UInt16
    /// M4: the external MCP token (config.json `mcpToken`); `nil` refuses every external MCP
    /// caller and every note URL.
    public var mcpToken: String?

    public init(token: String, port: UInt16, mcpToken: String? = nil) {
        self.token = token
        self.port = port
        self.mcpToken = mcpToken
    }

    public func route(_ head: HTTPRequestHead) -> HookRoute {
        let path = head.path
        if path == Self.mcpPath { return mcpRoute(head) }
        if head.headers.contains("Origin") { return .reject(.forbidden) }
        guard let host = head.headers.single("Host"), isAllowedHost(host) else { return .reject(.forbidden) }
        if let id = Self.noteID(fromPath: path) { return noteURLRoute(head, id: id) }
        switch path {
        case Self.healthPath:
            switch head.method {
            case "GET": return .health(headOnly: false)
            case "HEAD": return .health(headOnly: true)
            default: return .reject(.methodNotAllowed)
            }
        case Self.hooksPath, Self.statusLinePath, Self.promptHookPath:
            guard head.method == "POST" else { return .reject(.methodNotAllowed) }
        default:
            return .reject(.notFound)
        }
        guard let presented = head.headers.single(CoddHookHeader.token),
              Self.constantTimeEquals(Array(presented.utf8), Array(token.utf8)) else {
            return .reject(.unauthorized)
        }
        if path == Self.statusLinePath { return statusLineRoute(head) }
        guard let raw = head.headers.single(CoddHookHeader.session), let id = Self.sessionID(raw) else {
            return .reject(.badRequest)
        }
        if head.framing == .none { return .reject(.lengthRequired) }
        return path == Self.promptHookPath ? .promptHook(sessionID: id) : .hook(sessionID: id)
    }

    /// `/mcp`: Host → Origin → method → caller → body length.
    private func mcpRoute(_ head: HTTPRequestHead) -> HookRoute {
        guard let host = head.headers.single("Host"), isAllowedHost(host) else { return .reject(.forbidden) }
        let origins = head.headers.values("Origin")
        if !origins.isEmpty {
            guard origins.count == 1, isAllowedOrigin(origins[0]) else { return .reject(.forbidden) }
        }
        guard head.method == "POST" else { return .reject(.methodNotAllowed) }
        guard let caller = mcpCaller(head) else { return .reject(.unauthorized) }
        if head.framing == .none { return .reject(.lengthRequired) }
        return .mcp(caller: caller)
    }

    /// The authenticated MCP caller, or `nil` (401).
    func mcpCaller(_ head: HTTPRequestHead) -> MCPRouteCaller? {
        let sessions = head.headers.values(CoddHookHeader.session)
        let tokens = head.headers.values(CoddHookHeader.token)
        if !sessions.isEmpty {
            // A session header means session auth only: never a fallback to the external token.
            guard sessions.count == 1, let id = Self.sessionID(sessions[0]), tokens.count == 1,
                  MCPAuth.isValidSessionToken(tokens[0], hookToken: token, sessionID: id) else { return nil }
            return .session(id)
        }
        guard let mcpToken, !mcpToken.isEmpty else { return nil }
        let authorizations = head.headers.values("Authorization")
        guard tokens.count <= 1, authorizations.count <= 1 else { return nil }
        var presented = tokens
        if let authorization = authorizations.first {
            guard let bearer = Self.bearerToken(authorization) else { return nil }
            presented.append(bearer)
        }
        // Every presented copy must be right (a client sending both sends the same value).
        guard !presented.isEmpty,
              presented.allSatisfy({ Self.constantTimeEquals(Array($0.utf8), Array(mcpToken.utf8)) }) else { return nil }
        return .external
    }

    /// `/n/<id>.md`: `GET`, then the note's URL token as `t` (exactly once), else 404.
    private func noteURLRoute(_ head: HTTPRequestHead, id: String) -> HookRoute {
        guard head.method == "GET" else { return .reject(.methodNotAllowed) }
        let values = Self.queryItems(head.target).filter { $0.name == "t" }.map { $0.value }
        guard values.count == 1, MCPAuth.isValidNoteURLToken(values[0], mcpToken: mcpToken, noteID: id) else {
            return .reject(.notFound)
        }
        return .noteURL(id: id, token: values[0])
    }

    /// `http://127.0.0.1:<port>` or `http://localhost:<port>` (scheme and host in any case).
    func isAllowedOrigin(_ origin: String) -> Bool {
        let o = origin.lowercased()
        return o == "http://127.0.0.1:\(port)" || o == "http://localhost:\(port)"
    }

    /// `Bearer <token>` (scheme in any case); `nil` for another scheme or an empty token.
    static func bearerToken(_ value: String) -> String? {
        let v = ASCIIText.trimOWS(value)
        let bytes = Array(v.utf8)
        guard bytes.count > 7, ASCIIText.equalsIgnoringCase(String(decoding: bytes[0..<6], as: UTF8.self), "Bearer"),
              bytes[6] == 0x20 else { return nil }
        let token = ASCIIText.trimOWS(String(decoding: bytes[7...], as: UTF8.self))
        return token.isEmpty ? nil : token
    }

    /// The note id of a `/n/<id>.md` path whose id has the note id shape; `nil` for any other path.
    public static func noteID(fromPath path: String) -> String? {
        guard path.hasPrefix(noteURLPrefix), path.hasSuffix(noteURLSuffix) else { return nil }
        let id = String(path.dropFirst(noteURLPrefix.count).dropLast(noteURLSuffix.count))
        return isValidNoteID(id) ? id : nil
    }

    /// `[a-z0-9]+(-[a-z0-9]+)*`, at most ``maxNoteIDLength`` characters.
    public static func isValidNoteID(_ id: String) -> Bool {
        let b = Array(id.utf8)
        guard !b.isEmpty, b.count <= maxNoteIDLength, b.first != 0x2D, b.last != 0x2D else { return false }
        var previousDash = false
        for c in b {
            if c == 0x2D {
                if previousDash { return false }
                previousDash = true
            } else {
                guard (0x30...0x39).contains(c) || (0x61...0x7A).contains(c) else { return false }
                previousDash = false
            }
        }
        return true
    }

    /// `http://127.0.0.1:<port>/n/<id>.md?t=<token>` (COPY REF form 5).
    public static func noteURL(port: UInt16, noteID: String, mcpToken: String) -> String {
        "http://127.0.0.1:\(port)\(noteURLPrefix)\(noteID)\(noteURLSuffix)?t=\(MCPAuth.noteURLToken(mcpToken: mcpToken, noteID: noteID))"
    }

    /// The query of a request target as `(name, value)` pairs in order: `+` as a space, `%XX`
    /// decoded (an invalid escape keeps the text as given), empty names dropped.
    public static func queryItems(_ target: String) -> [(name: String, value: String)] {
        guard let q = target.firstIndex(of: "?") else { return [] }
        var items: [(name: String, value: String)] = []
        for part in target[target.index(after: q)...].split(separator: "&", omittingEmptySubsequences: true) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decodeQueryComponent(pair[0])
            guard !name.isEmpty else { continue }
            items.append((name, pair.count > 1 ? decodeQueryComponent(pair[1]) : ""))
        }
        return items
    }

    /// ``queryItems(_:)`` as a dictionary; the first value wins for a repeated name.
    public static func query(_ target: String) -> [String: String] {
        var out: [String: String] = [:]
        for item in queryItems(target) where out[item.name] == nil { out[item.name] = item.value }
        return out
    }

    static func decodeQueryComponent(_ s: Substring) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// `/statusline` after the token: an optional session (exactly once and a UUID when present)
    /// and a body of known length up to ``statusLineMaxBodyBytes``.
    private func statusLineRoute(_ head: HTTPRequestHead) -> HookRoute {
        var session: UUID?
        let values = head.headers.values(CoddHookHeader.session)
        if !values.isEmpty {
            guard values.count == 1, let id = Self.sessionID(values[0]) else { return .reject(.badRequest) }
            session = id
        }
        switch head.framing {
        case .none: return .reject(.lengthRequired)
        case .length(let n) where n > Self.statusLineMaxBodyBytes: return .reject(.payloadTooLarge)
        case .length, .chunked: return .statusLine(sessionID: session)
        }
    }

    /// The `Allow` header for a 405 on `path`.
    public static func allowedMethods(for path: String) -> String? {
        switch path {
        case hooksPath, statusLinePath, promptHookPath, mcpPath: return "POST"
        case healthPath: return "GET, HEAD"
        default: return noteID(fromPath: path) != nil ? "GET" : nil
        }
    }

    /// ``rejectionReason(_:_:)`` with the M4 routes described from what the policy knows (the
    /// port for `Host` / `Origin`, whether an external token is set). Never quotes a token.
    func rejectionReason(_ status: HTTPStatus, _ head: HTTPRequestHead) -> String {
        let path = head.path
        func quoted(_ name: String) -> String {
            let v = head.headers.values(name)
            return v.isEmpty ? "missing" : v.map { "\"\($0.prefix(80))\"" }.joined(separator: ", ")
        }
        switch (status, path) {
        case (.forbidden, Self.mcpPath):
            if let host = head.headers.single("Host"), isAllowedHost(host) { return "Origin not allowed (\(quoted("Origin")))" }
            return "Host not allowed (\(quoted("Host")))"
        case (.unauthorized, Self.mcpPath):
            return mcpAuthFailure(head)
        case (.notFound, _) where Self.noteID(fromPath: path) != nil:
            let n = Self.queryItems(head.target).filter { $0.name == "t" }.count
            return n > 1 ? "note URL token repeated" : n == 0 ? "note URL token missing" : "note URL token wrong or MCP token not set"
        default:
            return Self.rejectionReason(status, head)
        }
    }

    private func mcpAuthFailure(_ head: HTTPRequestHead) -> String {
        let sessions = head.headers.values(CoddHookHeader.session)
        let tokens = head.headers.values(CoddHookHeader.token)
        if !sessions.isEmpty {
            if sessions.count > 1 { return "\(CoddHookHeader.session) repeated" }
            if Self.sessionID(sessions[0]) == nil { return "\(CoddHookHeader.session) not a UUID" }
            if tokens.isEmpty { return "MCP session token missing" }
            return tokens.count > 1 ? "token header repeated" : "wrong MCP session token"
        }
        let authorizations = head.headers.values("Authorization")
        if tokens.count > 1 || authorizations.count > 1 { return "token header repeated" }
        if let a = authorizations.first, Self.bearerToken(a) == nil { return "Authorization is not a Bearer token" }
        if tokens.isEmpty && authorizations.isEmpty { return "MCP token missing" }
        return mcpToken?.isEmpty == false ? "wrong MCP token" : "external MCP token not set"
    }

    /// A diagnostic for a rejection. Header values are only quoted for `Host` and `Origin`
    /// (not secret); the token and session headers are described, never quoted.
    static func rejectionReason(_ status: HTTPStatus, _ head: HTTPRequestHead) -> String {
        func quoted(_ name: String) -> String {
            let v = head.headers.values(name)
            return v.isEmpty ? "missing" : v.map { "\"\($0.prefix(80))\"" }.joined(separator: ", ")
        }
        switch status {
        case .forbidden:
            return head.headers.contains("Origin") ? "Origin header present (\(quoted("Origin")))" : "Host not allowed (\(quoted("Host")))"
        case .unauthorized:
            let n = head.headers.values(CoddHookHeader.token).count
            return n == 0 ? "token missing" : n > 1 ? "token header repeated" : "wrong token"
        case .badRequest:
            return head.path == statusLinePath
                ? "\(CoddHookHeader.session) repeated or not a UUID"
                : "\(CoddHookHeader.session) missing, repeated or not a UUID"
        case .notFound:
            return "no route for \(head.method) \(head.path.prefix(80))"
        case .methodNotAllowed:
            return "\(head.method) not allowed on \(head.path.prefix(80))"
        case .lengthRequired:
            return "no Content-Length or chunked body"
        case .payloadTooLarge:
            return "body over \(statusLineMaxBodyBytes) bytes on \(head.path.prefix(80))"
        default:
            return status.reasonPhrase
        }
    }

    func isAllowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1:\(port)" || h == "localhost:\(port)"
    }

    /// A canonical 8-4-4-4-12 hex UUID (either case); the shape is checked before Foundation parses
    /// it, so no other spelling (braces, URNs, missing dashes) is accepted.
    static func sessionID(_ raw: String) -> UUID? {
        let b = Array(raw.utf8)
        guard b.count == 36 else { return nil }
        for (i, c) in b.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard c == UInt8(ascii: "-") else { return nil }
            } else {
                guard (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c) else { return nil }
            }
        }
        return UUID(uuidString: raw)
    }

    /// Compares without an early exit, so the time taken does not reveal how much of a guessed
    /// token was right (only whether the lengths match, and the length is public).
    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
