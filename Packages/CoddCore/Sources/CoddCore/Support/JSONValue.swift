import Foundation

/// A loosely typed JSON value.
///
/// Hook payloads, registry files and cswap output are undocumented or evolving formats, so the
/// decoders in CoddCore read them through this type and apply JavaScript-compatible rules
/// (`typeof v === 'string'`, truthiness, `??`) instead of failing on an unexpected shape.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The string payload, if this is a string (any content, including blank).
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The numeric payload, if this is a number.
    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The boolean payload, if this is a boolean.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The members, if this is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The elements, if this is an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Member lookup; `nil` when this is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// JavaScript truthiness (`null`, `false`, `0`, `NaN` and `""` are falsy).
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// `Number.isInteger(v) && v >= 0` as an `Int`, else `nil`.
    public var nonNegativeIntegerValue: Int? {
        guard case .number(let n) = self, n.isFinite, n >= 0, n.rounded(.towardZero) == n,
              n < 9_007_199_254_740_992 else { return nil }
        return Int(n)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue {
    /// Parses JSON bytes; `nil` when they are not valid JSON.
    ///
    /// ECMAScript `JSON.parse` accepts unpaired UTF-16 surrogate escapes (`"\ud83d"`), and
    /// `JSON.stringify` emits them for strings cut in the middle of a surrogate pair (a truncated
    /// tool output in a hook payload, for example). Foundation rejects the whole document, which
    /// would silently drop the event, so on failure the parse is retried with every unpaired
    /// surrogate escape replaced by `�` (only that string value differs from the JS result).
    /// Known remaining difference: duplicate object keys keep the FIRST value (JS keeps the last);
    /// `JSON.stringify` output never contains duplicates.
    ///
    /// Arrays and objects nested deeper than ``maximumNestingDepth`` become `null` (decoding recurses
    /// per level; see `JSONNesting`), and so do the values of `nullingTopLevelKeys` in a top-level
    /// object, which are skipped without being decoded.
    public static func parse(_ data: Data, nullingTopLevelKeys: Set<String> = []) -> JSONValue? {
        let data = JSONNesting.pruned(data, maxDepth: maximumNestingDepth, nullingTopLevelKeys: nullingTopLevelKeys) ?? data
        if let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v }
        guard let repaired = replacingUnpairedSurrogateEscapes(data) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: repaired)
    }

    /// `data` with unpaired `\uD800`–`\uDFFF` escapes replaced by `�`, or `nil` when there are
    /// none (nothing to repair). Backslashes only occur inside JSON strings, so no string tracking
    /// is needed: every `\` starts an escape whose second byte is skipped.
    static func replacingUnpairedSurrogateEscapes(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var out: [UInt8] = []
        var changed = false
        var i = 0
        func unit(at j: Int) -> UInt16? {
            guard j + 6 <= b.count, b[j] == 0x5C, b[j + 1] == 0x75 else { return nil } // \u
            var v: UInt16 = 0
            for k in 2..<6 {
                guard let h = hexValue(b[j + k]) else { return nil }
                v = v << 4 | UInt16(h)
            }
            return v
        }
        while i < b.count {
            guard b[i] == 0x5C, i + 1 < b.count else {
                out.append(b[i])
                i += 1
                continue
            }
            guard let u = unit(at: i) else {
                out.append(contentsOf: b[i...(i + 1)]) // other escape: copy both bytes
                i += 2
                continue
            }
            if (0xD800...0xDBFF).contains(u), let low = unit(at: i + 6), (0xDC00...0xDFFF).contains(low) {
                out.append(contentsOf: b[i..<(i + 12)]) // a proper pair
                i += 12
            } else if (0xD800...0xDFFF).contains(u) {
                out.append(contentsOf: Array(#"�"#.utf8))
                changed = true
                i += 6
            } else {
                out.append(contentsOf: b[i..<(i + 6)])
                i += 6
            }
        }
        return changed ? Data(out) : nil
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x37
        case 0x61...0x66: return c - 0x57
        default: return nil
        }
    }

    /// Port of status-writer.js `safeParse(readStdin())`: bytes are decoded as UTF-8 with
    /// replacement characters (like `Buffer.toString('utf8')`); blank, invalid or non-object JSON
    /// yields an empty object.
    public static func parseObjectLeniently(_ data: Data, nullingTopLevelKeys: Set<String> = []) -> [String: JSONValue] {
        let text = String(decoding: data, as: UTF8.self)
        guard !JSText.trim(text).isEmpty else { return [:] }
        return parse(Data(text.utf8), nullingTopLevelKeys: nullingTopLevelKeys)?.objectValue ?? [:]
    }

    /// Deepest array / object nesting `parse` decodes. Every format CODD reads is a few levels deep;
    /// 64 keeps the recursive decode far from the 512 KiB stack of a dispatch worker thread.
    public static let maximumNestingDepth = 64

    /// Serializes to compact JSON with sorted keys (deterministic output for tests and argv).
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value if present and of the right type; any mismatch yields `nil` instead of an error.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// Decodes an array while skipping elements that fail to decode (instead of failing the whole array).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                out.append(value)
            } else if (try? container.decode(JSONValue.self)) == nil {
                break // cannot advance past this element; stop rather than loop forever
            }
        }
        elements = out
    }
}

/// Literal conformances (deliberately NOT `ExpressibleByNilLiteral`: it would make `nil` in
/// `flatMap { … nil … }` closures silently mean `.null`).
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
