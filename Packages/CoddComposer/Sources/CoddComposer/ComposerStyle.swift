import AppKit

/// How the composer looks. The package has no theme: the app passes CODD's Phosphor Console tokens.
public struct ComposerStyle: Sendable {
    /// NSFont is immutable (AppKit documents it as safe to use from any thread) but not marked Sendable.
    nonisolated(unsafe) public var font: NSFont
    public var textColor: NSColor
    public var placeholderColor: NSColor
    public var caretColor: NSColor
    /// Text the input method is still composing (注音 before it is committed); drawn underlined.
    public var markedTextColor: NSColor
    public var background: NSColor
    /// Padding between the field's edge and the text; it scrolls with the text, like CSS padding.
    public var insets: NSEdgeInsets
    public var minLines: Int = 1
    public var maxLines: Int = 8
    /// Every line is exactly this tall (CSS `line-height`), so a line falling back to PingFang for CJK
    /// is as tall as a Latin one and the field grows in whole lines. nil: the font's default height.
    public var lineHeight: CGFloat?
    /// Selection colors; nil leaves the system's.
    public var selectionBackground: NSColor?
    public var selectionTextColor: NSColor?
    /// Draws every `codd://note/<id>` as the Split artboard's `.sp-ref` chip (amber text, 8 % amber
    /// fill, amber-dim border). The text never changes, so the payload stays plain text. Off by
    /// default: the app's composer is unchanged until it opts in (M4 I2b, D40).
    public var referenceChips: Bool = false
    public var referenceChipText: NSColor = ComposerStyle.rgb(0xFFB84A)
    public var referenceChipFill: NSColor = ComposerStyle.rgb(0xFFB84A, alpha: 0.08)
    public var referenceChipBorder: NSColor = ComposerStyle.rgb(0xE09A2C)
    /// The chip's height (`.sp-ref{height:18px}`), centered on the line.
    public var referenceChipHeight: CGFloat = 18
    /// With `referenceChips` on, `[圖已過期]` (an image removed 24 h after its send, post-M4) draws as
    /// a muted chip: dim text, a faint cream fill, the dimmer border. Same height and padding.
    public var expiredChipText: NSColor = ComposerStyle.rgb(0xA8A298)
    public var expiredChipFill: NSColor = ComposerStyle.rgb(0xF5ECD6, alpha: 0.04)
    public var expiredChipBorder: NSColor = ComposerStyle.rgb(0x7A7468)

    public init(
        font: NSFont,
        textColor: NSColor,
        placeholderColor: NSColor,
        caretColor: NSColor,
        markedTextColor: NSColor,
        background: NSColor,
        insets: NSEdgeInsets,
        minLines: Int = 1,
        maxLines: Int = 8,
        lineHeight: CGFloat? = nil,
        selectionBackground: NSColor? = nil,
        selectionTextColor: NSColor? = nil,
        referenceChips: Bool = false
    ) {
        self.font = font
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.caretColor = caretColor
        self.markedTextColor = markedTextColor
        self.background = background
        self.insets = insets
        self.minLines = max(1, minLines)
        self.maxLines = max(self.minLines, maxLines)
        self.lineHeight = lineHeight
        self.selectionBackground = selectionBackground
        self.selectionTextColor = selectionTextColor
        self.referenceChips = referenceChips
    }

    /// The helmet `.composer .ta` look: 12.5 pt monospaced (SF Mono standing in for JetBrains Mono),
    /// line height 1.5, cream text, dimmer placeholder, amber caret and composition, black field,
    /// 8 / 10 pt padding, amber selection with black text.
    public static var standard: ComposerStyle {
        ComposerStyle(
            font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
            textColor: ComposerStyle.rgb(0xF5ECD6),
            placeholderColor: ComposerStyle.rgb(0x7A7468),
            caretColor: ComposerStyle.rgb(0xFFB84A),
            markedTextColor: ComposerStyle.rgb(0xFFB84A),
            background: ComposerStyle.rgb(0x050505),
            insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10),
            lineHeight: (12.5 * 1.5).rounded(),
            selectionBackground: ComposerStyle.rgb(0xFFB84A),
            selectionTextColor: ComposerStyle.rgb(0x000000)
        )
    }

    /// sRGB color from `0xRRGGBB`.
    public static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The height of one line as laid out: `lineHeight`, else the font's default line height.
    @MainActor public var resolvedLineHeight: CGFloat {
        if let lineHeight, lineHeight > 0 { return lineHeight }
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    /// Glyphs sit on the bottom of a line taller than the font; this lifts them to the middle.
    @MainActor var baselineOffset: CGFloat {
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        return max(0, (resolvedLineHeight - natural) / 2).rounded(.down)
    }

    @MainActor var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = resolvedLineHeight
        style.maximumLineHeight = resolvedLineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }

    @MainActor var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset,
        ]
    }
}
