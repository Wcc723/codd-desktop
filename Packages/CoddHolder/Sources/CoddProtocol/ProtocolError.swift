/// Errors raised while decoding frames or message payloads.
public enum ProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The length field is below the minimum (2 bytes for the type).
    case frameTooShort(length: UInt32)
    /// The length field exceeds `Frame.maxLength` (1 MiB). The stream is not trustworthy any more.
    case frameTooLarge(length: UInt32)
    /// A known frame type carried a payload that does not match its layout.
    case badPayload(type: FrameType, reason: String)
    /// A JSON payload could not be parsed.
    case badJSON(type: FrameType, reason: String)

    public var description: String {
        switch self {
        case .frameTooShort(let length): "frame length \(length) is below the minimum of 2"
        case .frameTooLarge(let length): "frame length \(length) exceeds the 1 MiB limit"
        case .badPayload(let type, let reason): "bad \(type) payload: \(reason)"
        case .badJSON(let type, let reason): "bad \(type) JSON: \(reason)"
        }
    }
}
