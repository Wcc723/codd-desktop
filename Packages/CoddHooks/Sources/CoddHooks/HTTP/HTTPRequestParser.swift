/// A request the parser refuses, with the status to answer.
public struct HTTPParseError: Error, Sendable, Equatable {
    public var status: HTTPStatus
    public var reason: String

    public init(_ status: HTTPStatus, _ reason: String) {
        self.status = status
        self.reason = reason
    }
}

/// Incremental parser for ONE HTTP/1.x request (the endpoint closes every connection after one
/// response, so bytes after the first request, such as a pipelined second request, are ignored).
///
/// Feed bytes with ``append(_:)`` in whatever pieces the network delivers and call ``next()``
/// until it returns `nil` (more bytes needed). It yields ``Event/head(_:)`` once, as soon as the
/// header block is complete (so the caller can authenticate before reading any body), then
/// ``Event/body(_:)`` once. Framing follows RFC 9112 strictly where ambiguity could be abused
/// (`Content-Length` together with `Transfer-Encoding`, differing duplicate lengths, obs-fold,
/// whitespace before a colon) and leniently where it is harmless (bare LF line ends, empty lines
/// before the request line, chunk extensions, trailers).
public struct HTTPRequestParser: Sendable {
    public struct Limits: Sendable, Equatable {
        /// Request line plus header fields.
        public var maxHeadBytes: Int
        public var maxHeaderCount: Int
        public var maxBodyBytes: Int
        public var maxChunkLineBytes: Int

        public init(maxHeadBytes: Int = 16 * 1024, maxHeaderCount: Int = 100, maxBodyBytes: Int = 1 << 20,
                    maxChunkLineBytes: Int = 1024) {
            self.maxHeadBytes = maxHeadBytes
            self.maxHeaderCount = maxHeaderCount
            self.maxBodyBytes = maxBodyBytes
            self.maxChunkLineBytes = maxChunkLineBytes
        }
    }

    public enum Event: Sendable, Equatable {
        case head(HTTPRequestHead)
        case body([UInt8])
    }

    private enum Phase: Sendable, Equatable {
        case head
        case fixed(Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers(bytes: Int)
        case done
    }

    public private(set) var limits: Limits
    private var buffer: [UInt8] = []
    /// First unconsumed byte in ``buffer``.
    private var cursor = 0
    /// Where the search for the end of the head resumes (avoids rescanning on byte-wise input).
    private var headScanFrom = 0
    private var phase: Phase = .head
    private var body: [UInt8] = []

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Lowers the body limit once the route is known (`/statusline` takes 64 KiB, `/hooks` 1 MiB).
    /// A `Content-Length` was already checked by the caller; this bounds a chunked body.
    public mutating func limitBody(to maxBytes: Int) {
        limits.maxBodyBytes = min(limits.maxBodyBytes, maxBytes)
    }

    /// `true` once the body was returned; later bytes are ignored.
    public var isComplete: Bool { phase == .done }

    /// Bytes received after the complete request (pipelining is not supported; they are dropped).
    public var trailingByteCount: Int { phase == .done ? buffer.count - cursor : 0 }

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        if cursor > 64 * 1024 {
            buffer.removeFirst(cursor)
            headScanFrom = max(0, headScanFrom - cursor)
            cursor = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next event, or `nil` when more bytes are needed (or the request is complete).
    public mutating func next() throws(HTTPParseError) -> Event? {
        while true {
            switch phase {
            case .head:
                guard let head = try parseHead() else { return nil }
                switch head.framing {
                case .none: phase = .fixed(0)
                case .length(let n): phase = .fixed(n)
                case .chunked: phase = .chunkSize
                }
                return .head(head)

            case .fixed(let n):
                guard buffer.count - cursor >= n else { return nil }
                let out = Array(buffer[cursor..<(cursor + n)])
                cursor += n
                phase = .done
                return .body(out)

            case .chunkSize:
                guard let line = try takeLine(limit: limits.maxChunkLineBytes, tooLong: .badRequest) else { return nil }
                let size = try Self.chunkSize(line)
                if size == 0 {
                    phase = .trailers(bytes: 0)
                } else {
                    guard body.count + size <= limits.maxBodyBytes else {
                        throw HTTPParseError(.payloadTooLarge, "chunked body over \(limits.maxBodyBytes) bytes")
                    }
                    phase = .chunkData(remaining: size)
                }

            case .chunkData(let remaining):
                let available = buffer.count - cursor
                guard available > 0 else { return nil }
                let take = min(remaining, available)
                body.append(contentsOf: buffer[cursor..<(cursor + take)])
                cursor += take
                phase = take == remaining ? .chunkDataEnd : .chunkData(remaining: remaining - take)

            case .chunkDataEnd:
                guard cursor < buffer.count else { return nil }
                if buffer[cursor] == 0x0A {
                    cursor += 1
                } else if buffer[cursor] == 0x0D {
                    guard cursor + 1 < buffer.count else { return nil }
                    guard buffer[cursor + 1] == 0x0A else { throw HTTPParseError(.badRequest, "chunk not followed by CRLF") }
                    cursor += 2
                } else {
                    throw HTTPParseError(.badRequest, "chunk longer than its size")
                }
                phase = .chunkSize

            case .trailers(let used):
                let left = limits.maxHeadBytes - used
                guard let line = try takeLine(limit: left, tooLong: .headerFieldsTooLarge) else { return nil }
                if line.isEmpty {
                    phase = .done
                    let out = body
                    body = []
                    return .body(out)
                }
                phase = .trailers(bytes: used + line.count + 2)

            case .done:
                return nil
            }
        }
    }

    // MARK: - Head

    private mutating func parseHead() throws(HTTPParseError) -> HTTPRequestHead? {
        // RFC 9112 §2.2: ignore empty lines before the request line.
        while cursor < buffer.count, buffer[cursor] == 0x0A || buffer[cursor] == 0x0D {
            if buffer[cursor] == 0x0D, cursor + 1 >= buffer.count { return nil }
            if buffer[cursor] == 0x0D, buffer[cursor + 1] != 0x0A { throw HTTPParseError(.badRequest, "stray CR") }
            cursor += buffer[cursor] == 0x0D ? 2 : 1
            headScanFrom = cursor
        }
        guard let (headEnd, bodyStart) = findHeadEnd() else {
            if buffer.count - cursor > limits.maxHeadBytes {
                throw HTTPParseError(.headerFieldsTooLarge, "head over \(limits.maxHeadBytes) bytes")
            }
            return nil
        }
        guard headEnd - cursor <= limits.maxHeadBytes else {
            throw HTTPParseError(.headerFieldsTooLarge, "head over \(limits.maxHeadBytes) bytes")
        }
        let lines = try Self.splitLines(buffer[cursor..<headEnd])
        cursor = bodyStart
        guard let requestLine = lines.first else { throw HTTPParseError(.badRequest, "empty request") }
        let (method, target, version) = try Self.parseRequestLine(requestLine)
        let fieldLines = lines.dropFirst()
        guard fieldLines.count <= limits.maxHeaderCount else {
            throw HTTPParseError(.headerFieldsTooLarge, "more than \(limits.maxHeaderCount) header fields")
        }
        var headers = HTTPHeaders()
        for line in fieldLines { headers.append(try Self.parseField(line)) }
        let framing = try framing(headers, version: version)
        return HTTPRequestHead(method: method, target: target, version: version, headers: headers, framing: framing)
    }

    /// Index of the LF that ends the last header line and the index of the first body byte.
    private mutating func findHeadEnd() -> (Int, Int)? {
        var i = max(cursor, headScanFrom)
        while i < buffer.count {
            if buffer[i] == 0x0A {
                if i + 1 < buffer.count, buffer[i + 1] == 0x0A { return (i, i + 2) }
                if i + 2 < buffer.count, buffer[i + 1] == 0x0D, buffer[i + 2] == 0x0A { return (i, i + 3) }
                if i + 2 >= buffer.count { break } // terminator may still be arriving
            }
            i += 1
        }
        headScanFrom = max(cursor, buffer.count - 3)
        return nil
    }

    /// Lines split on LF with one trailing CR removed; any other CR is an error.
    static func splitLines(_ bytes: ArraySlice<UInt8>) throws(HTTPParseError) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        for raw in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = raw.last == 0x0D ? raw.dropLast() : raw
            if line.contains(0x0D) { throw HTTPParseError(.badRequest, "bare CR in head") }
            lines.append(line)
        }
        return lines
    }

    static func parseRequestLine(_ line: ArraySlice<UInt8>) throws(HTTPParseError) -> (String, String, HTTPVersion) {
        let parts = line.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(ASCIIText.isTokenChar),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw HTTPParseError(.badRequest, "malformed request line")
        }
        let version: HTTPVersion
        switch String(decoding: parts[2], as: UTF8.self) {
        case "HTTP/1.1": version = .http11
        case "HTTP/1.0": version = .http10
        case let v where v.hasPrefix("HTTP/") && v.utf8.count == 8: throw HTTPParseError(.versionNotSupported, v)
        default: throw HTTPParseError(.badRequest, "malformed HTTP version")
        }
        return (String(decoding: parts[0], as: UTF8.self), String(decoding: parts[1], as: UTF8.self), version)
    }

    static func parseField(_ line: ArraySlice<UInt8>) throws(HTTPParseError) -> HTTPField {
        guard let first = line.first, first != 0x20, first != 0x09 else {
            throw HTTPParseError(.badRequest, "obsolete line folding")
        }
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { throw HTTPParseError(.badRequest, "header without colon") }
        let name = line[line.startIndex..<colon]
        // Whitespace between the name and the colon fails the token check (RFC 9112 §5.1: reject).
        guard !name.isEmpty, name.allSatisfy(ASCIIText.isTokenChar) else { throw HTTPParseError(.badRequest, "invalid header name") }
        var value = line[(colon + 1)...]
        while let f = value.first, f == 0x20 || f == 0x09 { value = value.dropFirst() }
        while let l = value.last, l == 0x20 || l == 0x09 { value = value.dropLast() }
        guard !value.contains(where: { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }) else {
            throw HTTPParseError(.badRequest, "control character in header value")
        }
        return HTTPField(name: String(decoding: name, as: UTF8.self), value: String(decoding: value, as: UTF8.self))
    }

    private func framing(_ headers: HTTPHeaders, version: HTTPVersion) throws(HTTPParseError) -> HTTPBodyFraming {
        let te = headers.values("Transfer-Encoding")
        let cl = headers.values("Content-Length")
        if !te.isEmpty {
            // Both headers, or Transfer-Encoding on HTTP/1.0, are the request-smuggling shapes.
            guard cl.isEmpty else { throw HTTPParseError(.badRequest, "Content-Length with Transfer-Encoding") }
            guard version == .http11 else { throw HTTPParseError(.badRequest, "Transfer-Encoding on HTTP/1.0") }
            let codings = te.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { ASCIIText.trimOWS(String($0)) }
            guard codings.count == 1, ASCIIText.equalsIgnoringCase(codings[0], "chunked") else {
                throw HTTPParseError(.notImplemented, "unsupported transfer coding")
            }
            return .chunked
        }
        guard !cl.isEmpty else { return .none }
        var length: Int?
        for item in cl.flatMap({ $0.split(separator: ",", omittingEmptySubsequences: false) }) {
            let digits = ASCIIText.trimOWS(String(item))
            guard !digits.isEmpty, digits.utf8.count <= 15, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let n = Int(digits) else {
                throw HTTPParseError(.badRequest, "invalid Content-Length")
            }
            guard length == nil || length == n else { throw HTTPParseError(.badRequest, "conflicting Content-Length") }
            length = n
        }
        let n = length ?? 0
        guard n <= limits.maxBodyBytes else { throw HTTPParseError(.payloadTooLarge, "body over \(limits.maxBodyBytes) bytes") }
        return .length(n)
    }

    // MARK: - Chunked

    /// One line (without its CR LF / LF), or `nil` when the line end has not arrived.
    private mutating func takeLine(limit: Int, tooLong: HTTPStatus) throws(HTTPParseError) -> ArraySlice<UInt8>? {
        guard let lf = buffer[cursor...].firstIndex(of: 0x0A) else {
            if buffer.count - cursor > limit { throw HTTPParseError(tooLong, "line too long") }
            return nil
        }
        var line = buffer[cursor..<lf]
        if line.last == 0x0D { line = line.dropLast() }
        guard line.count <= limit else { throw HTTPParseError(tooLong, "line too long") }
        if line.contains(0x0D) { throw HTTPParseError(.badRequest, "bare CR") }
        cursor = lf + 1
        return line
    }

    /// `chunk-size [ chunk-ext ]`: up to 8 hex digits (more cannot fit the body limit anyway).
    static func chunkSize(_ line: ArraySlice<UInt8>) throws(HTTPParseError) -> Int {
        let sizePart = line.prefix { $0 != UInt8(ascii: ";") }
        var digits = sizePart[...]
        while let l = digits.last, l == 0x20 || l == 0x09 { digits = digits.dropLast() } // BWS before ';'
        guard !digits.isEmpty, digits.count <= 8 else { throw HTTPParseError(.badRequest, "invalid chunk size") }
        var size = 0
        for c in digits {
            let v: Int
            switch c {
            case 0x30...0x39: v = Int(c - 0x30)
            case 0x41...0x46: v = Int(c - 0x37)
            case 0x61...0x66: v = Int(c - 0x57)
            default: throw HTTPParseError(.badRequest, "invalid chunk size")
            }
            size = size << 4 | v
        }
        return size
    }
}
