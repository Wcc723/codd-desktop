import Foundation

/// What a block is. Blocks are whole lines; only fences, tables and a frontmatter-like block at
/// the very start span several lines.
public enum MarkdownBlockKind: Sendable, Hashable {
    case heading(level: Int)
    case paragraph
    /// `indent` = leading columns / 2 (a tab counts 4 columns).
    case bullet(indent: Int)
    case ordered(indent: Int, number: Int)
    case task(indent: Int, done: Bool)
    case quote
    /// `info` is the trimmed info string (`css`, `swift title="x"`).
    case codeFence(info: String)
    /// A fence whose first info word is in the hidden set (`codd-annotations`) directly after an
    /// image line (§3.3: anywhere else it is an ordinary code block).
    case hiddenFence(info: String)
    /// A line that is exactly one image, `![alt](path)`.
    case image(alt: String, path: String)
    case rule
    case table
    case blank
    /// `---` on the first line through the next `---` / `...` line.
    case frontmatterLike
}

/// One block: its kind, its whole lines (UTF-16, line endings included) and the syntax ranges the
/// live preview hides off the caret (`**`, `*`, `` ` ``, `## `, the list / quote prefix, link
/// syntax, a fence's own lines). The first mark of a list or quote block, when it starts at the
/// line start, is the prefix (indent + marker) that stays hidden even on the caret line.
public struct MarkdownBlock: Sendable, Equatable {
    public var kind: MarkdownBlockKind
    public var range: NSRange
    public var inlineMarks: [NSRange]

    public init(kind: MarkdownBlockKind, range: NSRange, inlineMarks: [NSRange] = []) {
        self.kind = kind
        self.range = range
        self.inlineMarks = inlineMarks
    }
}

/// Line-based Markdown block parser for the live preview: a full parse and an incremental reparse
/// that re-reads only from the block before an edit until the parse meets the old blocks again
/// (so typing restyles one or two lines, and opening a fence restyles what it swallows).
public enum MarkdownBlockParser {
    /// The fences hidden after an image by default (§3.3).
    public static let defaultHiddenFenceInfoStrings: Set<String> = ["codd-annotations"]

    public static func blocks(in text: String) -> [MarkdownBlock] {
        blocks(in: text, hiddenFenceInfoStrings: defaultHiddenFenceInfoStrings)
    }

    public static func blocks(in text: String, hiddenFenceInfoStrings: Set<String>) -> [MarkdownBlock] {
        blocks(in: text as NSString, hiddenFenceInfoStrings: hiddenFenceInfoStrings)
    }

    static func blocks(in text: NSString, hiddenFenceInfoStrings: Set<String>) -> [MarkdownBlock] {
        let window = UTF16Window(text, from: 0, prefetchAll: true)
        var iterator = BlockIterator(window: window, start: 0, state: .documentStart, hidden: hiddenFenceInfoStrings)
        var result: [MarkdownBlock] = []
        result.reserveCapacity(max(16, text.length / 40))
        while let block = iterator.next() {
            result.append(block)
        }
        return result
    }

    /// A full parse that also returns each block's inline spans (one scan per line at load).
    static func blocksWithSpans(in text: NSString, hiddenFenceInfoStrings: Set<String>) -> (blocks: [MarkdownBlock], spans: [[InlineSpan]]) {
        let window = UTF16Window(text, from: 0, prefetchAll: true)
        var iterator = BlockIterator(window: window, start: 0, state: .documentStart, hidden: hiddenFenceInfoStrings, collectSpans: true)
        var blocks: [MarkdownBlock] = []
        var spans: [[InlineSpan]] = []
        blocks.reserveCapacity(max(16, text.length / 40))
        spans.reserveCapacity(max(16, text.length / 40))
        while let block = iterator.next() {
            blocks.append(block)
            spans.append(iterator.spans?.items ?? [])
            iterator.spans?.items.removeAll(keepingCapacity: true)
        }
        return (blocks, spans)
    }

    /// `blocks` parsed from the text before an edit; `edited` is the edited range in the new
    /// `text` and `delta` its change in length (NSTextStorage's `editedRange` / `changeInLength`).
    /// Equal to a full parse of `text`.
    public static func reparse(_ blocks: [MarkdownBlock], text: String, edited: NSRange, delta: Int) -> [MarkdownBlock] {
        reparse(blocks, text: text, edited: edited, delta: delta, hiddenFenceInfoStrings: defaultHiddenFenceInfoStrings)
    }

    public static func reparse(_ blocks: [MarkdownBlock], text: String, edited: NSRange, delta: Int,
                               hiddenFenceInfoStrings: Set<String>) -> [MarkdownBlock] {
        var copy = blocks
        _ = applyEdit(&copy, text: text as NSString, edited: edited, delta: delta, hidden: hiddenFenceInfoStrings)
        return copy
    }

    /// The reparse in place (the editor keeps one array and shifts the untouched tail without
    /// copying it). Returns the indices of the blocks that were parsed anew (in the new array).
    @discardableResult
    static func applyEdit(_ blocks: inout [MarkdownBlock], text: NSString, edited: NSRange, delta: Int,
                          hidden: Set<String>) -> Range<Int> {
        let newLength = text.length
        let oldLength = blocks.last.map { NSMaxRange($0.range) } ?? 0
        let editStart = edited.location
        let editEndNew = NSMaxRange(edited)
        let editEndOld = editEndNew - delta
        guard !blocks.isEmpty, oldLength + delta == newLength, editStart >= 0, editStart <= oldLength,
              editEndNew <= newLength, editEndOld >= editStart
        else {
            blocks = Self.blocks(in: text, hiddenFenceInfoStrings: hidden)
            return 0 ..< blocks.count
        }
        var first = blockIndex(containing: editStart, in: blocks) ?? (blocks.count - 1)
        first = max(0, first - 1)
        let parseStart = blocks[first].range.location
        let state: BlockIterator.State
        if first == 0 {
            state = .documentStart
        } else if case .image = blocks[first - 1].kind {
            state = .afterImage
        } else {
            state = .normal
        }
        // Old blocks starting at or after the old edit end are the resync candidates.
        var candidate = firstBlockIndex(startingAtOrAfter: editEndOld, in: blocks)
        let window = UTF16Window(text, from: parseStart, prefetchAll: false)
        var iterator = BlockIterator(window: window, start: parseStart, state: state, hidden: hidden)
        var parsed: [MarkdownBlock] = []
        var resync: Int?
        while let block = iterator.next() {
            if block.range.location >= editEndNew {
                while candidate < blocks.count, blocks[candidate].range.location + delta < block.range.location {
                    candidate += 1
                }
                if candidate < blocks.count, isShifted(blocks[candidate], by: delta, equalTo: block) {
                    resync = candidate
                    break
                }
            }
            parsed.append(block)
        }
        let tail = resync ?? blocks.count
        if delta != 0, tail < blocks.count {
            for index in tail ..< blocks.count {
                blocks[index].range.location += delta
                for mark in blocks[index].inlineMarks.indices {
                    blocks[index].inlineMarks[mark].location += delta
                }
            }
        }
        blocks.replaceSubrange(first ..< tail, with: parsed)
        return first ..< (first + parsed.count)
    }

    /// The block whose range contains `location` (binary search over tiled blocks); nil when
    /// `location` is at or past the end.
    static func blockIndex(containing location: Int, in blocks: [MarkdownBlock]) -> Int? {
        var low = 0
        var high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = blocks[mid].range
            if location < range.location {
                high = mid - 1
            } else if location >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    static func firstBlockIndex(startingAtOrAfter location: Int, in blocks: [MarkdownBlock]) -> Int {
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].range.location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func isShifted(_ old: MarkdownBlock, by delta: Int, equalTo new: MarkdownBlock) -> Bool {
        guard old.kind == new.kind, old.range.length == new.range.length,
              old.range.location + delta == new.range.location,
              old.inlineMarks.count == new.inlineMarks.count
        else { return false }
        for (a, b) in zip(old.inlineMarks, new.inlineMarks) where a.location + delta != b.location || a.length != b.length {
            return false
        }
        return true
    }
}

// MARK: - Text access

/// UTF-16 units of an NSString from `base` on, fetched in chunks as the parser reads them (a full
/// parse fetches everything at once; an incremental one usually reads a few lines). A raw buffer,
/// not an Array: pointer subscripts are inlined even in debug builds, which keeps a 1 MB parse fast.
final class UTF16Window {
    let text: NSString
    let length: Int
    let base: Int
    private var buffer: UnsafeMutablePointer<UInt16>
    private var capacity: Int
    private var fetchedEnd: Int

    init(_ text: NSString, from base: Int, prefetchAll: Bool) {
        self.text = text
        length = text.length
        self.base = base
        let wanted = prefetchAll ? max(1, length - base) : max(1, min(length - base, 8192))
        capacity = wanted
        buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: capacity)
        fetchedEnd = base
        fetch(upTo: min(length, base + wanted))
    }

    deinit {
        buffer.deallocate()
    }

    /// The unit at `index`; before the window (a look-behind at a line start) it reads the text
    /// itself, past the end it is 0.
    @inline(__always)
    subscript(index: Int) -> UInt16 {
        if index >= base, index < fetchedEnd { return buffer[index - base] }
        return unit(outside: index)
    }

    private func unit(outside index: Int) -> UInt16 {
        if index < base { return index >= 0 ? text.character(at: index) : 0 }
        guard index < length else { return 0 }
        fetch(upTo: min(length, max(index + 1, base + (fetchedEnd - base) * 2 + 8192)))
        return buffer[index - base]
    }

    private func fetch(upTo end: Int) {
        guard end > fetchedEnd else { return }
        let needed = end - base
        if needed > capacity {
            let grown = UnsafeMutablePointer<UInt16>.allocate(capacity: needed)
            grown.update(from: buffer, count: fetchedEnd - base)
            buffer.deallocate()
            buffer = grown
            capacity = needed
        }
        text.getCharacters(buffer + (fetchedEnd - base), range: NSRange(location: fetchedEnd, length: end - fetchedEnd))
        fetchedEnd = end
    }

    func string(_ range: NSRange) -> String {
        text.substring(with: range)
    }
}

enum Unit {
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let hash: UInt16 = 0x23
    static let star: UInt16 = 0x2A
    static let dash: UInt16 = 0x2D
    static let plus: UInt16 = 0x2B
    static let underscore: UInt16 = 0x5F
    static let tilde: UInt16 = 0x7E
    static let backtick: UInt16 = 0x60
    static let greater: UInt16 = 0x3E
    static let less: UInt16 = 0x3C
    static let pipe: UInt16 = 0x7C
    static let bang: UInt16 = 0x21
    static let openBracket: UInt16 = 0x5B
    static let closeBracket: UInt16 = 0x5D
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let backslash: UInt16 = 0x5C
    static let dot: UInt16 = 0x2E
    static let colon: UInt16 = 0x3A
    static let quote: UInt16 = 0x22
    static let ideographicSpace: UInt16 = 0x3000

    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }
    @inline(__always) static func isWhitespace(_ c: UInt16) -> Bool {
        c == space || c == tab || c == newline || c == carriageReturn || c == ideographicSpace
    }
    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) static func isLowerAlnum(_ c: UInt16) -> Bool { isDigit(c) || (c >= 0x61 && c <= 0x7A) }
    @inline(__always) static func isASCIIPunctuation(_ c: UInt16) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
    /// Word characters for intraword `_` (CJK counts as a word character; its punctuation does not).
    @inline(__always) static func isWordCharacter(_ c: UInt16) -> Bool {
        if c < 0x80 { return isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        if (c >= 0x3000 && c <= 0x303F) || (c >= 0xFF00 && c <= 0xFF0F) || (c >= 0xFF1A && c <= 0xFF20) { return false }
        return true
    }
}

// MARK: - Block iterator

struct BlockIterator {
    enum State: Equatable { case documentStart, normal, afterImage }

    let window: UTF16Window
    let hidden: Set<String>
    private var position: Int
    private var state: State
    /// When set, the inline spans of each block are collected here too (the editor's load styles
    /// from them instead of scanning every line a second time). Reset by the caller per block.
    let spans: SpanSink?

    init(window: UTF16Window, start: Int, state: State, hidden: Set<String>, collectSpans: Bool = false) {
        self.window = window
        self.hidden = hidden
        position = start
        self.state = state
        spans = collectSpans ? SpanSink() : nil
    }

    /// `(content end, line end)`: the line's last content unit and the start of the next line.
    func line(at start: Int) -> (contentEnd: Int, lineEnd: Int) {
        let length = window.length
        var index = start
        while index < length {
            let c = window[index]
            if c == Unit.newline { return (index, index + 1) }
            if c == Unit.carriageReturn {
                if index + 1 < length, window[index + 1] == Unit.newline { return (index, index + 2) }
                return (index, index + 1)
            }
            index += 1
        }
        return (length, length)
    }

    /// Leading indentation in columns and the first non-space index.
    func indent(_ start: Int, _ contentEnd: Int) -> (columns: Int, first: Int) {
        var columns = 0
        var index = start
        while index < contentEnd {
            let c = window[index]
            if c == Unit.space { columns += 1 } else if c == Unit.tab { columns += 4 - columns % 4 } else { break }
            index += 1
        }
        return (columns, index)
    }

    func run(of unit: UInt16, at start: Int, end: Int) -> Int {
        var index = start
        while index < end, window[index] == unit { index += 1 }
        return index - start
    }

    func isBlank(_ start: Int, _ contentEnd: Int) -> Bool {
        var index = start
        while index < contentEnd {
            if !Unit.isSpace(window[index]) { return false }
            index += 1
        }
        return true
    }

    mutating func next() -> MarkdownBlock? {
        guard position < window.length else { return nil }
        let start = position
        let (contentEnd, lineEnd) = line(at: start)
        let atDocumentStart = state == .documentStart && start == 0
        let afterImage = state == .afterImage
        state = .normal

        if atDocumentStart, let end = frontmatterEnd(start, contentEnd, lineEnd) {
            return finish(MarkdownBlock(kind: .frontmatterLike, range: NSRange(location: start, length: end - start)), end: end)
        }
        let (columns, first) = indent(start, contentEnd)
        if columns <= 3, let fence = fenceOpening(first, contentEnd) {
            return finish(fenceBlock(start, lineEnd, fence, afterImage: afterImage), end: nil)
        }
        if isBlank(start, contentEnd) {
            return finish(MarkdownBlock(kind: .blank, range: NSRange(location: start, length: lineEnd - start)), end: lineEnd)
        }
        let lineRange = NSRange(location: start, length: lineEnd - start)
        let c = window[first]
        if columns <= 3, c == Unit.hash, let block = heading(start, first, contentEnd, lineRange) {
            return finish(block, end: lineEnd)
        }
        if columns <= 3, c == Unit.dash || c == Unit.star || c == Unit.underscore, isRule(first, contentEnd, c) {
            return finish(MarkdownBlock(kind: .rule, range: lineRange), end: lineEnd)
        }
        if c == Unit.dash || c == Unit.star || c == Unit.plus, first + 1 < contentEnd, Unit.isSpace(window[first + 1]) {
            return finish(listItem(start, first, columns, contentEnd, lineRange), end: lineEnd)
        }
        if Unit.isDigit(c), let block = orderedItem(start, first, columns, contentEnd, lineRange) {
            return finish(block, end: lineEnd)
        }
        if columns <= 3, c == Unit.greater {
            var contentStart = first + 1
            if contentStart < contentEnd, Unit.isSpace(window[contentStart]) { contentStart += 1 }
            var marks = [NSRange(location: start, length: contentStart - start)]
            InlineScanner(window: window).scan(contentStart, contentEnd, marks: &marks, spans: spans)
            return finish(MarkdownBlock(kind: .quote, range: lineRange, inlineMarks: marks), end: lineEnd)
        }
        if columns <= 3, c == Unit.pipe {
            var end = lineEnd
            while end < window.length {
                let (nextContentEnd, nextLineEnd) = line(at: end)
                let (nextColumns, nextFirst) = indent(end, nextContentEnd)
                guard nextColumns <= 3, nextFirst < nextContentEnd, window[nextFirst] == Unit.pipe else { break }
                end = nextLineEnd
            }
            return finish(MarkdownBlock(kind: .table, range: NSRange(location: start, length: end - start)), end: end)
        }
        if c == Unit.bang, let block = imageLine(first, contentEnd, lineRange) {
            state = .afterImage
            position = lineEnd
            return block
        }
        var marks: [NSRange] = []
        InlineScanner(window: window).scan(first, contentEnd, marks: &marks, spans: spans)
        return finish(MarkdownBlock(kind: .paragraph, range: lineRange, inlineMarks: marks), end: lineEnd)
    }

    private mutating func finish(_ block: MarkdownBlock, end: Int?) -> MarkdownBlock {
        position = end ?? NSMaxRange(block.range)
        return block
    }

    // MARK: Kinds

    private func frontmatterEnd(_ start: Int, _ contentEnd: Int, _ lineEnd: Int) -> Int? {
        guard run(of: Unit.dash, at: start, end: contentEnd) == 3, isBlank(start + 3, contentEnd), lineEnd < window.length else {
            return nil
        }
        var cursor = lineEnd
        while cursor < window.length {
            let (end, next) = line(at: cursor)
            let dashes = run(of: Unit.dash, at: cursor, end: end)
            let dots = run(of: Unit.dot, at: cursor, end: end)
            if (dashes == 3 && isBlank(cursor + 3, end)) || (dots == 3 && isBlank(cursor + 3, end)) { return next }
            cursor = next
        }
        return nil
    }

    struct Fence {
        let unit: UInt16
        let count: Int
        let info: String
    }

    private func fenceOpening(_ first: Int, _ contentEnd: Int) -> Fence? {
        let c = window[first]
        guard c == Unit.backtick || c == Unit.tilde else { return nil }
        let count = run(of: c, at: first, end: contentEnd)
        guard count >= 3 else { return nil }
        var infoStart = first + count
        while infoStart < contentEnd, Unit.isSpace(window[infoStart]) { infoStart += 1 }
        var infoEnd = contentEnd
        while infoEnd > infoStart, Unit.isSpace(window[infoEnd - 1]) { infoEnd -= 1 }
        if c == Unit.backtick {
            var index = infoStart
            while index < infoEnd {
                if window[index] == Unit.backtick { return nil }
                index += 1
            }
        }
        let info = infoEnd > infoStart ? window.string(NSRange(location: infoStart, length: infoEnd - infoStart)) : ""
        return Fence(unit: c, count: count, info: info)
    }

    private func isFenceClosing(_ start: Int, _ contentEnd: Int, _ fence: Fence) -> Bool {
        let (columns, first) = indent(start, contentEnd)
        guard columns <= 3, first < contentEnd, window[first] == fence.unit else { return false }
        let count = run(of: fence.unit, at: first, end: contentEnd)
        return count >= fence.count && isBlank(first + count, contentEnd)
    }

    private func fenceBlock(_ start: Int, _ lineEnd: Int, _ fence: Fence, afterImage: Bool) -> MarkdownBlock {
        var marks = [NSRange(location: start, length: lineEnd - start)]
        var cursor = lineEnd
        var end = window.length
        while cursor < window.length {
            let (contentEnd, next) = line(at: cursor)
            if isFenceClosing(cursor, contentEnd, fence) {
                marks.append(NSRange(location: cursor, length: next - cursor))
                end = next
                break
            }
            cursor = next
        }
        let word = fence.info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { $0.lowercased() } ?? ""
        let kind: MarkdownBlockKind = afterImage && hidden.contains(word) ? .hiddenFence(info: fence.info) : .codeFence(info: fence.info)
        return MarkdownBlock(kind: kind, range: NSRange(location: start, length: end - start), inlineMarks: marks)
    }

    private func heading(_ start: Int, _ first: Int, _ contentEnd: Int, _ lineRange: NSRange) -> MarkdownBlock? {
        let level = run(of: Unit.hash, at: first, end: contentEnd)
        guard level >= 1, level <= 6 else { return nil }
        var contentStart = first + level
        guard contentStart == contentEnd || Unit.isSpace(window[contentStart]) else { return nil }
        while contentStart < contentEnd, Unit.isSpace(window[contentStart]) { contentStart += 1 }
        // A closing sequence (`## Title ##`) is syntax too.
        var textEnd = contentEnd
        while textEnd > contentStart, Unit.isSpace(window[textEnd - 1]) { textEnd -= 1 }
        var closingStart = textEnd
        while closingStart > contentStart, window[closingStart - 1] == Unit.hash { closingStart -= 1 }
        var closing: NSRange?
        if closingStart < textEnd, closingStart > contentStart, Unit.isSpace(window[closingStart - 1]) {
            var spaceStart = closingStart
            while spaceStart > contentStart, Unit.isSpace(window[spaceStart - 1]) { spaceStart -= 1 }
            closing = NSRange(location: spaceStart, length: contentEnd - spaceStart)
            textEnd = spaceStart
        }
        var marks = [NSRange(location: start, length: contentStart - start)]
        InlineScanner(window: window).scan(contentStart, textEnd, marks: &marks, spans: spans)
        if let closing { marks.append(closing) }
        return MarkdownBlock(kind: .heading(level: level), range: lineRange, inlineMarks: marks)
    }

    private func isRule(_ first: Int, _ contentEnd: Int, _ unit: UInt16) -> Bool {
        var count = 0
        var index = first
        while index < contentEnd {
            let c = window[index]
            if c == unit { count += 1 } else if !Unit.isSpace(c) { return false }
            index += 1
        }
        return count >= 3
    }

    private func listItem(_ start: Int, _ first: Int, _ columns: Int, _ contentEnd: Int, _ lineRange: NSRange) -> MarkdownBlock {
        var afterMarker = first + 1
        while afterMarker < contentEnd, Unit.isSpace(window[afterMarker]) { afterMarker += 1 }
        let indent = columns / 2
        // Task: `- [ ] ` / `- [x] `; the box stays visible text, the `- ` before it is the prefix.
        if afterMarker + 3 <= contentEnd, window[afterMarker] == Unit.openBracket, window[afterMarker + 2] == Unit.closeBracket {
            let mark = window[afterMarker + 1]
            let boxEnd = afterMarker + 3
            if mark == Unit.space || mark == 0x78 || mark == 0x58, boxEnd == contentEnd || Unit.isSpace(window[boxEnd]) {
                var contentStart = boxEnd
                while contentStart < contentEnd, Unit.isSpace(window[contentStart]) { contentStart += 1 }
                var marks = [NSRange(location: start, length: afterMarker - start)]
                InlineScanner(window: window).scan(contentStart, contentEnd, marks: &marks, spans: spans)
                return MarkdownBlock(kind: .task(indent: indent, done: mark != Unit.space), range: lineRange, inlineMarks: marks)
            }
        }
        var marks = [NSRange(location: start, length: afterMarker - start)]
        InlineScanner(window: window).scan(afterMarker, contentEnd, marks: &marks, spans: spans)
        return MarkdownBlock(kind: .bullet(indent: indent), range: lineRange, inlineMarks: marks)
    }

    private func orderedItem(_ start: Int, _ first: Int, _ columns: Int, _ contentEnd: Int, _ lineRange: NSRange) -> MarkdownBlock? {
        var index = first
        var number = 0
        while index < contentEnd, Unit.isDigit(window[index]), index - first < 9 {
            number = number * 10 + Int(window[index] - 0x30)
            index += 1
        }
        guard index > first, index < contentEnd, window[index] == Unit.dot || window[index] == Unit.closeParen,
              index + 1 < contentEnd, Unit.isSpace(window[index + 1])
        else { return nil }
        var contentStart = index + 1
        while contentStart < contentEnd, Unit.isSpace(window[contentStart]) { contentStart += 1 }
        var marks: [NSRange] = []
        if first > start { marks.append(NSRange(location: start, length: first - start)) }
        InlineScanner(window: window).scan(contentStart, contentEnd, marks: &marks, spans: spans)
        return MarkdownBlock(kind: .ordered(indent: columns / 2, number: number), range: lineRange, inlineMarks: marks)
    }

    private func imageLine(_ first: Int, _ contentEnd: Int, _ lineRange: NSRange) -> MarkdownBlock? {
        guard first + 1 < contentEnd, window[first + 1] == Unit.openBracket else { return nil }
        var end = contentEnd
        while end > first, Unit.isSpace(window[end - 1]) { end -= 1 }
        let scanner = InlineScanner(window: window)
        guard let link = scanner.link(at: first + 1, end: end), link.end == end else { return nil }
        let alt = window.string(NSRange(location: first + 2, length: link.closeBracket - first - 2))
        let marks = [NSRange(location: first, length: 2), NSRange(location: link.closeBracket, length: end - link.closeBracket)]
        return MarkdownBlock(kind: .image(alt: alt, path: window.string(link.urlRange)), range: lineRange, inlineMarks: marks)
    }
}
