import AppKit
import CoddUI

/// Tinted block a row belongs to (R1: groups are light tinted blocks; NEEDS YOU is amber).
enum BlockStyle: Equatable {
    case none
    case needs
    case tinted(TagColor)
    /// `未分類` and groups without a color: dashed outline, no tint.
    case ungrouped
}

/// Position of a row inside its block (which outline edges it draws).
enum BlockEdge: Equatable { case single, top, middle, bottom }

/// Background emphasis of a session row (`.srow` variants).
enum RowEmphasis: Equatable {
    case none, current, waiting, waitingCurrent, error
}

/// How a row reacts to hover.
enum HoverKind: Equatable { case none, session, header }

/// Row view = the block background plus the session row background. Content is drawn by the
/// cell view. Everything here is pushed in (by the cell or the controller); the row view
/// itself observes nothing.
final class SidebarRowView: NSTableRowView {
    var block: BlockStyle = .none { didSet { if block != oldValue { needsDisplay = true } } }
    var edge: BlockEdge = .middle { didSet { if edge != oldValue { needsDisplay = true } } }
    /// Transparent gap above the block (group headers: `.gblk{margin-top:5px}`).
    var topGap: CGFloat = 0 { didSet { if topGap != oldValue { needsDisplay = true } } }
    var emphasis: RowEmphasis = .none { didSet { if emphasis != oldValue { needsDisplay = true } } }
    var hoverKind: HoverKind = .none
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            (view(atColumn: 0) as? SidebarCellView)?.isHovered = isHovered
        }
    }
    /// Drop target highlight for the whole group block (`.gblk.drop`); the group header cell
    /// also says `移入`.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
            (view(atColumn: 0) as? NSView)?.needsDisplay = true
        }
    }
    /// The row is being dragged (SidebarStates A `.ss-ghost`): its slot shows a dashed amber-dim
    /// outline over a faint amber fill and dimmed content. Rows of one dragged project share
    /// one outline (`ghostEdge`).
    var ghostEdge: BlockEdge? {
        didSet {
            guard ghostEdge != oldValue else { return }
            needsDisplay = true
            // The row's own layer dims the cell drawn into it (`.ss-ghost span{opacity:.75}`); the
            // cell has no layer of its own to fade.
            alphaValue = ghostEdge == nil ? 1 : 0.7
        }
    }
    /// Set by the outline: more than one row is selected (`.srow.sel` styling).
    var showsMultiSelection = false { didSet { if showsMultiSelection != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The cell draws into this layer: one backing store per row instead of two. Views
        // that need their own layer (lamp, rename field, add-group button) opt in explicitly.
        canDrawSubviewsIntoLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isEmphasized: Bool { get { false } set {} }

    /// M5 D21: the row is one VoiceOver element that says what its cell draws (title, state,
    /// duration, badges; a header's counts).
    override func accessibilityLabel() -> String? {
        subviews.lazy.compactMap { ($0 as? SidebarCellView)?.spokenLabel }.first ?? super.accessibilityLabel()
    }

    /// The cell's actions (a project row's `+`) in VoiceOver's actions rotor.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let actions = subviews.lazy.compactMap { ($0 as? SidebarCellView)?.rowAccessibilityActions }.first ?? []
        return actions.isEmpty ? super.accessibilityCustomActions() : actions
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isDropTarget = false
        ghostEdge = nil
        emphasis = .none
        endPulse(nil)
    }

    /// The cell always spans the row: NSTableView places it once, and a width change that comes
    /// later (a legacy scroller appearing after the first layout) would otherwise leave it wider.
    override func layout() {
        super.layout()
        for case let cell as SidebarCellView in subviews where cell.frame != bounds { cell.frame = bounds }
        if let pulseLayer, pulseLayer.frame != pulseRect {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pulseLayer.frame = pulseRect
            CATransaction.commit()
        }
    }

    // MARK: Reveal pulse

    /// How long the reveal highlight stays (a project revealed for a dropped folder, ⌘O).
    static let pulseDuration: TimeInterval = 1.0
    /// The reveal highlight is up (tests, dump).
    private(set) var isPulsing = false
    /// Whether the latest highlight was animated (false with 減少動態; tests).
    private(set) var lastPulseAnimated: Bool?
    private var pulseLayer: CALayer?
    private var pulseGeneration = 0

    /// Where the highlight sits: the selection's rectangle (inside the block border).
    private var pulseRect: CGRect { block == .none ? blockRect : blockRect.insetBy(dx: 1, dy: 0) }

    /// The reveal highlight: an amber wash with a 1 px amber ring over the row that fades in and
    /// out twice in about a second (the render server animates it: no work per frame). With
    /// `animated` false (減少動態) it shows still and goes after the same time, without a fade.
    func pulse(animated: Bool) {
        pulseGeneration += 1
        let generation = pulseGeneration
        isPulsing = true
        lastPulseAnimated = animated
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.pulseDuration))
            self?.endPulse(generation)
        }
        // The row is layer-backed; without its layer yet there is nothing to draw on.
        guard let host = layer else { return }
        let marker = pulseLayer ?? CALayer()
        pulseLayer = marker
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.removeAllAnimations()
        marker.frame = pulseRect
        marker.backgroundColor = Palette.amber.withAlphaComponent(0.14).cgColor
        marker.borderColor = Palette.amber.withAlphaComponent(0.85).cgColor
        marker.borderWidth = 1
        marker.opacity = animated ? 0 : 1
        // Below the layers of the cell's own controls (the `+`), above the drawn row.
        if marker.superlayer !== host { host.insertSublayer(marker, at: 0) }
        CATransaction.commit()
        if animated {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0.35, 1, 0]
            fade.keyTimes = [0, 0.18, 0.5, 0.68, 1]
            fade.duration = Self.pulseDuration
            fade.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            marker.add(fade, forKey: "reveal")
        }
    }

    /// Removes the highlight (`generation`: only when no newer pulse started since; nil: now).
    private func endPulse(_ generation: Int?) {
        if let generation, generation != pulseGeneration { return }
        if generation == nil { pulseGeneration += 1 }
        guard let marker = pulseLayer else { isPulsing = false; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.removeAllAnimations()
        marker.removeFromSuperlayer()
        CATransaction.commit()
        pulseLayer = nil
        isPulsing = false
    }

    /// The block rectangle (inset from the sidebar edges, below the top gap).
    var blockRect: CGRect {
        CGRect(x: Metrics.sidebarInset, y: topGap, width: bounds.width - Metrics.sidebarInset * 2, height: bounds.height - topGap)
    }

    // MARK: Drawing

    override func drawBackground(in dirtyRect: NSRect) {
        let rect = blockRect
        drawBlock(rect)
        let content = block == .none ? rect : rect.insetBy(dx: 1, dy: 0)
        if let ghostEdge {
            drawGhost(content, edge: ghostEdge)
        } else {
            drawEmphasis(content)
        }
    }

    /// `.ss-ghost{border:1px dashed var(--amber-dim);background:rgba(255,184,74,.03)}`.
    private func drawGhost(_ rect: CGRect, edge: BlockEdge) {
        let inner = rect.insetBy(dx: 2, dy: 0)
        Draw.fill(inner, Palette.amber.withAlphaComponent(0.03))
        drawDashedEdges(inner, color: Palette.amberDim, top: edge == .top || edge == .single,
                        bottom: edge == .bottom || edge == .single)
    }

    /// `.srow.sel`: several selected sessions, or a project the sidebar selected for the user (a
    /// folder that already was a project; a lone selected session shows as the current row instead).
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, showsMultiSelection || hoverKind == .header else { return }
        let rect = (block == .none ? blockRect : blockRect.insetBy(dx: 1, dy: 0))
        Draw.fill(rect, Palette.amber.withAlphaComponent(0.06))
        Draw.strokeRect(rect, color: Palette.amberDim)
    }

    override func drawSeparator(in dirtyRect: NSRect) {}

    private func drawBlock(_ rect: CGRect) {
        let top = edge == .top || edge == .single
        let bottom = edge == .bottom || edge == .single
        switch block {
        case .none:
            return
        case .needs:
            Draw.fill(rect, Palette.amber.withAlphaComponent(0.035))
            drawEdges(rect, color: Palette.amber.withAlphaComponent(0.28), top: top, bottom: bottom)
        case .tinted(let tag):
            let tint = tag.color
            Draw.fill(rect, tint.withAlphaComponent(isDropTarget ? 0.15 : 0.07))
            if isDropTarget {
                drawDashedEdges(rect, color: Palette.amber, top: top, bottom: bottom)
            } else {
                drawEdges(rect, color: tint.withAlphaComponent(0.17), top: top, bottom: bottom)
            }
        case .ungrouped:
            if isDropTarget { Draw.fill(rect, Palette.amber.withAlphaComponent(0.05)) }
            drawDashedEdges(rect, color: isDropTarget ? Palette.amber : Palette.lineBright, top: top, bottom: bottom)
        }
    }

    private func drawEdges(_ rect: CGRect, color: NSColor, top: Bool, bottom: Bool) {
        Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), color)
        Draw.fill(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height), color)
        if top { Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), color) }
        if bottom { Draw.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), color) }
    }

    private func drawDashedEdges(_ rect: CGRect, color: NSColor, top: Bool, bottom: Bool) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY))
        if top {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.5))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY + 0.5))
        }
        if bottom {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        }
        let dash: [CGFloat] = [3, 2]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    private func drawEmphasis(_ rect: CGRect) {
        let bar = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        switch emphasis {
        case .waiting, .waitingCurrent:
            let strong = emphasis == .waitingCurrent
            Draw.hGradient(rect, from: Palette.amber.withAlphaComponent(strong ? 0.16 : 0.09),
                           to: Palette.amber.withAlphaComponent(strong ? 0.04 : 0.02))
            Draw.fill(bar, Palette.amber)
        case .error:
            Draw.hGradient(rect, from: Palette.danger.withAlphaComponent(0.08), to: Palette.danger.withAlphaComponent(0.015))
            Draw.fill(bar, Palette.danger)
        case .current:
            Draw.fill(rect, Palette.bgLift)
            Draw.fill(bar, Palette.amber)
        case .none:
            guard isHovered else { return }
            switch (hoverKind, block) {
            case (.session, .tinted(let tag)):
                Draw.fill(rect, tag.color.withAlphaComponent(0.13))
                Draw.fill(bar, tag.color.withAlphaComponent(0.45))
            case (.session, _):
                Draw.fill(rect, Palette.bgSoft)
                Draw.fill(bar, Palette.lineBright)
            case (.header, .tinted(let tag)):
                Draw.fill(rect, tag.color.withAlphaComponent(0.12))
            case (.header, _):
                Draw.fill(rect, Palette.bgSoft)
            default:
                break
            }
        }
    }
}
