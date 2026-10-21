import Foundation

/// A lossless YAML **subset** frontmatter (D2): `key: scalar`, `key: [a, b]`, block lists
/// (`key:` + `- a` lines), single / double quoted strings and `#` comment lines. Every line is kept
/// as read (unknown keys, comments, order, CRLF), so an untouched note round-trips byte for byte and
/// `set` rewrites only the lines of the key it changes (or appends the key before the closing `---`).
/// Anything outside the subset (nested maps, block scalars, flow maps, anchors, duplicate keys) makes
/// `isParsable` false; `set` is then a no-op and the library refuses metadata edits on that note.
public struct Frontmatter: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        var text: String
        /// `\n`, `\r\n`, or empty for a last line without a terminator.
        var ending: String
    }

    enum Value: Sendable, Equatable {
        case scalar(String?)
        case flowList([String])
        /// `prefix` is the item lines' text before the value (`- ` or `  - `).
        case blockList([String], prefix: String)
    }

    struct Entry: Sendable, Equatable {
        var key: String
        var firstLine: Int
        var lineCount: Int
        var value: Value
        var trailingComment: String?
    }

    var opening: Line
    var lines: [Line]
    var closing: Line
    private(set) var entries: [Entry] = []
    public private(set) var isParsable: Bool = true

    /// An empty frontmatter (`---` / `---`) for a note that has none yet.
    public init(lineEnding: NoteLineEnding = .lf) {
        let nl = lineEnding == .crlf ? "\r\n" : "\n"
        opening = Line(text: "---", ending: nl)
        lines = []
        closing = Line(text: "---", ending: nl)
        reparse()
    }

    init(opening: Line, lines: [Line], closing: Line) {
        self.opening = opening
        self.lines = lines
        self.closing = closing
        reparse()
    }

    /// Splits a note file into its frontmatter (nil when the text does not start with a `---` line
    /// closed by another `---` line) and the body. `bodyOffset` is the body's start in UTF-16 units.
    public static func split(_ text: String) -> (frontmatter: Frontmatter?, body: String, bodyOffset: Int) {
        // Only the frontmatter's lines are scanned; the body is sliced off by byte offset.
        let bytes = Array(text.utf8)
        var k = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { k = 3 }
        guard bytes.count >= k + 3, bytes[k] == 45, bytes[k + 1] == 45, bytes[k + 2] == 45 else { return (nil, text, 0) }
        var lines: [Line] = []
        var lineStart = 0
        var i = 0
        var closingIndex: Int?
        var bodyStart = 0
        while i < bytes.count {
            guard bytes[i] == 10 else {
                i += 1
                continue
            }
            var end = i
            var ending = "\n"
            if end > lineStart, bytes[end - 1] == 13 {
                end -= 1
                ending = "\r\n"
            }
            let line = Line(text: String(decoding: bytes[lineStart..<end], as: UTF8.self), ending: ending)
            lines.append(line)
            lineStart = i + 1
            i += 1
            if lines.count == 1 {
                var open = line.text
                if open.hasPrefix("\u{FEFF}") { open.removeFirst() }
                guard isDelimiter(open, allowDots: false) else { return (nil, text, 0) }
            } else if isDelimiter(line.text, allowDots: true) {
                closingIndex = lines.count - 1
                bodyStart = lineStart
                break
            }
        }
        if closingIndex == nil, lineStart < bytes.count, lines.count >= 1 {
            // A closing delimiter on the last line without a terminator.
            let last = String(decoding: bytes[lineStart...], as: UTF8.self)
            if isDelimiter(last, allowDots: true) {
                lines.append(Line(text: last, ending: ""))
                closingIndex = lines.count - 1
                bodyStart = bytes.count
            }
        }
        guard let ci = closingIndex, ci >= 1 else { return (nil, text, 0) }
        let fm = Frontmatter(opening: lines[0], lines: Array(lines[1..<ci]), closing: lines[ci])
        let body = String(decoding: bytes[bodyStart...], as: UTF8.self)
        return (fm, body, BodyLines.utf16Count(bytes, 0, bodyStart))
    }

    /// The frontmatter text including both delimiters and the closing line's terminator.
    public func serialized() -> String {
        var s = opening.text + opening.ending
        for l in lines { s += l.text + l.ending }
        s += closing.text + closing.ending
        return s
    }

    /// The terminator used for new lines: the opening line's.
    var newline: String { opening.ending.isEmpty ? "\n" : opening.ending }

    public var lineEnding: NoteLineEnding { newline == "\r\n" ? .crlf : .lf }

    public var keys: [String] { entries.map(\.key) }

    public func contains(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// The value of a `key: scalar` line (quotes removed, escapes applied); nil when missing, null
    /// (`key:`) or a list.
    public func scalar(_ key: String) -> String? {
        guard let e = entries.first(where: { $0.key == key }), case .scalar(let v) = e.value else { return nil }
        return v
    }

    /// The items of a flow or block list; `[]` for a null value; nil when missing or a plain scalar.
    public func list(_ key: String) -> [String]? {
        guard let e = entries.first(where: { $0.key == key }) else { return nil }
        switch e.value {
        case .flowList(let a), .blockList(let a, _): return a
        case .scalar(nil): return []
        case .scalar: return nil
        }
    }

    /// Sets (or with nil removes) a scalar key, touching only that key's lines.
    public mutating func set(_ key: String, scalar value: String?) {
        guard isParsable else { return }
        guard let value else {
            remove(key)
            return
        }
        if let e = entries.first(where: { $0.key == key }), case .scalar(let old) = e.value, old == value { return }
        var text = "\(key): \(Self.formatScalar(value))"
        if let e = entries.first(where: { $0.key == key }), let c = e.trailingComment, e.lineCount == 1 { text += " " + c }
        replace(key, with: [text])
    }

    /// Sets a boolean key (`true` / `false`, unquoted).
    public mutating func set(_ key: String, bool value: Bool) {
        set(key, raw: value ? "true" : "false")
    }

    /// Sets a key to `raw` written verbatim (booleans, numbers): the caller guarantees it is valid YAML.
    mutating func set(_ key: String, raw value: String) {
        guard isParsable else { return }
        if let e = entries.first(where: { $0.key == key }), case .scalar(let old) = e.value, old == value { return }
        var text = "\(key): \(value)"
        if let e = entries.first(where: { $0.key == key }), let c = e.trailingComment, e.lineCount == 1 { text += " " + c }
        replace(key, with: [text])
    }

    /// Sets (or with nil removes) a list key. An existing block list stays a block list.
    public mutating func set(_ key: String, list value: [String]?) {
        guard isParsable else { return }
        guard let value else {
            remove(key)
            return
        }
        if let e = entries.first(where: { $0.key == key }) {
            switch e.value {
            case .flowList(let a) where a == value: return
            case .blockList(let a, _) where a == value: return
            default: break
            }
        }
        if let e = entries.first(where: { $0.key == key }), case .blockList(_, let prefix) = e.value, !value.isEmpty {
            replace(key, with: ["\(key):"] + value.map { prefix + Self.formatScalar($0) })
            return
        }
        var text = "\(key): [" + value.map(Self.formatListItem).joined(separator: ", ") + "]"
        if let e = entries.first(where: { $0.key == key }), let c = e.trailingComment, e.lineCount == 1 { text += " " + c }
        replace(key, with: [text])
    }

    private mutating func remove(_ key: String) {
        guard let e = entries.first(where: { $0.key == key }) else { return }
        lines.removeSubrange(e.firstLine..<(e.firstLine + e.lineCount))
        reparse()
    }

    private mutating func replace(_ key: String, with texts: [String]) {
        let nl = newline
        let newLines = texts.map { Line(text: $0, ending: nl) }
        if let e = entries.first(where: { $0.key == key }) {
            // Keep the replaced block's last terminator style on its last line.
            lines.replaceSubrange(e.firstLine..<(e.firstLine + e.lineCount), with: newLines)
        } else {
            lines.append(contentsOf: newLines)
        }
        reparse()
    }

    // MARK: - Parsing

    private mutating func reparse() {
        var parser = Parser(lines: lines)
        if let parsed = parser.parse() {
            entries = parsed
            isParsable = true
        } else {
            entries = []
            isParsable = false
        }
    }

    static func isDelimiter(_ text: String, allowDots: Bool) -> Bool {
        var t = Substring(text)
        while let last = t.last, last == " " || last == "\t" { t.removeLast() }
        return t == "---" || (allowDots && t == "...")
    }

    private struct Parser {
        let lines: [Line]

        mutating func parse() -> [Entry]? {
            var entries: [Entry] = []
            var seen = Set<String>()
            var i = 0
            while i < lines.count {
                let t = lines[i].text
                let lead = t.drop(while: { $0 == " " || $0 == "\t" })
                if lead.isEmpty || lead.hasPrefix("#") {
                    i += 1
                    continue
                }
                guard lead.count == t.count else { return nil }  // indented content without a key
                guard let (key, rest) = Self.splitKey(t) else { return nil }
                guard !seen.contains(key) else { return nil }
                seen.insert(key)
                let (valueText, comment) = Self.stripComment(rest)
                let v = valueText.trimmingCharacters(in: .whitespaces)
                if v.isEmpty {
                    // A block list, or null.
                    var j = i + 1
                    var items: [String] = []
                    var prefix: String?
                    var lastItemLine = i
                    while j < lines.count {
                        let lt = lines[j].text
                        let ll = lt.drop(while: { $0 == " " || $0 == "\t" })
                        if ll.isEmpty {
                            j += 1
                            continue
                        }
                        if ll == "-" || ll.hasPrefix("- ") || ll.hasPrefix("-\t") {
                            let itemText = ll.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
                            let (iv, _) = Self.stripComment(String(itemText))
                            guard let parsed = Self.parseScalar(iv.trimmingCharacters(in: .whitespaces), inFlow: false) else {
                                return nil
                            }
                            if prefix == nil {
                                let indent = lt.prefix(lt.count - ll.count)
                                prefix = indent + "- "
                            }
                            items.append(parsed ?? "")
                            lastItemLine = j
                            j += 1
                            continue
                        }
                        if ll.hasPrefix("#"), ll.count < lt.count {
                            j += 1
                            continue
                        }
                        if ll.count < lt.count { return nil }  // a nested map or a continuation
                        break
                    }
                    if items.isEmpty {
                        entries.append(Entry(key: key, firstLine: i, lineCount: 1, value: .scalar(nil), trailingComment: comment))
                        i += 1
                    } else {
                        entries.append(Entry(key: key, firstLine: i, lineCount: lastItemLine - i + 1,
                                             value: .blockList(items, prefix: prefix ?? "- "), trailingComment: nil))
                        i = lastItemLine + 1
                    }
                    continue
                }
                // A continuation line of a multi-line plain scalar is outside the subset.
                if i + 1 < lines.count {
                    let next = lines[i + 1].text
                    let nl = next.drop(while: { $0 == " " || $0 == "\t" })
                    if !nl.isEmpty, nl.count < next.count, !nl.hasPrefix("#") { return nil }
                }
                let first = v.first!
                if first == "[" {
                    guard v.hasSuffix("]"), let items = Self.parseFlowList(String(v.dropFirst().dropLast())) else { return nil }
                    entries.append(Entry(key: key, firstLine: i, lineCount: 1, value: .flowList(items), trailingComment: comment))
                } else if "{|>&*!@`".contains(first) {
                    return nil
                } else {
                    guard let s = Self.parseScalar(v, inFlow: false) else { return nil }
                    entries.append(Entry(key: key, firstLine: i, lineCount: 1, value: .scalar(s), trailingComment: comment))
                }
                i += 1
            }
            return entries
        }

        /// `key: rest` → (key, rest). The colon must be followed by a blank or the line end.
        static func splitKey(_ t: String) -> (String, String)? {
            guard let first = t.first, !"-?:,[]{}#&*!|>'\"%@`".contains(first) else { return nil }
            var idx = t.startIndex
            while idx < t.endIndex {
                if t[idx] == ":" {
                    let next = t.index(after: idx)
                    if next == t.endIndex || t[next] == " " || t[next] == "\t" {
                        var key = String(t[t.startIndex..<idx])
                        while key.last == " " || key.last == "\t" { key.removeLast() }
                        guard !key.isEmpty else { return nil }
                        return (key, String(t[next...]))
                    }
                }
                idx = t.index(after: idx)
            }
            return nil
        }

        /// Splits off a ` # comment` that is outside quotes.
        static func stripComment(_ s: String) -> (String, String?) {
            var inSingle = false, inDouble = false
            var prev: Character = " "
            var escaped = false
            for idx in s.indices {
                let c = s[idx]
                if inDouble {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inDouble = false }
                } else if inSingle {
                    if c == "'" { inSingle = false }
                } else if c == "\"", prev == " " || prev == "\t" || prev == "[" || prev == "," {
                    inDouble = true
                } else if c == "'", prev == " " || prev == "\t" || prev == "[" || prev == "," {
                    inSingle = true
                } else if c == "#", prev == " " || prev == "\t" {
                    var value = String(s[s.startIndex..<idx])
                    while value.last == " " || value.last == "\t" { value.removeLast() }
                    return (value, String(s[idx...]))
                }
                prev = c
            }
            return (s, nil)
        }

        /// A plain or quoted scalar; `.some(nil)` for an empty plain value; nil when malformed.
        static func parseScalar(_ v: String, inFlow: Bool) -> String?? {
            guard let first = v.first else { return .some(nil) }
            if first == "\"" {
                guard v.count >= 2, v.last == "\"", let s = unescapeDouble(String(v.dropFirst().dropLast())) else { return nil }
                return .some(s)
            }
            if first == "'" {
                guard v.count >= 2, v.last == "'" else { return nil }
                let inner = String(v.dropFirst().dropLast())
                // A lone quote inside must be doubled.
                let undoubled = inner.replacingOccurrences(of: "''", with: "")
                guard !undoubled.contains("'") else { return nil }
                return .some(inner.replacingOccurrences(of: "''", with: "'"))
            }
            if inFlow, v.contains(where: { "[]{}".contains($0) }) { return nil }
            if !inFlow, "[]{}|>&*!@`".contains(first) { return nil }
            return .some(v)
        }

        static func unescapeDouble(_ s: String) -> String? {
            var out = ""
            var it = s.unicodeScalars.makeIterator()
            while let c = it.next() {
                if c == "\"" { return nil }
                guard c == "\\" else {
                    out.unicodeScalars.append(c)
                    continue
                }
                guard let e = it.next() else { return nil }
                switch e {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "0": out += "\0"
                case "\\": out += "\\"
                case "\"": out += "\""
                case "/": out += "/"
                case " ": out += " "
                case "u", "x", "U":
                    let n = e == "x" ? 2 : (e == "u" ? 4 : 8)
                    var hex = ""
                    for _ in 0..<n {
                        guard let h = it.next() else { return nil }
                        hex.unicodeScalars.append(h)
                    }
                    guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else { return nil }
                    out.unicodeScalars.append(sc)
                default: return nil
                }
            }
            return out
        }

        static func parseFlowList(_ inner: String) -> [String]? {
            var items: [String] = []
            var current = ""
            var inSingle = false, inDouble = false, escaped = false
            for c in inner {
                if inDouble {
                    current.append(c)
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inDouble = false }
                    continue
                }
                if inSingle {
                    current.append(c)
                    if c == "'" { inSingle = false }
                    continue
                }
                switch c {
                case "\"" where current.trimmingCharacters(in: .whitespaces).isEmpty:
                    inDouble = true
                    current.append(c)
                case "'" where current.trimmingCharacters(in: .whitespaces).isEmpty:
                    inSingle = true
                    current.append(c)
                case ",":
                    items.append(current)
                    current = ""
                default:
                    current.append(c)
                }
            }
            guard !inSingle, !inDouble else { return nil }
            items.append(current)
            var out: [String] = []
            for (k, raw) in items.enumerated() {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    // `[]` and a trailing comma are fine; an empty middle item is not.
                    if items.count == 1 || k == items.count - 1 { continue }
                    return nil
                }
                guard let v = parseScalar(t, inFlow: true), let value = v else { return nil }
                out.append(value)
            }
            return out
        }
    }

    // MARK: - Formatting

    static func formatScalar(_ s: String) -> String {
        needsQuotes(s, inFlow: false) ? doubleQuoted(s) : s
    }

    static func formatListItem(_ s: String) -> String {
        needsQuotes(s, inFlow: true) ? doubleQuoted(s) : s
    }

    static func needsQuotes(_ s: String, inFlow: Bool) -> Bool {
        guard let first = s.first, let last = s.last else { return true }
        if first == " " || first == "\t" || last == " " || last == "\t" { return true }
        if "?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        // A leading `-` followed by a blank (or alone) would read as a list item.
        if first == "-", s.count == 1 || s.dropFirst().first == " " { return true }
        if s.contains(": ") || s.contains(" #") || s.hasSuffix(":") { return true }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\u{7F}" }) { return true }
        if inFlow, s.contains(where: { ",[]{}".contains($0) }) { return true }
        let lower = s.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"].contains(lower) { return true }
        if Double(s) != nil || Int(s) != nil { return true }
        return false
    }

    static func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if c.value < 0x20 || c == "\u{7F}" { out += String(format: "\\x%02x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }
}
