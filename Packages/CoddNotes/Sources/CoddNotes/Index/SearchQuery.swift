import Foundation

/// A parsed search query (D6): whitespace-separated terms, `#tag` filters, `"quoted phrases"`
/// (spaces kept), all AND-ed. Terms are NFKC-lowercased; those of ≥ 3 Unicode scalars use the FTS5
/// trigram index, shorter ones a `LIKE` scan.
struct SearchQuery: Sendable, Equatable {
    var terms: [String]
    var tags: [String]

    var matchTerms: [String] { terms.filter { $0.unicodeScalars.count >= 3 } }
    var likeTerms: [String] { terms.filter { $0.unicodeScalars.count < 3 } }
    var isEmpty: Bool { terms.isEmpty && tags.isEmpty }

    init(_ text: String) {
        var terms: [String] = []
        var tags: [String] = []
        var current = ""
        var inQuotes = false
        var quoted = false
        func flush() {
            defer {
                current = ""
                quoted = false
            }
            if !quoted, current.hasPrefix("#"), current.count > 1 {
                var t = Substring(current)
                while t.hasPrefix("#") { t.removeFirst() }
                let tag = SearchFold.fold(String(t))
                if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
                return
            }
            let folded = SearchFold.fold(quoted ? current : current.trimmingCharacters(in: .whitespaces))
            if !folded.trimmingCharacters(in: .whitespaces).isEmpty, !terms.contains(folded) { terms.append(folded) }
        }
        for ch in text {
            // A quote opens a phrase only at the start of a term; inside a term it is literal text.
            if ch == "\"", !inQuotes, current.isEmpty {
                inQuotes = true
                quoted = true
                continue
            }
            if ch == "\"", inQuotes {
                inQuotes = false
                flush()
                continue
            }
            if !inQuotes, ch.isWhitespace {
                if !current.isEmpty { flush() }
                continue
            }
            current.append(ch)
        }
        if inQuotes, current.isEmpty {
            // A lone `"` is searched as the character itself.
            current = "\""
            quoted = true
        }
        if !current.isEmpty { flush() }
        self.terms = terms
        self.tags = tags
    }
}

enum SearchSnippet {
    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    /// Plain text around the first match of any term in `text` (newlines shown as spaces), with
    /// UTF-16 highlight ranges of every term occurrence. Nil when no term occurs in `text`.
    static func make(text: String, terms: [String], before: Int = 24, length: Int = 110) -> (String, [NSRange])? {
        guard !terms.isEmpty, !text.isEmpty else { return nil }
        var first: Range<String.Index>?
        for t in terms {
            if let r = text.range(of: t, options: options), first == nil || r.lowerBound < first!.lowerBound { first = r }
        }
        guard let hit = first else { return nil }
        // Back up to `before` characters, or to the start of the hit's line when that is closer.
        var start = text.index(hit.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        if let lineStart = text[start..<hit.lowerBound].lastIndex(of: "\n") { start = text.index(after: lineStart) }
        let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        snippet = prefix + snippet + suffix
        return (snippet, highlights(in: snippet, terms: terms))
    }

    /// Every occurrence of every term, merged where they overlap, sorted.
    static func highlights(in s: String, terms: [String]) -> [NSRange] {
        var ranges: [NSRange] = []
        for t in terms where !t.isEmpty {
            var from = s.startIndex
            while from < s.endIndex, let r = s.range(of: t, options: options, range: from..<s.endIndex) {
                ranges.append(NSRange(r, in: s))
                from = r.upperBound > r.lowerBound ? r.upperBound : s.index(after: r.lowerBound)
            }
        }
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for r in ranges {
            if let last = merged.last, r.location <= last.location + last.length {
                let end = max(last.location + last.length, r.location + r.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
