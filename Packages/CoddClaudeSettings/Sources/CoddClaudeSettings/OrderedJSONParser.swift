import Foundation

/// Where a document stopped being RFC 8259 JSON. It carries the position only: settings files
/// hold tokens and keys, so no error, log line or dialog may quote their content.
public struct OrderedJSONError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 1-based line.
    public var line: Int
    /// 1-based column, counted in Unicode scalars.
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "invalid JSON at line \(line), column \(column)" }
}

extension OrderedJSON {
    /// Deepest nesting of objects and arrays ``parse(_:)`` accepts.
    public static let maximumDepth = 512

    /// Strict RFC 8259: one value, whitespace around it, UTF-8 without a byte order mark, no
    /// comments, no trailing commas, no lone surrogate escapes (a Swift `String` cannot hold one,
    /// and refusing the file is safer than altering a string). A repeated object key keeps its
    /// first position and its last value, like `JSON.parse`.
    public static func parse(_ data: Data) throws(OrderedJSONError) -> OrderedJSON {
        let result: Result<OrderedJSON, OrderedJSONError> = data.withUnsafeBytes { raw in
            var parser = JSONByteParser(bytes: raw.bindMemory(to: UInt8.self))
            return Result { () throws(OrderedJSONError) in try parser.parseDocument() }
        }
        return try result.get()
    }
}

/// Iterative recursive-descent parser: containers live on an explicit stack, so the depth limit
/// is a counter rather than the thread's stack size (tests and the app parse on pool threads).
private struct JSONByteParser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        b = bytes
    }

    /// One open container. Members carry an index so a repeated key is merged in O(1).
    private struct Frame {
        var isObject: Bool
        var elements: [OrderedJSON] = []
        var members: [(key: String, value: OrderedJSON)] = []
        var index: [String: Int] = [:]
        var key = ""
    }

    mutating func parseDocument() throws(OrderedJSONError) -> OrderedJSON {
        var stack: [Frame] = []
        skipWhitespace()
        while true {
            // A value starts at `i`.
            guard i < b.count else { throw error(at: i) }
            var value: OrderedJSON
            switch b[i] {
            case UInt8(ascii: "{"):
                guard stack.count < OrderedJSON.maximumDepth else { throw error(at: i) }
                i += 1
                skipWhitespace()
                if i < b.count, b[i] == UInt8(ascii: "}") {
                    i += 1
                    value = .object([])
                } else {
                    var frame = Frame(isObject: true)
                    frame.key = try parseKey()
                    stack.append(frame)
                    continue
                }
            case UInt8(ascii: "["):
                guard stack.count < OrderedJSON.maximumDepth else { throw error(at: i) }
                i += 1
                skipWhitespace()
                if i < b.count, b[i] == UInt8(ascii: "]") {
                    i += 1
                    value = .array([])
                } else {
                    stack.append(Frame(isObject: false))
                    continue
                }
            case UInt8(ascii: "\""):
                value = .string(try parseString())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                value = .number(try parseNumber())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                value = .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                value = .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                value = .null
            default:
                throw error(at: i)
            }

            // Hand the finished value to its container; closing a container finishes another.
            while true {
                guard !stack.isEmpty else {
                    skipWhitespace()
                    guard i == b.count else { throw error(at: i) }
                    return value
                }
                let top = stack.count - 1
                if stack[top].isObject {
                    let key = stack[top].key
                    if let existing = stack[top].index[key] {
                        stack[top].members[existing].value = value
                    } else {
                        stack[top].index[key] = stack[top].members.count
                        stack[top].members.append((key: key, value: value))
                    }
                } else {
                    stack[top].elements.append(value)
                }
                skipWhitespace()
                guard i < b.count else { throw error(at: i) }
                let c = b[i]
                if c == UInt8(ascii: ",") {
                    i += 1
                    skipWhitespace()
                    if stack[top].isObject { stack[top].key = try parseKey() }
                    break
                }
                if stack[top].isObject, c == UInt8(ascii: "}") {
                    i += 1
                    value = .object(stack.removeLast().members)
                    continue
                }
                if !stack[top].isObject, c == UInt8(ascii: "]") {
                    i += 1
                    value = .array(stack.removeLast().elements)
                    continue
                }
                throw error(at: i)
            }
        }
    }

    /// `"key"` `:` with the whitespace after it; `i` lands on the value.
    private mutating func parseKey() throws(OrderedJSONError) -> String {
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw error(at: i) }
        let key = try parseString()
        skipWhitespace()
        guard i < b.count, b[i] == UInt8(ascii: ":") else { throw error(at: i) }
        i += 1
        skipWhitespace()
        return key
    }

    private mutating func skipWhitespace() {
        while i < b.count {
            switch b[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private mutating func expectLiteral(_ word: StaticString) throws(OrderedJSONError) {
        let n = word.utf8CodeUnitCount
        let start = word.utf8Start
        for k in 0..<n {
            guard i + k < b.count, b[i + k] == start[k] else { throw error(at: i + k) }
        }
        i += n
    }

    private mutating func parseNumber() throws(OrderedJSONError) -> String {
        let start = i
        if b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count, isDigit(b[i]) else { throw error(at: i) }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else {
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            guard i < b.count, isDigit(b[i]) else { throw error(at: i) }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, isDigit(b[i]) else { throw error(at: i) }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        return String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
    }

    private func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    /// A string starting at the quote under `i`. Fast path: no escapes, one UTF-8 validation.
    private mutating func parseString() throws(OrderedJSONError) -> String {
        let open = i
        i += 1
        let start = i
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                let slice = UnsafeBufferPointer(rebasing: b[start..<i])
                i += 1
                guard let s = String(validating: slice, as: UTF8.self) else { throw error(at: open) }
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            if c < 0x20 { throw error(at: i) }
            i += 1
        }
        var buffer = [UInt8](UnsafeBufferPointer(rebasing: b[start..<min(i, b.count)]))
        while true {
            guard i < b.count else { throw error(at: i) }
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                break
            }
            if c < 0x20 { throw error(at: i) }
            if c != UInt8(ascii: "\\") {
                buffer.append(c)
                i += 1
                continue
            }
            let escape = i
            i += 1
            guard i < b.count else { throw error(at: i) }
            switch b[i] {
            case UInt8(ascii: "\""): buffer.append(0x22); i += 1
            case UInt8(ascii: "\\"): buffer.append(0x5C); i += 1
            case UInt8(ascii: "/"): buffer.append(0x2F); i += 1
            case UInt8(ascii: "b"): buffer.append(0x08); i += 1
            case UInt8(ascii: "f"): buffer.append(0x0C); i += 1
            case UInt8(ascii: "n"): buffer.append(0x0A); i += 1
            case UInt8(ascii: "r"): buffer.append(0x0D); i += 1
            case UInt8(ascii: "t"): buffer.append(0x09); i += 1
            case UInt8(ascii: "u"):
                i += 1
                let unit = try hex4()
                var scalarValue = UInt32(unit)
                if (0xD800...0xDBFF).contains(unit) {
                    guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else {
                        throw error(at: escape)
                    }
                    i += 2
                    let low = try hex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw error(at: escape) }
                    scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(unit) {
                    throw error(at: escape)
                }
                guard let scalar = Unicode.Scalar(scalarValue) else { throw error(at: escape) }
                UTF8.encode(scalar) { buffer.append($0) }
            default:
                throw error(at: i)
            }
        }
        guard let s = String(validating: buffer, as: UTF8.self) else { throw error(at: open) }
        return s
    }

    private mutating func hex4() throws(OrderedJSONError) -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard i < b.count else { throw error(at: i) }
            let c = b[i]
            let digit: UInt16
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(c - UInt8(ascii: "A") + 10)
            default: throw error(at: i)
            }
            value = value << 4 | digit
            i += 1
        }
        return value
    }

    /// Line and column of byte `offset`; the column counts scalars, not bytes.
    private func error(at offset: Int) -> OrderedJSONError {
        let end = min(offset, b.count)
        var line = 1
        var column = 1
        for k in 0..<end {
            let c = b[k]
            if c == 0x0A {
                line += 1
                column = 1
            } else if c & 0xC0 != 0x80 {
                column += 1
            }
        }
        return OrderedJSONError(line: line, column: column)
    }
}
