/// Why a body is not JSON. The message goes into the `-32700` error, so it names the problem and
/// the byte offset but never quotes the body.
struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    var reason: String
    var offset: Int

    var description: String { "\(reason) at byte \(offset)" }
}

/// A strict RFC 8259 reader over UTF-8 bytes.
///
/// Recursive descent with a depth cap: nothing the MCP surface accepts nests deeply, and the cap
/// keeps a hostile body (`[[[[…`) from exhausting a cooperative-pool thread's stack. Strings must
/// be valid UTF-8; a lone surrogate escape (`\ud800`) becomes U+FFFD, as JavaScript would keep it
/// unpaired. A UTF-8 byte order mark before the value is skipped.
struct JSONParser {
    static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSON {
        var parser = JSONParser(bytes: bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw parser.failure("unexpected data after the value") }
        return value
    }

    static func parse(_ text: String) throws(JSONParseError) -> JSON {
        try parse(Array(text.utf8))
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func failure(_ reason: String) -> JSONParseError {
        JSONParseError(reason: reason, offset: index)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws(JSONParseError) -> JSON {
        guard index < bytes.count else {
            throw failure(bytes.isEmpty ? "empty body" : "unexpected end of input")
        }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw failure("unexpected character")
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONParseError) {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw failure("invalid literal") }
        let matches = literal.withUTF8Buffer { expected in
            (0..<count).allSatisfy { bytes[index + $0] == expected[$0] }
        }
        guard matches else { throw failure("invalid literal") }
        index += count
    }

    private mutating func parseObject(depth: Int) throws(JSONParseError) -> JSON {
        guard depth <= Self.maximumDepth else { throw failure("nested deeper than \(Self.maximumDepth) levels") }
        index += 1  // {
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw failure("expected a member name")
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure("expected ':'") }
            index += 1
            skipWhitespace()
            object.append(key, try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw failure("unterminated object") }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(object)
            default: throw failure("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(JSONParseError) -> JSON {
        guard depth <= Self.maximumDepth else { throw failure("nested deeper than \(Self.maximumDepth) levels") }
        index += 1  // [
        var items: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw failure("unterminated array") }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(items)
            default: throw failure("expected ',' or ']'")
            }
        }
    }

    private mutating func parseNumber() throws(JSONParseError) -> JSONNumber {
        let start = index
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw failure("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            if index < bytes.count, isDigit(bytes[index]) { throw failure("leading zero in a number") }
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw failure("invalid fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { throw failure("invalid exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        return JSONNumber(validatedText: String(decoding: bytes[start..<index], as: UTF8.self))
    }

    /// Reads a string starting at its opening quote. Unescaped runs are copied in bulk and the
    /// whole string is UTF-8 validated once at the end.
    private mutating func parseString() throws(JSONParseError) -> String {
        let quote = index
        index += 1
        var buffer: [UInt8] = []
        var runStart = index
        while true {
            guard index < bytes.count else {
                index = quote
                throw failure("unterminated string")
            }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                buffer.append(contentsOf: bytes[runStart..<index])
                index += 1
                break
            }
            if byte < 0x20 { throw failure("control character in a string") }
            if byte != UInt8(ascii: "\\") {
                index += 1
                continue
            }
            buffer.append(contentsOf: bytes[runStart..<index])
            index += 1
            guard index < bytes.count else { throw failure("unterminated escape") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): buffer.append(0x22)
            case UInt8(ascii: "\\"): buffer.append(0x5C)
            case UInt8(ascii: "/"): buffer.append(0x2F)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                let scalar = try parseUnicodeEscape()
                UTF8.encode(scalar) { buffer.append($0) }
            default:
                index -= 1
                throw failure("invalid escape")
            }
            runStart = index
        }
        guard let string = String(validating: buffer, as: UTF8.self) else {
            index = quote
            throw failure("invalid UTF-8 in a string")
        }
        return string
    }

    /// After `\u`: four hex digits, joined with a following `\uDC00…\uDFFF` when they are a high
    /// surrogate. Unpaired surrogates become U+FFFD.
    private mutating func parseUnicodeEscape() throws(JSONParseError) -> Unicode.Scalar {
        let first = try parseHex4()
        if (0xD800...0xDBFF).contains(first) {
            if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let save = index
                index += 2
                let second = try parseHex4()
                if (0xDC00...0xDFFF).contains(second) {
                    let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(value) ?? "\u{FFFD}"
                }
                index = save  // not a pair: the second escape is read on its own
            }
            return "\u{FFFD}"
        }
        if (0xDC00...0xDFFF).contains(first) { return "\u{FFFD}" }
        return Unicode.Scalar(first) ?? "\u{FFFD}"
    }

    private mutating func parseHex4() throws(JSONParseError) -> UInt32 {
        guard index + 4 <= bytes.count else { throw failure("invalid \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[index]
            let digit: UInt32
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(b - UInt8(ascii: "A") + 10)
            default: throw failure("invalid \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }
}
