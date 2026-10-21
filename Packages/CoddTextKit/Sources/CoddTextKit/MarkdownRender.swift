import AppKit

/// Read-only rendering for cards (the condense preview, the notes drawer): the editor's styling
/// with the syntax removed from the string (no glyph hiding outside the editor). Bullets become
/// `▪`, tasks keep their `[x]` / `[ ]`, images become `[圖片] <alt>`, hidden fences and the
/// frontmatter are dropped, runs of blank lines collapse to one.
public enum MarkdownRender {
    @MainActor
    public static func attributedPreview(_ markdown: String, style: MarkdownEditorStyle, maxLines: Int?) -> NSAttributedString {
        let text = markdown as NSString
        let blocks = MarkdownBlockParser.blocks(in: text, hiddenFenceInfoStrings: MarkdownBlockParser.defaultHiddenFenceInfoStrings)
        let styler = MarkdownStyler(style: style, mode: .livePreview, padsInlineBoxes: false)
        let window = UTF16Window(text, from: 0, prefetchAll: true)
        let output = NSMutableAttributedString()
        var lines = 0
        var lastWasBlank = true
        var truncated = false
        func appendLine(_ line: NSAttributedString) -> Bool {
            if let maxLines, lines >= maxLines {
                truncated = true
                return false
            }
            if output.length > 0 { output.append(NSAttributedString(string: "\n", attributes: styler.base(for: .paragraph))) }
            output.append(line)
            lines += 1
            return true
        }
        blockLoop: for block in blocks {
            switch block.kind {
            case .hiddenFence, .frontmatterLike:
                continue
            case .blank:
                if !lastWasBlank, output.length > 0 {
                    guard appendLine(NSAttributedString(string: "", attributes: styler.base(for: .paragraph))) else { break blockLoop }
                }
                lastWasBlank = true
                continue
            case let .image(alt, _):
                let attributes = styler.base(for: .image(alt: alt, path: ""))
                guard appendLine(NSAttributedString(string: "[圖片] " + alt, attributes: attributes)) else { break blockLoop }
            case .codeFence:
                let interior = MarkdownStyler.codeInterior(of: block)
                let styled = styledCopy(block, styler: styler, window: window, text: text)
                let code = styled.attributedSubstring(from: NSRange(location: interior.location - block.range.location, length: interior.length))
                for codeLine in splitLines(code) {
                    guard appendLine(codeLine) else { break blockLoop }
                }
            default:
                let styled = styledCopy(block, styler: styler, window: window, text: text)
                guard appendLine(stripped(styled, block: block, styler: styler, style: style, window: window)) else { break blockLoop }
            }
            lastWasBlank = false
        }
        // No trailing empty line.
        while output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        if truncated {
            output.append(NSAttributedString(string: "…", attributes: styler.base(for: .paragraph)))
        }
        return output
    }

    /// The block's text styled exactly as the editor styles it.
    private static func styledCopy(_ block: MarkdownBlock, styler: MarkdownStyler, window: UTF16Window, text: NSString) -> NSAttributedString {
        let storage = NSMutableAttributedString(string: text.substring(with: block.range))
        let local = MarkdownBlock(kind: block.kind, range: NSRange(location: 0, length: block.range.length),
                                  inlineMarks: block.inlineMarks.map { NSRange(location: $0.location - block.range.location, length: $0.length) })
        let localWindow = UTF16Window(storage.string as NSString, from: 0, prefetchAll: true)
        styler.apply(local, to: storage, window: localWindow)
        return storage
    }

    /// The styled line without its marks and line ending; bullets get `▪ `.
    private static func stripped(_ styled: NSAttributedString, block: MarkdownBlock, styler: MarkdownStyler, style: MarkdownEditorStyle,
                                 window: UTF16Window) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: styled)
        let base = block.range.location
        for mark in block.inlineMarks.reversed() {
            let local = NSRange(location: mark.location - base, length: mark.length)
            guard NSMaxRange(local) <= result.length else { continue }
            result.deleteCharacters(in: local)
        }
        while result.length > 0, let last = result.string.unicodeScalars.last, last == "\n" || last == "\r" {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        switch block.kind {
        case let .bullet(indent):
            var attributes = styler.base(for: block.kind)
            attributes[.foregroundColor] = style.bullet
            result.insert(NSAttributedString(string: String(repeating: "  ", count: indent) + "▪ ", attributes: attributes), at: 0)
        case .quote:
            var attributes = styler.base(for: block.kind)
            attributes[.foregroundColor] = style.quoteBar
            result.insert(NSAttributedString(string: "▎", attributes: attributes), at: 0)
        default:
            break
        }
        return result
    }

    private static func splitLines(_ text: NSAttributedString) -> [NSAttributedString] {
        var lines: [NSAttributedString] = []
        let string = text.string as NSString
        var start = 0
        while start < string.length {
            let range = string.lineRange(for: NSRange(location: start, length: 0))
            var content = range
            while content.length > 0 {
                let unit = string.character(at: NSMaxRange(content) - 1)
                guard unit == 0x0A || unit == 0x0D else { break }
                content.length -= 1
            }
            lines.append(text.attributedSubstring(from: content))
            start = NSMaxRange(range)
        }
        return lines
    }
}
