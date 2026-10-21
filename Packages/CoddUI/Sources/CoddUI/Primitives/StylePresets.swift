import AppKit

/// `.chip` color variants (helmet: `.chip`, `.chip.amber`, `.chip.ok`, `.chip.cy`, `.chip.bad`, `.chip.fill`).
public enum ChipKind: Sendable, Equatable, CaseIterable {
    case plain, amber, ok, cyan, bad, fill
}

extension ChipStyle {
    /// A helmet `.chip`: 20 px, 11 px mono, 1 px border, `padding: 0 7px` (the border is drawn inside
    /// the chip's width, so the text sits at 7 + 1). `caps` = `.chip.caps` (10 px, uppercase, .1em);
    /// `mini` = Settings `.sx-mini` (16 px tall, 9.5 px, `padding: 0 5px`; `.chip.caps` keeps its 10 px);
    /// `dashed` = Status `.chip.sx-dc` (dim text, dashed border); `weight` = `.medium` inside card
    /// headers (`.card-h .chip{font-weight:500}`). `display` = a chip inside `.modal .m-h`, which inherits
    /// Space Mono Bold (`.chip` sets no font family; `cswap 0.26.0`, `+9`). `height` overrides the box
    /// height (`.sx-chips .chip` 22).
    public static func chip(_ kind: ChipKind = .plain, caps: Bool = false, mini: Bool = false, dashed: Bool = false,
                            weight: Typeface.Weight = .regular, display: Bool = false, height: CGFloat? = nil) -> ChipStyle {
        var color: NSColor
        var border: NSColor
        var fill: NSColor?
        var fontWeight = weight
        switch kind {
        case .plain: color = Palette.bone; border = Palette.lineBright
        case .amber: color = Palette.amber; border = Palette.amberDim
        case .ok: color = Palette.success; border = Palette.success.withAlphaComponent(0.4)
        case .cyan: color = Palette.cyan; border = Palette.cyan.withAlphaComponent(0.4)
        case .bad: color = Palette.danger; border = Palette.danger.withAlphaComponent(0.45)
        case .fill: color = .black; border = Palette.amber; fill = Palette.amber; fontWeight = .bold
        }
        if dashed, kind == .plain { color = Palette.dim }
        let size: CGFloat = caps ? 10 : (mini ? 9.5 : 11)
        let font = display ? Typeface.display(size) : Typeface.mono(size, fontWeight)
        let text = TextStyle(font: font, color: color, tracking: caps ? 0.1 : (display ? 0.04 : 0.03), uppercase: caps)
        return ChipStyle(text: text, border: border, fill: fill, dashed: dashed,
                         height: height ?? (mini ? 16 : 20), padding: (mini ? 5 : 7) + 1)
    }

    /// `.code` (`~/.claude/settings.json` inside a sentence): 12 px amber on --bg, 1 px --line border.
    public static var code: ChipStyle {
        ChipStyle(text: TextStyle.mono(12, Palette.amber), border: Palette.line, fill: Palette.bg, height: 20, padding: 6)
    }

    /// `.path`: 11.5 px dim on --bg-soft, 1 px --line border, `padding: 1px 8px`.
    public static var path: ChipStyle {
        ChipStyle(text: TextStyle.mono(11.5, Palette.dim), border: Palette.line, fill: Palette.bgSoft, height: 21, padding: 9)
    }

    /// Later-milestone marker on disabled rows (`M4`, `M5`, `FUTURE`; D17): the `.ext` / `.sx-tail.fut` look.
    public static var milestone: ChipStyle { .ext }
}

extension TextStyle {
    /// `.h-page`: Space Mono 26 amber with its glow.
    public static var pageTitle: TextStyle {
        TextStyle(font: Typeface.display(26), color: Palette.amber, tracking: 0.02, shadow: Draw.glow(Palette.amberGlow, radius: 12))
    }

    /// `.h-sub`: Space Mono 13 amber caps, .16em.
    public static var subTitle: TextStyle {
        TextStyle(font: Typeface.display(13), color: Palette.amber, tracking: 0.16, uppercase: true)
    }

    /// `.card h3` / `.card-h`: Space Mono 12 amber caps, .16em.
    public static var cardTitle: TextStyle {
        TextStyle(font: Typeface.display(12), color: Palette.amber, tracking: 0.16, uppercase: true)
    }

    /// `.modal .m-h`: Space Mono 12.5 amber caps, .16em.
    public static var modalTitle: TextStyle {
        TextStyle(font: Typeface.display(12.5), color: Palette.amber, tracking: 0.16, uppercase: true)
    }

    /// `.hint`: 11.5 dimmer, .02em.
    public static var hint: TextStyle { TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02) }

    /// `.lbl`: 10.5 dim caps, .16em.
    public static var fieldLabel: TextStyle { TextStyle.caps(10.5, Palette.dim, tracking: 0.16) }

    /// `.sec`: 10.5 dim caps, .18em.
    public static var sectionLabel: TextStyle { TextStyle.caps(10.5, Palette.dim, tracking: 0.18) }

    /// `.comment` (`// 自動切換未開啟`): 12 dimmer.
    public static var comment: TextStyle { TextStyle.mono(12, Palette.dimmer) }

    /// The same style with a fixed line height (CSS `line-height` for wrapping text; e.g. `.sx-lab .hint`
    /// 1.45). `NSTextField` otherwise uses the font's own line height, which differs for CJK fallback.
    /// `lineHeight` is in design points (it follows the interface zoom like the font).
    public func attributes(lineHeight designLineHeight: CGFloat, lineBreak: NSLineBreakMode = .byWordWrapping) -> [NSAttributedString.Key: Any] {
        let lineHeight = UIZoom.scaled(designLineHeight)
        var attrs = attributes(lineBreak: lineBreak)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        attrs[.paragraphStyle] = paragraph
        // Center the glyphs in the taller line box (CSS half-leading) instead of sitting on its bottom.
        attrs[.baselineOffset] = max(0, (lineHeight - Typeface.lineHeight(font)) / 2)
        return attrs
    }

    /// `string(_:)` with a fixed line height (see `attributes(lineHeight:lineBreak:)`).
    public func string(_ text: String, lineHeight: CGFloat, lineBreak: NSLineBreakMode = .byWordWrapping) -> NSAttributedString {
        NSAttributedString(string: uppercase ? text.uppercased() : text, attributes: attributes(lineHeight: lineHeight, lineBreak: lineBreak))
    }
}
