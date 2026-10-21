import AppKit
import CoddUI

/// A design length (a CSS px of the Settings board) at the current interface zoom: the drawn parts
/// are laid out by hand, so their offsets and heights follow the zoom like their fonts. Exact at
/// UI 字級 13 (`UIZoom.pt`).
func xz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// Text styles of the Settings artboard (`.sx-*` classes in Settings.src.html).
@MainActor
enum SxStyle {
    /// `.sx-name`: 13 cream.
    static var name: TextStyle { TextStyle.mono(13, Palette.cream) }
    /// `.sx-en`: 10.5 caps .14em dimmer.
    static var english: TextStyle { TextStyle.caps(10.5, Palette.dimmer, tracking: 0.14) }
    /// `.sx-lab .hint`: 11.5 dimmer, line height 1.45.
    static var hint: TextStyle { TextStyle.hint }
    static let hintLineHeight: CGFloat = 17
    /// `.sx-lead`: 12 dim.
    static var lead: TextStyle { TextStyle.mono(12, Palette.dim) }
    /// `.sx-ph .zh`: PingFang TC 15 medium bone, .04em.
    static var pageZh: TextStyle {
        TextStyle(font: Typeface.named("PingFangTC-Medium", 15), color: Palette.bone, tracking: 0.04)
    }
    /// `code` inside sentences: 12 amber on --bg (the 1 px --line border is approximated by the
    /// background; padding 0 5 by thin spaces).
    static var code: TextStyle { TextStyle.mono(12, Palette.amber) }

    /// `code` span for attributed hints and names.
    static func codeSpan(_ text: String, size: CGFloat = 12) -> NSAttributedString {
        let span = NSMutableAttributedString(attributedString: TextStyle.mono(size, Palette.amber).string("\u{2009}\(text)\u{2009}"))
        span.addAttribute(.backgroundColor, value: Palette.bg, range: NSRange(location: 0, length: span.length))
        return span
    }
}

/// A run of styled text pieces (`hint` + `code` + amber), built in place of the artboard's
/// inline spans.
@MainActor
struct SxRich {
    enum Piece {
        case text(String)
        case code(String)
        case color(String, NSColor)
        case styled(String, TextStyle)
    }

    var pieces: [Piece]

    init(_ pieces: [Piece]) { self.pieces = pieces }
    init(_ text: String) { pieces = [.text(text)] }

    var plain: String {
        pieces.map { piece in
            switch piece {
            case .text(let s), .code(let s), .color(let s, _), .styled(let s, _): s
            }
        }.joined()
    }

    /// `lineHeight` is in design points (like `TextStyle.string(_:lineHeight:)`), laid out at the zoom.
    func attributed(_ base: TextStyle, lineHeight designLineHeight: CGFloat? = nil, lineBreak: NSLineBreakMode = .byWordWrapping)
        -> NSAttributedString {
        let lineHeight = designLineHeight.map(UIZoom.scaled)
        let out = NSMutableAttributedString()
        for piece in pieces {
            switch piece {
            case .text(let s): out.append(base.string(s))
            // The code span's design size (its font is made at the zoom from it).
            case .code(let s): out.append(SxStyle.codeSpan(s, size: min(12, base.font.pointSize / UIZoom.scale + 0.5)))
            case .color(let s, let color): out.append(base.with(color: color).string(s))
            case .styled(let s, let style): out.append(style.string(s))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        let range = NSRange(location: 0, length: out.length)
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            out.addAttribute(.baselineOffset, value: max(0, (lineHeight - Typeface.lineHeight(base.font)) / 2), range: range)
        }
        out.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return out
    }
}

/// A label that wraps at whatever width Auto Layout gives it (two layout passes: the width is
/// learned in the first). `single` keeps one truncated line instead.
final class SxLabel: NSTextField {
    private let wraps: Bool

    init(_ text: NSAttributedString, wraps: Bool = true) {
        self.wraps = wraps
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        attributedStringValue = text
        maximumNumberOfLines = wraps ? 0 : 1
        lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        cell?.wraps = wraps
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.staticText)
    }

    convenience init(_ text: String, style: TextStyle, wraps: Bool = true, lineHeight: CGFloat? = nil) {
        self.init(SxRich(text).attributed(style, lineHeight: lineHeight, lineBreak: wraps ? .byWordWrapping : .byTruncatingTail),
                  wraps: wraps)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ text: NSAttributedString) {
        if attributedStringValue != text {
            attributedStringValue = text
            invalidateIntrinsicContentSize()
        }
    }

    var text: String { attributedStringValue.string }

    override func layout() {
        super.layout()
        guard wraps, preferredMaxLayoutWidth != bounds.width, bounds.width > 0 else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}
