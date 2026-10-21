import AppKit

/// A text run style: font + color + letter spacing (CSS `letter-spacing` in em).
///
/// A style follows the interface zoom: `font` is the stored font made again at the current
/// ``UIZoom/scale`` (``Typeface/current(_:)``), so a style kept in a property draws at the new
/// size after ⌘+ / ⌘−. Letter spacing is in em, so it follows the font.
@MainActor
public struct TextStyle {
    private var storedFont: NSFont
    public var font: NSFont {
        get { Typeface.current(storedFont) }
        set { storedFont = newValue }
    }
    public var color: NSColor
    /// Letter spacing in em (e.g. `.14` for caps labels).
    public var tracking: CGFloat = 0
    public var uppercase = false
    public var shadow: NSShadow?

    public init(font: NSFont, color: NSColor, tracking: CGFloat = 0, uppercase: Bool = false, shadow: NSShadow? = nil) {
        storedFont = font
        self.color = color
        self.tracking = tracking
        self.uppercase = uppercase
        self.shadow = shadow
    }

    public func attributes(lineBreak: NSLineBreakMode = .byTruncatingTail) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        let font = font
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .ligature: 0,
        ]
        if tracking != 0 { attrs[.kern] = tracking * font.pointSize }
        if let shadow { attrs[.shadow] = shadow }
        return attrs
    }

    public func string(_ text: String, lineBreak: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        NSAttributedString(string: uppercase ? text.uppercased() : text, attributes: attributes(lineBreak: lineBreak))
    }

    public func with(color: NSColor) -> TextStyle {
        var copy = self
        copy.color = color
        return copy
    }

    public static func mono(_ size: CGFloat, _ color: NSColor, _ weight: Typeface.Weight = .regular) -> TextStyle {
        TextStyle(font: Typeface.mono(size, weight), color: color)
    }

    public static func mono(_ size: CGFloat, _ color: NSColor, tracking: CGFloat, _ weight: Typeface.Weight = .regular) -> TextStyle {
        TextStyle(font: Typeface.mono(size, weight), color: color, tracking: tracking)
    }

    /// Structural caps label (`.sec`, `.lbl`): uppercase with wide tracking.
    public static func caps(_ size: CGFloat, _ color: NSColor, tracking: CGFloat = 0.16, _ weight: Typeface.Weight = .regular) -> TextStyle {
        TextStyle(font: Typeface.mono(size, weight), color: color, tracking: tracking, uppercase: true)
    }
}

/// Text drawing helpers for custom-drawn rows. All take flipped-view coordinates.
@MainActor
public enum Draw {
    /// Draws `text` vertically centered in a line box `[y, y + height)` starting at `x`,
    /// truncated to `maxWidth`. Returns the drawn width.
    @discardableResult
    public static func text(_ text: NSAttributedString, x: CGFloat, centerY: CGFloat, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        guard maxWidth > 0, text.length > 0 else { return 0 }
        let size = text.size()
        let width = min(ceil(size.width), maxWidth)
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let lineHeight = font.map(Typeface.lineHeight) ?? ceil(size.height)
        let rect = CGRect(x: x, y: round(centerY - lineHeight / 2), width: width, height: lineHeight + 2)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return width
    }

    public static func width(_ text: NSAttributedString) -> CGFloat { ceil(text.size().width) }

    /// 1 px dashed line (CSS `1px dashed`), pixel-aligned.
    public static func dashedLine(from a: CGPoint, to b: CGPoint, color: NSColor, dash: [CGFloat] = [3, 2]) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: a.x, y: a.y + 0.5))
        path.line(to: CGPoint(x: b.x, y: b.y + 0.5))
        path.lineWidth = 1
        dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: dash.count, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    /// 1 px dashed rectangle outline.
    public static func dashedRect(_ rect: CGRect, color: NSColor, dash: [CGFloat] = [3, 2]) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: dash.count, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    /// 1 px solid rectangle outline (inside `rect`).
    public static func strokeRect(_ rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    public static func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill(using: .sourceOver)
    }

    /// Horizontal gradient fill (CSS `linear-gradient(90deg, a, b)`).
    public static func hGradient(_ rect: CGRect, from a: NSColor, to b: NSColor) {
        NSGradient(starting: a, ending: b)?.draw(in: rect, angle: 0)
    }

    /// Caret `▸`, rotated 90° when open (`.caret.open`).
    public static func caret(open: Bool, at origin: CGPoint, color: NSColor) {
        let path = NSBezierPath()
        let s: CGFloat = UIZoom.scaled(3.2)
        let c = CGPoint(x: origin.x + UIZoom.scaled(5), y: origin.y)
        if open {
            path.move(to: CGPoint(x: c.x - s, y: c.y - s * 0.6))
            path.line(to: CGPoint(x: c.x + s, y: c.y - s * 0.6))
            path.line(to: CGPoint(x: c.x, y: c.y + s * 0.8))
        } else {
            path.move(to: CGPoint(x: c.x - s * 0.6, y: c.y - s))
            path.line(to: CGPoint(x: c.x + s * 0.8, y: c.y))
            path.line(to: CGPoint(x: c.x - s * 0.6, y: c.y + s))
        }
        path.close()
        color.setFill()
        path.fill()
    }
}

/// Chip-like boxes: state pill `.state`, `.chip`, `.kbd`, `.badge`, `.ext`.
///
/// `height` and `padding` are given in design points and read at the current zoom
/// (``UIZoom/pt(_:)``): a stored chip style grows with the interface zoom like its text.
@MainActor
public struct ChipStyle {
    public var text: TextStyle
    public var border: NSColor?
    public var fill: NSColor?
    public var dashed = false
    private var designHeight: CGFloat = 15
    private var designPadding: CGFloat = 5
    /// Box height at the current zoom; set it in design points.
    public var height: CGFloat {
        get { UIZoom.pt(designHeight) }
        set { designHeight = newValue }
    }
    /// Inner padding (each side) at the current zoom; set it in design points.
    public var padding: CGFloat {
        get { UIZoom.pt(designPadding) }
        set { designPadding = newValue }
    }

    public init(text: TextStyle, border: NSColor? = nil, fill: NSColor? = nil, dashed: Bool = false, height: CGFloat = 15, padding: CGFloat = 5) {
        self.text = text
        self.border = border
        self.fill = fill
        self.dashed = dashed
        designHeight = height
        designPadding = padding
    }

    public func size(for label: String) -> CGSize {
        CGSize(width: Draw.width(text.string(label)) + padding * 2, height: height)
    }

    /// Draws the chip with its left edge at `x`, centered on `centerY`. Returns its width. With
    /// `maxWidth` the box is at most that wide and its label ends in `…` when it does not fit.
    @discardableResult
    public func draw(_ label: String, x: CGFloat, centerY: CGFloat, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let string = text.string(label, lineBreak: .byTruncatingTail)
        let padding = padding
        let height = height
        let width = min(Draw.width(string) + padding * 2, max(maxWidth, padding * 2))
        let rect = CGRect(x: x, y: round(centerY - height / 2), width: width, height: height)
        if let fill { Draw.fill(rect, fill) }
        if let border {
            if dashed { Draw.dashedRect(rect, color: border) } else { Draw.strokeRect(rect, color: border) }
        }
        Draw.text(string, x: x + padding, centerY: rect.midY, maxWidth: width - padding * 2)
        return width
    }

    /// Cyan account chip (`#2`) and other small `.chip` variants.
    public static func smallChip(_ color: NSColor, border: NSColor) -> ChipStyle {
        ChipStyle(text: TextStyle.mono(9.5, color), border: border, fill: nil, height: 15, padding: 4)
    }

    /// `EXT` badge: dashed border, dim caps.
    public static var ext: ChipStyle {
        ChipStyle(text: TextStyle.caps(9, Palette.dim, tracking: 0.12), border: Palette.lineBright, fill: nil,
                  dashed: true, height: 14, padding: 4)
    }

    /// Amber count badge (`.badge`).
    public static var badge: ChipStyle {
        ChipStyle(text: TextStyle.mono(10, .black, .bold), border: nil, fill: Palette.amber, height: 15, padding: 4)
    }
}

extension Draw {
    /// A glow (`text-shadow` / `box-shadow: 0 0 <radius> <color>`) as an unoffset shadow. The body of
    /// the app's former `HomeHeaderView.glow(_:radius:)`, which now forwards here.
    public static func glow(_ color: NSColor, radius: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        return shadow
    }
}
