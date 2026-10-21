/// Protocol version spoken by this build (HELLO / WELCOME `proto`).
public enum CoddProtocolVersion {
    public static let current: UInt16 = 1
}

/// Frame type codes of holder wire protocol v1 (docs/ARCHITECTURE.md, "Holder wire protocol v1").
///
/// A struct rather than an enum so that codes from newer peers survive decoding; receivers ignore
/// types they do not know (the protocol is extended only through capability flags).
public struct FrameType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// c→h, JSON handshake.
    public static let hello = FrameType(rawValue: 0x0001)
    /// h→c, JSON handshake reply.
    public static let welcome = FrameType(rawValue: 0x0002)
    /// c→h, `u64 fromOffset` (`UInt64.max` = latest resync point).
    public static let attach = FrameType(rawValue: 0x0003)
    /// c→h, stop streaming OUTPUT (the connection stays open).
    public static let detach = FrameType(rawValue: 0x0004)
    /// h→c, `u64 offset` + bytes.
    public static let output = FrameType(rawValue: 0x0010)
    /// h→c, `u64 from`, `u64 to` (+ `u64 replayEnd` and a mode snapshot, capability `gap.resync`).
    public static let gap = FrameType(rawValue: 0x0011)
    /// h→c, marks where the OUTPUT of an ATTACH begins (capability `attach.ack`, sent only to clients
    /// that list it in HELLO `caps`). Decoded as `Message.unknown`; use `AttachedInfo(payload:)`.
    public static let attached = FrameType(rawValue: 0x0012)
    /// c→h, `u8 flags` + bytes.
    public static let input = FrameType(rawValue: 0x0020)
    /// c→h, `u16 cols, u16 rows, u16 pxW, u16 pxH`.
    public static let resize = FrameType(rawValue: 0x0021)
    /// c→h, `u8 signo`.
    public static let signal = FrameType(rawValue: 0x0022)
    /// c→h, no payload.
    public static let repaint = FrameType(rawValue: 0x0023)
    /// h→c, `i32 status`, `u8 signaled`.
    public static let exit = FrameType(rawValue: 0x0030)
    /// both, `u64 token`.
    public static let ping = FrameType(rawValue: 0x0040)
    /// both, `u64 token`.
    public static let pong = FrameType(rawValue: 0x0041)
    /// h→c, UTF-8 title.
    public static let title = FrameType(rawValue: 0x0050)
    /// h→c, UTF-8 path.
    public static let cwd = FrameType(rawValue: 0x0051)
    /// h→c, no payload.
    public static let bell = FrameType(rawValue: 0x0052)
    /// h→c, JSON `{"code","message"}`.
    public static let error = FrameType(rawValue: 0x00FF)

    public var name: String? {
        switch self {
        case .hello: "HELLO"
        case .welcome: "WELCOME"
        case .attach: "ATTACH"
        case .detach: "DETACH"
        case .output: "OUTPUT"
        case .gap: "GAP"
        case .attached: "ATTACHED"
        case .input: "INPUT"
        case .resize: "RESIZE"
        case .signal: "SIGNAL"
        case .repaint: "REPAINT"
        case .exit: "EXIT"
        case .ping: "PING"
        case .pong: "PONG"
        case .title: "TITLE"
        case .cwd: "CWD"
        case .bell: "BELL"
        case .error: "ERROR"
        default: nil
        }
    }

    public var description: String {
        if let name { return name }
        let hex = String(rawValue, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}
