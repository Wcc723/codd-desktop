import AppKit

/// Top-left origin container (all CODD custom layouts are top-down).
open class FlippedView: NSView {
    open override var isFlipped: Bool { true }
}

/// Solid background with optional 1 px edges (solid or dashed), drawn by the layer-backed
/// view itself (cheap: redrawn only when a property changes).
open class PanelView: FlippedView {
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Edges(rawValue: 1)
        public static let bottom = Edges(rawValue: 2)
        public static let left = Edges(rawValue: 4)
        public static let right = Edges(rawValue: 8)
    }

    open var fill: NSColor? { didSet { needsDisplay = true } }
    open var edges: Edges = [] { didSet { needsDisplay = true } }
    open var edgeColor: NSColor = Palette.line { didSet { needsDisplay = true } }
    open var dashedEdges: Edges = [] { didSet { needsDisplay = true } }

    public init(fill: NSColor? = nil, edges: Edges = [], edgeColor: NSColor = Palette.line, dashed: Edges = []) {
        self.fill = fill
        self.edges = edges
        self.edgeColor = edgeColor
        self.dashedEdges = dashed
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    open override var wantsUpdateLayer: Bool { false }

    open override func draw(_ dirtyRect: NSRect) {
        if let fill { Draw.fill(bounds, fill) }
        let b = bounds
        for (edge, from, to) in [(Edges.top, CGPoint(x: 0, y: 0), CGPoint(x: b.width, y: 0)),
                                 (.bottom, CGPoint(x: 0, y: b.height - 1), CGPoint(x: b.width, y: b.height - 1))]
        where edges.contains(edge) {
            if dashedEdges.contains(edge) {
                Draw.dashedLine(from: from, to: to, color: edgeColor)
            } else {
                Draw.fill(CGRect(x: from.x, y: from.y, width: b.width, height: 1), edgeColor)
            }
        }
        if edges.contains(.left) { Draw.fill(CGRect(x: 0, y: 0, width: 1, height: b.height), edgeColor) }
        if edges.contains(.right) { Draw.fill(CGRect(x: b.width - 1, y: 0, width: 1, height: b.height), edgeColor) }
    }
}

/// A header band that drags the window (our custom header replaces the title bar) and
/// zooms on double-click, like a native title bar.
open class WindowDragView: PanelView {
    open override var mouseDownCanMoveWindow: Bool { true }

    open override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// Non-editable single-line label with CODD text styling.
@MainActor
public enum Label {
    public static func make(_ text: String = "", style: TextStyle) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: style.string(text))
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    public static func set(_ field: NSTextField, _ text: String, style: TextStyle) {
        let value = style.string(text)
        if field.attributedStringValue != value { field.attributedStringValue = value }
    }
}

/// Multi-line label that wraps at whatever width the layout gives it.
public final class WrappingLabel: NSTextField {
    public convenience init(_ text: String, style: TextStyle) {
        self.init(wrappingLabelWithString: "")
        attributedStringValue = style.string(text, lineBreak: .byWordWrapping)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    public override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

extension NSView {
    /// First descendant of a type (depth-first).
    public func descendant<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T { return match }
            if let match = sub.descendant(ofType: type) { return match }
        }
        return nil
    }

    /// Pins all edges to `other` (Auto Layout).
    public func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// Horizontal stack with CODD defaults (centered, fixed spacing, no detaching surprises).
@MainActor
public func hStack(_ views: [NSView], spacing: CGFloat, edgeInsets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    stack.edgeInsets = edgeInsets
    stack.detachesHiddenViews = true
    // Let `.width`-aligned parents stretch nested stacks (NSStackView hugs hard by default).
    stack.setHuggingPriority(.defaultLow, for: .horizontal)
    return stack
}

@MainActor
public func vStack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading,
            edgeInsets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = spacing
    stack.edgeInsets = edgeInsets
    stack.detachesHiddenViews = true
    stack.setHuggingPriority(.defaultLow, for: .horizontal)
    return stack
}

/// A vertical stack whose arranged subviews always span its full width (inside the edge insets).
/// NSStackView's `.width` alignment only makes the views equally wide, which leaves rows without
/// an intrinsic width floating; pages and forms need real full-width rows.
@MainActor
public func columnStack(_ views: [NSView], spacing: CGFloat, edgeInsets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
    let stack = vStack([], spacing: spacing, alignment: .leading, edgeInsets: edgeInsets)
    for view in views { stack.addFullWidth(view) }
    return stack
}

extension NSStackView {
    /// Adds `view` stretched to the stack's width (inside its edge insets).
    public func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left).isActive = true
        view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right).isActive = true
    }

    /// New edge insets for a stack filled with ``addFullWidth(_:)``: the views' side constraints
    /// move with them (a narrow page with smaller side padding).
    public func setFullWidthInsets(_ insets: NSEdgeInsets) {
        edgeInsets = insets
        let arranged = Set(arrangedSubviews.map(ObjectIdentifier.init))
        for constraint in constraints where constraint.secondItem === self {
            guard let view = constraint.firstItem as? NSView, arranged.contains(ObjectIdentifier(view)),
                  constraint.relation == .equal, constraint.multiplier == 1 else { continue }
            switch constraint.firstAttribute {
            case .leading: constraint.constant = insets.left
            case .trailing: constraint.constant = -insets.right
            default: break
            }
        }
    }
}

/// A flexible spacer for stack views.
@MainActor
public func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
}
