/// An `http://127.0.0.1[:port]/…` or `http://localhost[:port]/…` URL, the only kind `codd-hook` posts to.
///
/// Hook bodies carry prompts and tool input and the request carries the hook token, so anything that
/// could leave the machine (another host, `https` through a proxy, userinfo tricks) is refused at
/// parse time. `localhost` is never resolved: it is connected as 127.0.0.1, which also avoids a
/// resolver round trip and an IPv6 attempt on the SessionStart critical path.
public struct LoopbackURL: Sendable, Equatable {
    /// The authority as sent in `Host`: the host lowercased plus `:port` when the URL had one.
    public var authority: String
    public var port: UInt16
    /// The origin-form request target (`/hooks`, `/hooks?x=1`); `/` when the URL has no path.
    public var target: String

    public init(authority: String, port: UInt16, target: String) {
        self.authority = authority
        self.port = port
        self.target = target
    }

    /// Parses `string`; `nil` unless it is a plain loopback `http` URL.
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        let scheme = Array("http://".utf8)
        guard bytes.count > scheme.count,
              zip(bytes.prefix(scheme.count), scheme).allSatisfy({ ASCII.lower($0) == $1 }) else { return nil }
        var rest = bytes.dropFirst(scheme.count)
        // A fragment is never sent.
        if let hash = rest.firstIndex(of: UInt8(ascii: "#")) { rest = rest[..<hash] }
        let authorityEnd = rest.firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") } ?? rest.endIndex
        let authorityBytes = Array(rest[..<authorityEnd])
        var target = Array(rest[authorityEnd...])
        if target.first == UInt8(ascii: "?") { target.insert(UInt8(ascii: "/"), at: 0) }
        if target.isEmpty { target = [UInt8(ascii: "/")] }
        // Request-target bytes must be visible ASCII (no spaces, controls or raw UTF-8).
        guard target.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }

        let host: [UInt8]
        let port: UInt16
        if let colon = authorityBytes.firstIndex(of: UInt8(ascii: ":")) {
            host = Array(authorityBytes[..<colon])
            let digits = authorityBytes[(colon + 1)...]
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy(ASCII.isDigit) else { return nil }
            let value = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
            guard (1...65535).contains(value) else { return nil }
            port = UInt16(value)
        } else {
            host = authorityBytes
            port = 80
        }
        let lowered = host.map(ASCII.lower)
        guard lowered == Array("127.0.0.1".utf8) || lowered == Array("localhost".utf8) else { return nil }
        var authority = String(decoding: lowered, as: UTF8.self)
        if authorityBytes.contains(UInt8(ascii: ":")) { authority += ":\(port)" }
        self.init(authority: authority, port: port, target: String(decoding: target, as: UTF8.self))
    }
}

/// ASCII helpers shared by the client code (no Foundation).
enum ASCII {
    @inline(__always) static func lower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b | 0x20 : b }
    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }

    /// Case-insensitive ASCII equality.
    static func equalsIgnoringCase(_ a: some Collection<UInt8>, _ b: some Collection<UInt8>) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { lower($0) == lower($1) }
    }

    /// `true` when `s` can be placed in a header value: visible ASCII and spaces only (no CR/LF, so
    /// an environment value can never inject a header).
    static func isSafeHeaderValue(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }
}
