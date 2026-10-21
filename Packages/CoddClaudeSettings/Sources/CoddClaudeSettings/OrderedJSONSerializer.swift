extension OrderedJSON {
    /// The text `JSON.stringify(value, null, indent)` produces for the parsed value, except that
    /// numbers keep their original token: `{` / `[` then a newline and one `indent` per level,
    /// `"key": value`, `,` separators, empty containers as `{}` / `[]`, and with an empty indent
    /// the compact form (`{"a":1}`). Like JavaScript, at most 10 characters of `indent` are used.
    ///
    /// Strings are escaped exactly as `JSON.stringify` does: `\"`, `\\`, `\b`, `\f`, `\n`, `\r`,
    /// `\t`, other U+0000–U+001F as lowercase `\u00xx`; everything else, U+2028 / U+2029 and
    /// non-ASCII included, is written raw. (JavaScript also writes lone surrogates as `\udxxx`;
    /// a Swift `String` cannot contain one, and the parser refuses them.)
    public func serialized(indent: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(1024)
        JSONWriter.write(self, gap: JSONWriter.gap(indent), level: 0, into: &out)
        return String(decoding: out, as: UTF8.self)
    }
}

/// Byte-level writer shared by ``OrderedJSON/serialized(indent:)`` and the diff renderer, so the
/// lines of a diff are exactly the lines of the file CODD writes.
enum JSONWriter {
    /// `JSON.stringify` keeps the first 10 characters of a string indent.
    static func gap(_ indent: String) -> [UInt8] {
        Array(String(String.UnicodeScalarView(indent.unicodeScalars.prefix(10))).utf8)
    }

    static func write(_ value: OrderedJSON, gap: [UInt8], level: Int, into out: inout [UInt8]) {
        switch value {
        case .object(let members):
            guard !members.isEmpty else {
                out.append(contentsOf: [0x7B, 0x7D])
                return
            }
            out.append(0x7B)
            for (k, member) in members.enumerated() {
                if k > 0 { out.append(0x2C) }
                newline(gap: gap, level: level + 1, into: &out)
                quote(member.key, into: &out)
                out.append(0x3A)
                if !gap.isEmpty { out.append(0x20) }
                write(member.value, gap: gap, level: level + 1, into: &out)
            }
            newline(gap: gap, level: level, into: &out)
            out.append(0x7D)
        case .array(let elements):
            guard !elements.isEmpty else {
                out.append(contentsOf: [0x5B, 0x5D])
                return
            }
            out.append(0x5B)
            for (k, element) in elements.enumerated() {
                if k > 0 { out.append(0x2C) }
                newline(gap: gap, level: level + 1, into: &out)
                write(element, gap: gap, level: level + 1, into: &out)
            }
            newline(gap: gap, level: level, into: &out)
            out.append(0x5D)
        case .string(let s):
            quote(s, into: &out)
        case .number(let token):
            out.append(contentsOf: token.utf8)
        case .bool(let flag):
            out.append(contentsOf: (flag ? "true" : "false").utf8)
        case .null:
            out.append(contentsOf: "null".utf8)
        }
    }

    private static func newline(gap: [UInt8], level: Int, into out: inout [UInt8]) {
        guard !gap.isEmpty else { return }
        out.append(0x0A)
        for _ in 0..<level { out.append(contentsOf: gap) }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// JavaScript's QuoteJSONString over UTF-8: only `"`, `\` and C0 controls are escaped.
    static func quote(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for c in s.utf8 {
            switch c {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"),
                                        hexDigits[Int(c >> 4)], hexDigits[Int(c & 0x0F)]])
            default:
                out.append(c)
            }
        }
        out.append(0x22)
    }

    static func quoted(_ s: String) -> String {
        var out: [UInt8] = []
        quote(s, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    static func compact(_ value: OrderedJSON) -> String {
        value.serialized(indent: "")
    }
}
