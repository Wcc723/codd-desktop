/// HELLO (c→h): `{"proto":1,"client":"CODD/0.1","takeover":bool,"caps":[…]}`.
public struct Hello: Sendable, Equatable {
    public var proto: Int
    public var client: String
    /// Disconnect a currently attached client instead of being refused with `busy`.
    public var takeover: Bool
    public var caps: [String]

    public init(proto: Int = Int(CoddProtocolVersion.current), client: String, takeover: Bool = false, caps: [String] = []) {
        self.proto = proto
        self.client = client
        self.takeover = takeover
        self.caps = caps
    }

    public func jsonValue() -> JSONValue {
        .object([
            JSONMember("proto", .number(proto)),
            JSONMember("client", .string(client)),
            JSONMember("takeover", .bool(takeover)),
            JSONMember("caps", .strings(caps)),
        ])
    }

    /// `proto` is required; everything else is optional so older/newer clients interoperate.
    public init(json: JSONValue) throws(ProtocolError) {
        guard json.objectValue != nil else { throw .badPayload(type: .hello, reason: "not an object") }
        guard let proto = json["proto"]?.intValue else { throw .badPayload(type: .hello, reason: "missing proto") }
        self.proto = proto
        self.client = json["client"]?.stringValue ?? ""
        self.takeover = json["takeover"]?.boolValue ?? false
        self.caps = json["caps"]?.stringArrayValue ?? []
    }
}

/// WELCOME (h→c): session snapshot sent right after an accepted HELLO.
///
/// Fields beyond docs/ARCHITECTURE.md (`holderPid`, `ringSize`, `spawnOffset`, `signaled`, `progress`,
/// `resyncModes`) are additive; decoders ignore unknown keys.
///
/// Replay recipe for a client attaching from `resync`: reset its terminal, apply
/// `resyncModes.restoreSequence()` (modes in effect AT `resync`), then feed OUTPUT. `modes` is the
/// state after `ringEnd` (for a client attaching live); applying it before a replay is wrong for kitty
/// keyboard flags, whose push/pop are not idempotent.
public struct Welcome: Sendable, Equatable {
    public var proto: Int
    public var holder: String
    public var session: String
    public var childPid: Int32
    public var cols: UInt16
    public var rows: UInt16
    /// Oldest stream offset still in the ring.
    public var ringStart: UInt64
    /// Stream offset of the next byte the child will produce.
    public var ringEnd: UInt64
    /// Latest resync point still in the ring (or `ringStart` if none is).
    public var resync: UInt64
    public var modes: TerminalModes
    public var title: String?
    public var cwd: String?
    public var exited: Bool
    public var exitStatus: Int32?
    public var signaled: Bool?
    public var caps: [String]
    public var holderPid: Int32?
    public var ringSize: UInt64?
    /// Stream offset where this holder's child started writing (rings can continue across holders).
    public var spawnOffset: UInt64?
    /// Latest OSC 9;4 progress report.
    public var progress: TerminalProgress?
    /// Terminal modes in effect at `resync` (absent when no resync point survived in the ring and
    /// `resync` fell back to `ringStart`, where the modes are unknown).
    public var resyncModes: TerminalModes?

    public init(
        proto: Int = Int(CoddProtocolVersion.current), holder: String, session: String, childPid: Int32,
        cols: UInt16, rows: UInt16, ringStart: UInt64, ringEnd: UInt64, resync: UInt64,
        modes: TerminalModes = TerminalModes(), title: String? = nil, cwd: String? = nil,
        exited: Bool = false, exitStatus: Int32? = nil, signaled: Bool? = nil, caps: [String] = [],
        holderPid: Int32? = nil, ringSize: UInt64? = nil, spawnOffset: UInt64? = nil,
        progress: TerminalProgress? = nil, resyncModes: TerminalModes? = nil
    ) {
        self.proto = proto
        self.holder = holder
        self.session = session
        self.childPid = childPid
        self.cols = cols
        self.rows = rows
        self.ringStart = ringStart
        self.ringEnd = ringEnd
        self.resync = resync
        self.modes = modes
        self.title = title
        self.cwd = cwd
        self.exited = exited
        self.exitStatus = exitStatus
        self.signaled = signaled
        self.caps = caps
        self.holderPid = holderPid
        self.ringSize = ringSize
        self.spawnOffset = spawnOffset
        self.progress = progress
        self.resyncModes = resyncModes
    }

    public func jsonValue() -> JSONValue {
        .compactObject([
            ("proto", .number(proto)),
            ("holder", .string(holder)),
            ("session", .string(session)),
            ("childPid", .number(childPid)),
            ("cols", .number(Int(cols))),
            ("rows", .number(Int(rows))),
            ("ringStart", .number(ringStart)),
            ("ringEnd", .number(ringEnd)),
            ("resync", .number(resync)),
            ("modes", modes.jsonValue()),
            ("title", title.map(JSONValue.string)),
            ("cwd", cwd.map(JSONValue.string)),
            ("exited", .bool(exited)),
            ("exitStatus", exitStatus.map { .number($0) }),
            ("signaled", signaled.map(JSONValue.bool)),
            ("caps", .strings(caps)),
            ("holderPid", holderPid.map { .number($0) }),
            ("ringSize", ringSize.map { .number($0) }),
            ("spawnOffset", spawnOffset.map { .number($0) }),
            ("progress", progress?.jsonValue()),
            ("resyncModes", resyncModes?.jsonValue()),
        ])
    }

    public init(json: JSONValue) throws(ProtocolError) {
        func required<T>(_ key: String, _ value: T?) throws(ProtocolError) -> T {
            guard let value else { throw .badPayload(type: .welcome, reason: "missing or invalid \(key)") }
            return value
        }
        guard json.objectValue != nil else { throw .badPayload(type: .welcome, reason: "not an object") }
        proto = try required("proto", json["proto"]?.intValue)
        holder = json["holder"]?.stringValue ?? ""
        session = try required("session", json["session"]?.stringValue)
        childPid = Int32(truncatingIfNeeded: json["childPid"]?.int64Value ?? 0)
        cols = try required("cols", json["cols"]?.uint64Value.flatMap { UInt16(exactly: $0) })
        rows = try required("rows", json["rows"]?.uint64Value.flatMap { UInt16(exactly: $0) })
        ringStart = try required("ringStart", json["ringStart"]?.uint64Value)
        ringEnd = try required("ringEnd", json["ringEnd"]?.uint64Value)
        resync = json["resync"]?.uint64Value ?? ringStart
        modes = json["modes"].map(TerminalModes.init(json:)) ?? TerminalModes()
        title = json["title"]?.stringValue
        cwd = json["cwd"]?.stringValue
        exited = json["exited"]?.boolValue ?? false
        exitStatus = json["exitStatus"]?.int64Value.map { Int32(truncatingIfNeeded: $0) }
        signaled = json["signaled"]?.boolValue
        caps = json["caps"]?.stringArrayValue ?? []
        holderPid = json["holderPid"]?.int64Value.map { Int32(truncatingIfNeeded: $0) }
        ringSize = json["ringSize"]?.uint64Value
        spawnOffset = json["spawnOffset"]?.uint64Value
        progress = json["progress"].flatMap(TerminalProgress.init(json:))
        resyncModes = json["resyncModes"].flatMap { $0.objectValue == nil ? nil : TerminalModes(json: $0) }
    }
}

/// ERROR (h→c): `{"code":str,"message":str}`. The holder closes the connection after most errors.
public struct ErrorInfo: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public func jsonValue() -> JSONValue {
        .object([JSONMember("code", .string(code)), JSONMember("message", .string(message))])
    }

    public init(json: JSONValue) throws(ProtocolError) {
        guard let code = json["code"]?.stringValue else { throw .badPayload(type: .error, reason: "missing code") }
        self.code = code
        self.message = json["message"]?.stringValue ?? ""
    }

    public var description: String { "\(code): \(message)" }
}

/// ERROR codes sent by the holder.
public enum HolderErrorCode {
    /// Framing or payload error; the holder closes the connection.
    public static let badFrame = "bad-frame"
    /// A frame other than HELLO arrived before the handshake.
    public static let helloRequired = "hello-required"
    /// HELLO asked for a protocol version this holder does not speak.
    public static let unsupportedProto = "unsupported-proto"
    /// Another client is attached and HELLO did not ask for takeover.
    public static let busy = "busy"
    /// Sent to the previous client when a new HELLO with `takeover:true` replaced it.
    public static let takenOver = "taken-over"
    /// HELLO did not arrive in time.
    public static let helloTimeout = "hello-timeout"
}

/// Capability strings advertised in WELCOME `caps` (and, for opt-in behaviour, listed by the client in
/// HELLO `caps`). Protocol v1 is frozen: new behaviour is added only behind a new capability string.
public enum HolderCapability {
    /// INPUT flag bit0 (submit: `\r` 10 ms after the last payload byte reached the PTY).
    public static let inputSubmit = "input.submit"
    /// REPAINT (shrink by one column, restore once output is quiet).
    public static let repaint = "repaint"
    /// Backpressure plus drop mode with GAP for stalled clients.
    public static let flowControl = "flow"
    /// TITLE frames from OSC 0/2.
    public static let title = "osc.title"
    /// CWD frames from OSC 7.
    public static let cwd = "osc.cwd"
    /// BELL frames.
    public static let bell = "bell"
    /// ATTACHED after every ATTACH (opt-in: the holder sends it only when HELLO `caps` lists it).
    public static let attachAck = "attach.ack"
    /// GAP carries `replayEnd` and the modes in effect at `to` after the v1 fields.
    public static let gapResync = "gap.resync"
    /// ATTACHED carries the current modes after its v1 fields.
    public static let attachModes = "attach.modes"
    /// INPUT flag bit1 (paste): one frame is one paste, bracketed by the holder when the child has
    /// `?2004` on; with submit, `\r` follows 50 ms after the paste reached the PTY. Always on (M2).
    public static let inputPaste = "input.paste"

    /// Everything this holder build advertises in WELCOME.
    public static let v1: [String] = [
        inputSubmit, repaint, flowControl, title, cwd, bell, attachAck, gapResync, attachModes, inputPaste,
    ]
}
