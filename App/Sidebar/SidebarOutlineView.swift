import AppKit

/// Callbacks from the outline view that need the controller.
@MainActor
protocol SidebarOutlineActions: AnyObject {
    func contextMenu(forRow row: Int) -> NSMenu?
    func beginRenameSelected()
    func archiveSelected()
    /// ⌥⇧↑ / ⌥⇧↓: move the selected session one place within its project.
    func moveSelected(by offset: Int)
    /// The pointer is over another row (-1: none). Drives the hover card.
    func hoverDidChange(row: Int)
    /// The pointer moved (the hover card comes back after a scroll only then).
    func outlineMouseMoved()
    /// A click or a scroll on the list (the hover card goes away).
    func outlineInteracted(scroll: Bool)
    /// A drag left the list or ended over it: the insertion line and the target block go away.
    func dropExited()
}

/// View-based outline with custom chrome: no disclosure triangles (cells draw `▸`), no
/// indentation (cells lay out their own padding), one tracking area for hover, native NSMenu
/// context menus, Return = rename, ⌘⌫ = archive, ⌥⇧↑↓ = reorder.
final class SidebarOutlineView: NSOutlineView {
    weak var actions: SidebarOutlineActions?
    /// The hovered row view (not its index: rows move under a still mouse when the diff
    /// inserts or removes rows above, and the highlight must follow the view under the mouse).
    private weak var hoveredRowView: SidebarRowView?
    private var hoverArea: NSTrackingArea?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x = 0
        frame.size.width = bounds.width
        return frame
    }

    // MARK: Hover (one tracking area for the whole list)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
        actions?.outlineMouseMoved()
    }

    override func mouseDown(with event: NSEvent) {
        actions?.outlineInteracted(scroll: false)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        actions?.outlineInteracted(scroll: false)
        super.rightMouseDown(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    // MARK: Drops (a Finder drag never reaches the controller's `endedAt`)

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        actions?.dropExited()
    }

    /// No `super`: NSTableView (and NSView) do not implement this optional method at runtime.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        actions?.dropExited()
    }

    override func scrollWheel(with event: NSEvent) {
        actions?.outlineInteracted(scroll: true)
        super.scrollWheel(with: event)
        refreshHover()
    }

    /// Re-evaluates hover after content moved under a still mouse.
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    private func setHoveredRow(_ row: Int) {
        let view = row >= 0 && row < numberOfRows ? rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView : nil
        // Same view: nothing to do unless it was recycled meanwhile (reuse clears the flag).
        guard view !== hoveredRowView || view?.isHovered == false else { return }
        hoveredRowView?.isHovered = false
        hoveredRowView = view
        view?.isHovered = true
        actions?.hoverDidChange(row: view == nil ? -1 : row)
    }

    /// The row view currently drawn as hovered (tests / self-test).
    var hoveredRowViewForTesting: SidebarRowView? { hoveredRowView }

    // MARK: Menus + keys

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return actions?.contextMenu(forRow: row)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let plain = modifiers.isEmpty
        switch event.keyCode {
        case 36 where plain, 76 where plain: // Return / Enter
            actions?.beginRenameSelected()
        case 51 where event.modifierFlags.contains(.command): // ⌘⌫
            actions?.archiveSelected()
        case 126 where modifiers == [.option, .shift]: // ⌥⇧↑
            actions?.moveSelected(by: -1)
        case 125 where modifiers == [.option, .shift]: // ⌥⇧↓
            actions?.moveSelected(by: 1)
        default:
            super.keyDown(with: event)
        }
    }
}

/// What the list's scroll view asks while a drag is over its insets (above the first row, below
/// the list), where the outline itself is not under the pointer.
@MainActor
protocol SidebarScrollDropTarget: AnyObject {
    func scrollDragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation
    func scrollDragPerform(_ info: any NSDraggingInfo) -> Bool
    func dropExited()
}

/// The sidebar list's scroll view: its insets take the same drops as the list (rows from the
/// list itself, folders from Finder), planned by the controller from the pointer.
final class SidebarScrollView: NSScrollView {
    weak var dropTarget: SidebarScrollDropTarget?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.scrollDragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.scrollDragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.dropExited()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.scrollDragPerform(sender) ?? false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.dropExited()
    }
}
