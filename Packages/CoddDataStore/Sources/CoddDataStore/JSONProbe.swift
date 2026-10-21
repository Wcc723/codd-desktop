import Foundation

/// Decides "is this a JSON object, and what is its version member" at least as leniently as
/// every store's own parser (D14: the preflight is never stricter than a file's store).
///
/// The fast path is `JSONDecoder` into top-level members only: Foundation validates the whole
/// document without building it, so a composer.json with a long history costs one scan. Should it
/// fail, `JSONSerialization` (the parser of CleanupState, the notes state files and the backups
/// index) and then the CoddCore `JSONValue.parse` repairs (nesting below 64 levels replaced by
/// `null`, unpaired UTF-16 surrogate escapes replaced) get their turn; only a document none of
/// them accepts as an object counts as not parseable.
enum JSONProbe {
    enum Version: Equatable {
        case missing
        case integer(Int)
        /// Present but not an integer (a string, a fraction, a boolean, null, an object).
        case notInteger
    }

    /// The version member of a JSON object, or nil when `data` is not a JSON object.
    static func version(of data: Data, key: String?) -> Version? {
        if let members = try? JSONDecoder().decode([String: Member].self, from: data) {
            guard let key else { return .missing }
            switch members[key] {
            case nil: return .missing
            case .integer(let n)?: return .integer(n)
            case .other?: return .notInteger
            }
        }
        guard let object = object(of: data) else { return nil }
        return version(in: object, key: key)
    }

    /// The whole object (for a migration), through the same fallbacks.
    static func object(of data: Data) -> [String: Any]? {
        for candidate in candidates(data) {
            if let object = (try? JSONSerialization.jsonObject(with: candidate)) as? [String: Any] { return object }
        }
        return nil
    }

    static func version(in object: [String: Any], key: String?) -> Version {
        guard let key, let value = object[key] else { return .missing }
        return integer(value).map(Version.integer) ?? .notInteger
    }

    /// CoddCore's `exactIntegerValue` on a `JSONSerialization` value: a number (not a boolean)
    /// that is whole and below 2^53.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }

    /// The original, then the `JSONValue.parse` variants (pruned, then surrogates repaired).
    private static func candidates(_ data: Data) -> [Data] {
        var out = [data]
        let pruned = prunedNesting(data, maxDepth: 64)
        if let pruned { out.append(pruned) }
        if let repaired = replacingUnpairedSurrogateEscapes(pruned ?? data) { out.append(repaired) }
        return out
    }

    /// One top-level member, read without descending into it.
    private enum Member: Decodable {
        case integer(Int)
        case other

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.singleValueContainer() else {
                self = .other
                return
            }
            if (try? container.decode(Bool.self)) != nil {
                self = .other
            } else if let n = try? container.decode(Int.self) {
                self = .integer(n)
            } else {
                self = .other
            }
        }
    }

    // MARK: - CoddCore JSONValue.parse repairs (ported, Foundation only)

    /// Arrays and objects deeper than `maxDepth` replaced by `null`; nil when nothing changed.
    /// Never fails: bytes it does not understand are copied, so invalid JSON stays invalid.
    static func prunedNesting(_ data: Data, maxDepth: Int) -> Data? {
        let b = [UInt8](data)
        var out: [UInt8] = []
        var changed = false
        var depth = 0
        var i = 0
        func skipString(_ start: Int) -> Int {
            var j = start + 1
            while j < b.count {
                switch b[j] {
                case 0x5C: j += 2
                case 0x22: return j + 1
                default: j += 1
                }
            }
            return b.count
        }
        func skipContainer(_ start: Int) -> Int {
            var level = 0
            var j = start
            while j < b.count {
                switch b[j] {
                case 0x22:
                    j = skipString(j)
                    continue
                case 0x7B, 0x5B:
                    level += 1
                case 0x7D, 0x5D:
                    level -= 1
                    if level == 0 { return j + 1 }
                default:
                    break
                }
                j += 1
            }
            return b.count
        }
        out.reserveCapacity(b.count)
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x22:
                let end = min(skipString(i), b.count)
                out.append(contentsOf: b[i..<end])
                i = end
            case 0x7B, 0x5B:
                if depth + 1 > maxDepth {
                    i = skipContainer(i)
                    out.append(contentsOf: Array("null".utf8))
                    changed = true
                } else {
                    depth += 1
                    out.append(c)
                    i += 1
                }
            case 0x7D, 0x5D:
                depth = max(0, depth - 1)
                out.append(c)
                i += 1
            default:
                out.append(c)
                i += 1
            }
        }
        return changed ? Data(out) : nil
    }

    /// Unpaired `\uD800`–`\uDFFF` escapes replaced by `�`; nil when there are none.
    static func replacingUnpairedSurrogateEscapes(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var out: [UInt8] = []
        var changed = false
        var i = 0
        func hex(_ c: UInt8) -> UInt16? {
            switch c {
            case 0x30...0x39: UInt16(c - 0x30)
            case 0x41...0x46: UInt16(c - 0x37)
            case 0x61...0x66: UInt16(c - 0x57)
            default: nil
            }
        }
        func unit(at j: Int) -> UInt16? {
            guard j + 6 <= b.count, b[j] == 0x5C, b[j + 1] == 0x75 else { return nil }
            var v: UInt16 = 0
            for k in 2..<6 {
                guard let h = hex(b[j + k]) else { return nil }
                v = v << 4 | h
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
                out.append(contentsOf: b[i...(i + 1)])
                i += 2
                continue
            }
            if (0xD800...0xDBFF).contains(u), let low = unit(at: i + 6), (0xDC00...0xDFFF).contains(low) {
                out.append(contentsOf: b[i..<(i + 12)])
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
}
