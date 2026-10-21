import AppKit
import CoddUI

/// Custom `NSMenuItem.view` for the color row of a native context menu: label line
/// (`顏色 · pink`) and 8 tag swatches + "none". Clicking a swatch applies it and closes the menu.
/// Keys 1–8 / 0 pick a swatch while the menu is open. Outside a menu (`showsLabel: false`, the
/// new-session sheet) it is a plain swatch row that keeps the picked color selected.
final class SwatchMenuItemView: NSView {
    private(set) var current: TagColor? { didSet { if current != oldValue { needsDisplay = true } } }
    private let allowsNone: Bool
    private let showsLabel: Bool
    private let onPick: (TagColor?) -> Void
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?
    /// M5 D21: one VoiceOver radio button per swatch.
    private var swatchElements: [DrawnRowElement] = []

    override func accessibilityChildren() -> [Any]? {
        swatchElements = drawnRowElements(reusing: swatchElements, role: .radioButton)
        return swatchElements
    }

    private static let swatch: CGFloat = 20
    private static let gap: CGFloat = 6
    private static let left: CGFloat = 14

    init(current: TagColor?, allowsNone: Bool = true, showsLabel: Bool = true, onPick: @escaping (TagColor?) -> Void) {
        self.current = current
        self.allowsNone = allowsNone
        self.showsLabel = showsLabel
        self.onPick = onPick
        let count = TagColor.allCases.count + (allowsNone ? 1 : 0)
        let width = Self.left * 2 + CGFloat(count) * Self.swatch + CGFloat(count - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: max(260, width), height: showsLabel ? 54 : 30))
        setAccessibilityRole(.group)
        setAccessibilityLabel("顏色")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var options: [TagColor?] { TagColor.allCases.map { Optional($0) } + (allowsNone ? [nil] : []) }

    private func rect(at index: Int) -> CGRect {
        CGRect(x: (showsLabel ? Self.left : 4) + CGFloat(index) * (Self.swatch + Self.gap), y: showsLabel ? 24 : 5,
               width: Self.swatch, height: Self.swatch)
    }

    override var intrinsicContentSize: NSSize { frame.size }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = options.indices.first { rect(at: $0).insetBy(dx: -3, dy: -3).contains(point) }
        if index != hovered { hovered = index; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = options.indices.first(where: { rect(at: $0).insetBy(dx: -3, dy: -3).contains(point) }) else { return }
        pick(options[index])
    }

    override func keyDown(with event: NSEvent) {
        if let chars = event.charactersIgnoringModifiers, let n = Int(chars) {
            if n >= 1, n <= TagColor.allCases.count { pick(TagColor.allCases[n - 1]); return }
            if n == 0, allowsNone { pick(nil); return }
        }
        super.keyDown(with: event)
    }

    /// Shows `color` as the picked one (the ⌘N sheet's 1–8 keys).
    func setCurrent(_ color: TagColor?) { current = color }

    private func pick(_ color: TagColor?) {
        onPick(color)
        if let menu = enclosingMenuItem?.menu { menu.cancelTracking() } else { current = color }
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsLabel { drawLabel() }
        drawSwatches()
    }

    private func drawLabel() {
        let label = NSMutableAttributedString(string: "顏色", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        label.append(NSAttributedString(string: "  " + (current?.rawValue ?? "none"),
                                        attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        label.draw(at: CGPoint(x: Self.left, y: 3))
    }

    private func drawSwatches() {
        for (i, option) in options.enumerated() {
            let r = rect(at: i)
            if let option {
                Draw.fill(r, option.color)
            } else {
                Draw.strokeRect(r, color: Palette.lineBright)
                let x = TextStyle.mono(11, Palette.dim).string("✕")
                Draw.text(x, x: r.midX - Draw.width(x) / 2, centerY: r.midY)
            }
            if option == current {
                Draw.strokeRect(r, color: Palette.cream)
                Draw.strokeRect(r.insetBy(dx: -3, dy: -3), color: Palette.amber)
            } else if hovered == i {
                Draw.strokeRect(r.insetBy(dx: -2, dy: -2), color: Palette.dim)
            }
        }
    }
}

// MARK: Accessibility (M5 D21)

/// One radio button per swatch (`紅` … `青`, `無`), chosen = the current color; press picks it.
extension SwatchMenuItemView: DrawnRowsHost {
    var drawnRowCount: Int { options.count }
    func drawnRowLabel(_ index: Int) -> String? { swatchSpokenName(options.indices.contains(index) ? options[index] : nil) }
    func drawnRowFrame(_ index: Int) -> CGRect { rect(at: index) }
    func isDrawnRowSelected(_ index: Int) -> Bool { options.indices.contains(index) && options[index] == current }
    func pressDrawnRow(_ index: Int) { if options.indices.contains(index) { pick(options[index]) } }
}

/// `紅`, …, `無顏色`.
func swatchSpokenName(_ color: TagColor?) -> String { color.map { "\($0.spokenName)色" } ?? "無顏色" }
