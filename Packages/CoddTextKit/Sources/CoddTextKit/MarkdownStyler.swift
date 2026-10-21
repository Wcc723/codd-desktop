import AppKit

extension NSAttributedString.Key {
    /// Inline code content: the layout manager draws the helmet `code` box behind it.
    static let coddInlineCode = NSAttributedString.Key("codd.inlineCode")
    /// A `codd://note/<id>` reference: drawn as the amber chip.
    static let coddChip = NSAttributedString.Key("codd.chip")
    /// The target a click opens (`[text](url)`, a bare URL, a note ref); not `.link`, so AppKit's
    /// own link handling and styling stay out of the way.
    static let coddLink = NSAttributedString.Key("codd.link")
    /// The `[x]` / `[ ]` of a task line: a click toggles it.
    static let coddTaskBox = NSAttributedString.Key("codd.taskBox")
}

/// Turns blocks into text-storage attributes: fonts, colors, fixed line heights and indents, the
/// custom keys the layout manager draws from. Attributes never depend on the caret (what the caret
/// reveals is glyph generation, not attributes), so moving the caret never edits the storage.
final class MarkdownStyler {
    let style: MarkdownEditorStyle
    let mode: MarkdownEditorMode
    private var paragraphStyles: [ParagraphKey: NSParagraphStyle] = [:]
    private var baseCache: [BaseKey: [NSAttributedString.Key: Any]] = [:]
    /// Per block kind: its base attributes (the front cache of `base(for:)`).
    private var kindCache: [MarkdownBlockKind: [NSAttributedString.Key: Any]] = [:]
    /// Per block kind: its base attributes with the mark color and no tracking.
    private var markCache: [MarkdownBlockKind: [NSAttributedString.Key: Any]] = [:]

    private struct ParagraphKey: Hashable {
        let height: CGFloat
        let first: CGFloat
        let head: CGFloat
        let tail: CGFloat
    }

    private enum BaseKey: Hashable {
        case title, heading2, heading3, minorHeading, body, task, code, fenceLine, source
        case list(first: CGFloat, head: CGFloat, task: Bool)
        case quote
        case muted
    }

    /// Kern room for the inline code and chip boxes the editor draws (a read-only card draws none).
    let padsInlineBoxes: Bool

    init(style: MarkdownEditorStyle, mode: MarkdownEditorMode, padsInlineBoxes: Bool = true) {
        self.style = style
        self.mode = mode
        self.padsInlineBoxes = padsInlineBoxes
    }

    // MARK: Line metrics shared with the layout

    /// The fixed height of one text line of `kind` and the font its baseline is centered for.
    func line(for kind: MarkdownBlockKind) -> (height: CGFloat, font: NSFont) {
        if mode == .source { return (style.sourceFont.pointSize * style.sourceLineHeight, style.sourceFont) }
        switch kind {
        case let .heading(level):
            switch level {
            case 1: return (style.titleFont.pointSize * style.titleLineHeight, style.titleFont)
            case 2: return (style.heading2Font.pointSize * style.heading2LineHeight, style.heading2Font)
            case 3: return (style.heading3Font.pointSize * style.headingLineHeight, style.heading3Font)
            default: return (style.minorHeadingFont.pointSize * style.headingLineHeight, style.minorHeadingFont)
            }
        case .task:
            return (style.bodyFont.pointSize * style.taskLineHeight, style.bodyFont)
        case .codeFence, .hiddenFence, .frontmatterLike:
            return (style.codeFont.pointSize * style.codeLineHeight, style.codeFont)
        default:
            return (style.bodyFont.pointSize * style.bodyLineHeight, style.bodyFont)
        }
    }

    func paragraphStyle(height: CGFloat, first: CGFloat = 0, head: CGFloat = 0, tail: CGFloat = 0) -> NSParagraphStyle {
        let key = ParagraphKey(height: height, first: first, head: head, tail: tail)
        if let cached = paragraphStyles[key] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.firstLineHeadIndent = first
        paragraph.headIndent = head
        paragraph.tailIndent = tail
        paragraph.lineBreakMode = .byWordWrapping
        paragraphStyles[key] = paragraph
        return paragraph
    }

    private func attributes(_ key: BaseKey, font: NSFont, color: NSColor, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        if let cached = baseCache[key] { return cached }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .ligature: 0]
        if style.bodyTracking != 0 { attributes[.kern] = style.bodyTracking * font.pointSize }
        baseCache[key] = attributes
        return attributes
    }

    /// The attributes a whole block line starts from (also the typing attributes on that line).
    func base(for kind: MarkdownBlockKind) -> [NSAttributedString.Key: Any] {
        if let cached = kindCache[kind] { return cached }
        let attributes = makeBase(for: kind)
        kindCache[kind] = attributes
        return attributes
    }

    private func makeBase(for kind: MarkdownBlockKind) -> [NSAttributedString.Key: Any] {
        let (height, _) = line(for: kind)
        if mode == .source {
            return attributes(.source, font: style.sourceFont, color: style.text, paragraph: paragraphStyle(height: height))
        }
        switch kind {
        case let .heading(level):
            switch level {
            case 1: return attributes(.title, font: style.titleFont, color: style.title, paragraph: paragraphStyle(height: height))
            case 2: return attributes(.heading2, font: style.heading2Font, color: style.heading, paragraph: paragraphStyle(height: height))
            case 3: return attributes(.heading3, font: style.heading3Font, color: style.minorHeading, paragraph: paragraphStyle(height: height))
            default:
                return attributes(.minorHeading, font: style.minorHeadingFont, color: style.minorHeading, paragraph: paragraphStyle(height: height))
            }
        case let .bullet(indent):
            let first = style.listIndent * CGFloat(indent + 1)
            return attributes(.list(first: first, head: first, task: false), font: style.bodyFont, color: style.text,
                              paragraph: paragraphStyle(height: height, first: first, head: first))
        case let .ordered(indent, number):
            let first = style.listIndent * CGFloat(indent)
            let digits = CGFloat(String(number).count + 2)
            let head = first + digits * (advance(of: style.bodyFont) + style.bodyTracking * style.bodyFont.pointSize)
            return attributes(.list(first: first, head: head, task: false), font: style.bodyFont, color: style.text,
                              paragraph: paragraphStyle(height: height, first: first, head: head))
        case let .task(indent, _):
            let first = style.listIndent * CGFloat(indent)
            let head = first + style.taskBoxWidth
            return attributes(.list(first: first, head: head, task: true), font: style.bodyFont, color: style.text,
                              paragraph: paragraphStyle(height: height, first: first, head: head))
        case .quote:
            return attributes(.quote, font: style.bodyFont, color: style.text,
                              paragraph: paragraphStyle(height: height, first: style.quoteIndent, head: style.quoteIndent))
        case .codeFence:
            let left = style.codePadding.left + 1
            let right = style.codePadding.right + 1
            return attributes(.code, font: style.codeFont, color: style.codeText,
                              paragraph: paragraphStyle(height: height, first: left, head: left, tail: -right))
        case .hiddenFence, .frontmatterLike:
            return attributes(.fenceLine, font: style.codeFont, color: style.mark, paragraph: paragraphStyle(height: height))
        case .image, .rule:
            return attributes(.muted, font: style.bodyFont, color: style.mark, paragraph: paragraphStyle(height: height))
        default:
            return attributes(.body, font: style.bodyFont, color: style.text, paragraph: paragraphStyle(height: height))
        }
    }

    /// A mark's attributes on a `kind` line: one `setAttributes` (cheaper than merging into the base).
    func markAttributes(for kind: MarkdownBlockKind) -> [NSAttributedString.Key: Any] {
        if let cached = markCache[kind] { return cached }
        var attributes = base(for: kind)
        attributes[.foregroundColor] = style.mark
        attributes[.kern] = 0
        markCache[kind] = attributes
        return attributes
    }

    /// The width of one monospaced cell.
    func advance(of font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Applying

    func apply<C: Collection>(_ blocks: C, to storage: NSMutableAttributedString, window: UTF16Window) where C.Element == MarkdownBlock {
        for block in blocks {
            apply(block, to: storage, window: window)
        }
    }

    /// Styles blocks with the spans their parse already found (`blocksWithSpans`).
    func apply(_ blocks: [MarkdownBlock], spans: [[InlineSpan]], to storage: NSMutableAttributedString, window: UTF16Window) {
        for (index, block) in blocks.enumerated() {
            apply(block, to: storage, window: window, spans: index < spans.count ? spans[index] : nil)
        }
    }

    func apply(_ block: MarkdownBlock, to storage: NSMutableAttributedString, window: UTF16Window, spans known: [InlineSpan]? = nil) {
        let range = block.range
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.setAttributes(base(for: block.kind), range: range)
        let marks = block.inlineMarks
        switch block.kind {
        case .heading, .paragraph, .bullet, .ordered, .task, .quote:
            let content = Self.contentRange(of: block, window: window)
            let spans: [InlineSpan]
            if let known {
                spans = known
            } else {
                let sink = SpanSink()
                var scratch: [NSRange] = []
                InlineScanner(window: window).scan(content.location, NSMaxRange(content), marks: &scratch, spans: sink)
                spans = sink.items
            }
            // Marks first: no tracking (a hidden glyph would still advance by its kern), then the
            // spans, whose box padding may sit on a mark.
            let markAttributes = markAttributes(for: block.kind)
            for mark in marks { storage.setAttributes(markAttributes, range: mark) }
            applySpans(spans, to: storage, kind: block.kind, window: window, lineStart: range.location)
            applyKindDetails(block, to: storage, content: content, window: window)
        case let .codeFence(info):
            for mark in marks { storage.addAttribute(.foregroundColor, value: style.mark, range: mark) }
            if mode == .source { storage.addAttribute(.foregroundColor, value: style.codeText, range: Self.codeInterior(of: block)) }
            highlight(Self.codeInterior(of: block), language: info, in: storage, window: window)
        case .image:
            for mark in marks { storage.addAttribute(.foregroundColor, value: style.mark, range: mark) }
            if marks.count == 2 {
                let alt = NSRange(location: NSMaxRange(marks[0]), length: marks[1].location - NSMaxRange(marks[0]))
                storage.addAttribute(.foregroundColor, value: style.text, range: alt)
            }
        case .table:
            var index = range.location
            let end = NSMaxRange(range)
            while index < end {
                if window[index] == Unit.pipe { storage.addAttribute(.foregroundColor, value: style.tablePipe, range: NSRange(location: index, length: 1)) }
                index += 1
            }
        case .hiddenFence, .rule, .blank, .frontmatterLike:
            if mode == .source, case .rule = block.kind { storage.addAttribute(.foregroundColor, value: style.mark, range: range) }
            if mode == .source, case .hiddenFence = block.kind { storage.addAttribute(.foregroundColor, value: style.mark, range: range) }
        }
    }

    private func applyKindDetails(_ block: MarkdownBlock, to storage: NSMutableAttributedString, content: NSRange, window: UTF16Window) {
        switch block.kind {
        case .heading(let level):
            let tracking = level == 1 ? style.titleTracking : (level == 2 ? style.heading2Tracking : 0)
            if mode == .livePreview, tracking > 0 {
                let font = level == 1 ? style.titleFont : style.heading2Font
                storage.addAttribute(.kern, value: tracking * font.pointSize, range: content)
            }
            if mode == .source {
                storage.addAttribute(.foregroundColor, value: style.heading, range: content)
                for mark in block.inlineMarks { storage.addAttribute(.foregroundColor, value: style.mark, range: mark) }
            }
        case .ordered:
            // The number and its `.` / `)` in the bullet color.
            let index = content.location
            var end = index
            while end < NSMaxRange(content), Unit.isDigit(window[end]) { end += 1 }
            if end < NSMaxRange(content) { end += 1 }
            storage.addAttribute(.foregroundColor, value: style.bullet, range: NSRange(location: index, length: end - index))
        case let .task(_, done):
            guard let prefix = block.inlineMarks.first else { return }
            let box = NSRange(location: NSMaxRange(prefix), length: 3)
            guard NSMaxRange(box) <= NSMaxRange(block.range) else { return }
            storage.addAttribute(.foregroundColor, value: style.taskBox, range: box)
            storage.addAttribute(.coddTaskBox, value: true, range: box)
            if done {
                storage.addAttributes([.foregroundColor: style.taskCheck, .font: mode == .source ? style.sourceFont : style.boldFont],
                                      range: NSRange(location: box.location + 1, length: 1))
            }
            if mode == .livePreview {
                // The space after the box reaches the artboard's 36 pt text start.
                let used = 4 * advance(of: style.bodyFont) + 3 * style.bodyTracking * style.bodyFont.pointSize
                let spaceIndex = NSMaxRange(box)
                if spaceIndex < NSMaxRange(block.range), Unit.isSpace(window[spaceIndex]), style.taskBoxWidth > used {
                    storage.addAttribute(.kern, value: style.taskBoxWidth - used, range: NSRange(location: spaceIndex, length: 1))
                }
                if done {
                    let text = NSRange(location: content.location, length: NSMaxRange(content) - content.location)
                    if let start = firstContent(after: NSMaxRange(box), end: NSMaxRange(content), window: window) {
                        let doneRange = NSRange(location: start, length: NSMaxRange(text) - start)
                        storage.addAttributes([
                            .foregroundColor: style.doneText,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: style.doneStrike,
                        ], range: doneRange)
                    }
                }
            }
        default:
            break
        }
    }

    private func firstContent(after index: Int, end: Int, window: UTF16Window) -> Int? {
        var cursor = index
        while cursor < end, Unit.isSpace(window[cursor]) { cursor += 1 }
        return cursor < end ? cursor : nil
    }

    private func applySpans(_ spans: [InlineSpan], to storage: NSMutableAttributedString, kind: MarkdownBlockKind,
                            window: UTF16Window, lineStart: Int) {
        guard !spans.isEmpty else { return }
        // The scanner emits outer spans first, so a code span inside `**…**` keeps its own font.
        let ordered = spans
        var isHeading = false
        if case .heading = kind { isHeading = true }
        let preview = mode == .livePreview
        for span in ordered where span.range.length > 0 {
            switch span.kind {
            case .strong:
                if !isHeading {
                    if preview { storage.addAttribute(.font, value: style.boldFont, range: span.range) }
                    storage.addAttribute(.foregroundColor, value: style.strong, range: span.range)
                }
            case .emphasis:
                storage.addAttribute(.obliqueness, value: style.italicObliqueness, range: span.range)
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: style.mark], range: span.range)
            case .code:
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.inlineCodeText]
                if preview {
                    attributes[.font] = style.inlineCodeFont
                    attributes[.coddInlineCode] = true
                }
                storage.addAttributes(attributes, range: span.range)
                if preview, padsInlineBoxes { pad(span, in: storage, by: style.inlineCodePadding, lineStart: lineStart) }
            case let .link(url):
                storage.addAttribute(.coddLink, value: url, range: span.full)
                if url.hasPrefix("codd://note/") {
                    chip(span, in: storage, lineStart: lineStart)
                } else {
                    storage.addAttribute(.foregroundColor, value: style.link, range: span.range)
                }
            case let .image(path):
                storage.addAttribute(.coddLink, value: path, range: span.full)
                storage.addAttribute(.foregroundColor, value: style.link, range: span.range)
            case let .noteRef(id):
                storage.addAttribute(.coddLink, value: "codd://note/\(id)", range: span.full)
                chip(span, in: storage, lineStart: lineStart)
            case let .autolink(url):
                storage.addAttribute(.coddLink, value: url, range: span.full)
                storage.addAttribute(.foregroundColor, value: style.link, range: span.range)
            }
        }
    }

    private func chip(_ span: InlineSpan, in storage: NSMutableAttributedString, lineStart: Int) {
        storage.addAttribute(.foregroundColor, value: style.chipText, range: span.range)
        guard mode == .livePreview, padsInlineBoxes else { return }
        storage.addAttribute(.coddChip, value: true, range: span.range)
        pad(span, in: storage, by: style.chipPadding, lineStart: lineStart)
    }

    /// Room for a box drawn around `span.range`: kern after the character before the span and
    /// after its last character (the text itself never changes).
    private func pad(_ span: InlineSpan, in storage: NSMutableAttributedString, by padding: CGFloat, lineStart: Int) {
        let tracking = style.bodyTracking * style.bodyFont.pointSize
        if span.full.location > lineStart {
            storage.addAttribute(.kern, value: padding + tracking, range: NSRange(location: span.full.location - 1, length: 1))
        }
        storage.addAttribute(.kern, value: padding + tracking, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
    }

    private func highlight(_ interior: NSRange, language info: String, in storage: NSMutableAttributedString, window: UTF16Window) {
        guard interior.length > 0 else { return }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard MarkdownCodeHighlighter.supports(language) else { return }
        let code = window.string(interior)
        for (range, token) in MarkdownCodeHighlighter.spans(code: code, language: language) {
            let target = NSRange(location: interior.location + range.location, length: range.length)
            guard NSMaxRange(target) <= NSMaxRange(interior) else { continue }
            switch token {
            case .keyword: storage.addAttribute(.foregroundColor, value: style.codeKeyword, range: target)
            case .string, .number: storage.addAttribute(.foregroundColor, value: style.codeString, range: target)
            case .comment: storage.addAttributes([.foregroundColor: style.codeComment, .obliqueness: style.italicObliqueness], range: target)
            case .punctuation: storage.addAttribute(.foregroundColor, value: style.codePunctuation, range: target)
            }
        }
    }

    // MARK: Ranges

    /// The text of a line block without its prefix mark and line ending.
    static func contentRange(of block: MarkdownBlock, window: UTF16Window) -> NSRange {
        var start = block.range.location
        switch block.kind {
        case .heading, .bullet, .task, .quote:
            if let first = block.inlineMarks.first, first.location == block.range.location { start = NSMaxRange(first) }
        case .ordered:
            if let first = block.inlineMarks.first, first.location == block.range.location { start = NSMaxRange(first) }
        default:
            break
        }
        let end = lineContentEnd(of: block.range, window: window)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The end of a line's content (before `\n`, `\r\n` or `\r`).
    static func lineContentEnd(of range: NSRange, window: UTF16Window) -> Int {
        var end = NSMaxRange(range)
        if end > range.location, window[end - 1] == Unit.newline { end -= 1 }
        if end > range.location, window[end - 1] == Unit.carriageReturn { end -= 1 }
        return end
    }

    /// The lines between a fence's opening and closing lines.
    static func codeInterior(of block: MarkdownBlock) -> NSRange {
        let start = block.inlineMarks.first.map(NSMaxRange) ?? block.range.location
        let end = block.inlineMarks.count > 1 ? block.inlineMarks[1].location : NSMaxRange(block.range)
        return NSRange(location: start, length: max(0, end - start))
    }
}
