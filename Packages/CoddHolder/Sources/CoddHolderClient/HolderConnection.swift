import CoddPosix
import CoddProtocol
import Darwin

/// Errors of the blocking client.
public enum HolderClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case system(SystemError)
    case protocolViolation(ProtocolError)
    /// The holder closed the connection.
    case closed
    /// The holder answered the handshake with ERROR.
    case rejected(ErrorInfo)
    /// No reply within the timeout.
    case timeout
    /// A frame that does not fit the current exchange.
    case unexpected(FrameType)

    public var description: String {
        switch self {
        case .system(let error): error.description
        case .protocolViolation(let error): "protocol error: \(error)"
        case .closed: "connection closed by holder"
        case .rejected(let info): "holder refused: \(info)"
        case .timeout: "timed out waiting for the holder"
        case .unexpected(let type): "unexpected \(type) frame"
        }
    }
}

/// Blocking, single-threaded connection to a holder socket (for codd-holderctl and tests; the app
/// uses `HolderStream`). Not thread-safe.
public final class HolderConnection {
    public let fd: Int32
    private var decoder = FrameDecoder()
    private var readBuffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var reachedEOF = false
    public private(set) var isClosed = false
    /// WELCOME of the handshake (nil before it).
    public private(set) var welcome: Welcome?
    /// Newest modes the holder reported: WELCOME `modes`, then each ATTACHED's current modes (only
    /// with `attach.ack` in the handshake `caps`). Brackets a paste for a holder without `input.paste`.
    public private(set) var newestModes: TerminalModes?

    /// Receive buffer requested on the client side (the AF_UNIX default is 8 KiB).
    public static let receiveBufferBytes: Int32 = 1 << 20

    public init(socketPath: String) throws(HolderClientError) {
        do {
            fd = try UnixSocket.connect(path: socketPath)
        } catch {
            throw .system(error)
        }
        UnixSocket.setBufferSizes(fd, send: 256 << 10, receive: Self.receiveBufferBytes)
    }

    deinit {
        close()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Descriptor.closeQuietly(fd)
    }

    /// HELLO → WELCOME. Throws `.rejected` when the holder answers with ERROR (busy, proto, …).
    /// `caps` opts into capability-gated frames (e.g. `attach.ack`); none by default.
    public func handshake(
        client: String = "codd-holderctl/0.1", takeover: Bool = false, caps: [String] = [], timeoutMilliseconds: Int = 5000
    ) throws(HolderClientError) -> Welcome {
        try send(.hello(Hello(client: client, takeover: takeover, caps: caps)))
        guard let reply = try receive(timeoutMilliseconds: timeoutMilliseconds) else { throw .timeout }
        switch reply {
        case .welcome(let welcome):
            self.welcome = welcome
            newestModes = welcome.modes
            return welcome
        case .error(let info): throw .rejected(info)
        default: throw .unexpected(reply.type)
        }
    }

    public func send(_ message: Message) throws(HolderClientError) {
        do {
            try Descriptor.writeAll(fd, message.encoded())
        } catch {
            throw .system(error)
        }
    }

    /// WELCOME `caps` lists `input.paste` (false before the handshake).
    public var supportsPaste: Bool { welcome?.caps.contains(HolderCapability.inputPaste) ?? false }

    /// INPUT in one write, split into frames; only the last carries `submit`. `paste` as in
    /// `HolderStream.sendInput`: the holder brackets when it has `input.paste`, otherwise this
    /// connection does when `newestModes` have `?2004` (send it after the handshake).
    public func sendInput(_ bytes: [UInt8], submit: Bool = false, paste: Bool = false) throws(HolderClientError) {
        let (payload, pasteFlag) = InputFraming.prepare(
            bytes, paste: paste, holderSupportsPaste: supportsPaste, modes: newestModes)
        var frames: [UInt8] = []
        InputFraming.appendFrames(payload, submit: submit, paste: pasteFlag, to: &frames)
        do {
            try Descriptor.writeAll(fd, frames)
        } catch {
            throw .system(error)
        }
    }

    /// Sends several messages with one write (e.g. split INPUT).
    public func send(_ messages: [Message]) throws(HolderClientError) {
        var bytes: [UInt8] = []
        for message in messages { message.append(to: &bytes) }
        do {
            try Descriptor.writeAll(fd, bytes)
        } catch {
            throw .system(error)
        }
    }

    /// Next message, or nil after `timeoutMilliseconds` (0 = only what is available now,
    /// negative = wait forever). Throws `.closed` at end of stream.
    public func receive(timeoutMilliseconds: Int) throws(HolderClientError) -> Message? {
        let deadline = timeoutMilliseconds < 0
            ? UInt64.max
            : Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        while true {
            if let message = try nextBuffered() { return message }
            if reachedEOF { throw .closed }
            let now = Clock.monotonicNanoseconds()
            let waitMilliseconds: Int32
            if deadline == UInt64.max {
                waitMilliseconds = -1
            } else {
                waitMilliseconds = now >= deadline ? 0 : Int32(clamping: (deadline - now + 999_999) / 1_000_000)
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, waitMilliseconds)
            if ready < 0 && errno != EINTR { throw .system(.current("poll")) }
            if ready > 0 {
                try fill()
            } else if waitMilliseconds == 0 {
                return nil
            }
        }
    }

    /// True when decoded-but-unreturned frames are buffered (so callers polling the fd do not stall).
    public var hasBufferedData: Bool { decoder.bufferedByteCount > 0 }

    /// Reads once (blocking until data or EOF) into the decoder.
    private func fill() throws(HolderClientError) {
        let count = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            readBuffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        } else if count == 0 {
            reachedEOF = true
        } else if errno != EINTR && errno != EAGAIN {
            if errno == ECONNRESET {
                reachedEOF = true
            } else {
                throw .system(.current("read"))
            }
        }
    }

    private func nextBuffered() throws(HolderClientError) -> Message? {
        do throws(ProtocolError) {
            guard let frame = try decoder.next() else { return nil }
            // Only peeked at (the frame is still returned as `.unknown`): a short one is not an error here.
            if frame.type == .attached, let current = (try? AttachedInfo(payload: frame.payload))?.currentModes {
                newestModes = current
            }
            return try Message(frame: frame)
        } catch {
            throw .protocolViolation(error)
        }
    }
}
