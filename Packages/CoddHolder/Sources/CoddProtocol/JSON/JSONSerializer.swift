extension JSONValue {
    /// Compact UTF-8 serialization. Non-finite doubles become `null`.
    public func serialized() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        JSONValue.write(self, to: &out)
        return out
    }

    public func serializedString() -> String {
        String(decoding: serialized(), as: UTF8.self)
    }

    private static func write(_ value: JSONValue, to out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let flag):
            out.append(contentsOf: (flag ? "true" : "false").utf8)
        case .int(let number):
            out.append(contentsOf: String(number).utf8)
        case .uint(let number):
            out.append(contentsOf: String(number).utf8)
        case .double(let number):
            writeDouble(number, to: &out)
        case .string(let text):
            writeString(text, to: &out)
        case .array(let elements):
            out.append(UInt8(ascii: "["))
            for (position, element) in elements.enumerated() {
                if position > 0 { out.append(UInt8(ascii: ",")) }
                write(element, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (position, member) in members.enumerated() {
                if position > 0 { out.append(UInt8(ascii: ",")) }
                writeString(member.key, to: &out)
                out.append(UInt8(ascii: ":"))
                write(member.value, to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeDouble(_ number: Double, to out: inout [UInt8]) {
        guard number.isFinite else {
            out.append(contentsOf: "null".utf8)
            return
        }
        if number.rounded() == number, abs(number) < 9.0e15 {
            out.append(contentsOf: String(Int64(number)).utf8)
        } else {
            // Swift's shortest round-trip representation is valid JSON for finite values.
            out.append(contentsOf: number.description.utf8)
        }
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func writeString(_ text: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x00..<0x20, 0x7F:
                out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
