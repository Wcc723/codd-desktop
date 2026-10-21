import Foundation

/// A parsed JSON value. preferences.json is read into this rather than straight into the model, so
/// one bad field falls back to its default alone and keys this version does not know (a newer
/// CODD's, a hand edit's) survive the next save.
enum PrefJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([PrefJSON])
    case object([String: PrefJSON])

    /// An integral number (`20` or `20.0`), else nil.
    var integer: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): d.rounded() == d && abs(d) < 9.0e15 ? Int(d) : nil
        default: nil
        }
    }

    var objectValue: [String: PrefJSON]? {
        if case .object(let o) = self { o } else { nil }
    }

    /// `self` written over `base`: two objects merge key by key (recursively, so unknown keys of
    /// `base` stay at every level); anything else replaces `base`.
    func merged(over base: PrefJSON?) -> PrefJSON {
        guard case .object(let mine) = self, case .object(var theirs)? = base else { return self }
        for (key, value) in mine { theirs[key] = value.merged(over: theirs[key]) }
        return .object(theirs)
    }
}

extension PrefJSON: Codable {
    init(from decoder: any Decoder) throws {
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
        } else if let a = try? c.decode([PrefJSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: PrefJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
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
}

// MARK: - Leaf codecs

/// How one leaf type is stored, shown (`value(atPath:)`) and parsed (`set(_:atPath:)`).
struct PrefCodec<Value> {
    var encode: (Value) -> PrefJSON
    /// nil: unusable, the field keeps its default. `adjusted`: usable after clamping or
    /// normalizing, which still counts as a repair.
    var decode: (PrefJSON) -> (value: Value, adjusted: Bool)?
    var text: (Value) -> String
    /// nil: not a valid value for the field. Ranged values are clamped, as on decode.
    var parse: (String) -> Value?
}

/// The text for "no value" in `value(atPath:)` / `set(_:atPath:)` (`null` is accepted too).
let nilText = "nil"

func isNilText(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    return t == nilText || t == "null"
}

func clamp(_ v: Int, _ range: ClosedRange<Int>) -> Int {
    min(max(v, range.lowerBound), range.upperBound)
}

extension PrefCodec where Value == Bool {
    static var bool: Self {
        Self(
            encode: { .bool($0) },
            decode: { if case .bool(let b) = $0 { (b, false) } else { nil } },
            text: { $0 ? "true" : "false" },
            parse: { s in
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "yes", "1", "on": true
                case "false", "no", "0", "off": false
                default: nil
                }
            })
    }
}

extension PrefCodec where Value == Int {
    /// A number in `range`; outside it is clamped (the stepper rows and typed inputs).
    static func clamped(_ range: ClosedRange<Int>) -> Self {
        Self(
            encode: { .int($0) },
            decode: { json in json.integer.map { (clamp($0, range), clamp($0, range) != $0) } },
            text: { String($0) },
            parse: { Int($0.trimmingCharacters(in: .whitespaces)).map { clamp($0, range) } })
    }

    /// One of the values of a select row; anything else is invalid.
    static func oneOf(_ options: [Int]) -> Self {
        Self(
            encode: { .int($0) },
            decode: { json in json.integer.flatMap { options.contains($0) ? ($0, false) : nil } },
            text: { String($0) },
            parse: { Int($0.trimmingCharacters(in: .whitespaces)).flatMap { options.contains($0) ? $0 : nil } })
    }
}

extension PrefCodec where Value == Int? {
    /// A select row whose `nil` option is 永不 / 永久, stored as JSON `null` (a missing key means
    /// the default, which is not nil).
    static func oneOf(_ options: [Int?]) -> Self {
        Self(
            encode: { $0.map(PrefJSON.int) ?? .null },
            decode: { json -> (value: Int?, adjusted: Bool)? in
                if json == .null { return options.contains(nil) ? (nil, false) : nil }
                guard let i = json.integer, options.contains(i) else { return nil }
                return (i, false)
            },
            text: { $0.map(String.init) ?? nilText },
            parse: { s -> Int?? in
                if isNilText(s) { return options.contains(nil) ? .some(nil) : nil }
                guard let i = Int(s.trimmingCharacters(in: .whitespaces)), options.contains(i) else { return nil }
                return .some(i)
            })
    }
}

extension PrefCodec where Value == UInt32 {
    static var uint32: Self {
        Self(
            encode: { .int(Int($0)) },
            decode: { json in json.integer.flatMap { UInt32(exactly: $0) }.map { ($0, false) } },
            text: { String($0) },
            parse: { UInt32($0.trimmingCharacters(in: .whitespaces)) })
    }
}

extension PrefCodec where Value == String {
    /// Any string; a blank one is invalid when `nonBlank` (a path or a model name).
    static func string(nonBlank: Bool) -> Self {
        func ok(_ s: String) -> Bool { !nonBlank || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Self(
            encode: { .string($0) },
            decode: { if case .string(let s) = $0, ok(s) { (s, false) } else { nil } },
            text: { $0 },
            parse: { ok($0) ? $0 : nil })
    }

    /// One of the values of a select row (exact on decode, case-insensitive on set).
    static func oneOf(_ options: [String]) -> Self {
        Self(
            encode: { .string($0) },
            decode: { if case .string(let s) = $0, options.contains(s) { (s, false) } else { nil } },
            text: { $0 },
            parse: { s in options.first { $0.caseInsensitiveCompare(s.trimmingCharacters(in: .whitespaces)) == .orderedSame } })
    }

    /// A local time of day, stored `HH:mm`; `H:mm` is accepted and normalized.
    static var timeOfDay: Self {
        Self(
            encode: { .string($0) },
            decode: { json in
                guard case .string(let s) = json, let t = normalizedTime(s) else { return nil }
                return (t, t != s)
            },
            text: { $0 },
            parse: { normalizedTime($0) })
    }
}

/// `"8:05"` → `"08:05"`; nil unless hours 0–23 and minutes 00–59.
func normalizedTime(_ s: String) -> String? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
          parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
    return String(format: "%02d:%02d", h, m)
}

extension PrefCodec where Value == String? {
    /// An optional string where nil means "use the standard" (cswap path, condense account); a
    /// blank string reads as nil.
    static var optionalString: Self {
        func clean(_ s: String) -> String? { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s }
        return Self(
            encode: { $0.map(PrefJSON.string) ?? .null },
            decode: { json -> (value: String?, adjusted: Bool)? in
                switch json {
                case .null: (nil, false)
                case .string(let s): (clean(s), false)
                default: nil
                }
            },
            text: { $0 ?? nilText },
            parse: { s -> String?? in isNilText(s) ? .some(nil) : .some(clean(s)) })
    }
}

extension PrefCodec where Value == [String] {
    /// A list of ids; non-string and blank elements are dropped (a repair). Set takes a
    /// comma-separated list (an empty string is the empty list).
    static var stringList: Self {
        Self(
            encode: { .array($0.map(PrefJSON.string)) },
            decode: { json in
                guard case .array(let items) = json else { return nil }
                let kept: [String] = items.compactMap {
                    if case .string(let s) = $0, !s.trimmingCharacters(in: .whitespaces).isEmpty { s } else { nil }
                }
                return (kept, kept.count != items.count)
            },
            text: { $0.joined(separator: ",") },
            parse: { s in
                s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            })
    }
}

/// ISO 8601 in UTC with milliseconds (`2026-10-17T09:30:00.000Z`), like quota.json.
let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
let isoPlain = Date.ISO8601FormatStyle()

func parseISODate(_ s: String) -> Date? {
    let t = s.trimmingCharacters(in: .whitespaces)
    return (try? isoWithFraction.parse(t)) ?? (try? isoPlain.parse(t))
}

extension PrefCodec where Value == Date? {
    static var optionalDate: Self {
        Self(
            encode: { $0.map { .string($0.formatted(isoWithFraction)) } ?? .null },
            decode: { json -> (value: Date?, adjusted: Bool)? in
                switch json {
                case .null: return (nil, false)
                case .string(let s): return parseISODate(s).map { ($0, false) }
                default: return nil
                }
            },
            text: { $0?.formatted(isoWithFraction) ?? nilText },
            parse: { s -> Date?? in isNilText(s) ? .some(nil) : parseISODate(s).map { .some($0) } })
    }
}

extension PrefCodec where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// An enum stored by raw value; an unknown raw value is invalid (the field keeps its default).
    static var enumeration: Self {
        Self(
            encode: { .string($0.rawValue) },
            decode: { if case .string(let s) = $0, let v = Value(rawValue: s) { (v, false) } else { nil } },
            text: { $0.rawValue },
            parse: { s in
                let t = s.trimmingCharacters(in: .whitespaces)
                return Value(rawValue: t) ?? Value.allCases.first { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }
            })
    }
}

// MARK: - Field tables

enum SetOutcome { case done, unknownPath, invalidValue }

/// One stored key of a group: a leaf with its codec, or a nested group. Each group lists its keys
/// once (``FieldTable/fields``) and decoding, encoding and the dotted paths all come from that.
struct PrefField<Root> {
    let key: String
    let encode: (Root) -> PrefJSON
    /// Applies the stored value to `root` (which holds the default); returns the dotted paths
    /// that had to be repaired, `path` being this field's own.
    let decode: (inout Root, PrefJSON, _ path: String) -> [String]
    /// `rest` is the remaining path below this field (empty for a leaf).
    let text: (Root, ArraySlice<Substring>) -> String?
    let assign: (inout Root, ArraySlice<Substring>, String) -> SetOutcome
    let leafPaths: [String]

    static func leaf<V>(_ key: String, _ keyPath: WritableKeyPath<Root, V>, _ codec: PrefCodec<V>) -> Self {
        Self(
            key: key,
            encode: { codec.encode($0[keyPath: keyPath]) },
            decode: { root, json, path in
                guard let (value, adjusted) = codec.decode(json) else { return [path] }
                root[keyPath: keyPath] = value
                return adjusted ? [path] : []
            },
            text: { root, rest in rest.isEmpty ? codec.text(root[keyPath: keyPath]) : nil },
            assign: { root, rest, text in
                guard rest.isEmpty else { return .unknownPath }
                guard let value = codec.parse(text) else { return .invalidValue }
                root[keyPath: keyPath] = value
                return .done
            },
            leafPaths: [key])
    }

    /// A nested group. It decodes over the value `root` already holds, so a group type used twice
    /// with different defaults (the four notification events) keeps the right one per key.
    static func group<G: FieldTable>(_ key: String, _ keyPath: WritableKeyPath<Root, G>) -> Self {
        Self(
            key: key,
            encode: { $0[keyPath: keyPath].tableJSON() },
            decode: { root, json, path in
                var group = root[keyPath: keyPath]
                let repaired = G.read(json, into: &group, path: path)
                root[keyPath: keyPath] = group
                return repaired
            },
            text: { root, rest in rest.isEmpty ? nil : root[keyPath: keyPath].value(at: rest) },
            assign: { root, rest, text in
                guard !rest.isEmpty else { return .unknownPath }
                var group = root[keyPath: keyPath]
                let outcome = group.assign(text, at: rest)
                if case .done = outcome { root[keyPath: keyPath] = group }
                return outcome
            },
            leafPaths: G.leafPaths.map { "\(key).\($0)" })
    }
}

/// A preferences group: its stored keys in artboard order.
protocol FieldTable {
    static var fields: [PrefField<Self>] { get }
}

extension FieldTable {
    static var leafPaths: [String] { fields.flatMap(\.leafPaths) }

    /// Applies `json` over `value` field by field. A key that is missing keeps the value's default
    /// silently (older files, new fields); a wrong type, an unknown enum value or an out-of-range
    /// number keeps (or clamps to) the default and is returned as repaired. Unknown keys are
    /// ignored here; the store keeps them.
    static func read(_ json: PrefJSON, into value: inout Self, path: String) -> [String] {
        guard case .object(let object) = json else { return [path] }
        var repaired: [String] = []
        for field in fields {
            guard let stored = object[field.key] else { continue }
            repaired += field.decode(&value, stored, path.isEmpty ? field.key : "\(path).\(field.key)")
        }
        return repaired
    }

    /// Every field, optionals as explicit `null` (a missing key would mean the default).
    func tableJSON() -> PrefJSON {
        var object: [String: PrefJSON] = [:]
        for field in Self.fields { object[field.key] = field.encode(self) }
        return .object(object)
    }

    func value(at components: ArraySlice<Substring>) -> String? {
        guard let first = components.first, let field = Self.fields.first(where: { $0.key == first }) else { return nil }
        return field.text(self, components.dropFirst())
    }

    mutating func assign(_ text: String, at components: ArraySlice<Substring>) -> SetOutcome {
        guard let first = components.first, let field = Self.fields.first(where: { $0.key == first }) else { return .unknownPath }
        return field.assign(&self, components.dropFirst(), text)
    }

    /// `Decodable` for a group on its own: as tolerant as the store, but the repairs are not
    /// reported. Only a value that is not a JSON object throws.
    static func decodeTable(from decoder: any Decoder, over base: Self) throws -> Self {
        let json = try PrefJSON(from: decoder)
        guard json.objectValue != nil else {
            throw DecodingError.typeMismatch(
                Self.self, .init(codingPath: decoder.codingPath, debugDescription: "expected a JSON object"))
        }
        var value = base
        _ = read(json, into: &value, path: "")
        return value
    }
}
