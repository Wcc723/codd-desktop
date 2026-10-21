import CoddHolderClient
import CoddProtocol

/// Shared bits of the connecting subcommands.
enum ConnectionHelpers {
    static let clientName = "codd-holderctl/0.1"

    /// Connects and completes the handshake.
    static func open(_ options: CommandLineOptions) throws -> (HolderConnection, Welcome) {
        let connection = try HolderConnection(socketPath: try options.required("--socket"))
        let welcome = try connection.handshake(client: clientName, takeover: options.has("--takeover"))
        return (connection, welcome)
    }

    /// `--from start|resync|live|<offset>` → ATTACH offset.
    static func attachOffset(_ text: String?, welcome: Welcome, default fallback: String) throws -> UInt64 {
        switch text ?? fallback {
        case "start": return welcome.ringStart
        case "resync": return Message.latestResync
        case "live": return welcome.ringEnd
        case let other:
            guard let value = UInt64(other) else {
                throw CommandLineOptions.Failure(description: "--from must be start, resync, live or an offset")
            }
            return value
        }
    }

    /// Interprets `\n \r \t \e \\ \xHH` in `text`.
    static func unescape(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var bytes = Array(text.utf8)[...]
        while let byte = bytes.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = bytes.popFirst() else {
                out.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "e"): out.append(0x1B)
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "x"):
                let digits = String(decoding: bytes.prefix(2), as: UTF8.self)
                if digits.count == 2, let value = UInt8(digits, radix: 16) {
                    out.append(value)
                    bytes = bytes.dropFirst(2)
                } else {
                    out.append(contentsOf: [UInt8(ascii: "\\"), next])
                }
            default:
                out.append(contentsOf: [UInt8(ascii: "\\"), next])
            }
        }
        return out
    }
}
