import AppKit
import CoddUI

/// A design length (a CSS px of the Cleanup board) at the current interface zoom: the page is laid
/// out by hand, so its offsets, columns and row heights follow the zoom like its fonts. Exact at
/// UI 字級 13 (`UIZoom.pt`).
func kz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// Anything on the Cleanup page that draws text a user can read: the tests and the accessibility
/// tree read `displayedText` (what is drawn, uppercased where the style is).
@MainActor
protocol CleanupTextShowing: AnyObject {
    var displayedText: String { get }
}

/// Text styles of the Cleanup artboard that CoddUI's presets do not cover.
@MainActor
enum CleanupStyles {
    /// `.nb-cl-crumb`: 10.5 caps .16em.
    static func crumb(_ color: NSColor) -> TextStyle { TextStyle.caps(10.5, color, tracking: 0.16) }
    /// `.nb-cl-tbl th`: 10 caps .16em --dim (medium).
    static var columnTitle: TextStyle { TextStyle.caps(10, Palette.dim, tracking: 0.16, .medium) }
    /// `th .cjk`: 10.5 --dimmer .04em.
    static var columnCJK: TextStyle { TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04) }
    /// `.nb-cl-it .tt`: 12.5 cream.
    static var rowTitle: TextStyle { TextStyle.mono(12.5, Palette.cream) }
    /// `.nb-cl-it .l2`: 10.5 --dim.
    static var rowSecond: TextStyle { TextStyle.mono(10.5, Palette.dim) }
    /// `.nb-cl-why` line 1: 12 bone, line height 1.45.
    static var why: TextStyle { TextStyle.mono(12, Palette.bone) }
    static let whyLineHeight: CGFloat = 12 * 1.45
    /// `.nb-cl-why .sub`: 10.5 --dimmer (--dim on a selected or hovered row).
    static func whySub(highlighted: Bool) -> TextStyle { TextStyle.mono(10.5, highlighted ? Palette.dim : Palette.dimmer) }
    static let subLineHeight: CGFloat = 10.5 * 1.45
    /// `.nb-cl-ai`: 11.5, line height 1.45.
    static func ai(_ color: NSColor) -> TextStyle { TextStyle.mono(11.5, color) }
    static let aiLineHeight: CGFloat = 11.5 * 1.45
    /// `.hint` with the `.codd` line height 1.5.
    static let hintLineHeight: CGFloat = 11.5 * 1.5

    /// `.chip.nb-xs`: 17 px, 9.5 px, `padding: 0 5px`, .12em (no text transform).
    static func smallChip(_ kind: ChipKind?, dashed: Bool) -> ChipStyle {
        var style = ChipStyle.chip(kind ?? .plain, dashed: dashed, height: 17)
        let color = (kind == nil && dashed) ? Palette.bone : style.text.color
        style.text = TextStyle(font: Typeface.mono(9.5), color: color, tracking: 0.12)
        style.padding = 6
        return style
    }

    /// `.nb-cl-st .chip`: 20 px, 10.5 px, `padding: 0 6px`.
    static func statusChip(_ kind: ChipKind) -> ChipStyle {
        var style = ChipStyle.chip(kind)
        style.text = TextStyle(font: Typeface.mono(10.5), color: style.text.color, tracking: 0.03)
        style.padding = 7
        return style
    }

    /// `.nb-cl-review .tfill .kbd`: 16 px, 10 px.
    static var hintKbd: ChipStyle {
        ChipStyle(text: TextStyle.mono(10, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 16, padding: 6)
    }
}

/// One custom-drawn line of text, vertically centered and truncated at the tail.
final class TextLine: NSView, CleanupTextShowing {
    private(set) var attributed = NSAttributedString()
    var alignRight = false { didSet { if alignRight != oldValue { needsDisplay = true } } }

    init(_ text: String = "", style: TextStyle) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        set(text, style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { attributed.string }

    @discardableResult
    func set(_ text: String, style: TextStyle) -> Bool { set(attributed: style.string(text)) }

    @discardableResult
    func set(runs: [(String, TextStyle)]) -> Bool {
        let string = NSMutableAttributedString()
        for (text, style) in runs { string.append(style.string(text)) }
        return set(attributed: string)
    }

    @discardableResult
    func set(attributed value: NSAttributedString) -> Bool {
        guard !value.isEqual(to: attributed) else { return false }
        attributed = value
        setAccessibilityValue(value.string)
        needsDisplay = true
        return true
    }

    var textWidth: CGFloat { Draw.width(attributed) }

    /// The height of one line of the largest font in the text.
    var lineHeight: CGFloat {
        var height: CGFloat = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = value as? NSFont { height = max(height, Typeface.lineHeight(font)) }
        }
        return height
    }

    override var intrinsicContentSize: NSSize { NSSize(width: textWidth, height: lineHeight) }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0 else { return }
        let width = min(textWidth, bounds.width)
        let x = alignRight ? bounds.width - width : 0
        Draw.text(attributed, x: x, centerY: bounds.midY, maxWidth: bounds.width - max(0, x))
    }
}

/// Wrapping text with a fixed CSS line height; the height follows the width it is given.
final class TextBlock: NSView, CleanupTextShowing {
    private(set) var attributed = NSAttributedString()
    private(set) var lineHeight: CGFloat

    init(_ text: String = "", style: TextStyle, lineHeight: CGFloat) {
        self.lineHeight = lineHeight
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        set(text, style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { attributed.string }

    @discardableResult
    func set(_ text: String, style: TextStyle) -> Bool {
        set(attributed: style.string(text, lineHeight: lineHeight))
    }

    @discardableResult
    func set(runs: [(String, TextStyle)]) -> Bool {
        let string = NSMutableAttributedString()
        for (text, style) in runs { string.append(style.string(text, lineHeight: lineHeight)) }
        return set(attributed: string)
    }

    @discardableResult
    func set(attributed value: NSAttributedString) -> Bool {
        guard !value.isEqual(to: attributed) else { return false }
        attributed = value
        setAccessibilityValue(value.string)
        needsDisplay = true
        return true
    }

    func height(forWidth width: CGFloat) -> CGFloat { TextMeasure.height(attributed, width: width, lineHeight: lineHeight) }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0 else { return }
        attributed.draw(with: bounds, options: [.usesLineFragmentOrigin])
    }
}

@MainActor
enum TextMeasure {
    /// The height of `text` wrapped at `width`, a whole number of lines (at least one). `lineHeight`
    /// is in design points, like `TextStyle.string(_:lineHeight:)`: it is measured at the zoom.
    static func height(_ text: NSAttributedString, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        let line = UIZoom.scaled(lineHeight)
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        let lines = max(1, (ceil(rect.height) / line).rounded())
        return lines * line
    }

    /// Lines of `text` at `width`.
    static func lines(_ text: NSAttributedString, width: CGFloat, lineHeight: CGFloat) -> Int {
        Int((height(text, width: width, lineHeight: lineHeight) / UIZoom.scaled(lineHeight)).rounded())
    }

    /// A design line height (or a run of them) as laid out at the interface zoom.
    static func zoomed(_ lineHeight: CGFloat) -> CGFloat { UIZoom.scaled(lineHeight) }
}

/// A static chip drawn with a `ChipStyle` (frame-friendly; exposes its label to tests).
final class ChipBox: NSView, CleanupTextShowing {
    private(set) var label: String
    private(set) var style: ChipStyle

    init(_ label: String, style: ChipStyle) {
        self.label = label
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { style.text.uppercase ? label.uppercased() : label }

    func set(_ label: String, style: ChipStyle) {
        self.label = label
        self.style = style
        setAccessibilityValue(label)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { style.size(for: label) }

    override func draw(_ dirtyRect: NSRect) {
        style.draw(label, x: 0, centerY: bounds.midY)
    }
}

/// The 8 px project tag square (`.tag`); a nil color draws the dashed `--dimmer` outline.
final class TagSquareView: NSView {
    var color: NSColor? { didSet { if color != oldValue { needsDisplay = true } } }

    init(color: NSColor? = nil) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: kz(8), height: kz(8)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let color { Draw.fill(bounds, color) } else { Draw.dashedRect(bounds, color: Palette.dimmer, dash: [2, 1]) }
    }
}

/// `.meta-rule`: `──── 每週一 09:00 · 15 項 · 上次 10/08 ────` (11 px caps .18em --dim with
/// gradient lines fading toward the text).
final class MetaRuleView: NSView, CleanupTextShowing {
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var style: TextStyle { TextStyle.caps(11, Palette.dim, tracking: 0.18) }

    var displayedText: String { text.uppercased() }

    func set(_ value: String) {
        guard value != text else { return }
        text = value
        setAccessibilityValue(displayedText)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let string = style.string(text)
        let width = Draw.width(string)
        let x = round((bounds.width - width) / 2)
        let mid = floor(bounds.midY)
        let gap: CGFloat = kz(12)
        Draw.hGradient(CGRect(x: 0, y: mid, width: max(0, x - gap), height: 1),
                       from: Palette.lineBright, to: Palette.lineBright.withAlphaComponent(0))
        Draw.hGradient(CGRect(x: x + width + gap, y: mid, width: max(0, bounds.width - x - width - gap), height: 1),
                       from: Palette.lineBright.withAlphaComponent(0), to: Palette.lineBright)
        Draw.text(string, x: x, centerY: bounds.midY)
    }
}

/// A target for AppKit actions that runs a closure (CoddButton uses target / action).
@MainActor
final class ButtonAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire(_ sender: Any?) { run() }
}

extension NSControl {
    /// Wires the control to a closure kept alive by the returned object (store it).
    func onPress(_ run: @escaping () -> Void) -> ButtonAction {
        let action = ButtonAction(run)
        target = action
        self.action = #selector(ButtonAction.fire(_:))
        return action
    }
}

/// A CoddButton that runs `run` when pressed.
@MainActor
final class ActionButton {
    let button: CoddButton
    var run: (() -> Void)?
    private var holder: ButtonAction?

    init(_ label: String, style: CoddButton.Style, accessibility: String? = nil) {
        button = CoddButton(label, style: style)
        if let accessibility { button.setAccessibilityLabel(accessibility) }
        holder = button.onPress { [weak self] in self?.run?() }
    }
}

/// Glyphs the artboard draws as inline SVG with curves, which `SVGPath.parse` (M / L / H / V / Z
/// only) cannot read.
@MainActor
enum Glyphs {
    /// The AI eye (`M2 10s3-5.25 8-5.25S18 10 18 10s-3 5.25-8 5.25S2 10 2 10z` + a 2.25 circle),
    /// stroke 1.5 in a 20 × 20 viewBox, drawn into `rect` (flipped coordinates).
    static func eye(in rect: CGRect, color: NSColor) {
        let scale = min(rect.width, rect.height) / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        let path = NSBezierPath()
        path.move(to: p(2, 10))
        path.curve(to: p(10, 4.75), controlPoint1: p(2, 10), controlPoint2: p(5, 4.75))
        path.curve(to: p(18, 10), controlPoint1: p(15, 4.75), controlPoint2: p(18, 10))
        path.curve(to: p(10, 15.25), controlPoint1: p(18, 10), controlPoint2: p(15, 15.25))
        path.curve(to: p(2, 10), controlPoint1: p(5, 15.25), controlPoint2: p(2, 10))
        path.close()
        let r = 2.25 * scale
        let center = p(10, 10)
        path.appendOval(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        path.lineWidth = 1.5 * scale
        path.lineCapStyle = .square
        color.setStroke()
        path.stroke()
    }
}

extension NSView {
    /// Every `CleanupTextShowing` text and CoddButton label in this subtree, in subview order
    /// (hidden views skipped; a text-showing view is a leaf: it reports its children's text).
    @MainActor
    func cleanupVisibleTexts() -> [String] {
        var out: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let text = view as? CleanupTextShowing {
                let value = text.displayedText
                if !value.isEmpty { out.append(value) }
                return
            }
            if let button = view as? CoddButton {
                out.append(button.label)
                return
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return out
    }
}

extension CGRect {
    /// The rect with its edges rounded to whole points (crisp 1 px lines).
    var pixelAligned: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded(), x1 = maxX.rounded(), y1 = maxY.rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
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
