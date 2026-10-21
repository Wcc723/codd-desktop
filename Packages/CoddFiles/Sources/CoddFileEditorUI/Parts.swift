import AppKit
import CoddUI

/// FileEditor artboard colors that are not CoddUI tokens.
public enum FileEditorColors {
    /// `.fe-node.mod .nm{color:#f3d9a6}`: the name of a git-modified file.
    public static let modifiedName = NSColor(hex: 0xF3D9A6)
    /// `--t-pink`, the sample session's color tag.
    public static let tagPink = NSColor(hex: 0xFF7CB5)
}

/// The artboard's own stroke icons (viewBox 0 0 20 20, stroke 1.5, square caps).
public enum FileEditorIcon: Sendable {
    /// `新增檔案`: a page with a plus.
    case newFile
    /// `全部收合`: a square with a minus.
    case collapseAll
    /// `分割編輯器`: a rectangle split in two.
    case splitEditor
    /// The note icon of a note tab (CoddUI's rail NOTES icon).
    case note

    fileprivate var strokes: [String] {
        switch self {
        case .newFile: ["M5 2.75h6.5l3.5 3.5v11H5z", "M10 9.5v5M7.5 12h5"]
        case .collapseAll: ["M7 10h6"]
        case .splitEditor: ["M10 3.75v12.5"]
        case .note: ["M5 2.75h7.5l3 3v11.5H5z", "M12.25 2.75V6h3.25M7.5 9.5h5M7.5 12.5h5M7.5 15h3"]
        }
    }

    fileprivate var rects: [CGRect] {
        switch self {
        case .collapseAll: [CGRect(x: fz(3.75), y: fz(3.75), width: fz(12.5), height: fz(12.5))]
        case .splitEditor: [CGRect(x: fz(2.75), y: fz(3.75), width: fz(14.5), height: fz(12.5))]
        default: []
        }
    }

    /// Draws into `rect` (a flipped view's coordinates).
    @MainActor
    public func draw(in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let scale = min(rect.width, rect.height) / 20
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: scale)
        transform.concat()
        let path = NSBezierPath()
        for d in strokes { path.append(SVGPath.parse(d)) }
        for r in rects { path.append(NSBezierPath(rect: r)) }
        path.lineWidth = 1.5
        path.lineCapStyle = .square
        path.lineJoinStyle = .miter
        color.setStroke()
        path.stroke()
        context.restoreGraphicsState()
    }
}

/// Drawing pieces shared by the tree, the tabs and the status items.
/// A design length (a CSS px of the FileEditor board) at the current interface zoom: the views
/// are laid out by hand, so offsets, row heights and widths follow the zoom like their fonts.
/// Exact at UI 字級 13 (`UIZoom.pt`).
func fz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

@MainActor
enum Parts {
    /// `.fe-ext`: 9.5 px dim, .04em (a 28 px column in the tree, auto width in tabs).
    static let extStyle = TextStyle(font: Typeface.mono(9.5), color: Palette.dim, tracking: 0.04)

    /// Draws `ext`; returns its width.
    @discardableResult
    static func drawExt(_ ext: String, x: CGFloat, centerY: CGFloat, maxWidth: CGFloat = fz(28)) -> CGFloat {
        guard !ext.isEmpty else { return 0 }
        return Draw.text(extStyle.string(ext), x: x, centerY: centerY, maxWidth: maxWidth)
    }

    /// `.fe-m`: amber `M`, 10.5 bold, in a 10 px column. Returns 10.
    @discardableResult
    static func drawModified(x: CGFloat, centerY: CGFloat) -> CGFloat {
        let text = TextStyle.mono(10.5, Palette.amber, .bold).string("M")
        Draw.text(text, x: x + (fz(10) - Draw.width(text)) / 2, centerY: centerY)
        return fz(10)
    }

    /// The `.fe-ai` chip: 14 px high, 9 px bold, .1em, text in the session color, its border at 50 %
    /// and fill at 8 %; without a color a bone outline (D26).
    static func aiChipWidth() -> CGFloat {
        Draw.width(aiText(Palette.bone).string("AI")) + fz(8) + 2
    }

    @discardableResult
    static func drawAIChip(x: CGFloat, centerY: CGFloat, color: NSColor?) -> CGFloat {
        let tint = color ?? Palette.bone
        let width = aiChipWidth()
        let rect = CGRect(x: x, y: round(centerY - fz(7)), width: width, height: fz(14))
        if let color { Draw.fill(rect, color.withAlphaComponent(0.08)) }
        Draw.strokeRect(rect, color: color.map { $0.withAlphaComponent(0.5) } ?? Palette.bone.withAlphaComponent(0.6))
        let text = aiText(tint).string("AI")
        Draw.text(text, x: x + (width - Draw.width(text)) / 2 + 0.5, centerY: rect.midY)
        return width
    }

    private static func aiText(_ color: NSColor) -> TextStyle {
        TextStyle(font: Typeface.mono(9, .bold), color: color, tracking: 0.1)
    }

    /// `.tag`: an 8 px color square (none: a dashed outline).
    static func drawTag(_ color: NSColor?, x: CGFloat, centerY: CGFloat) {
        let rect = CGRect(x: x, y: round(centerY - fz(4)), width: fz(8), height: fz(8))
        if let color { Draw.fill(rect, color) } else { Draw.dashedRect(rect, color: Palette.dimmer) }
    }

    /// `.lamp`: a 12 px column with the glyph; busy green glows (`.lamp.st-busy`).
    @discardableResult
    static func drawLamp(_ glyph: String, color: NSColor, x: CGFloat, centerY: CGFloat) -> CGFloat {
        var style = TextStyle.mono(11, color)
        if color == Palette.success { style.shadow = Draw.glow(Palette.success.withAlphaComponent(0.55), radius: 6) }
        let text = style.string(glyph)
        Draw.text(text, x: x + (fz(12) - Draw.width(text)) / 2, centerY: centerY)
        return fz(12)
    }

    /// An italic run (JetBrains Mono ships no italic here: a synthesized slant, like the browser's).
    static func italic(_ string: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        copy.addAttribute(.obliqueness, value: 0.18, range: NSRange(location: 0, length: copy.length))
        return copy
    }
}

/// A 22 / 28 px square icon button (`.icon-btn`, `.fe-ib`) drawing a ``FileEditorIcon`` or a text
/// glyph: dim, amber with a --line-bright border on hover, 40 % when disabled (the tooltip still
/// shows, e.g. `新增檔案（之後提供）`).
public final class FileEditorIconButton: NSControl, KeyboardFocusTracking {
    public enum Content: Sendable, Equatable {
        case icon(FileEditorIcon)
        case glyph(String)
    }

    public let content: Content
    /// The button's side in design points (laid out at the interface zoom).
    public let side: CGFloat
    public var onClick: (() -> Void)?
    public private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    public init(_ content: Content, side: CGFloat = 22, label: String) {
        self.content = content
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: fz(side), height: fz(side)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).zoomed(side).isActive = true
        heightAnchor.constraint(equalToConstant: side).zoomed(side).isActive = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: fz(side), height: fz(side)) }
    public override var isEnabled: Bool { didSet { needsDisplay = true; setAccessibilityEnabled(isEnabled) } }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
        let hot = isHovered && isEnabled
        if hot { Draw.strokeRect(bounds, color: Palette.lineBright) }
        let color = hot ? Palette.amber : Palette.dim
        switch content {
        case .icon(let icon):
            let s: CGFloat = side <= 22 ? fz(14) : fz(16)
            icon.draw(in: CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s), color: color)
        case .glyph(let glyph):
            let text = TextStyle.mono(side <= 22 ? 12 : 14, color).string(glyph)
            Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    /// Clicks it like the mouse would (tests, keyboard paths).
    public func performClickAction() {
        guard isEnabled else { return }
        onClick?()
    }

    // MARK: Keyboard (D21): a key view under Full Keyboard Access, the focus style, space / ⏎ press.

    public private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

    public override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: isEnabled, refuses: false) }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusTracker.becameFirstResponder() }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusTracker.resignedFirstResponder() }
        return resigned
    }

    public override func keyDown(with event: NSEvent) {
        if KeyFocus.isPressKey(event) {
            focusTracker.noteKeyboardInteraction()
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }
}

/// `.select.fe-sel`: a 22 px select (11 px cream on --bg-soft, the amber ▼) that opens a native
/// menu; per-item enabled flags (the `基準：AI 開始前` item exists only when there is such a baseline).
public final class CompactSelectView: FieldBoxView, KeyboardFocusTracking {
    /// Keyboard focus shows the box's own focused look (FieldBoxView, like CoddUI's SelectButton).
    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in
            guard let self else { return }
            self.isFocused = self.focusTracker.showsFocusRing
        }
        return tracker
    }()
    public private(set) var titles: [String] = []
    public private(set) var enabled: [Bool] = []
    public private(set) var selectedIndex = 0
    public var onSelect: ((Int) -> Void)?

    public init(accessibilityLabel: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityLabel)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).zoomed(22).isActive = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setItems(_ titles: [String], selected: Int, enabled: [Bool] = []) {
        guard titles != self.titles || selected != selectedIndex || enabled != self.enabled else { return }
        self.titles = titles
        self.enabled = enabled
        selectedIndex = titles.indices.contains(selected) ? selected : 0
        setAccessibilityValue(currentTitle)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public var currentTitle: String { titles.indices.contains(selectedIndex) ? titles[selectedIndex] : "" }

    private var textStyle: TextStyle { TextStyle.mono(11, Palette.cream) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(Draw.width(textStyle.string(currentTitle)) + fz(8) + fz(24)), height: fz(22))
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.text(textStyle.string(currentTitle), x: fz(8), centerY: bounds.midY, maxWidth: bounds.width - fz(8) - fz(22))
        let x = bounds.maxX - fz(13)
        let y = bounds.midY
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x - fz(5), y: y - fz(2.5)))
        chevron.line(to: CGPoint(x: x + fz(5), y: y - fz(2.5)))
        chevron.line(to: CGPoint(x: x, y: y + fz(2.5)))
        chevron.close()
        Palette.amber.setFill()
        chevron.fill()
    }

    public override func mouseDown(with event: NSEvent) { showMenu() }

    public override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    // MARK: Keyboard (D21): a key view under Full Keyboard Access, the focus style, space / ⏎ / ↓ open the menu.

    public override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: !titles.isEmpty, refuses: false) }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusTracker.becameFirstResponder() }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusTracker.resignedFirstResponder() }
        return resigned
    }

    public override func keyDown(with event: NSEvent) {
        if KeyFocus.isPressKey(event) || KeyboardFocus.key(of: event) == .down {
            focusTracker.noteKeyboardInteraction()
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Picks `index` as the menu would (tests).
    public func choose(_ index: Int) {
        guard titles.indices.contains(index), enabled.indices.contains(index) ? enabled[index] : true else { return }
        selectedIndex = index
        setAccessibilityValue(currentTitle)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onSelect?(index)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, title) in titles.enumerated() {
            let item = ClosureMenuItem(title: title) { [weak self] in self?.choose(index) }
            item.state = index == selectedIndex ? .on : .off
            item.isEnabled = enabled.indices.contains(index) ? enabled[index] : true
            menu.addItem(item)
        }
        menu.minimumWidth = bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + fz(2)), in: self)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }
}

/// File-name helpers for the ext column.
public enum FileExt {
    /// The `.fe-ext` label: the last extension (`tailwind.config.js` → `js`), for a dot file the
    /// first segment (`.env.local` → `env`, `.gitignore` → `git`), lowercased, at most 4 letters;
    /// empty without an extension (`Makefile`).
    public static func label(for name: String) -> String {
        var label: Substring
        if name.hasPrefix(".") {
            let rest = name.dropFirst()
            if let dot = rest.firstIndex(of: ".") {
                label = rest[..<dot]
            } else {
                label = rest.prefix(3)
            }
        } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            label = name[name.index(after: dot)...]
        } else {
            label = ""
        }
        return String(label.lowercased().prefix(4))
    }
}

/// A one-line label drawn with `Draw.text` and sized with the same measure, so CJK runs (PingFang
/// through the cascade list) never get cut short the way an `NSTextField`'s cell measured them.
public final class DrawnLabel: NSView {
    public var text: String { didSet { if text != oldValue { changed() } } }
    public var style: TextStyle { didSet { changed() } }

    public init(_ text: String = "", style: TextStyle) {
        self.text = text
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Draw.width(style.string(text)) + 1, height: Typeface.lineHeight(style.font))
    }

    private func changed() {
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.text(style.string(text), x: 0, centerY: bounds.midY, maxWidth: bounds.width)
    }
}
