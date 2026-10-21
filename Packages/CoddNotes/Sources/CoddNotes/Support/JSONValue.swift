import Foundation

/// A JSON value that keeps what CODD does not understand (unknown annotation keys, §3.3) and
/// serializes compactly with CJK unescaped and a caller-chosen key order.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Compact JSON; object keys sorted (callers that need a specific order build the text themselves).
    func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 { out += String(Int(d)) } else if d.isFinite { out += String(d) } else { out += "null" }
        case .string(let s): JSONText.appendString(s, to: &out)
        case .array(let a):
            out += "["
            for (k, v) in a.enumerated() {
                if k > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (k, key) in o.keys.sorted().enumerated() {
                if k > 0 { out += "," }
                JSONText.appendString(key, to: &out)
                out += ":"
                o[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.isFinite: Int(d.rounded())
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

enum JSONText {
    /// A JSON string literal: only `"`, `\` and control characters are escaped, so CJK stays readable.
    static func appendString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    static func quoted(_ s: String) -> String {
        var out = ""
        appendString(s, to: &out)
        return out
    }
}
