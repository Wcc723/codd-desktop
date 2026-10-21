import AppKit
import CoddUI

/// What every sidebar cell needs: the stores, the window UI state and the controller.
@MainActor
final class SidebarEnvironment {
    let store: any SessionStore
    let accounts: any AccountStore
    let shell: ShellState
    /// Real mode (D29: sample account data is labelled as such there).
    let realMode: Bool
    weak var controller: SidebarViewController?

    init(store: any SessionStore, accounts: any AccountStore, shell: ShellState, realMode: Bool = false) {
        self.store = store
        self.accounts = accounts
        self.shell = shell
        self.realMode = realMode
    }
}

/// Decoration a cell asks its row view to draw.
struct RowDecoration: Equatable {
    var block: BlockStyle = .none
    var emphasis: RowEmphasis = .none
    var hover: HoverKind = .none
    var topGap: CGFloat = 0
}

/// Base sidebar cell: custom drawn (one view per row), reused by identifier.
///
/// `refresh()` runs inside an `ObservationLoop`, so a cell redraws exactly when a property it
/// reads changes (no `reloadData`, no list-wide invalidation). The loop stops while the cell
/// sits in the reuse queue (no window) and restarts when it is shown again.
class SidebarCellView: NSTableCellView, ZoomRefreshing {
    private(set) var node: NodeKind?
    private(set) var env: SidebarEnvironment?
    private var loop: ObservationLoop?

    var decoration = RowDecoration() {
        didSet { if decoration != oldValue { pushDecoration() } }
    }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No own layer: the row view flattens the cell into its layer (canDrawSubviewsIntoLayer).
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Binds the cell to a row. Called from `outlineView(_:viewFor:item:)`.
    func bind(_ node: NodeKind, env: SidebarEnvironment) {
        self.node = node
        self.env = env
        restartLoop()
    }

    /// Subclasses read the model here (tracked) and store what they draw.
    func refresh() {}

    // MARK: Accessibility (M5 D21)

    /// What VoiceOver says for the row (its `SidebarRowView` speaks it): the cell draws its text, so
    /// the row is one element with this label, and only the cell's real buttons are separate
    /// elements. Computed when asked (a duration is current then).
    var spokenLabel: String? { nil }

    /// What the row offers in VoiceOver's actions rotor (the project row's `+`); empty for most rows.
    var rowAccessibilityActions: [NSAccessibilityCustomAction] { [] }

    /// The cell itself is no element: its buttons are the row's children, its label the row's.
    override func isAccessibilityElement() -> Bool { false }

    /// M4 interface zoom: what `refresh()` derives from design points (the group gap in the row's
    /// decoration, frames) is taken again at the new zoom.
    func zoomDidChange() {
        guard node != nil else { return }
        refresh()
        needsLayout = true
        needsDisplay = true
    }

    private func restartLoop() {
        loop?.cancel()
        loop = ObservationLoop { [weak self] in
            guard let self else { return }
            self.refresh()
            self.needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loop?.cancel()
            loop = nil
        } else if loop == nil, node != nil {
            restartLoop()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        pushDecoration()
    }

    private func pushDecoration() {
        guard let row = superview as? SidebarRowView else { return }
        row.block = decoration.block
        row.emphasis = decoration.emphasis
        row.hoverKind = decoration.hover
        row.topGap = decoration.topGap
    }

    /// Drag image = a snapshot of the row content.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return [] }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = bounds
        return [component]
    }

    // MARK: Helpers for subclasses

    /// Block style for a group (tinted by its color, dashed when ungrouped / colorless).
    func blockStyle(forGroup id: GroupID?) -> BlockStyle {
        guard let id, let group = env?.store.group(id) else { return .none }
        if group.isUngrouped { return .ungrouped }
        return group.color.map(BlockStyle.tinted) ?? .ungrouped
    }

    func blockStyle(for node: NodeKind) -> BlockStyle {
        guard let snapshotBlock = env?.controller?.snapshot.block(of: node) else { return .none }
        switch snapshotBlock {
        case .needs: return .needs
        case .group(let id): return blockStyle(forGroup: id)
        }
    }

    /// Left edge of content inside a block (block inset + 1 px border).
    var contentLeft: CGFloat { Metrics.sidebarInset + (decoration.block == .none ? 0 : 1) }
    var contentRight: CGFloat { bounds.width - Metrics.sidebarInset - (decoration.block == .none ? 0 : 1) }
}
