/// A JSON value that keeps what a plain decoder loses: object key order and each number's exact
/// spelling. CODD edits the user's Claude settings, which must change only where CODD changes
/// them; Claude Code itself writes the file with `JSON.stringify(v, null, 2)`, which
/// ``serialized(indent:)`` reproduces, so an untouched file round-trips byte for byte.
public indirect enum OrderedJSON: Sendable, Equatable {
    /// Members in file order. ``parse(_:)`` merges a repeated key like `JSON.parse` does (first
    /// position, last value), so the tree is what Claude Code sees.
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The number token as written (`1e3`, `0.10`, `-0`, `12345678901234567890`); never
    /// re-formatted, so number spellings survive an edit.
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.key != y.key || x.value != y.value { return false }
            return true
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    /// The member `key` of an object (the last one, should a hand-built object repeat it).
    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    public var objectMembers: [(key: String, value: OrderedJSON)]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var arrayElements: [OrderedJSON]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The number as a `Double` (nil for other kinds or a token `Double` cannot read).
    public var doubleValue: Double? {
        if case .number(let token) = self { return Double(token) }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// Replaces `key`'s value in place, or appends the member when it is missing (what assigning
    /// a property does to a JavaScript object). No-op on non-objects.
    mutating func setValue(_ value: OrderedJSON, forKey key: String) {
        guard case .object(var members) = self else { return }
        if let i = members.lastIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append((key: key, value: value))
        }
        self = .object(members)
    }

    /// Removes every member named `key`. No-op on non-objects.
    mutating func removeValue(forKey key: String) {
        guard case .object(var members) = self else { return }
        members.removeAll { $0.key == key }
        self = .object(members)
    }
}
