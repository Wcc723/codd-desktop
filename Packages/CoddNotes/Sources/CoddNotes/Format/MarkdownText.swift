import Darwin
import Foundation

/// Markdown helpers for the index: the H1 title, the plain text that snippets and search use.
enum MarkdownText {
    /// The first ATX H1 (`# x`) outside code blocks: its text and line index.
    static func firstH1(_ lines: [BodyLine]) -> (title: String, line: Int)? {
        var fence: Fence?
        for (k, l) in lines.enumerated() {
            if let f = fence {
                if f.closes(l.text) { fence = nil }
                continue
            }
            if let f = Fence(opening: l.text) {
                fence = f
                continue
            }
            if let t = h1Text(l.text) { return (t, k) }
        }
        return nil
    }

    static func h1Text(_ line: String) -> String? {
        var t = Substring(line)
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        var indent = 0
        while t.first == " ", indent < 3 {
            t.removeFirst()
            indent += 1
        }
        guard t.hasPrefix("#") else { return nil }
        t.removeFirst()
        guard t.isEmpty || t.first == " " || t.first == "\t" else { return nil }
        var s = t.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: ` ###`.
        if let r = s.range(of: " #+$", options: .regularExpression) { s.removeSubrange(r) }
        if s.allSatisfy({ $0 == "#" }) { s = "" }
        return s.isEmpty ? nil : s
    }

    /// The body as plain text, one output line per content line: the H1 title line is dropped,
    /// heading / list / quote / task marks and emphasis are removed, links keep their text, images
    /// their alt text, code keeps its content, `codd-annotations` blocks become their comments and
    /// HTML comments (the `codd:ai-append` markers) disappear. Original case.
    static func plainText(_ body: String) -> String {
        plainText(lines: BodyLines.split(body))
    }

    static func plainText(lines: [BodyLine], titleLine: Int?? = nil) -> String {
        let titleLine = titleLine ?? firstH1(lines)?.line
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var fence: Fence?
        var annotationLines: [String] = []
        var inComment = false
        for (k, l) in lines.enumerated() {
            if let f = fence {
                if f.closes(l.text) {
                    if f.info.hasPrefix("codd-annotations") {
                        if let a = ImageAnnotations.decode(annotationLines.joined(separator: "\n")) {
                            for item in a.items where !item.note.isEmpty { out.append(item.note) }
                        }
                        annotationLines = []
                    }
                    fence = nil
                } else if f.info.hasPrefix("codd-annotations") {
                    annotationLines.append(l.text)
                } else {
                    out.append(l.text)
                }
                continue
            }
            if let f = Fence(opening: l.text) {
                fence = f
                continue
            }
            if k == titleLine { continue }
            var t = l.text
            if inComment {
                guard let end = t.range(of: "-->") else { continue }
                t = String(t[end.upperBound...])
                inComment = false
            }
            while t.withCString({ strstr($0, "<!--") != nil }), let start = t.range(of: "<!--") {
                if let end = t.range(of: "-->", range: start.upperBound..<t.endIndex) {
                    t.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    t = String(t[..<start.lowerBound])
                    inComment = true
                    break
                }
            }
            let stripped = stripLine(t)
            if stripped.isEmpty {
                if let last = out.last, !last.isEmpty { out.append("") }
            } else {
                out.append(stripped)
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        return out.joined(separator: "\n")
    }

    /// The first two non-empty lines of `plain`, each at most 120 characters.
    static func snippet(_ plain: String) -> String {
        var picked: [String] = []
        for line in plain.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            picked.append(t.count > 120 ? String(t.prefix(119)) + "…" : t)
            if picked.count == 2 { break }
        }
        return picked.joined(separator: "\n")
    }

    typealias Bytes = [UInt8]

    // ASCII bytes of the marks. UTF-8 continuation and lead bytes of non-ASCII scalars are all
    // ≥ 0x80, so scanning bytes for ASCII marks never splits a CJK character.
    static let space: UInt8 = 32, tab: UInt8 = 9, hash: UInt8 = 35, gt: UInt8 = 62, lt: UInt8 = 60, pipe: UInt8 = 124
    static let dash: UInt8 = 45, star: UInt8 = 42, plus: UInt8 = 43, under: UInt8 = 95, colon: UInt8 = 58, dot: UInt8 = 46
    static let rparen: UInt8 = 41, lparen: UInt8 = 40, lbracket: UInt8 = 91, rbracket: UInt8 = 93, bang: UInt8 = 33
    static let tick: UInt8 = 96, tilde: UInt8 = 126, backslash: UInt8 = 92

    static func isBlank(_ b: UInt8) -> Bool { b == space || b == tab }

    /// One line without its block marks (indent, quotes, heading `#`s, list markers, task boxes,
    /// thematic breaks, table separators) and inline marks.
    static func stripLine(_ line: String) -> String {
        // Fast path for the common line: no block mark at its start and no inline mark at all
        // (strcspn runs in C; this function is the hot loop of an index build).
        if let f = line.utf8.first, f != space, f != tab, f != hash, f != gt, f != pipe, f != dash, f != star, f != plus,
           f != under, f != colon, f != lbracket, !(f >= 48 && f <= 57),
           line.withCString({ strcspn($0, "![]*_~`|<\\") }) == line.utf8.count {
            return line
        }
        let u = Array(line.utf8)
        var a = 0
        var b = u.count
        while a < b, isBlank(u[a]) { a += 1 }
        while b > a, isBlank(u[b - 1]) { b -= 1 }
        guard a < b else { return "" }
        // Table separator rows.
        if u[a] == pipe || u[a] == dash || u[a] == colon {
            var onlyTable = true
            var pipes = 0
            for k in a..<b {
                let c = u[k]
                if c == pipe { pipes += 1 }
                if !(c == pipe || c == dash || c == colon || isBlank(c)) {
                    onlyTable = false
                    break
                }
            }
            if onlyTable, pipes > 0 { return "" }
        }
        // Block quote marks.
        while a < b, u[a] == gt {
            a += 1
            while a < b, u[a] == space { a += 1 }
        }
        guard a < b else { return "" }
        // Headings.
        if u[a] == hash {
            var h = a
            while h < b, u[h] == hash, h - a < 6 { h += 1 }
            if h == b || isBlank(u[h]) {
                a = h
                while a < b, isBlank(u[a]) { a += 1 }
                // Closing sequence ` ###`.
                var e = b
                while e > a, u[e - 1] == hash { e -= 1 }
                if e < b, e > a, u[e - 1] == space {
                    b = e
                    while b > a, u[b - 1] == space { b -= 1 }
                }
            }
        }
        guard a < b else { return "" }
        // Thematic breaks (`---`, `***`, `___`, spaced or not).
        let first = u[a]
        if first == dash || first == star || first == under {
            var marks = 0
            var only = true
            for k in a..<b {
                if u[k] == first {
                    marks += 1
                } else if u[k] != space {
                    only = false
                    break
                }
            }
            if only, marks >= 3 { return "" }
        }
        // List markers and task boxes.
        if b - a >= 2, u[a] == dash || u[a] == star || u[a] == plus, u[a + 1] == space {
            a += 2
        } else {
            var d = a
            while d < b, d - a < 9, u[d] >= 48, u[d] <= 57 { d += 1 }
            if d > a, d + 1 < b, u[d] == dot || u[d] == rparen, u[d + 1] == space { a = d + 2 }
        }
        if b - a >= 4, u[a] == lbracket, u[a + 1] == space || u[a + 1] == 120 || u[a + 1] == 88, u[a + 2] == rbracket,
           u[a + 3] == space {
            a += 4
        }
        return inline(u, a, b)
    }

    static func inline(_ s: String) -> String {
        let u = Array(s.utf8)
        return inline(u, 0, u.count)
    }

    /// Inline Markdown → text: images keep alt, links keep their text, `**` / `__` / `~~` / `` ` ``
    /// marks and paired `*` emphasis go, `|` table pipes become spaces.
    static func inline(_ u: Bytes, _ from: Int, _ to: Int) -> String {
        String(decoding: inlineBytes(u, from, to), as: UTF8.self)
    }

    static func inlineBytes(_ u: Bytes, _ from: Int, _ to: Int) -> ArraySlice<UInt8> {
        guard from < to else { return [] }
        let firstMark = u.withUnsafeBufferPointer { buf -> Int in
            var k = from
            while k < to {
                switch buf[k] {
                case bang, lbracket, rbracket, star, under, tilde, tick, pipe, lt, backslash: return k
                default: k += 1
                }
            }
            return to
        }
        if firstMark == to { return u[from..<to] }
        let emphasis = u[firstMark..<to].contains(star) ? emphasisMarks(u, from, to) : []
        var out: Bytes = []
        out.reserveCapacity(to - from)
        var i = from
        while i < to {
            let c = u[i]
            if c == backslash, i + 1 < to, u[i + 1] < 128, isASCIIPunctuation(u[i + 1]) {
                out.append(u[i + 1])
                i += 2
                continue
            }
            if c == bang || c == lbracket {
                let open = c == bang ? i + 1 : i
                if open < to, u[open] == lbracket, let close = matching(u, from: open, to: to), close + 1 < to,
                   u[close + 1] == lparen, let paren = u[(close + 1)..<to].firstIndex(of: rparen)
                {
                    out.append(contentsOf: inlineBytes(u, open + 1, close))
                    i = paren + 1
                    continue
                }
            }
            if c == lt, let close = u[i..<to].firstIndex(of: gt), close > i + 1 {
                let inner = u[(i + 1)..<close]
                if inner.starts(with: Array("http://".utf8)) || inner.starts(with: Array("https://".utf8))
                    || inner.starts(with: Array("codd://".utf8)) {
                    out.append(contentsOf: inner)
                    i = close + 1
                    continue
                }
            }
            if c == tick {
                i += 1
                continue
            }
            if c == tilde, i + 1 < to, u[i + 1] == tilde {
                i += 2
                continue
            }
            if c == star, emphasis.contains(i) {
                i += 1
                continue
            }
            if c == under, i + 1 < to, u[i + 1] == under {
                i += 2
                continue
            }
            if c == pipe {
                if let last = out.last, last != space { out.append(space) }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        var a = 0, b = out.count
        while a < b, out[a] == space { a += 1 }
        while b > a, out[b - 1] == space { b -= 1 }
        return out[a..<b]
    }

    static func isASCIIPunctuation(_ b: UInt8) -> Bool {
        (33...47).contains(b) || (58...64).contains(b) || (91...96).contains(b) || (123...126).contains(b)
    }

    /// Positions of `*` that are emphasis marks: runs touching text on one side (not a lone `*`
    /// between blanks), when the line has at least two such runs. `star*x` alone keeps its `*`.
    static func emphasisMarks(_ u: Bytes, _ from: Int, _ to: Int) -> Set<Int> {
        var runs: [Range<Int>] = []
        var k = from
        while k < to {
            guard u[k] == star else {
                k += 1
                continue
            }
            var e = k
            while e < to, u[e] == star { e += 1 }
            let before = k > from ? u[k - 1] : space
            let after = e < to ? u[e] : space
            if !(isBlank(before) && isBlank(after)) { runs.append(k..<e) }
            k = e
        }
        guard runs.count >= 2 else { return [] }
        return Set(runs.flatMap { Array($0) })
    }

    private static func matching(_ u: Bytes, from open: Int, to: Int) -> Int? {
        var depth = 0
        var k = open
        while k < to {
            if u[k] == lbracket { depth += 1 }
            if u[k] == rbracket {
                depth -= 1
                if depth == 0 { return k }
            }
            k += 1
        }
        return nil
    }
}

/// Search text folding: NFKC + lowercase, the form both the FTS columns and `LIKE` terms use (D6).
enum SearchFold {
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
    }
}
