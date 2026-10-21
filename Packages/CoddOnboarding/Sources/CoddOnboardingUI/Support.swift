import AppKit
import CoddUI

/// A design length (a CSS px of the Onboarding artboard) at the current interface zoom. The wizard is
/// laid out by hand in `layout()`, so every offset, column and row height follows ⌘+ / ⌘− like its
/// fonts (`UIZoom.pt`; exact at UI 字級 13).
func dz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// Anything that draws text a user reads: tests compare `displayedText` with the artboard.
@MainActor
protocol OnboardingTextShowing: AnyObject {
    var displayedText: String { get }
}

/// The helmet's tag colors (`--t-red` … `--t-cyan`, SPEC §3) by Claude Code `/color` name.
@MainActor
enum TagColor {
    static func color(_ name: String?) -> NSColor? {
        switch name {
        case "red": NSColor(hex: 0xEF5B5B)
        case "blue": NSColor(hex: 0x5B8DEF)
        case "green": NSColor(hex: 0x4EC9B0)
        case "yellow": NSColor(hex: 0xE6C84E)
        case "purple": NSColor(hex: 0xB07CFF)
        case "orange": NSColor(hex: 0xFF9B4E)
        case "pink": NSColor(hex: 0xFF7CB5)
        case "cyan": NSColor(hex: 0x4ED1E6)
        default: nil
        }
    }

    /// The 8 px `.tag` square; nil draws the dashed --dimmer outline of 未分類.
    static func drawSquare(_ name: String?, in rect: CGRect) {
        if let color = color(name) { Draw.fill(rect, color) } else { Draw.dashedRect(rect, color: Palette.dimmer, dash: [2, 1]) }
    }
}

/// Tone names of the models (`ok`, `amber`, `danger`, `dim`, `comment`, `code`) as colors.
@MainActor
enum ToneColor {
    static func color(_ tone: String) -> NSColor {
        switch tone {
        case "ok": Palette.success
        case "amber": Palette.amber
        case "danger": Palette.danger
        case "code": Palette.amber
        case "comment": Palette.dimmer
        default: Palette.dim
        }
    }
}

extension NSView {
    /// Sets the frame (pixel-aligned) and asks for a layout pass when the size changed.
    @MainActor
    func place(_ rect: CGRect) {
        let aligned = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: max(0, rect.width.rounded()),
                             height: max(0, rect.height.rounded()))
        guard frame != aligned else { return }
        let resized = frame.size != aligned.size
        frame = aligned
        if resized { needsLayout = true; needsDisplay = true }
    }
}

/// A target for AppKit actions that runs a closure (CoddButton uses target / action).
@MainActor
final class Trampoline: NSObject {
    var run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire(_ sender: Any?) { run() }
}

/// A CoddButton with a closure; the trampoline lives as long as the button.
@MainActor
final class PressButton {
    let button: CoddButton
    private let trampoline: Trampoline

    init(_ label: String, style: CoddButton.Style, accessibility: String? = nil, run: @escaping () -> Void = {}) {
        button = CoddButton(label, style: style)
        trampoline = Trampoline(run)
        button.target = trampoline
        button.action = #selector(Trampoline.fire(_:))
        button.setAccessibilityLabel(accessibility ?? label)
    }

    var run: () -> Void {
        get { trampoline.run }
        set { trampoline.run = newValue }
    }
}

// MARK: - Text

/// Runs of styled text in one attributed string.
@MainActor
func runs(_ parts: [(String, TextStyle)]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (text, style) in parts { out.append(style.string(text)) }
    return out
}

/// One custom-drawn line of text, vertically centered and truncated at the tail.
final class TextLine: NSView, OnboardingTextShowing, ZoomRefreshing {
    enum Alignment { case left, right, center }

    private(set) var attributed = NSAttributedString()
    var alignment: Alignment = .left { didSet { if alignment != oldValue { needsDisplay = true } } }
    private var build: (() -> NSAttributedString)?

    init(accessible: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(accessible)
        if accessible { setAccessibilityRole(.staticText) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { attributed.string }

    /// The text from `make`, built again after a zoom change (styles hold design sizes).
    func set(_ make: @escaping () -> NSAttributedString) {
        build = make
        apply(make())
    }

    func set(_ text: String, style: TextStyle) {
        set { style.string(text) }
    }

    private func apply(_ value: NSAttributedString) {
        guard !value.isEqual(to: attributed) else { return }
        attributed = value
        setAccessibilityValue(value.string)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var textWidth: CGFloat { Draw.width(attributed) }

    override var intrinsicContentSize: NSSize {
        var height: CGFloat = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = value as? NSFont { height = max(height, Typeface.lineHeight(font)) }
        }
        return NSSize(width: textWidth, height: height)
    }

    func zoomDidChange() {
        if let build { apply(build()) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0 else { return }
        let width = min(textWidth, bounds.width)
        let x: CGFloat
        switch alignment {
        case .left: x = 0
        case .right: x = bounds.width - width
        case .center: x = ((bounds.width - width) / 2).rounded()
        }
        Draw.text(attributed, x: x, centerY: bounds.midY, maxWidth: bounds.width - max(0, x))
    }
}

/// The looks of wrapping text with inline `code` boxes and **bold** runs (the leads, the hints).
struct RichLook {
    var size: CGFloat
    var color: NSColor
    /// CSS `line-height` in design px.
    var lineHeight: CGFloat
    var tracking: CGFloat = 0.01
    var boldColor: NSColor = Palette.cream
    var codeSize: CGFloat = 12
    var codeColor: NSColor = Palette.amber
    /// `code{background:var(--bg);border:1px solid var(--line);padding:0 5px}`.
    var codeFill: NSColor? = Palette.bg
    var codeBorder: NSColor? = Palette.line
}

/// Tiny markup for the copy: `` `code` `` and `**bold**`.
enum Markup {
    enum Kind { case plain, bold, code }

    static func parse(_ text: String) -> [(String, Kind)] {
        var out: [(String, Kind)] = []
        var current = ""
        var kind = Kind.plain
        var index = text.startIndex
        func flush() {
            if !current.isEmpty { out.append((current, kind)) }
            current = ""
        }
        while index < text.endIndex {
            let char = text[index]
            if char == "`" {
                flush()
                kind = kind == .code ? .plain : .code
                index = text.index(after: index)
                continue
            }
            if char == "*", kind != .code, text[index...].hasPrefix("**") {
                flush()
                kind = kind == .bold ? .plain : .bold
                index = text.index(index, offsetBy: 2)
                continue
            }
            current.append(char)
            index = text.index(after: index)
        }
        flush()
        return out
    }

    /// The text without markup.
    static func plain(_ text: String) -> String { parse(text).map(\.0).joined() }
}

/// Wrapping text (TextKit) with code boxes drawn behind the code runs.
final class RichTextView: NSView, OnboardingTextShowing, ZoomRefreshing {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    private(set) var markup = ""
    var look: RichLook { didSet { rebuild() } }
    static let codeKey = NSAttributedString.Key("CODDOnboardingCode")

    init(_ markup: String = "", look: RichLook) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        set(markup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { storage.string }

    func set(_ markup: String) {
        guard markup != self.markup || storage.length == 0 else { return }
        self.markup = markup
        rebuild()
    }

    private func rebuild() {
        storage.setAttributedString(Self.attributed(markup, look: look))
        setAccessibilityValue(storage.string)
        needsDisplay = true
    }

    func zoomDidChange() { rebuild() }

    static func attributed(_ markup: String, look: RichLook) -> NSAttributedString {
        let line = UIZoom.scaled(look.lineHeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = line
        paragraph.maximumLineHeight = line
        paragraph.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString()
        var codeRanges: [NSRange] = []
        for (text, kind) in Markup.parse(markup) {
            let font: NSFont
            var color = look.color
            switch kind {
            case .plain: font = Typeface.mono(look.size)
            case .bold: font = Typeface.mono(look.size, .semibold); color = look.boldColor
            case .code: font = Typeface.mono(look.codeSize); color = look.codeColor
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .ligature: 0,
                .baselineOffset: max(0, (line - Typeface.lineHeight(font)) / 2),
            ]
            if look.tracking != 0 { attributes[.kern] = look.tracking * font.pointSize }
            let start = out.length
            out.append(NSAttributedString(string: text, attributes: attributes))
            if kind == .code {
                let range = NSRange(location: start, length: out.length - start)
                out.addAttribute(codeKey, value: true, range: range)
                codeRanges.append(range)
            }
        }
        // `padding: 0 5px`: room before and after each code run, as kerning of the neighbor glyphs.
        let pad = dz(5)
        let string = out.string as NSString
        for range in codeRanges where range.length > 0 {
            if range.location > 0 { addKern(pad, at: string.rangeOfComposedCharacterSequence(at: range.location - 1), in: out) }
            addKern(pad, at: string.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1), in: out)
        }
        return out
    }

    private static func addKern(_ value: CGFloat, at range: NSRange, in text: NSMutableAttributedString) {
        let current = (text.attribute(.kern, at: range.location, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        text.addAttribute(.kern, value: current + value, range: range)
    }

    /// The wrapped height at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard storage.length > 0, width > 0 else { return 0 }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// The width of the longest line when nothing wraps.
    var naturalWidth: CGFloat { ceil(storage.size().width) + dz(2) }

    override func draw(_ dirtyRect: NSRect) {
        guard storage.length > 0 else { return }
        container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let pad = dz(5)
        storage.enumerateAttribute(Self.codeKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let boxHeight = font.map(Typeface.lineHeight) ?? dz(16)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: container) { rect, _ in
                let box = CGRect(x: rect.minX - pad, y: (rect.midY - boxHeight / 2).rounded(), width: rect.width + pad,
                                 height: boxHeight).integral
                if let fill = self.look.codeFill { Draw.fill(box, fill) }
                if let border = self.look.codeBorder { Draw.strokeRect(box, color: border) }
            }
        }
        let range = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: range, at: .zero)
    }
}

// MARK: - Buttons

/// `.btn.sm.plain` (`[顯示隱藏項目]` without brackets): 22 px, 1 px --line-bright, 10.5 px medium caps
/// .08em cream; hover amber with its glow. CoddButton's `.plain` is another look (amber text,
/// border only on hover), hence this small button.
final class BoxButton: NSButton {
    var label: String { didSet { if label != oldValue { title = label; invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let trampoline: Trampoline

    init(_ label: String, run: @escaping () -> Void = {}) {
        self.label = label
        trampoline = Trampoline(run)
        super.init(frame: .zero)
        title = label
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        target = trampoline
        action = #selector(Trampoline.fire(_:))
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var run: () -> Void {
        get { trampoline.run }
        set { trampoline.run = newValue }
    }

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    private var style: TextStyle { TextStyle(font: Typeface.mono(10.5, .medium), color: Palette.cream, tracking: 0.08, uppercase: true) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(Draw.width(style.string(label)) + dz(7) * 2 + 2), height: dz(22))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
        let hot = isHovered && isEnabled
        if hot || isHighlighted { Draw.fill(bounds, Palette.amber.withAlphaComponent(isHighlighted ? 0.12 : 0.06)) }
        Draw.strokeRect(bounds, color: hot ? Palette.amber : Palette.lineBright)
        let text = style.with(color: hot ? Palette.amber : Palette.cream).string(label)
        Draw.text(text, x: ((bounds.width - Draw.width(text)) / 2).rounded(), centerY: bounds.midY)
    }
}

/// `.ob-link`: bone text with a dashed --line-bright underline; amber (underline --amber-dim) on hover.
final class LinkButton: NSButton {
    let label: String
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let trampoline: Trampoline

    init(_ label: String, run: @escaping () -> Void = {}) {
        self.label = label
        trampoline = Trampoline(run)
        super.init(frame: .zero)
        title = label
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        target = trampoline
        action = #selector(Trampoline.fire(_:))
        setAccessibilityRole(.link)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var run: () -> Void {
        get { trampoline.run }
        set { trampoline.run = newValue }
    }

    override var isFlipped: Bool { true }

    private var style: TextStyle { TextStyle.mono(11, Palette.bone, tracking: 0.01) }

    /// Text line (16.5) + padding-bottom 1 + the 1 px underline.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Draw.width(style.string(label)), height: ceil(UIZoom.scaled(16.5)) + 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let text = style.with(color: isHovered ? Palette.amber : Palette.bone).string(label)
        let width = min(Draw.width(text), bounds.width)
        Draw.text(text, x: 0, centerY: (bounds.height - 2) / 2, maxWidth: bounds.width)
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: width, y: bounds.height - 1),
                        color: isHovered ? Palette.amberDim : Palette.lineBright)
    }
}

/// A box drawn like `.panel` / `.card` behind custom content: fill, 1 px border, optional ASCII corners.
@MainActor
enum Panel {
    static func draw(_ rect: CGRect, fill: NSColor = Palette.bgSoft, border: NSColor = Palette.lineBright, corners: Bool = false) {
        Draw.fill(rect, fill)
        Draw.strokeRect(rect, color: border)
        guard corners else { return }
        // `.card::before{content:'┌─'}` / `::after{content:'─┘'}`: 11 px --amber-dim on a --bg patch.
        let style = TextStyle.mono(11, Palette.amberDim)
        let open = style.string("┌─")
        let close = style.string("─┘")
        let pad = dz(4)
        let openRect = CGRect(x: rect.minX - 1, y: rect.minY - dz(6), width: Draw.width(open) + pad * 2, height: dz(11))
        Draw.fill(openRect, Palette.bg)
        Draw.text(open, x: openRect.minX + pad, centerY: rect.minY)
        let closeWidth = Draw.width(close) + pad * 2
        let closeRect = CGRect(x: rect.maxX + 1 - closeWidth, y: rect.maxY - dz(5), width: closeWidth, height: dz(11))
        Draw.fill(closeRect, Palette.bg)
        Draw.text(close, x: closeRect.minX + pad, centerY: rect.maxY)
    }
}

/// A 1 px dashed vertical line in the pixel column starting at `x` (CSS `border-left:1px dashed`).
@MainActor
func dashedVLine(x: CGFloat, from top: CGFloat, to bottom: CGFloat, color: NSColor, dash: [CGFloat] = [3, 2]) {
    guard bottom > top else { return }
    let path = NSBezierPath()
    path.move(to: CGPoint(x: x.rounded() + 0.5, y: top))
    path.line(to: CGPoint(x: x.rounded() + 0.5, y: bottom))
    path.lineWidth = 1
    dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: dash.count, phase: 0) }
    color.setStroke()
    path.stroke()
}

extension NSView {
    /// Every text a user reads in this subtree, in subview order (hidden views skipped): the
    /// wizard's own text views, CODD buttons and key caps. Tests compare it with the artboard.
    @MainActor
    func onboardingTexts() -> [String] {
        var out: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let text = view as? OnboardingTextShowing {
                let value = text.displayedText
                if !value.isEmpty { out.append(value) }
            } else if let button = view as? CoddButton {
                out.append(button.label)
            } else if let button = view as? BoxButton {
                out.append(button.label)
            } else if let link = view as? LinkButton {
                out.append(link.label)
            } else if let kbd = view as? KbdView {
                out.append(kbd.text)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return out
    }
}
