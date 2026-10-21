/// A minimal JSON document model (Foundation-free) for the small handshake payloads and meta.json.
///
/// Integers keep full 64-bit precision (stream offsets are u64), objects keep member order so the
/// serialized form is deterministic.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Non-negative integers above `Int64.max`.
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    /// Builds an object, skipping members whose value is `nil` (optional fields).
    public static func compactObject(_ members: [(String, JSONValue?)]) -> JSONValue {
        .object(members.compactMap { key, value in value.map { JSONMember(key, $0) } })
    }

    public static func number(_ value: UInt64) -> JSONValue {
        value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
    }

    public static func number(_ value: Int) -> JSONValue { .int(Int64(value)) }

    public static func number(_ value: Int32) -> JSONValue { .int(Int64(value)) }

    public static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    /// Member lookup on objects (first match); `nil` for other kinds or a missing key.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [JSONMember]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Integral value as Int64 (doubles must be integral and in range).
    public var int64Value: Int64? {
        switch self {
        case .int(let value): return value
        case .uint: return nil
        case .double(let value):
            guard value.rounded() == value, value >= -9.2e18, value <= 9.2e18 else { return nil }
            return Int64(value)
        default: return nil
        }
    }

    /// Integral non-negative value as UInt64.
    public var uint64Value: UInt64? {
        switch self {
        case .int(let value): return value >= 0 ? UInt64(value) : nil
        case .uint(let value): return value
        case .double(let value):
            guard value.rounded() == value, value >= 0, value <= 1.8e19 else { return nil }
            return UInt64(value)
        default: return nil
        }
    }

    public var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .uint(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// Array of strings; non-string elements are skipped.
    public var stringArrayValue: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }
}

/// One object member. A struct (not a tuple) so `JSONValue` can be `Equatable`.
public struct JSONMember: Sendable, Equatable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// JSON parse failure with the byte position where it was detected.
public struct JSONError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var position: Int

    public init(_ message: String, at position: Int) {
        self.message = message
        self.position = position
    }

    public var description: String { "\(message) at byte \(position)" }
}
