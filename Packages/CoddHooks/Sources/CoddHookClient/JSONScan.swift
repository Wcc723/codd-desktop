/// A validating JSON scanner that locates values instead of building them (standard library only).
///
/// `codd-statusline` runs on every status-line refresh of every session, so it must not pay for
/// Foundation or a full decode: it only needs the byte span of `rate_limits` (forwarded verbatim)
/// and of `session_id`, and the server needs a handful of numbers out of that span. ``members(_:)``
/// validates the whole document (strings with escapes, numbers, literals, arrays, objects) without
/// recursion, so a deeply nested or truncated body is refused as a whole rather than half-read,
/// and nothing below the top level is materialised.
public enum JSONScan {
    /// Deepest array / object nesting accepted, counting the top-level object as 1 (the same bound
    /// as CoddCore's `JSONValue.maximumNestingDepth`). Deeper documents are rejected.
    public static let maximumNestingDepth = 64

    /// The members of the single top-level object in `bytes`: name → span of the value's bytes
    /// (whitespace excluded). `nil` unless `bytes` is exactly one valid JSON object, optionally
    /// surrounded by whitespace. A repeated name keeps the last value (as `JSON.parse` does).
    public static func members(_ bytes: [UInt8]) -> [String: Range<Int>]? {
        members(bytes, in: bytes.startIndex..<bytes.endIndex)
    }

    /// ``members(_:)`` for the object in `range` (for example a span returned by an outer call).
    /// The nesting limit counts from this object.
    public static func members(_ bytes: [UInt8], in range: Range<Int>) -> [String: Range<Int>]? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        let end = range.upperBound
        var i = skipWhitespace(bytes, range.lowerBound, end)
        guard i < end, bytes[i] == UInt8(ascii: "{") else { return nil }
        i = skipWhitespace(bytes, i + 1, end)
        var out: [String: Range<Int>] = [:]
        guard i < end else { return nil }
        if bytes[i] == UInt8(ascii: "}") {
            return skipWhitespace(bytes, i + 1, end) == end ? out : nil
        }
        while true {
            guard i < end, bytes[i] == UInt8(ascii: "\""), let keyEnd = skipString(bytes, i, end),
                  let key = string(bytes, i..<keyEnd) else { return nil }
            i = skipWhitespace(bytes, keyEnd, end)
            guard i < end, bytes[i] == UInt8(ascii: ":") else { return nil }
            i = skipWhitespace(bytes, i + 1, end)
            guard let valueEnd = skipValue(bytes, i, end, depth: 1) else { return nil }
            out[key] = i..<valueEnd
            i = skipWhitespace(bytes, valueEnd, end)
            guard i < end else { return nil }
            if bytes[i] == UInt8(ascii: ",") {
                i = skipWhitespace(bytes, i + 1, end)
                continue
            }
            guard bytes[i] == UInt8(ascii: "}") else { return nil }
            return skipWhitespace(bytes, i + 1, end) == end ? out : nil
        }
    }

    /// The decoded JSON string whose token (quotes included) is exactly `range`; `nil` when the span
    /// is not one valid string token. `\uXXXX` escapes are decoded, surrogate pairs combined, and
    /// an unpaired surrogate becomes U+FFFD (like CoddCore's repair of `JSON.stringify` output);
    /// invalid UTF-8 bytes are replaced the same way.
    public static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, range.count >= 2,
              bytes[range.lowerBound] == UInt8(ascii: "\""),
              skipString(bytes, range.lowerBound, range.upperBound) == range.upperBound else { return nil }
        let start = range.lowerBound + 1, end = range.upperBound - 1
        // Fast path: no escapes.
        if !bytes[start..<end].contains(UInt8(ascii: "\\")) {
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(end - start)
        var i = start
        while i < end {
            let c = bytes[i]
            guard c == UInt8(ascii: "\\") else {
                out.append(c)
                i += 1
                continue
            }
            let e = bytes[i + 1]
            i += 2
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            default: // "u": validated by skipString
                let unit = hex4(bytes, i)
                i += 4
                var scalar: UInt32 = 0xFFFD
                if (0xD800...0xDBFF).contains(unit) {
                    if i + 6 <= end, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let low = hex4(bytes, i + 2)
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                            i += 6
                        }
                    }
                } else if !(0xDC00...0xDFFF).contains(unit) {
                    scalar = UInt32(unit)
                }
                appendUTF8(scalar, to: &out)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The integer whose JSON number token is exactly `range` (no fraction, no exponent); `nil`
    /// for any other token or on overflow.
    public static func integer(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              skipNumber(bytes, range.lowerBound, range.upperBound) == range.upperBound else { return nil }
        var i = range.lowerBound
        let negative = bytes[i] == UInt8(ascii: "-")
        if negative { i += 1 }
        var value = 0
        while i < range.upperBound {
            let c = bytes[i]
            guard c >= 0x30, c <= 0x39 else { return nil } // fraction or exponent
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = negative ? m.subtractingReportingOverflow(Int(c - 0x30)) : m.addingReportingOverflow(Int(c - 0x30))
            guard !o1, !o2 else { return nil }
            value = s
            i += 1
        }
        return value
    }

    /// The finite number whose JSON number token is exactly `range`; `nil` for any other token
    /// (strings such as `"50"` included) and for values that overflow a `Double` (`1e999`).
    public static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Double? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              skipNumber(bytes, range.lowerBound, range.upperBound) == range.upperBound,
              let value = Double(String(decoding: bytes[range], as: UTF8.self)), value.isFinite else { return nil }
        return value
    }

    /// `true` when `range` is exactly the literal `null`.
    public static func isNull(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        range.count == 4 && range.upperBound <= bytes.count && bytes[range].elementsEqual("null".utf8)
    }

    // MARK: - Validation (no recursion)

    static func skipWhitespace(_ b: [UInt8], _ from: Int, _ end: Int) -> Int {
        var i = from
        while i < end, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        return i
    }

    /// The index after the value starting at `from` (which must not be whitespace), or `nil`.
    /// `depth` is the nesting of the container the value sits in.
    static func skipValue(_ b: [UInt8], _ from: Int, _ end: Int, depth: Int) -> Int? {
        // true = object, false = array.
        var stack: [Bool] = []
        var i = from
        while true {
            // A value is expected at i.
            guard i < end else { return nil }
            switch b[i] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let isObject = b[i] == UInt8(ascii: "{")
                guard depth + stack.count + 1 <= maximumNestingDepth else { return nil }
                stack.append(isObject)
                i = skipWhitespace(b, i + 1, end)
                guard i < end else { return nil }
                if b[i] == (isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                    stack.removeLast()
                    i += 1
                } else if isObject {
                    guard let next = skipKey(b, i, end) else { return nil }
                    i = next
                    continue
                } else {
                    continue
                }
            case UInt8(ascii: "\""):
                guard let next = skipString(b, i, end) else { return nil }
                i = next
            case UInt8(ascii: "-"), 0x30...0x39:
                guard let next = skipNumber(b, i, end) else { return nil }
                i = next
            case UInt8(ascii: "t"):
                guard let next = skipLiteral(b, i, end, "true") else { return nil }
                i = next
            case UInt8(ascii: "f"):
                guard let next = skipLiteral(b, i, end, "false") else { return nil }
                i = next
            case UInt8(ascii: "n"):
                guard let next = skipLiteral(b, i, end, "null") else { return nil }
                i = next
            default:
                return nil
            }
            // After a value: close containers or move to the next element.
            while true {
                guard let isObject = stack.last else { return i }
                i = skipWhitespace(b, i, end)
                guard i < end else { return nil }
                if b[i] == UInt8(ascii: ",") {
                    i = skipWhitespace(b, i + 1, end)
                    if isObject {
                        guard let next = skipKey(b, i, end) else { return nil }
                        i = next
                    }
                    break
                }
                guard b[i] == (isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) else { return nil }
                stack.removeLast()
                i += 1
            }
        }
    }

    /// `"key"` `:` and the whitespace up to the value.
    private static func skipKey(_ b: [UInt8], _ from: Int, _ end: Int) -> Int? {
        guard from < end, b[from] == UInt8(ascii: "\""), let keyEnd = skipString(b, from, end) else { return nil }
        let colon = skipWhitespace(b, keyEnd, end)
        guard colon < end, b[colon] == UInt8(ascii: ":") else { return nil }
        return skipWhitespace(b, colon + 1, end)
    }

    /// The index after the closing quote of the string starting at `from`, or `nil` (raw control
    /// characters, a bad escape, or no closing quote before `end`).
    static func skipString(_ b: [UInt8], _ from: Int, _ end: Int) -> Int? {
        guard from < end, b[from] == UInt8(ascii: "\"") else { return nil }
        var i = from + 1
        while i < end {
            let c = b[i]
            if c == UInt8(ascii: "\"") { return i + 1 }
            if c < 0x20 { return nil }
            if c == UInt8(ascii: "\\") {
                guard i + 1 < end else { return nil }
                switch b[i + 1] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                     UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    i += 2
                case UInt8(ascii: "u"):
                    guard i + 6 <= end, (i + 2..<i + 6).allSatisfy({ hexValue(b[$0]) != nil }) else { return nil }
                    i += 6
                default:
                    return nil
                }
                continue
            }
            i += 1
        }
        return nil
    }

    /// RFC 8259 `number`: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
    static func skipNumber(_ b: [UInt8], _ from: Int, _ end: Int) -> Int? {
        var i = from
        func digits() -> Bool {
            let start = i
            while i < end, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            return i > start
        }
        if i < end, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < end else { return nil }
        if b[i] == 0x30 {
            i += 1
        } else {
            guard digits() else { return nil }
        }
        if i < end, b[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() else { return nil }
        }
        if i < end, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < end, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() else { return nil }
        }
        return i
    }

    private static func skipLiteral(_ b: [UInt8], _ from: Int, _ end: Int, _ word: StaticString) -> Int? {
        let n = word.utf8CodeUnitCount
        guard from + n <= end else { return nil }
        let matches = word.withUTF8Buffer { w in (0..<n).allSatisfy { b[from + $0] == w[$0] } }
        return matches ? from + n : nil
    }

    // MARK: - Helpers

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x37
        case 0x61...0x66: return c - 0x57
        default: return nil
        }
    }

    /// Four hex digits at `i` (already validated).
    private static func hex4(_ b: [UInt8], _ i: Int) -> UInt16 {
        (0..<4).reduce(UInt16(0)) { $0 << 4 | UInt16(hexValue(b[i + $1]) ?? 0) }
    }

    private static func appendUTF8(_ scalar: UInt32, to out: inout [UInt8]) {
        switch scalar {
        case 0..<0x80:
            out.append(UInt8(scalar))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | (scalar >> 6)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | (scalar >> 12)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            out.append(UInt8(0xF0 | (scalar >> 18)))
            out.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}
