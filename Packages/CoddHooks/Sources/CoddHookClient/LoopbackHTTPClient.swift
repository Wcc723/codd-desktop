import Darwin

/// A point on the monotonic clock after which an operation gives up.
public struct MonotonicDeadline: Sendable, Equatable {
    /// `CLOCK_UPTIME_RAW` nanoseconds.
    public var nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// `now + milliseconds`.
    public static func after(milliseconds: Int) -> MonotonicDeadline {
        MonotonicDeadline(nanoseconds: now() + UInt64(max(0, milliseconds)) * 1_000_000)
    }

    @inline(__always) public static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public var hasPassed: Bool { Self.now() >= nanoseconds }

    /// Milliseconds left for poll(2), rounded up so a short remainder never becomes a busy loop of
    /// zero timeouts; 0 once passed.
    public var pollTimeout: Int32 {
        let now = Self.now()
        guard nanoseconds > now else { return 0 }
        return Int32(min(UInt64(Int32.max), (nanoseconds - now + 999_999) / 1_000_000))
    }
}

/// Why a loopback request did not produce a response.
public enum LoopbackHTTPError: Error, Sendable, Equatable {
    case socket(errno: Int32)
    case connect(errno: Int32)
    case send(errno: Int32)
    case receive(errno: Int32)
    case timedOut(stage: Stage)
    /// The peer closed the connection before a complete response head.
    case closedEarly
    case malformedResponse
    case responseTooLarge

    public enum Stage: String, Sendable {
        case connect, send, receive
    }
}

/// The parts of an HTTP response a hook client needs.
public struct LoopbackHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: [UInt8]

    public init(status: Int, body: [UInt8]) {
        self.status = status
        self.body = body
    }
}

/// Minimal blocking HTTP/1.1 client for 127.0.0.1, built on a non-blocking socket and poll(2) so
/// every step obeys one deadline. One request per connection (`Connection: close`).
public enum LoopbackHTTPClient {
    public static let userAgent = "codd-hook/1"
    /// Response heads and bodies from the CODD endpoint are tiny; anything larger is not CODD.
    public static let maxResponseBytes = 64 * 1024

    /// Serialises a request. Header names and values must already be safe (see
    /// ``ASCII/isSafeHeaderValue(_:)``); `Host`, `Content-Length`, `Connection` and `User-Agent`
    /// are added here.
    public static func requestBytes(
        method: String, url: LoopbackURL, headers: [(String, String)], body: [UInt8], userAgent: String = userAgent
    ) -> [UInt8] {
        var head = "\(method) \(url.target) HTTP/1.1\r\nHost: \(url.authority)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if !body.isEmpty || method == "POST" { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\nUser-Agent: \(userAgent)\r\n\r\n"
        return Array(head.utf8) + body
    }

    /// Connects to 127.0.0.1:`port`, sends `request` and reads one response (skipping `1xx`).
    public static func send(
        _ request: [UInt8], port: UInt16, deadline: MonotonicDeadline, isHead: Bool = false
    ) -> Result<LoopbackHTTPResponse, LoopbackHTTPError> {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno: errno)) }
        defer { close(fd) }
        var one: Int32 = 1
        // A peer reset must surface as EPIPE, never as SIGPIPE (which would kill codd-hook with a
        // non-zero status inside Claude's hook runner).
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        if let failure = connectLoopback(fd, port: port, deadline: deadline) { return .failure(failure) }
        if let failure = writeAll(fd, request, deadline: deadline) { return .failure(failure) }
        return readResponse(fd, deadline: deadline, isHead: isHead)
    }

    static func connectLoopback(_ fd: Int32, port: UInt16, deadline: MonotonicDeadline) -> LoopbackHTTPError? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return nil }
        guard errno == EINPROGRESS || errno == EINTR else { return .connect(errno: errno) }
        while true {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, deadline.pollTimeout)
            if n < 0, errno == EINTR { continue }
            if n < 0 { return .connect(errno: errno) }
            if n == 0 { return .timedOut(stage: .connect) }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0 else { return .connect(errno: errno) }
            return soError == 0 ? nil : .connect(errno: soError)
        }
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: MonotonicDeadline) -> LoopbackHTTPError? {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR { continue }
            guard n < 0, errno == EAGAIN else { return .send(errno: n < 0 ? errno : EPIPE) }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&p, 1, deadline.pollTimeout)
            if ready == 0 { return .timedOut(stage: .send) }
            if ready < 0, errno != EINTR { return .send(errno: errno) }
        }
        return nil
    }

    static func readResponse(
        _ fd: Int32, deadline: MonotonicDeadline, isHead: Bool
    ) -> Result<LoopbackHTTPResponse, LoopbackHTTPError> {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var eof = false
        while true {
            switch ResponseScanner.scan(buffer, eof: eof, isHead: isHead) {
            case .complete(let response): return .success(response)
            case .malformed: return .failure(.malformedResponse)
            case .needMore:
                if eof { return .failure(.closedEarly) }
            }
            if buffer.count > maxResponseBytes { return .failure(.responseTooLarge) }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                eof = true
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, deadline.pollTimeout)
                if ready == 0 { return .failure(.timedOut(stage: .receive)) }
                if ready < 0, errno != EINTR { return .failure(.receive(errno: errno)) }
            } else if errno == ECONNRESET, !buffer.isEmpty {
                eof = true // a reset after the response still leaves a usable response
            } else {
                return .failure(.receive(errno: errno))
            }
        }
    }
}

/// Finds one complete response in received bytes.
enum ResponseScanner {
    enum Result: Equatable {
        case needMore
        case malformed
        case complete(LoopbackHTTPResponse)
    }

    static func scan(_ bytes: [UInt8], eof: Bool, isHead: Bool) -> Result {
        var start = 0
        while true {
            guard let headEnd = findHeadEnd(bytes, from: start) else { return .needMore }
            guard let (status, contentLength) = parseHead(bytes[start..<headEnd.lineEnd]) else { return .malformed }
            let bodyStart = headEnd.bodyStart
            if (100..<200).contains(status) {
                start = bodyStart // 100 Continue and friends precede the real response
                continue
            }
            if isHead || status == 204 || status == 304 {
                return .complete(LoopbackHTTPResponse(status: status, body: []))
            }
            if let contentLength {
                guard bytes.count - bodyStart >= contentLength else { return .needMore }
                return .complete(LoopbackHTTPResponse(status: status, body: Array(bytes[bodyStart..<(bodyStart + contentLength)])))
            }
            // No length: the body runs to the end of the connection.
            return eof ? .complete(LoopbackHTTPResponse(status: status, body: Array(bytes[bodyStart...]))) : .needMore
        }
    }

    /// The end of the head (`\r\n\r\n`, or `\n\n` from a lenient peer).
    static func findHeadEnd(_ b: [UInt8], from start: Int) -> (lineEnd: Int, bodyStart: Int)? {
        var i = start
        while i < b.count {
            if b[i] == 0x0A {
                if i + 1 < b.count, b[i + 1] == 0x0A { return (i, i + 2) }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { return (i, i + 3) }
            }
            i += 1
        }
        return nil
    }

    /// Status code and `Content-Length` (if present and valid).
    static func parseHead(_ head: ArraySlice<UInt8>) -> (Int, Int?)? {
        let lines = head.split(separator: 0x0A, omittingEmptySubsequences: false).map { line -> ArraySlice<UInt8> in
            line.last == 0x0D ? line.dropLast() : line
        }
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: 0x20, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].starts(with: Array("HTTP/1.".utf8)), parts[1].count == 3,
              parts[1].allSatisfy(ASCII.isDigit) else { return nil }
        let status = parts[1].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { continue }
            guard ASCII.equalsIgnoringCase(line[..<colon], Array("content-length".utf8)) else { continue }
            let value = line[(colon + 1)...].drop { $0 == 0x20 || $0 == 0x09 }
            let digits = value.prefix { ASCII.isDigit($0) }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            contentLength = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        return (status, contentLength)
    }
}
