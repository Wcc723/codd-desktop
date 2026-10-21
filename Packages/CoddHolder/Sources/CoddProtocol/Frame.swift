/// One wire frame: `u32 BE length` (bytes of type + payload) | `u16 BE type` | payload.
public struct Frame: Sendable, Equatable {
    /// Size of the length field.
    public static let lengthFieldSize = 4
    /// Size of the type field.
    public static let typeFieldSize = 2
    /// Bytes before the payload.
    public static let headerSize = lengthFieldSize + typeFieldSize
    /// Largest allowed value of the length field (type + payload): 1 MiB.
    public static let maxLength = 1 << 20
    /// Largest payload that fits in one frame.
    public static let maxPayloadLength = maxLength - typeFieldSize

    public var type: FrameType
    public var payload: [UInt8]

    public init(type: FrameType, payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }

    /// The complete frame bytes.
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Frame.headerSize + payload.count)
        append(to: &out)
        return out
    }

    /// Appends the complete frame to `out`.
    ///
    /// - Precondition: `payload.count <= Frame.maxPayloadLength`. Producers of unbounded data
    ///   (INPUT, OUTPUT) split it; see `Message.inputMessages(_:submit:paste:)`.
    public func append(to out: inout [UInt8]) {
        Frame.appendHeader(type: type, payloadLength: payload.count, to: &out)
        out.append(contentsOf: payload)
    }

    /// Appends only the 6-byte header, for callers that stream the payload themselves.
    public static func appendHeader(type: FrameType, payloadLength: Int, to out: inout [UInt8]) {
        precondition(payloadLength >= 0 && payloadLength <= maxPayloadLength, "frame payload too large")
        WireBytes.append(UInt32(payloadLength + typeFieldSize), to: &out)
        WireBytes.append(type.rawValue, to: &out)
    }
}
