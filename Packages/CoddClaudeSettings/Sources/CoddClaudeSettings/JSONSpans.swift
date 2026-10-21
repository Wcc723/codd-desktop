import Foundation

/// One member of an object as it sits in the file: byte offsets into the document.
struct JSONMemberSpan: Equatable {
    /// The key's opening quote.
    var keyStart: Int
    var key: String
    var valueStart: Int
    /// One past the value's last byte.
    var valueEnd: Int
}

/// An object as it sits in the file, members in file order (a repeated key appears each time).
struct JSONObjectSpan: Equatable {
    /// The `{`.
    var start: Int
    /// One past the `}`.
    var end: Int
    var members: [JSONMemberSpan]
}

/// Byte-level navigation of a document ``OrderedJSON/parse(_:)`` already accepted. Editing
/// `~/.claude.json` by splicing bytes, instead of re-serialising the tree, keeps every byte CODD
/// does not change: other members, their layout and their string escapes (M4 D22). Nothing here
/// validates; callers parse first.
enum JSONSpans {
    static func skipWhitespace(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        var i = i
        while i < b.count {
            switch b[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return i
            }
        }
        return i
    }

    /// One past the closing quote of the string whose opening quote is at `i`: the next quote
    /// preceded by an even run of backslashes (`memchr`, so megabytes of `projects` strings are
    /// skipped quickly even in debug builds).
    static func stringEnd(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        guard let base = b.baseAddress else { return b.count }
        let contentStart = i + 1
        var from = contentStart
        while from < b.count {
            guard let found = memchr(base + from, Int32(UInt8(ascii: "\"")), b.count - from) else { return b.count }
            let quote = UnsafeRawPointer(found) - UnsafeRawPointer(base)
            var k = quote - 1
            var backslashes = 0
            while k >= contentStart, b[k] == UInt8(ascii: "\\") {
                backslashes += 1
                k -= 1
            }
            if backslashes % 2 == 0 { return quote + 1 }
            from = quote + 1
        }
        return b.count
    }

    /// One past the value starting at `i`. Containers are skipped with a depth counter (no
    /// recursion: `projects` can be deep and megabytes long).
    static func valueEnd(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        guard i < b.count else { return b.count }
        switch b[i] {
        case UInt8(ascii: "\""):
            return stringEnd(b, i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var k = i
            while k < b.count {
                switch b[k] {
                case UInt8(ascii: "\""):
                    k = stringEnd(b, k)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return k + 1 }
                default:
                    break
                }
                k += 1
            }
            return b.count
        default:
            // A number or a literal runs to the next delimiter.
            var k = i
            while k < b.count {
                switch b[k] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D: return k
                default: k += 1
                }
            }
            return k
        }
    }

    /// The object whose `{` is at `start`; nil when another kind of value starts there.
    static func object(_ b: UnsafeBufferPointer<UInt8>, at start: Int) -> JSONObjectSpan? {
        guard start < b.count, b[start] == UInt8(ascii: "{") else { return nil }
        var members: [JSONMemberSpan] = []
        var i = skipWhitespace(b, start + 1)
        if i < b.count, b[i] == UInt8(ascii: "}") {
            return JSONObjectSpan(start: start, end: i + 1, members: [])
        }
        while i < b.count {
            let keyStart = i
            let keyEnd = stringEnd(b, i)
            i = skipWhitespace(b, keyEnd)
            i = skipWhitespace(b, min(i + 1, b.count)) // the colon
            let valueStart = i
            let end = valueEnd(b, i)
            members.append(JSONMemberSpan(keyStart: keyStart, key: decodeKey(b, keyStart, keyEnd),
                                          valueStart: valueStart, valueEnd: end))
            i = skipWhitespace(b, end)
            guard i < b.count else { break }
            if b[i] == UInt8(ascii: "}") { return JSONObjectSpan(start: start, end: i + 1, members: members) }
            i = skipWhitespace(b, min(i + 1, b.count)) // the comma
        }
        return JSONObjectSpan(start: start, end: b.count, members: members)
    }

    /// The key text between the quotes at `start` and `end - 1`; escaped keys go through the
    /// strict parser so `"mcpServers"` is still `mcpServers`, as for `JSON.parse`.
    private static func decodeKey(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        let inner = UnsafeBufferPointer(rebasing: b[(start + 1)..<max(start + 1, end - 1)])
        if !inner.contains(UInt8(ascii: "\\")) { return String(decoding: inner, as: UTF8.self) }
        let quoted = Data(UnsafeBufferPointer(rebasing: b[start..<end]))
        return (try? OrderedJSON.parse(quoted))?.stringValue ?? String(decoding: inner, as: UTF8.self)
    }

    /// The number of line feeds before `offset` (0-based line index of the byte there).
    static func lineIndex(_ b: UnsafeBufferPointer<UInt8>, before offset: Int) -> Int {
        guard let base = b.baseAddress else { return 0 }
        let end = min(offset, b.count)
        var count = 0
        var from = 0
        while from < end, let found = memchr(base + from, 0x0A, end - from) {
            count += 1
            from = UnsafeRawPointer(found) - UnsafeRawPointer(base) + 1
        }
        return count
    }
}

/// How the file lays itself out, so inserted text matches it: the indent unit Claude's
/// `JSON.stringify(x, null, 2)` uses (or what the file uses), LF or CRLF, or the compact form.
struct JSONLayout: Equatable {
    /// Empty: compact (`{"a":1}`).
    var gap: [UInt8]
    var crlf: Bool

    /// Read from the root object: a newline right after `{` means a pretty layout whose unit is
    /// the whitespace before the first key; a member right after `{` means compact. An empty root
    /// takes Claude's own two spaces.
    static func detect(_ b: UnsafeBufferPointer<UInt8>, root: JSONObjectSpan) -> JSONLayout {
        var k = root.start + 1
        var crlf = false
        if k < b.count, b[k] == 0x0D {
            crlf = true
            k += 1
        }
        guard k < b.count, b[k] == 0x0A else {
            return root.members.isEmpty ? JSONLayout(gap: Array("  ".utf8), crlf: false) : JSONLayout(gap: [], crlf: false)
        }
        k += 1
        let start = k
        while k < b.count, b[k] == 0x20 || b[k] == 0x09 { k += 1 }
        let gap = Array(UnsafeBufferPointer(rebasing: b[start..<k]))
        return JSONLayout(gap: gap.isEmpty ? Array("  ".utf8) : Array(gap.prefix(10)), crlf: crlf)
    }

    /// `value` as `JSON.stringify` writes it nested `level` deep (its closing bracket indented
    /// `level` units), with this file's newline.
    func text(_ value: OrderedJSON, level: Int) -> [UInt8] {
        var out: [UInt8] = []
        JSONWriter.write(value, gap: gap, level: level, into: &out)
        return crlf ? Self.toCRLF(out) : out
    }

    /// `"key": value` (`"key":value` when compact).
    func member(_ key: String, _ value: OrderedJSON, level: Int) -> [UInt8] {
        var out: [UInt8] = []
        JSONWriter.quote(key, into: &out)
        out.append(UInt8(ascii: ":"))
        if !gap.isEmpty { out.append(0x20) }
        out.append(contentsOf: text(value, level: level))
        return out
    }

    func newline(level: Int) -> [UInt8] {
        guard !gap.isEmpty else { return [] }
        var out: [UInt8] = crlf ? [0x0D, 0x0A] : [0x0A]
        for _ in 0..<level { out.append(contentsOf: gap) }
        return out
    }

    /// JSON strings never hold a raw line feed, so every LF in writer output is layout.
    private static func toCRLF(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        for c in bytes {
            if c == 0x0A { out.append(0x0D) }
            out.append(c)
        }
        return out
    }
}

/// Rebuilds one object's bytes from the original slices: only the members that change and the
/// separators next to them differ.
enum JSONObjectEdit {
    /// The new bytes of `object` (from its `{` to its `}`) with `memberText` appended. The
    /// separator copies the whitespace the file puts before its first key (`,\n    ` in Claude's
    /// layout), so the new member lines up with its siblings.
    static func appending(_ b: UnsafeBufferPointer<UInt8>, object: JSONObjectSpan, memberText: [UInt8],
                          level: Int, layout: JSONLayout) -> [UInt8] {
        guard let first = object.members.first, let last = object.members.last else {
            var out: [UInt8] = [UInt8(ascii: "{")]
            out.append(contentsOf: layout.newline(level: level))
            out.append(contentsOf: memberText)
            out.append(contentsOf: layout.newline(level: level - 1))
            out.append(UInt8(ascii: "}"))
            return out
        }
        var out = Array(UnsafeBufferPointer(rebasing: b[object.start..<last.valueEnd]))
        out.append(UInt8(ascii: ","))
        out.append(contentsOf: UnsafeBufferPointer(rebasing: b[(object.start + 1)..<first.keyStart]))
        out.append(contentsOf: memberText)
        out.append(contentsOf: UnsafeBufferPointer(rebasing: b[last.valueEnd..<object.end]))
        return out
    }

    /// The new bytes of `object` without the members `keep` refuses (by index): the original
    /// lead and tail whitespace stay, and each kept member keeps the separator that preceded it
    /// (the first one none). Nothing kept gives `{}`, as `JSON.stringify` writes an empty object.
    static func removing(_ b: UnsafeBufferPointer<UInt8>, object: JSONObjectSpan, keep: (Int) -> Bool) -> [UInt8] {
        let kept = object.members.indices.filter(keep)
        guard let first = object.members.first, let last = object.members.last, !kept.isEmpty else {
            return Array("{}".utf8)
        }
        var out: [UInt8] = [UInt8(ascii: "{")]
        out.append(contentsOf: UnsafeBufferPointer(rebasing: b[(object.start + 1)..<first.keyStart]))
        for (n, index) in kept.enumerated() {
            if n > 0 {
                let previous = object.members[index - 1]
                out.append(contentsOf: UnsafeBufferPointer(rebasing: b[previous.valueEnd..<object.members[index].keyStart]))
            }
            let member = object.members[index]
            out.append(contentsOf: UnsafeBufferPointer(rebasing: b[member.keyStart..<member.valueEnd]))
        }
        out.append(contentsOf: UnsafeBufferPointer(rebasing: b[last.valueEnd..<object.end]))
        return out
    }
}
