extension JSONValue {
    /// Parses a complete JSON document (RFC 8259). Trailing non-whitespace is an error.
    public static func parse(_ bytes: [UInt8], maxDepth: Int = 64) throws(JSONError) -> JSONValue {
        var parser = JSONParser(bytes: bytes, maxDepth: maxDepth)
        return try parser.parseDocument()
    }

    public static func parse(_ text: String, maxDepth: Int = 64) throws(JSONError) -> JSONValue {
        try parse(Array(text.utf8), maxDepth: maxDepth)
    }
}

/// Recursive-descent parser over UTF-8 bytes with a nesting limit.
struct JSONParser {
    private let bytes: [UInt8]
    private let maxDepth: Int
    private var index = 0
    private var depth = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    mutating func parseDocument() throws(JSONError) -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw JSONError("trailing characters", at: index) }
        return value
    }

    private mutating func parseValue() throws(JSONError) -> JSONValue {
        guard index < bytes.count else { throw JSONError("unexpected end of input", at: index) }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw JSONError("unexpected character", at: index)
        }
    }

    private mutating func enter() throws(JSONError) {
        depth += 1
        if depth > maxDepth { throw JSONError("nesting too deep", at: index) }
    }

    private mutating func parseObject() throws(JSONError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // {
        var members: [JSONMember] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw JSONError("expected object key", at: index) }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw JSONError("expected ':'", at: index) }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(JSONMember(key, value))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"):
                index += 1
                return .object(members)
            default: throw JSONError("expected ',' or '}'", at: index)
            }
        }
    }

    private mutating func parseArray() throws(JSONError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // [
        var elements: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"):
                index += 1
                return .array(elements)
            default: throw JSONError("expected ',' or ']'", at: index)
            }
        }
    }

    private mutating func parseString() throws(JSONError) -> String {
        index += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard index < bytes.count else { throw JSONError("unterminated string", at: index) }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                try parseEscape(into: &out)
            case 0x00..<0x20:
                throw JSONError("control character in string", at: index)
            default:
                out.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseEscape(into out: inout [UInt8]) throws(JSONError) {
        guard index < bytes.count else { throw JSONError("unterminated escape", at: index) }
        let byte = bytes[index]
        index += 1
        switch byte {
        case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
            var scalar = try parseHex4()
            if (0xD800...0xDBFF).contains(scalar) {
                // High surrogate: combine with a following \uDC00-\uDFFF, otherwise replace.
                if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                        scalar = 0xFFFD
                    }
                } else {
                    scalar = 0xFFFD
                }
            } else if (0xDC00...0xDFFF).contains(scalar) {
                scalar = 0xFFFD
            }
            let unicode = Unicode.Scalar(scalar) ?? "\u{FFFD}"
            out.append(contentsOf: String(Character(unicode)).utf8)
        default:
            throw JSONError("invalid escape", at: index - 1)
        }
    }

    private mutating func parseHex4() throws(JSONError) -> UInt32 {
        guard index + 4 <= bytes.count else { throw JSONError("truncated \\u escape", at: index) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw JSONError("invalid hex digit", at: index)
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws(JSONError) -> JSONValue {
        let start = index
        var negative = false
        if peek() == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        guard let first = peek(), isDigit(first) else { throw JSONError("invalid number", at: index) }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = peek(), isDigit(next) { throw JSONError("leading zero", at: index) }
        } else {
            while let byte = peek(), isDigit(byte) { index += 1 }
        }
        var isInteger = true
        if peek() == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard let byte = peek(), isDigit(byte) else { throw JSONError("invalid fraction", at: index) }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            guard let byte = peek(), isDigit(byte) else { throw JSONError("invalid exponent", at: index) }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger {
            if negative, let value = Int64(text) { return .int(value) }
            if !negative, let value = UInt64(text) {
                return value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
            }
        }
        guard let value = Double(text) else { throw JSONError("number out of range", at: start) }
        return .double(value)
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONError) {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw JSONError("invalid literal", at: index) }
        let matches = literal.withUTF8Buffer { expected in
            for offset in 0..<count where bytes[index + offset] != expected[offset] {
                return false
            }
            return true
        }
        guard matches else { throw JSONError("invalid literal", at: index) }
        index += count
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }
}
