import AppKit
import CoddUI

/// Anything in the STATUS views that draws text a user can read: the tests and the accessibility
/// tree read `displayedText` (what is drawn, uppercased where the style is).
@MainActor
protocol StatusTextShowing: AnyObject {
    var displayedText: String { get }
}

/// One custom-drawn line of text (cheaper than an NSTextField and with the artboard's exact
/// vertical metrics): `runs` are drawn left to right, vertically centered, truncated at the tail.
final class TextLine: NSView, StatusTextShowing {
    private(set) var attributed = NSAttributedString()
    private var plain = ""
    /// Right-aligns the text inside the bounds (counts, values).
    var alignRight = false { didSet { if alignRight != oldValue { needsDisplay = true } } }
    var alignCenter = false { didSet { if alignCenter != oldValue { needsDisplay = true } } }
    /// An underline under the whole run (the REMOTE link, like the artboard's `<a>`).
    var underline: NSColor? { didSet { needsDisplay = true } }

    init(_ text: String = "", style: TextStyle) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        set(text, style: style)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    init(runs: [(String, TextStyle)]) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        set(runs: runs)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { plain }

    /// Sets one run; returns true when anything changed (callers count redraws in tests).
    @discardableResult
    func set(_ text: String, style: TextStyle) -> Bool {
        set(attributed: style.string(text, lineBreak: .byTruncatingTail))
    }

    @discardableResult
    func set(runs: [(String, TextStyle)]) -> Bool {
        let string = NSMutableAttributedString()
        for (text, style) in runs { string.append(style.string(text, lineBreak: .byTruncatingTail)) }
        return set(attributed: string)
    }

    @discardableResult
    func set(attributed value: NSAttributedString) -> Bool {
        guard !value.isEqual(to: attributed) else { return false }
        attributed = value
        plain = value.string
        setAccessibilityValue(plain)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        return true
    }

    /// Width of the full text and the height of one line of its largest font.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Draw.width(attributed), height: lineHeight)
    }

    var textWidth: CGFloat { Draw.width(attributed) }

    var lineHeight: CGFloat {
        var height: CGFloat = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = value as? NSFont { height = max(height, Typeface.lineHeight(font)) }
        }
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0 else { return }
        let width = min(textWidth, bounds.width)
        let x = alignRight ? bounds.width - width : (alignCenter ? (bounds.width - width) / 2 : 0)
        Draw.text(attributed, x: x, centerY: bounds.midY, maxWidth: bounds.width - max(0, x))
        if let underline {
            Draw.fill(CGRect(x: x, y: round(bounds.midY + lineHeight / 2) - sz(2), width: width, height: 1), underline)
        }
    }
}

/// Wrapping text (pace line, notes, long paths): height follows the width it is given.
final class TextBlock: NSView, StatusTextShowing {
    private(set) var attributed = NSAttributedString()
    /// `line-height` multiple of the font size (CSS `line-height: 1.4`); nil = the font's own.
    private var lineHeightMultiple: CGFloat?
    private var breakAnywhere = false
    var alignCenter = false { didSet { if alignCenter != oldValue { rebuild() } } }
    private var text = ""
    private var style: TextStyle

    init(_ text: String = "", style: TextStyle, lineHeight: CGFloat? = nil, breakAnywhere: Bool = false) {
        self.style = style
        self.lineHeightMultiple = lineHeight
        self.breakAnywhere = breakAnywhere
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        set(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { attributed.string }

    @discardableResult
    func set(_ text: String, style: TextStyle? = nil) -> Bool {
        let styleChanged = style.map { $0.font != self.style.font || $0.color != self.style.color } ?? false
        guard text != self.text || styleChanged else { return false }
        self.text = text
        if let style { self.style = style }
        rebuild()
        return true
    }

    private func rebuild() {
        // Word wrapping breaks paths after `-` / `/` and falls back to any character for a token
        // longer than the line (CSS `overflow-wrap:anywhere`); `.standard` avoids a one-character
        // CJK orphan (CSS `text-wrap:pretty`).
        var attrs = style.attributes(lineBreak: .byWordWrapping)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = breakAnywhere ? [] : .standard
        if alignCenter { paragraph.alignment = .center }
        if let lineHeightMultiple {
            let height = round(style.font.pointSize * lineHeightMultiple)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        attrs[.paragraphStyle] = paragraph
        attributed = NSAttributedString(string: style.uppercase ? text.uppercased() : text, attributes: attrs)
        setAccessibilityValue(attributed.string)
        needsDisplay = true
    }

    /// Height of the wrapped text at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 0 else { return 0 }
        let rect = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin])
        return ceil(rect.height)
    }

    /// Width of the text on one line.
    var singleLineWidth: CGFloat { Draw.width(attributed) }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0 else { return }
        attributed.draw(with: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + sz(2)),
                        options: [.usesLineFragmentOrigin])
    }
}

/// A `.chip` (or the `.path` box, a `code` span) drawn from a `ChipStyle`, readable by tests and
/// VoiceOver.
final class ChipLabel: NSView, StatusTextShowing {
    private(set) var label: String
    private var chip: ChipStyle
    /// A glyph drawn before the label in its own color (`●` in `● LIVE`, with an optional glow).
    private var lead: (String, NSColor, Bool)?

    init(_ label: String, style: ChipStyle, lead: (glyph: String, color: NSColor, glow: Bool)? = nil) {
        self.label = label
        self.chip = style
        self.lead = lead.map { ($0.glyph, $0.color, $0.glow) }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(displayedText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var style: ChipStyle { chip }

    var displayedText: String {
        let text = chip.text.uppercase ? label.uppercased() : label
        return lead.map { $0.0 + text } ?? text
    }

    @discardableResult
    func set(_ label: String, style: ChipStyle? = nil, lead: (glyph: String, color: NSColor, glow: Bool)? = nil) -> Bool {
        let newLead = lead.map { ($0.glyph, $0.color, $0.glow) }
        let leadChanged = newLead?.0 != self.lead?.0 || newLead?.1 != self.lead?.1
        guard label != self.label || style != nil || leadChanged else { return false }
        self.label = label
        if let style { chip = style }
        self.lead = newLead
        setAccessibilityValue(displayedText)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        return true
    }

    private var leadWidth: CGFloat {
        guard let lead else { return 0 }
        return Draw.width(Self.leadStyle(lead.1).string(lead.0)) + sz(5)
    }

    private static func leadStyle(_ color: NSColor) -> TextStyle { TextStyle.mono(9, color) }

    override var intrinsicContentSize: NSSize {
        let size = chip.size(for: label)
        return NSSize(width: size.width + leadWidth, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let lead else {
            // A chip given less than its width (a path in a narrow header) ends in `…` inside its box.
            chip.draw(label, x: 0, centerY: bounds.midY, maxWidth: bounds.width)
            return
        }
        // The lead glyph sits inside the chip box, before the label (`.chip` gap 5).
        let rect = CGRect(x: 0, y: round(bounds.midY - chip.height / 2), width: bounds.width, height: chip.height)
        if let fill = chip.fill { Draw.fill(rect, fill) }
        if let border = chip.border {
            if chip.dashed { Draw.dashedRect(rect, color: border) } else { Draw.strokeRect(rect, color: border) }
        }
        let glyph = NSMutableAttributedString(attributedString: Self.leadStyle(lead.1).string(lead.0))
        if lead.2 {
            let glow = NSShadow()
            glow.shadowColor = lead.1.withAlphaComponent(0.55)
            glow.shadowBlurRadius = 6
            glow.shadowOffset = .zero
            glyph.addAttribute(.shadow, value: glow, range: NSRange(location: 0, length: glyph.length))
        }
        let x = chip.padding + Draw.text(glyph, x: chip.padding, centerY: rect.midY) + sz(5)
        Draw.text(chip.text.string(label), x: x, centerY: rect.midY)
    }
}

/// Joins styled runs with explicit gaps (CSS `gap` / `margin-left` between inline spans) by
/// kerning the last character of each run.
@MainActor
enum TextRuns {
    static func joined(_ runs: [(String, TextStyle, CGFloat)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, style, gapAfter) in runs where !text.isEmpty {
            let run = NSMutableAttributedString(attributedString: style.string(text))
            if gapAfter > 0, run.length > 0 {
                let last = NSRange(location: run.length - 1, length: 1)
                run.addAttribute(.kern, value: style.tracking * style.font.pointSize + gapAfter, range: last)
            }
            out.append(run)
        }
        return out
    }
}

/// Chip looks of the Status artboard on top of CoddUI's `ChipStyle.chip` presets.
@MainActor
enum StatusChips {
    /// `.chip` (bone, line-bright border, 20 px).
    static var plain: ChipStyle { .chip() }
    /// `.chip.amber`.
    static var amber: ChipStyle { .chip(.amber) }
    /// `.chip.ok`.
    static var ok: ChipStyle { .chip(.ok) }
    /// `.chip.bad`.
    static var bad: ChipStyle { .chip(.bad) }
    /// `.chip.sx-dc`: the auto-switch rule while OFF (dim text, dashed border).
    static var dimDashed: ChipStyle { .chip(dashed: true) }
    /// `.chip` in a card head or `.sx-r` (monospace 500); `uppercase` inside `.card-h`.
    static func medium(_ kind: ChipKind, uppercase: Bool = false) -> ChipStyle {
        var style = ChipStyle.chip(kind, weight: .medium)
        style.text.uppercase = uppercase
        return style
    }
    /// `.chip.caps` (10 px, .1em): `● LIVE`, `OFF`, `● 正常`.
    static func caps(_ kind: ChipKind) -> ChipStyle { .chip(kind, caps: true) }
    /// `code` (12 px amber on `--bg`).
    static var code: ChipStyle { .code }
    /// `.path` (11.5 dim on `--bg-soft`).
    static var path: ChipStyle { .path }
}

/// M4 interface zoom: the text built at the old zoom is made again at the new one.
extension TextLine: ZoomRefreshing {
    func zoomDidChange() {
        guard let scaled = Typeface.rescaled(attributed) else { return }
        attributed = scaled
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

extension TextBlock: ZoomRefreshing {
    func zoomDidChange() {
        guard let scaled = Typeface.rescaled(attributed) else { return }
        attributed = scaled
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
