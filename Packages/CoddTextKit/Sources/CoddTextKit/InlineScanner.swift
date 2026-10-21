import Foundation

/// A styled inline run. `range` is what gets the style (the content), `full` includes the marks.
struct InlineSpan: Equatable {
    enum Kind: Equatable {
        case strong, emphasis, strike, code
        /// `[text](url)`: `range` is the text.
        case link(url: String)
        /// `![alt](path)` inside a line of text: `range` is the alt text.
        case image(path: String)
        /// `codd://note/<id>` or `[[note:<id>]]`, drawn as the amber chip (`range` == `full`).
        case noteRef(id: String)
        /// A bare `http(s)://…` URL.
        case autolink(url: String)
    }

    var kind: Kind
    var range: NSRange
    var full: NSRange
}

/// Collects spans when the styler needs them (the block parser only needs the marks).
final class SpanSink {
    var items: [InlineSpan] = []
}

/// A small inline Markdown scanner over one line: code spans, links / images, `**` / `__`, `*` /
/// `_` (not inside words for `_`), `~~`, backslash escapes, note refs and bare URLs. Marks come out
/// sorted by location, spans in document order with an outer span before the spans inside it. Not CommonMark: it covers what notes contain, and anything it does not
/// recognise simply stays visible text.
struct InlineScanner {
    let window: UTF16Window

    func scan(_ low: Int, _ high: Int, marks: inout [NSRange], spans: SpanSink?, allowLinks: Bool = true) {
        var index = low
        while index < high {
            let c = window[index]
            switch c {
            case Unit.backslash:
                if index + 1 < high, Unit.isASCIIPunctuation(window[index + 1]) {
                    marks.append(NSRange(location: index, length: 1))
                    index += 2
                    continue
                }
            case Unit.backtick:
                let count = run(c, index, high)
                if let close = backtickClose(index + count, count, high) {
                    marks.append(NSRange(location: index, length: count))
                    marks.append(NSRange(location: close, length: count))
                    spans?.items.append(InlineSpan(kind: .code, range: NSRange(location: index + count, length: close - index - count),
                                                   full: NSRange(location: index, length: close + count - index)))
                    index = close + count
                } else {
                    index += count
                }
                continue
            case Unit.bang:
                if allowLinks, index + 1 < high, window[index + 1] == Unit.openBracket, let link = link(at: index + 1, end: high) {
                    marks.append(NSRange(location: index, length: 2))
                    marks.append(NSRange(location: link.closeBracket, length: link.end - link.closeBracket))
                    spans?.items.append(InlineSpan(kind: .image(path: window.string(link.urlRange)),
                                                   range: NSRange(location: index + 2, length: link.closeBracket - index - 2),
                                                   full: NSRange(location: index, length: link.end - index)))
                    index = link.end
                    continue
                }
            case Unit.openBracket:
                if allowLinks, let end = noteWikiRef(index, high) {
                    if let spans {
                        let id = window.string(NSRange(location: index + 7, length: end - 2 - index - 7))
                        let full = NSRange(location: index, length: end - index)
                        spans.items.append(InlineSpan(kind: .noteRef(id: id), range: full, full: full))
                    }
                    index = end
                    continue
                }
                if allowLinks, let link = link(at: index, end: high) {
                    marks.append(NSRange(location: index, length: 1))
                    // Outer spans come before the spans inside them (the styler applies in order).
                    spans?.items.append(InlineSpan(kind: .link(url: window.string(link.urlRange)),
                                                   range: NSRange(location: index + 1, length: link.closeBracket - index - 1),
                                                   full: NSRange(location: index, length: link.end - index)))
                    scan(index + 1, link.closeBracket, marks: &marks, spans: spans, allowLinks: false)
                    marks.append(NSRange(location: link.closeBracket, length: link.end - link.closeBracket))
                    index = link.end
                    continue
                }
            case Unit.star, Unit.underscore, Unit.tilde:
                let count = run(c, index, high)
                if let consumed = delimited(c, index, count, high, marks: &marks, spans: spans, allowLinks: allowLinks) {
                    index = consumed
                } else {
                    index += count
                }
                continue
            case 0x63: // c
                if let end = noteRef(index, high) {
                    if let spans {
                        let id = window.string(NSRange(location: index + 12, length: end - index - 12))
                        let full = NSRange(location: index, length: end - index)
                        spans.items.append(InlineSpan(kind: .noteRef(id: id), range: full, full: full))
                    }
                    index = end
                    continue
                }
            case 0x68: // h
                if let end = autolink(index, low, high) {
                    if let spans {
                        let full = NSRange(location: index, length: end - index)
                        spans.items.append(InlineSpan(kind: .autolink(url: window.string(full)), range: full, full: full))
                    }
                    index = end
                    continue
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: Pieces

    func run(_ unit: UInt16, _ start: Int, _ end: Int) -> Int {
        var index = start
        while index < end, window[index] == unit { index += 1 }
        return index - start
    }

    /// The start of the closing backtick run of exactly `count` after `from`.
    func backtickClose(_ from: Int, _ count: Int, _ end: Int) -> Int? {
        var index = from
        while index < end {
            if window[index] == Unit.backtick {
                let length = run(Unit.backtick, index, end)
                if length == count { return index }
                index += length
            } else {
                index += 1
            }
        }
        return nil
    }

    struct Link {
        let closeBracket: Int
        let end: Int
        /// The destination without `<>` or a title (read with `window.string` only when needed).
        let urlRange: NSRange
    }

    /// `[text](url "title")` starting at the `[`; nested brackets and parentheses balance, code
    /// spans and escapes are skipped.
    func link(at open: Int, end: Int) -> Link? {
        var depth = 0
        var index = open
        var closeBracket: Int?
        while index < end {
            let c = window[index]
            if c == Unit.backslash { index += 2; continue }
            if c == Unit.backtick {
                let count = run(c, index, end)
                if let close = backtickClose(index + count, count, end) { index = close + count; continue }
                index += count
                continue
            }
            if c == Unit.openBracket { depth += 1 } else if c == Unit.closeBracket {
                depth -= 1
                if depth == 0 { closeBracket = index; break }
            }
            index += 1
        }
        guard let closeBracket, closeBracket + 1 < end, window[closeBracket + 1] == Unit.openParen else { return nil }
        var parens = 0
        index = closeBracket + 1
        var closeParen: Int?
        var angled = false
        if closeBracket + 2 < end, window[closeBracket + 2] == Unit.less { angled = true }
        while index < end {
            let c = window[index]
            if c == Unit.backslash { index += 2; continue }
            if angled, c == Unit.greater { angled = false; index += 1; continue }
            if !angled {
                if c == Unit.openParen { parens += 1 } else if c == Unit.closeParen {
                    parens -= 1
                    if parens == 0 { closeParen = index; break }
                }
            }
            index += 1
        }
        guard let closeParen else { return nil }
        var urlStart = closeBracket + 2
        var urlEnd = closeParen
        while urlStart < urlEnd, Unit.isSpace(window[urlStart]) { urlStart += 1 }
        while urlEnd > urlStart, Unit.isSpace(window[urlEnd - 1]) { urlEnd -= 1 }
        if urlStart < urlEnd, window[urlStart] == Unit.less {
            var close = urlStart + 1
            while close < urlEnd, window[close] != Unit.greater { close += 1 }
            return Link(closeBracket: closeBracket, end: closeParen + 1,
                        urlRange: NSRange(location: urlStart + 1, length: max(0, close - urlStart - 1)))
        }
        // An optional title after whitespace: `(url "title")`.
        var scan = urlStart
        while scan < urlEnd, !Unit.isSpace(window[scan]) { scan += 1 }
        return Link(closeBracket: closeBracket, end: closeParen + 1, urlRange: NSRange(location: urlStart, length: scan - urlStart))
    }

    /// `**…**`, `__…__`, `*…*`, `_…_`, `***…***`, `~~…~~` opening at `index` with a run of `count`.
    /// Returns the index after the closing run, or nil when it does not open anything.
    private func delimited(_ unit: UInt16, _ index: Int, _ count: Int, _ high: Int, marks: inout [NSRange],
                           spans: SpanSink?, allowLinks: Bool) -> Int? {
        if unit == Unit.tilde, count != 2 { return nil }
        guard count <= 3, canOpen(unit, index, count, high) else { return nil }
        guard let close = closing(unit, count, from: index + count, high) else { return nil }
        let content = NSRange(location: index + count, length: close - index - count)
        guard content.length > 0 else { return nil }
        marks.append(NSRange(location: index, length: count))
        let full = NSRange(location: index, length: close + count - index)
        if unit == Unit.tilde {
            spans?.items.append(InlineSpan(kind: .strike, range: content, full: full))
        } else {
            if count >= 2 { spans?.items.append(InlineSpan(kind: .strong, range: content, full: full)) }
            if count != 2 { spans?.items.append(InlineSpan(kind: .emphasis, range: content, full: full)) }
        }
        scan(content.location, close, marks: &marks, spans: spans, allowLinks: allowLinks)
        marks.append(NSRange(location: close, length: count))
        return close + count
    }

    private func canOpen(_ unit: UInt16, _ index: Int, _ count: Int, _ high: Int) -> Bool {
        let after = index + count
        guard after < high, !Unit.isWhitespace(window[after]) else { return false }
        if unit == Unit.underscore, index > 0, Unit.isWordCharacter(window[index - 1]) { return false }
        return true
    }

    private func canClose(_ unit: UInt16, _ index: Int, _ count: Int, _ high: Int) -> Bool {
        guard index > 0, !Unit.isWhitespace(window[index - 1]) else { return false }
        if unit == Unit.underscore, index + count < high, Unit.isWordCharacter(window[index + count]) { return false }
        return true
    }

    /// The closing run of exactly `count` (code spans and escapes skipped).
    private func closing(_ unit: UInt16, _ count: Int, from: Int, _ high: Int) -> Int? {
        var index = from
        while index < high {
            let c = window[index]
            if c == Unit.backslash { index += 2; continue }
            if c == Unit.backtick {
                let length = run(c, index, high)
                if let close = backtickClose(index + length, length, high) { index = close + length; continue }
                index += length
                continue
            }
            if c == unit {
                let length = run(unit, index, high)
                if length == count, index > from, canClose(unit, index, length, high) { return index }
                index += length
                continue
            }
            index += 1
        }
        return nil
    }

    private static let notePrefix: [UInt16] = Array("codd://note/".utf16)
    private static let wikiPrefix: [UInt16] = Array("[[note:".utf16)

    private func matches(_ prefix: [UInt16], at index: Int, _ high: Int) -> Bool {
        guard index + prefix.count <= high else { return false }
        for (offset, unit) in prefix.enumerated() where window[index + offset] != unit { return false }
        return true
    }

    /// The id charset `[a-z0-9]+(-[a-z0-9]+)*`, ≤ 48 units; returns the end of the id.
    private func noteID(from start: Int, _ high: Int) -> Int? {
        var index = start
        var lastWasDash = true
        while index < high, index - start < 48 {
            let c = window[index]
            if Unit.isLowerAlnum(c) {
                lastWasDash = false
            } else if c == Unit.dash, !lastWasDash, index + 1 < high, Unit.isLowerAlnum(window[index + 1]) {
                lastWasDash = true
            } else {
                break
            }
            index += 1
        }
        return index > start && !lastWasDash ? index : nil
    }

    func noteRef(_ index: Int, _ high: Int) -> Int? {
        guard matches(Self.notePrefix, at: index, high) else { return nil }
        return noteID(from: index + Self.notePrefix.count, high)
    }

    private func noteWikiRef(_ index: Int, _ high: Int) -> Int? {
        guard matches(Self.wikiPrefix, at: index, high), let idEnd = noteID(from: index + Self.wikiPrefix.count, high),
              idEnd + 2 <= high, window[idEnd] == Unit.closeBracket, window[idEnd + 1] == Unit.closeBracket
        else { return nil }
        return idEnd + 2
    }

    private static let http: [UInt16] = Array("http://".utf16)
    private static let https: [UInt16] = Array("https://".utf16)

    /// A bare URL up to whitespace, CJK text or a closing bracket; trailing ASCII punctuation is not part of it.
    private func autolink(_ index: Int, _ low: Int, _ high: Int) -> Int? {
        if index > low, Unit.isWordCharacter(window[index - 1]) { return nil }
        let prefix: Int
        if matches(Self.https, at: index, high) { prefix = Self.https.count } else if matches(Self.http, at: index, high) {
            prefix = Self.http.count
        } else {
            return nil
        }
        var end = index + prefix
        while end < high {
            let c = window[end]
            if Unit.isWhitespace(c) || c >= 0x80 || c == Unit.less || c == Unit.greater || c == Unit.quote || c == Unit.closeParen
                || c == Unit.closeBracket || c == Unit.backtick {
                break
            }
            end += 1
        }
        while end > index + prefix, [0x2E, 0x2C, 0x3A, 0x3B, 0x21, 0x3F].contains(window[end - 1]) { end -= 1 }
        return end > index + prefix ? end : nil
    }
}
