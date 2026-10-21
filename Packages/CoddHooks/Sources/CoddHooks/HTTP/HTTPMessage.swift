/// Status codes the hook endpoint sends (route handlers may send others; see
/// ``HTTPRouteResponse``).
public enum HTTPStatus: Int, Sendable, Equatable, CaseIterable {
    case `continue` = 100
    case ok = 200
    /// M4: MCP notifications and responses (from the MCP handler).
    case accepted = 202
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case requestTimeout = 408
    /// M4: a trashed or purged note's URL (from the note URL handler).
    case gone = 410
    case lengthRequired = 411
    case payloadTooLarge = 413
    case headerFieldsTooLarge = 431
    /// M4: a route handler's answer the server cannot send (over the response limit).
    case internalServerError = 500
    case notImplemented = 501
    case serviceUnavailable = 503
    case versionNotSupported = 505

    public var reasonPhrase: String {
        switch self {
        case .continue: return "Continue"
        case .ok: return "OK"
        case .accepted: return "Accepted"
        case .noContent: return "No Content"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .requestTimeout: return "Request Timeout"
        case .gone: return "Gone"
        case .lengthRequired: return "Length Required"
        case .payloadTooLarge: return "Content Too Large"
        case .headerFieldsTooLarge: return "Request Header Fields Too Large"
        case .internalServerError: return "Internal Server Error"
        case .notImplemented: return "Not Implemented"
        case .serviceUnavailable: return "Service Unavailable"
        case .versionNotSupported: return "HTTP Version Not Supported"
        }
    }
}

public enum HTTPVersion: Sendable, Equatable {
    case http10, http11
}

/// One header line, name as received.
public struct HTTPField: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Header fields in arrival order with case-insensitive lookup.
public struct HTTPHeaders: Sendable, Equatable {
    public private(set) var fields: [HTTPField]

    public init(_ fields: [HTTPField] = []) {
        self.fields = fields
    }

    mutating func append(_ field: HTTPField) {
        fields.append(field)
    }

    /// All values of `name` (ASCII case-insensitive).
    public func values(_ name: String) -> [String] {
        fields.compactMap { ASCIIText.equalsIgnoringCase($0.name, name) ? $0.value : nil }
    }

    /// The value when `name` occurs exactly once; `nil` when absent or repeated. Security-relevant
    /// headers (token, session, Host) are read with this, so a duplicated header is never resolved
    /// by picking one of the copies.
    public func single(_ name: String) -> String? {
        let v = values(name)
        return v.count == 1 ? v[0] : nil
    }

    public func contains(_ name: String) -> Bool {
        fields.contains { ASCIIText.equalsIgnoringCase($0.name, name) }
    }
}

/// How the request body is delimited.
public enum HTTPBodyFraming: Sendable, Equatable {
    /// No `Content-Length` and no `Transfer-Encoding`: no body.
    case none
    case length(Int)
    case chunked
}

/// A parsed request line and header block.
public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    /// The request target as received (`/hooks`, `/hooks?x=1`).
    public var target: String
    public var version: HTTPVersion
    public var headers: HTTPHeaders
    public var framing: HTTPBodyFraming

    public init(method: String, target: String, version: HTTPVersion, headers: HTTPHeaders, framing: HTTPBodyFraming) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.framing = framing
    }

    /// The target without its query.
    public var path: String {
        target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
    }

    /// `Expect: 100-continue` on an HTTP/1.1 request (curl sends it for bodies over 1 KiB and waits
    /// a second for the interim response before sending the body anyway).
    public var expectsContinue: Bool {
        version == .http11 && headers.values("Expect").contains { ASCIIText.equalsIgnoringCase(ASCIIText.trimOWS($0), "100-continue") }
    }
}

/// A response the endpoint sends; always `Connection: close`.
public struct HTTPResponse: Sendable, Equatable {
    public var status: HTTPStatus
    public var headers: [HTTPField]
    public var body: [UInt8]

    public init(status: HTTPStatus, headers: [HTTPField] = [], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Wire bytes. `204` and `1xx` carry no `Content-Length`; `omitBody` serves `HEAD`.
    public func serialized(omitBody: Bool = false) -> [UInt8] {
        var head = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        if status == .continue { return Array((head + "\r\n").utf8) }
        for field in headers { head += "\(field.name): \(field.value)\r\n" }
        if status != .noContent { head += "Content-Length: \(body.count)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + (omitBody || status == .noContent ? [] : body)
    }

    public static func empty(_ status: HTTPStatus, headers: [HTTPField] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }
}

extension HTTPRouteResponse {
    /// Header names the server owns; a handler's copies are dropped.
    static let serverHeaders: Set<String> = ["content-length", "content-type", "connection", "transfer-encoding", "cache-control"]

    /// Wire bytes of a handler's answer, framed like ``HTTPResponse/serialized(omitBody:)``. A status
    /// outside 200…599, or a body over `maxBodyBytes`, becomes an empty `500`.
    func serialized(maxBodyBytes: Int) -> [UInt8] {
        guard (200...599).contains(status), body.count <= maxBodyBytes else {
            return HTTPResponse.empty(.internalServerError).serialized()
        }
        let reason = HTTPStatus(rawValue: status)?.reasonPhrase ?? (status < 300 ? "OK" : status < 500 ? "Error" : "Server Error")
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        let bodyless = status == 204 || status == 304
        if let contentType, !bodyless, Self.isSafe(contentType) { head += "Content-Type: \(contentType)\r\n" }
        for field in headers where Self.isSafeName(field.name) && Self.isSafe(field.value)
            && !Self.serverHeaders.contains(field.name.lowercased()) {
            head += "\(field.name): \(field.value)\r\n"
        }
        if !bodyless { head += "Content-Length: \(body.count)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + (bodyless ? [] : body)
    }

    /// No control characters (CR / LF would split the header block).
    static func isSafe(_ value: String) -> Bool {
        !value.utf8.contains { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy(ASCIIText.isTokenChar)
    }
}

/// ASCII helpers for header handling (header names and the values CODD checks are ASCII).
enum ASCIIText {
    static func lower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b | 0x20 : b }

    static func equalsIgnoringCase(_ a: String, _ b: String) -> Bool {
        let x = a.utf8, y = b.utf8
        return x.count == y.count && zip(x, y).allSatisfy { lower($0) == lower($1) }
    }

    /// Trims optional whitespace (SP / HTAB) as RFC 9110 defines it.
    static func trimOWS(_ s: String) -> String {
        let b = Array(s.utf8)
        var start = 0, end = b.count
        while start < end, b[start] == 0x20 || b[start] == 0x09 { start += 1 }
        while end > start, b[end - 1] == 0x20 || b[end - 1] == 0x09 { end -= 1 }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    /// RFC 9110 `tchar`.
    static func isTokenChar(_ c: UInt8) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"), UInt8(ascii: "&"),
             UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."),
             UInt8(ascii: "^"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
            return true
        default: return false
        }
    }
}
