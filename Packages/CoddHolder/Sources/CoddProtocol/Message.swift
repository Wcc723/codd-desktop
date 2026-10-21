/// Typed view of a v1 frame.
///
/// Fixed-layout payloads must be at least as long as their v1 layout; trailing bytes are ignored so
/// future capability-gated extensions stay decodable by v1 peers.
public enum Message: Sendable, Equatable {
    case hello(Hello)
    case welcome(Welcome)
    /// `fromOffset == Message.latestResync` replays from the latest resync point.
    case attach(fromOffset: UInt64)
    case detach
    case output(offset: UInt64, bytes: [UInt8])
    case gap(from: UInt64, to: UInt64)
    case input(flags: InputFlags, bytes: [UInt8])
    case resize(WindowSize)
    case signal(UInt8)
    case repaint
    case exit(ExitInfo)
    case ping(token: UInt64)
    case pong(token: UInt64)
    case title(String)
    case cwd(String)
    case bell
    case error(ErrorInfo)
    /// A frame type this build does not know; receivers ignore it.
    case unknown(type: FrameType, payload: [UInt8])

    /// ATTACH offset meaning "from the latest resync point".
    public static let latestResync = UInt64.max

    /// Largest INPUT data chunk per frame (payload minus the flags byte).
    public static let maxInputChunk = Frame.maxPayloadLength - 1

    /// Splits `bytes` into INPUT messages that each fit in a frame; only the last carries `submit`.
    /// With `paste` every frame carries the paste flag (one frame is one paste for the holder, so a
    /// paste larger than a frame arrives as consecutive pastes).
    public static func inputMessages(_ bytes: [UInt8], submit: Bool, paste: Bool = false) -> [Message] {
        let pasteFlag: InputFlags = paste ? .paste : []
        guard bytes.count > maxInputChunk else {
            return [.input(flags: pasteFlag.union(submit ? .submit : []), bytes: bytes)]
        }
        var messages: [Message] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + maxInputChunk, bytes.count)
            let isLast = end == bytes.count
            messages.append(.input(flags: pasteFlag.union(isLast && submit ? .submit : []), bytes: Array(bytes[start..<end])))
            start = end
        }
        return messages
    }

    public var type: FrameType {
        switch self {
        case .hello: .hello
        case .welcome: .welcome
        case .attach: .attach
        case .detach: .detach
        case .output: .output
        case .gap: .gap
        case .input: .input
        case .resize: .resize
        case .signal: .signal
        case .repaint: .repaint
        case .exit: .exit
        case .ping: .ping
        case .pong: .pong
        case .title: .title
        case .cwd: .cwd
        case .bell: .bell
        case .error: .error
        case .unknown(let type, _): type
        }
    }

    // MARK: - Encoding

    public var frame: Frame {
        Frame(type: type, payload: payload)
    }

    /// Complete frame bytes.
    public func encoded() -> [UInt8] {
        frame.encoded()
    }

    /// Appends the complete frame bytes to `out`.
    public func append(to out: inout [UInt8]) {
        frame.append(to: &out)
    }

    public var payload: [UInt8] {
        var out: [UInt8] = []
        switch self {
        case .hello(let hello): out = hello.jsonValue().serialized()
        case .welcome(let welcome): out = welcome.jsonValue().serialized()
        case .attach(let offset): WireBytes.append(offset, to: &out)
        case .detach, .repaint, .bell: break
        case .output(let offset, let bytes):
            out.reserveCapacity(8 + bytes.count)
            WireBytes.append(offset, to: &out)
            out.append(contentsOf: bytes)
        case .gap(let from, let to):
            WireBytes.append(from, to: &out)
            WireBytes.append(to, to: &out)
        case .input(let flags, let bytes):
            out.reserveCapacity(1 + bytes.count)
            out.append(flags.rawValue)
            out.append(contentsOf: bytes)
        case .resize(let size):
            WireBytes.append(size.cols, to: &out)
            WireBytes.append(size.rows, to: &out)
            WireBytes.append(size.pixelWidth, to: &out)
            WireBytes.append(size.pixelHeight, to: &out)
        case .signal(let signo): out.append(signo)
        case .exit(let info):
            WireBytes.append(UInt32(bitPattern: info.status), to: &out)
            out.append(info.signaled ? 1 : 0)
        case .ping(let token), .pong(let token): WireBytes.append(token, to: &out)
        case .title(let text), .cwd(let text): out = Array(text.utf8)
        case .error(let info): out = info.jsonValue().serialized()
        case .unknown(_, let payload): out = payload
        }
        return out
    }

    // MARK: - Decoding

    public init(frame: Frame) throws(ProtocolError) {
        let payload = frame.payload
        func need(_ count: Int) throws(ProtocolError) {
            if payload.count < count {
                throw .badPayload(type: frame.type, reason: "expected at least \(count) bytes, got \(payload.count)")
            }
        }
        func json() throws(ProtocolError) -> JSONValue {
            do {
                return try JSONValue.parse(payload, maxDepth: 16)
            } catch {
                throw .badJSON(type: frame.type, reason: error.description)
            }
        }
        switch frame.type {
        case .hello:
            self = .hello(try Hello(json: try json()))
        case .welcome:
            self = .welcome(try Welcome(json: try json()))
        case .attach:
            try need(8)
            self = .attach(fromOffset: WireBytes.readUInt64(payload, at: 0))
        case .detach:
            self = .detach
        case .output:
            try need(8)
            self = .output(offset: WireBytes.readUInt64(payload, at: 0), bytes: Array(payload[8...]))
        case .gap:
            try need(16)
            self = .gap(from: WireBytes.readUInt64(payload, at: 0), to: WireBytes.readUInt64(payload, at: 8))
        case .input:
            try need(1)
            self = .input(flags: InputFlags(rawValue: payload[0]), bytes: Array(payload[1...]))
        case .resize:
            try need(8)
            self = .resize(WindowSize(
                cols: WireBytes.readUInt16(payload, at: 0),
                rows: WireBytes.readUInt16(payload, at: 2),
                pixelWidth: WireBytes.readUInt16(payload, at: 4),
                pixelHeight: WireBytes.readUInt16(payload, at: 6)))
        case .signal:
            try need(1)
            self = .signal(payload[0])
        case .repaint:
            self = .repaint
        case .exit:
            try need(5)
            self = .exit(ExitInfo(status: Int32(bitPattern: WireBytes.readUInt32(payload, at: 0)), signaled: payload[4] != 0))
        case .ping:
            try need(8)
            self = .ping(token: WireBytes.readUInt64(payload, at: 0))
        case .pong:
            try need(8)
            self = .pong(token: WireBytes.readUInt64(payload, at: 0))
        case .title:
            self = .title(String(decoding: payload, as: UTF8.self))
        case .cwd:
            self = .cwd(String(decoding: payload, as: UTF8.self))
        case .bell:
            self = .bell
        case .error:
            self = .error(try ErrorInfo(json: try json()))
        default:
            self = .unknown(type: frame.type, payload: payload)
        }
    }
}
