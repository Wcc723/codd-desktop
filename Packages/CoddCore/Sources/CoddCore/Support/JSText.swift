/// JavaScript-compatible string helpers used by the ported CODD web logic.
///
/// The originals rely on ECMAScript semantics (`String.prototype.trim`, `/\s/`, `Array.from` code
/// point iteration). Swift's own whitespace classes differ (for example Swift treats U+0085 as
/// whitespace, ECMAScript does not), so these helpers re-implement the exact ECMAScript sets.
public enum JSText {
    /// ECMAScript `WhiteSpace` + `LineTerminator` (the set matched by `/\s/` and removed by `trim`).
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String.prototype.trim`.
    public static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// status-writer.js `str(v)`: the string itself (untrimmed) when it is a string with
    /// non-whitespace content, else `nil`.
    public static func nonBlank(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue, !trim(s).isEmpty else { return nil }
        return s
    }

    /// session-insights.js `str(v)`: like ``nonBlank(_:)`` but returns the trimmed string.
    public static func nonBlankTrimmed(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue else { return nil }
        return nonBlankTrimmed(s)
    }

    /// session-insights.js `str(v)` for an already typed string.
    public static func nonBlankTrimmed(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = trim(s)
        return t.isEmpty ? nil : t
    }

    /// Port of `cleanText(v, max)` (status-writer.js and session-insights.js): removes CSI escape
    /// sequences, turns C0 controls and DEL into spaces, collapses whitespace runs, trims, and
    /// truncates to `max` Unicode code points. Non-strings and blank results yield `nil`.
    public static func cleanText(_ value: JSONValue?, max: Int) -> String? {
        guard let s = value?.stringValue else { return nil }
        return cleanText(s, max: max)
    }

    /// ``cleanText(_:max:)`` for an already typed string.
    public static func cleanText(_ s: String, max: Int) -> String? {
        let input = Array(s.unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(input.count)
        var i = 0
        var lastWasSpace = false
        while i < input.count {
            // 1. /\u001b\[[0-9;?]*[ -\/]*[@-~]/g — the three classes are disjoint, so a greedy scan
            //    is equivalent to the regex (no backtracking can produce a different match).
            if input[i].value == 0x1B, let end = csiEnd(input, from: i) {
                i = end
                continue
            }
            var scalar = input[i]
            // 2. /[\u0000-\u001f\u007f]/g → ' '
            if scalar.value < 0x20 || scalar.value == 0x7F { scalar = " " }
            // 3. /\s+/g → ' '
            if isWhitespace(scalar) {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
            i += 1
        }
        // 4. trim (only single spaces can remain at the ends after step 3)
        if out.first == " " { out.removeFirst() }
        if out.last == " " { out.removeLast() }
        guard !out.isEmpty else { return nil }
        // 5. Array.from(s) code point truncation
        if out.count > max { out = Array(out.prefix(Swift.max(0, max))) }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: out)
        return String(result)
    }

    /// Index just past a CSI sequence starting at `start` (which holds ESC), or `nil` if none matches.
    private static func csiEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start + 1
        guard j < s.count, s[j] == "[" else { return nil }
        j += 1
        while j < s.count, isCSIParameter(s[j]) { j += 1 }
        while j < s.count, (0x20...0x2F).contains(s[j].value) { j += 1 }
        guard j < s.count, (0x40...0x7E).contains(s[j].value) else { return nil }
        return j + 1
    }

    private static func isCSIParameter(_ c: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(c.value) || c == ";" || c == "?"
    }

    /// `/needle/i.test(haystack)` for an ASCII-only needle. ECMAScript non-Unicode case-insensitive
    /// matching never folds non-ASCII characters onto ASCII, so ASCII folding is exact here.
    public static func containsCaseInsensitiveASCII(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf8).map(asciiLower)
        let n = Array(needle.utf8).map(asciiLower)
        guard !n.isEmpty else { return true }
        guard h.count >= n.count else { return false }
        for start in 0...(h.count - n.count) where h[start] == n[0] {
            if Array(h[start..<(start + n.count)]) == n { return true }
        }
        return false
    }

    private static func asciiLower(_ b: UInt8) -> UInt8 {
        (0x41...0x5A).contains(b) ? b + 0x20 : b
    }
}
