/// A JSON value as the server reads and writes it.
///
/// Objects keep their members in order (the writer emits them as built, so responses and the
/// golden fixtures are stable) and numbers keep their JSON text (a request id is echoed exactly
/// as the client wrote it). Internal: the public API speaks Swift types, never JSON.
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSON? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var number: JSONNumber? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The value as an integer when it is a number with no fractional part that fits an `Int`.
    var int: Int? { number?.integerValue }

    var array: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var object: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }
}

/// A JSON number, stored as its text.
struct JSONNumber: Sendable, Equatable, CustomStringConvertible {
    /// Valid JSON number text (the parser checked the grammar; the initialisers produce it).
    let text: String

    init(_ value: Int) { text = String(value) }

    /// Nil for NaN and infinities, which JSON cannot carry.
    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        if value == value.rounded(.towardZero), abs(value) < 9.0e15 {
            text = String(Int64(value))
        } else {
            text = String(value)
        }
    }

    /// Text already known to match the JSON number grammar (the parser's output).
    init(validatedText: String) { text = validatedText }

    var doubleValue: Double { Double(text) ?? .nan }

    var integerValue: Int? {
        if let exact = Int(text) { return exact }
        let value = doubleValue
        guard value.isFinite, value == value.rounded(.towardZero),
              value >= -9.0e18, value <= 9.0e18 else { return nil }
        return Int(value)
    }

    var description: String { text }
}

/// A JSON object with its members in order. Lookups take the last member of a name, like
/// `JSON.parse` in JavaScript (what Claude Code would see for a duplicated key).
struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private(set) var members: [(key: String, value: JSON)]

    init() { members = [] }

    init(_ members: [(key: String, value: JSON)]) { self.members = members }

    init(dictionaryLiteral elements: (String, JSON)...) {
        members = elements.map { (key: $0.0, value: $0.1) }
    }

    subscript(key: String) -> JSON? {
        get { members.last(where: { $0.key == key })?.value }
        set {
            if let index = members.lastIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append((key: key, value: newValue))
            }
        }
    }

    /// Adds a member without looking for an earlier one of the same name (the parser: O(1) per
    /// member, so a body with 100k keys stays linear; lookups still see the last duplicate).
    mutating func append(_ key: String, _ value: JSON) {
        members.append((key: key, value: value))
    }

    var keys: [String] { members.map(\.key) }
    var isEmpty: Bool { members.isEmpty }
    var count: Int { members.count }

    static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.members.count == rhs.members.count
            && zip(lhs.members, rhs.members).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

/// Literals for building responses. Deliberately not `ExpressibleByNilLiteral`: `cond ? x : nil`
/// would then type-check as JSON `null` instead of an absent optional member.
extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(JSONNumber(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(JSONObject(elements.map { (key: $0.0, value: $0.1) }))
    }

    static func integer(_ value: Int) -> JSON { .number(JSONNumber(value)) }
}
