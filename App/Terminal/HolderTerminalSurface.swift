import AppKit
import CoddTerminal
import CoddUI

/// One slot of the session pane (tab strip terminal or ⌘J panel) in real mode. The view holds a
/// deck with the engine views of every terminal that ever showed in this slot and is still
/// hot: the shown one is visible, the others hidden but still in the window (libghostty keeps
/// parsing for them and needs at least one attached surface to drain its app mailbox). Over the
/// deck, the link under the pointer shows its real target (`TerminalSlotView`).
@MainActor
final class HolderTerminalSurface: TerminalSurface {
    let slot: TerminalSlot
    let deck = TerminalDeckView()
    private lazy var slotView = TerminalSlotView(deck: deck)
    private weak var hub: TerminalHub?
    var onGridSizeChange: ((TerminalGridSize) -> Void)?
    private var lastGrid: TerminalGridSize?

    init(slot: TerminalSlot, hub: TerminalHub) {
        self.slot = slot
        self.hub = hub
        deck.setAccessibilityRole(.group)
        deck.setAccessibilityLabel(slot == .main ? "終端機" : "下方終端機")
    }

    var view: NSView { slotView }

    /// The hovered link of the shown terminal (nil: the hover ended, or another terminal shows).
    func showHoverLink(_ link: String?) { slotView.showLink(link) }

    /// The hover bubble's text, nil while it is hidden (tests).
    var hoverLinkText: String? { slotView.linkText }

    /// The shown terminal's grid; before one reported, an estimate from the slot's size.
    var gridSize: TerminalGridSize {
        if let lastGrid { return lastGrid }
        // Terminal text has its own size (never the interface zoom).
        let font = Typeface.fixed(fontSize)
        let advance = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = max(1, Typeface.lineHeight(font))
        return TerminalGridSize(columns: max(1, Int((deck.bounds.width - 32) / advance)),
                                rows: max(1, Int((deck.bounds.height - 20) / lineHeight)))
    }

    var fontSize: CGFloat {
        get { hub?.fontSize ?? CoddTerminalSetup.configuration.fontSize }
        set { hub?.setFontSize(newValue) }
    }

    func attach(_ target: TerminalTarget) { hub?.show(target, in: slot) }
    func detach() { hub?.show(nil, in: slot) }
    func setOccluded(_ occluded: Bool) { hub?.setOccluded(occluded, slot: slot) }
    func send(_ input: TerminalInput) { hub?.send(input, slot: slot) }
    func focus() { hub?.focus(slot) }
    var acceptsInput: Bool { hub?.acceptsInput(slot) ?? false }

    /// The shown terminal reported a grid (or the slot switched to one that has).
    func showGrid(_ size: TerminalResize) {
        let grid = TerminalGridSize(columns: size.columns, rows: size.rows)
        guard grid != lastGrid else { return }
        lastGrid = grid
        onGridSizeChange?(grid)
    }
}

/// Holds a slot's engine views on top of each other, all sized to the deck, one visible.
///
/// A deck too small to hold a terminal (the slot collapsed during a layout pass) leaves its
/// views' frames alone, so hidden terminals never reflow to nothing or tell their PTY a bogus size.
final class TerminalDeckView: NSView {
    private(set) weak var visibleView: NSView?

    override var isFlipped: Bool { true }

    /// Shows `view` (adding it first) and hides the one shown before. Moves keyboard focus along
    /// when the hidden terminal had it: a hidden first responder would keep receiving keys.
    func show(_ view: NSView) {
        if view.superview !== self {
            view.frame = bounds
            addSubview(view)
        }
        guard visibleView !== view else {
            view.isHidden = false
            return
        }
        let hadFocus = visibleView.map(Self.hasFocus) ?? false
        visibleView?.isHidden = true
        view.isHidden = false
        visibleView = view
        if hadFocus { window?.makeFirstResponder(view) }
    }

    /// Shows nothing (panel closed, placeholder); the views stay as hot terminals.
    func showNothing() {
        guard let shown = visibleView else { return }
        let hadFocus = Self.hasFocus(shown)
        shown.isHidden = true
        visibleView = nil
        if hadFocus { window?.makeFirstResponder(nil) }
    }

    static func hasFocus(_ view: NSView) -> Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    private func fit() {
        guard bounds.width >= 40, bounds.height >= 24 else { return }
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}
