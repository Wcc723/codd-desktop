import AppKit
import CoddUI

/// Layout helpers for the specimen boards: a board is a dark page with a title and labelled rows.
@MainActor
enum Specimen {
    /// A board: `.h-page` title, a `.meta-rule`-like caption, then the sections.
    static func board(_ title: String, caption: String, sections: [NSView]) -> NSView {
        let page = PanelView(fill: Palette.bg)
        let head = vStack([Label.make(title, style: TextStyle.pageTitle),
                           Label.make(caption, style: TextStyle.caps(11, Palette.dim, tracking: 0.18))], spacing: 6)
        let column = columnStack([head] + sections, spacing: 26, edgeInsets: NSEdgeInsets(top: 32, left: 40, bottom: 40, right: 40))
        page.addSubview(column)
        column.pinEdges(to: page)
        return page
    }

    /// One labelled specimen: `.sec` label (the CSS class it reproduces) over the content.
    /// `fullWidth` stretches the content to the board width (headers with rules); otherwise the
    /// content keeps its own width at the left.
    static func section(_ label: String, _ content: NSView, fullWidth: Bool = false) -> NSView {
        let title = Label.make(label, style: TextStyle.sectionLabel)
        let body = fullWidth ? content : hStack([content, spacer()], spacing: 0)
        if !fullWidth { (body as? NSStackView)?.alignment = .top }
        return columnStack([title, body], spacing: 10)
    }

    static func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        // A trailing spacer takes any extra width, so the specimens keep their own sizes.
        let stack = hStack(views + [spacer()], spacing: spacing)
        for view in views { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
        return stack
    }

    static func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = vStack(views, spacing: spacing)
        for view in views { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
        return stack
    }

    /// Pins `view` to a fixed width (and height when given).
    @discardableResult
    static func sized<V: NSView>(_ view: V, width: CGFloat? = nil, height: CGFloat? = nil) -> V {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
        return view
    }

    /// A caption under a specimen (`dimmer` 10.5).
    static func caption(_ text: String) -> NSTextField {
        Label.make(text, style: TextStyle.mono(10.5, Palette.dimmer))
    }

    /// A specimen with its caption under it.
    static func captioned(_ view: NSView, _ text: String) -> NSView {
        let label = caption(text)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return vStack([view, label], spacing: 5)
    }

    static func label(_ text: String, _ style: TextStyle) -> NSTextField { Label.make(text, style: style) }

    static func chip(_ text: String, _ style: ChipStyle) -> ChipView { ChipView(text, style: style) }
}

/// A palette swatch: the color box with its token name and hex under it.
final class SwatchView: NSView {
    private let name: String
    private let color: NSColor

    init(_ name: String, _ color: NSColor) {
        self.name = name
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 92).isActive = true
        heightAnchor.constraint(equalToConstant: 66).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = CGRect(x: 0, y: 0, width: 92, height: 34)
        Draw.fill(box, color)
        Draw.strokeRect(box, color: Palette.lineBright)
        Draw.text(TextStyle.mono(10.5, Palette.bone).string(name), x: 0, centerY: 44, maxWidth: 92)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let hex = String(format: "#%02X%02X%02X", Int(srgb.redComponent * 255), Int(srgb.greenComponent * 255), Int(srgb.blueComponent * 255))
        let alpha = srgb.alphaComponent < 1 ? String(format: " %.2f", srgb.alphaComponent) : ""
        Draw.text(TextStyle.mono(10, Palette.dimmer).string(hex + alpha), x: 0, centerY: 58, maxWidth: 92)
    }
}

/// One stroke icon at 20 pt with its name.
final class IconSpecimenView: NSView {
    private let icon: Icon
    private let name: String

    init(_ icon: Icon, name: String) {
        self.icon = icon
        self.name = name
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        IconRenderer.draw(icon, in: CGRect(x: 22, y: 2, width: 20, height: 20), color: Palette.amber, flipped: true)
        let text = TextStyle.mono(9.5, Palette.dimmer).string(name)
        Draw.text(text, x: (64 - Draw.width(text)) / 2, centerY: 36, maxWidth: 64)
    }
}
