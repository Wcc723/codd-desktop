import AppKit
import CoddUI

/// Tiny markup for mock terminal transcripts, mirroring the `.term` spans of the mockups:
/// `<d>dim</d> <w>bold white</w> <a>amber</a> <g>green</g> <c>cyan</c> <r>red</r>
/// <cc>claude orange</cc> <inv>inverse</inv> <cur>cursor</cur> <add>…</add> <del>…</del>`.
/// Unknown tags (e.g. `<div class=…>` inside a diff) are kept as literal text. Tags nest.
enum TermMarkup {
    enum Span: String, CaseIterable, Sendable {
        case d, w, a, g, c, r, cc, inv, cur, add, del
    }

    struct Run: Equatable, Sendable {
        var text: String
        var spans: [Span]
    }

    /// Splits markup into styled runs (pure; unit-tested).
    static func parse(_ source: String) -> [Run] {
        var runs: [Run] = []
        var stack: [Span] = []
        var buffer = ""
        var index = source.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(Run(text: buffer, spans: stack))
            buffer = ""
        }

        while index < source.endIndex {
            let ch = source[index]
            if ch == "<", let close = source[index...].firstIndex(of: ">") {
                let inner = source[source.index(after: index)..<close]
                let isEnd = inner.hasPrefix("/")
                let name = isEnd ? String(inner.dropFirst()) : String(inner)
                if let span = Span(rawValue: name) {
                    flush()
                    if isEnd {
                        if let last = stack.lastIndex(of: span) { stack.remove(at: last) }
                    } else {
                        stack.append(span)
                    }
                    index = source.index(after: close)
                    continue
                }
            }
            buffer.append(ch)
            index = source.index(after: index)
        }
        flush()
        return runs
    }

    /// Attributed string for the fake terminal surface.
    @MainActor
    static func attributed(_ source: String, font: NSFont, boldFont: NSFont, lineHeight: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byClipping
        let result = NSMutableAttributedString()
        for run in parse(source) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: Palette.termForeground,
                .paragraphStyle: paragraph,
                .ligature: 0,
            ]
            for span in run.spans {
                switch span {
                case .d: attrs[.foregroundColor] = Palette.termDim
                case .w:
                    attrs[.foregroundColor] = Palette.termWhite
                    attrs[.font] = boldFont
                case .a: attrs[.foregroundColor] = Palette.amber
                case .g: attrs[.foregroundColor] = Palette.success
                case .c: attrs[.foregroundColor] = Palette.cyan
                case .r: attrs[.foregroundColor] = Palette.danger
                case .cc: attrs[.foregroundColor] = Palette.termClaude
                case .inv:
                    attrs[.backgroundColor] = Palette.termForeground
                    attrs[.foregroundColor] = NSColor.black
                case .cur:
                    attrs[.backgroundColor] = Palette.amber
                    attrs[.foregroundColor] = NSColor.black
                case .add:
                    attrs[.backgroundColor] = Palette.termAddBackground
                    attrs[.foregroundColor] = Palette.termAddText
                case .del:
                    attrs[.backgroundColor] = Palette.termDelBackground
                    attrs[.foregroundColor] = Palette.termDelText
                }
            }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return result
    }
}
