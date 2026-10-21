import AppKit
import CoddUI

/// Views that draw readable text report it here (what is drawn, uppercased where the style is),
/// so tests and diagnostics can compare the view tree with the artboard copy.
@MainActor
protocol NotebookTextProviding: AnyObject {
    var drawnTexts: [String] { get }
}

extension NSView {
    /// Every readable string under this view in reading order: lines top to bottom (items whose
    /// vertical centers are within 6 pt form one line), each line left to right. Hidden views are
    /// skipped; CoddButtons report their label as drawn.
    @MainActor
    func notebookVisibleTexts() -> [String] {
        var items: [(text: String, frame: CGRect)] = []
        collectNotebookTexts(root: self, into: &items)
        let sorted = items.sorted { $0.frame.midY < $1.frame.midY }
        var lines: [[(text: String, frame: CGRect)]] = []
        for item in sorted {
            if let first = lines.last?.first, abs(item.frame.midY - first.frame.midY) <= 6 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines.flatMap { line in line.sorted { $0.frame.minX < $1.frame.minX }.map(\.text) }
    }

    @MainActor
    private func collectNotebookTexts(root: NSView, into items: inout [(text: String, frame: CGRect)]) {
        guard !isHidden else { return }
        let frame = convert(bounds, to: root)
        if let provider = self as? NotebookTextProviding {
            for text in provider.drawnTexts where !text.isEmpty { items.append((text, frame)) }
        } else if let button = self as? CoddButton {
            let label = { if case .bracket = button.style { return button.label.uppercased() } else { return button.label } }()
            if !label.isEmpty { items.append((label, frame)) }
        } else if let field = self as? NSTextField, !field.isEditable, !field.stringValue.isEmpty {
            items.append((field.stringValue, frame))
        }
        for sub in subviews { sub.collectNotebookTexts(root: root, into: &items) }
    }

    /// All descendants of a type (depth-first, self excluded).
    @MainActor
    func notebookDescendants<T: NSView>(ofType type: T.Type) -> [T] {
        var out: [T] = []
        for sub in subviews {
            if let match = sub as? T { out.append(match) }
            out.append(contentsOf: sub.notebookDescendants(ofType: type))
        }
        return out
    }
}

/// A flipped, layer-backed view that redraws only on `needsDisplay`.
class CanvasView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

/// A clickable area with hover tracking (`:hover` looks), pressed by mouse or VoiceOver. Fires on
/// mouse-up inside, like a button. Disabled controls draw at 40 % (`.btn[disabled]`) and keep
/// their tooltip (the reason).
class HoverControl: NSControl, KeyboardFocusTracking {
    private(set) var isHovered = false
    private(set) var isPressed = false
    private var trackingArea: NSTrackingArea?
    var onClick: (() -> Void)?
    /// Draws the disabled look by lowering the alpha (subclasses that dim themselves turn it off).
    var dimsWhenDisabled = true
    /// D21: a key view while Full Keyboard Access is on; rows of a list or menu that keeps the focus
    /// itself (↑ ↓ ⏎ on the container) turn it off.
    var takesKeyboardFocus = true
    /// ↑ ↓ step to the sibling rows of the same column (see ``KeyListRow``).
    var steppedByArrows = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if dimsWhenDisabled { alphaValue = isEnabled ? 1 : 0.4 }
            setAccessibilityEnabled(isEnabled)
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
        focusTracker.viewDidMoveToWindow()
    }

    func setHovered(_ value: Bool) {
        guard isHovered != value else { return }
        isHovered = value
        needsDisplay = true
        hoverChanged()
    }

    /// Subclasses restyle their children.
    func hoverChanged() {}

    /// The hover look applies (enabled and hovered).
    var isHot: Bool { isHovered && isEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        needsDisplay = true
        if inside { performClick(nil) }
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        onClick?()
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    // MARK: Keyboard (D21)

    private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: takesKeyboardFocus && isEnabled, refuses: refusesFirstResponder) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusTracker.becameFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusTracker.resignedFirstResponder() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let key = KeyboardFocus.key(of: event)
        if key == .space || key == .return {
            focusTracker.noteKeyboardInteraction()
            performClick(nil)
        } else if steppedByArrows, key == .down || key == .up {
            KeyFocus.moveInList(from: self, by: key == .down ? 1 : -1)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension HoverControl: KeyListRow {
    var isKeyListRow: Bool { steppedByArrows }
}

/// A one-line custom-drawn label: `pieces` laid out with `InlineLayout` (text, chips, icons).
final class InlineLabel: CanvasView, NotebookTextProviding {
    private(set) var pieces: [InlinePiece] = []
    /// Design points (`InlineLayout` reads them at the zoom).
    var gap: CGFloat = 6 { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }

    init(_ pieces: [InlinePiece] = [], gap: CGFloat = 6) {
        self.gap = gap
        super.init(frame: .zero)
        set(pieces)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    func set(_ pieces: [InlinePiece]) {
        self.pieces = pieces
        setAccessibilityValue(drawnTexts.joined(separator: " "))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func set(text: String, style: TextStyle, lineBreak: NSLineBreakMode = .byTruncatingTail) {
        set([.text(text, style, shrink: true, lineBreak: lineBreak)])
    }

    var drawnTexts: [String] { [pieces.compactMap(\.plain).joined(separator: " ")] }

    override var intrinsicContentSize: NSSize {
        var height: CGFloat = 0
        for piece in pieces {
            switch piece.content {
            case .text(let string):
                // An empty piece has no attribute at index 0 (reading it raises NSRangeException).
                if string.length > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    height = max(height, Typeface.lineHeight(font))
                }
            case .chip(let chip): height = max(height, chip.height)
            case .icon(_, let size, _, _), .tag(_, let size): height = max(height, size)
            case .lamp(_, let size, _): height = max(height, Typeface.lineHeight(Typeface.mono(size)))
            case .box(let size, _): height = max(height, size.height)
            case .flex: break
            }
        }
        return NSSize(width: InlineLayout.width(pieces, gap: gap), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        var rect = bounds
        if alignment != .left {
            let width = min(bounds.width, InlineLayout.width(pieces, gap: gap))
            rect.origin.x = alignment == .right ? bounds.width - width : (bounds.width - width) / 2
            rect.size.width = width
        }
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect, gap: gap))
    }
}

/// Wrapping text with a fixed line height (CSS `line-height`), height follows the width.
final class WrapLabel: CanvasView, NotebookTextProviding {
    private(set) var attributed = NSAttributedString()
    private(set) var text = ""
    private var style: TextStyle
    /// The CSS line height in design points; `lineHeight` reads it at the interface zoom.
    private let designLineHeight: CGFloat
    private var lineHeight: CGFloat { zp(designLineHeight) }
    /// At most this many lines (CSS `-webkit-line-clamp`), the last one truncated; 0 = no limit.
    var maxLines = 0 { didSet { needsDisplay = true } }
    var strikethrough = false

    init(_ text: String = "", style: TextStyle, lineHeight: CGFloat) {
        self.style = style
        designLineHeight = lineHeight
        super.init(frame: .zero)
        set(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    func set(_ text: String, style: TextStyle? = nil) {
        if let style { self.style = style }
        self.text = text
        rebuild()
    }

    /// Replaces the text with a prepared attributed string (highlights).
    func set(attributed value: NSAttributedString) {
        text = value.string
        let out = NSMutableAttributedString(attributedString: value)
        out.addAttributes(paragraphAttributes, range: NSRange(location: 0, length: out.length))
        attributed = out
        setAccessibilityValue(text)
        needsDisplay = true
    }

    private var paragraphAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return [.paragraphStyle: paragraph, .baselineOffset: max(0, (lineHeight - Typeface.lineHeight(style.font)) / 2)]
    }

    private func rebuild() {
        var attrs = style.attributes(lineBreak: .byWordWrapping)
        for (key, value) in paragraphAttributes { attrs[key] = value }
        if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        attributed = NSAttributedString(string: style.uppercase ? text.uppercased() : text, attributes: attrs)
        setAccessibilityValue(text)
        needsDisplay = true
    }

    var drawnTexts: [String] { [attributed.string] }

    /// Lines the text takes at `width` (clamped by `maxLines`).
    func lineCount(for width: CGFloat) -> Int {
        guard attributed.length > 0, width > 0 else { return 0 }
        let bounds = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin])
        let lines = max(1, Int((ceil(bounds.height) + lineHeight / 2) / lineHeight))
        return maxLines > 0 ? min(lines, maxLines) : lines
    }

    func height(for width: CGFloat) -> CGFloat { CGFloat(lineCount(for: width)) * lineHeight }

    override func draw(_ dirtyRect: NSRect) {
        guard attributed.length > 0 else { return }
        let lines = lineCount(for: bounds.width)
        let rect = CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(lines) * lineHeight)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// M4 interface zoom: the text built at the old zoom is made again at the new one.
extension WrapLabel: ZoomRefreshing {
    func zoomDidChange() {
        guard let scaled = Typeface.rescaled(attributed) else { return }
        attributed = scaled
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

/// M4 interface zoom: the text pieces built at the old zoom are made again at the new one (the
/// list heads, `updated 10:05`, the status bar's position line kept their old size after a live
/// zoom).
extension InlineLabel: ZoomRefreshing {
    func zoomDidChange() {
        var changed = false
        let next = pieces.map { piece -> InlinePiece in
            guard case .text(let string) = piece.content, let scaled = Typeface.rescaled(string) else { return piece }
            changed = true
            var copy = piece
            copy.content = .text(scaled)
            return copy
        }
        guard changed else { return }
        set(next)
    }
}
