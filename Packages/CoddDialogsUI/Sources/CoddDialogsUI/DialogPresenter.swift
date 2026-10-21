import AppKit

/// Shows a dialog content view: as a sheet on a window (A switch account, B Hook 差異, D quit) or
/// as a non-modal child panel over a window's right edge (C add account, D24). The presenter only
/// places windows; closing is the app's job (`dismiss`) after the dialog's callback ran, so the
/// app decides what ✕ / ⎋ / 取消 mean (for C: maybe switch the login back first).
@MainActor
public enum DialogPresenter {
    /// D24: the panel's right edge sits this far inside the parent's right edge.
    public static let panelRightInset: CGFloat = 24
    /// D24: the panel's top edge sits this far below the parent's top edge.
    public static let panelTopInset: CGFloat = 80

    /// Begins `view` as a sheet on `window` (sized to the view's fitting size) and returns the
    /// sheet window. Keys reach the view first (⏎ primary, ⎋ cancel; see `DialogContentView`).
    @discardableResult
    public static func presentSheet(_ view: NSView, on window: NSWindow) -> NSWindow {
        var size = fittingSize(of: view)
        size.height = cappedHeight(size.height, under: window)
        let sheet = DialogSheetWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        sheet.backgroundColor = view.dialogBackground
        sheet.contentView = view
        sheet.initialFirstResponder = (view as? DialogContentView)?.initialResponder
        window.beginSheet(sheet)
        if let responder = (view as? DialogContentView)?.initialResponder { sheet.makeFirstResponder(responder) }
        return sheet
    }

    /// Shows `view` in a panel that is a child window of `window` (ordered above it only, never a
    /// floating level over other apps), its right edge `panelRightInset` inside the window's and
    /// its top `panelTopInset` below the window's top, so the terminal behind it stays visible and
    /// clickable. It is movable by its header, ⎋ cancels, and clicking into the parent window
    /// makes the parent key without the panel taking focus back.
    @discardableResult
    public static func presentPanel(_ view: NSView, over window: NSWindow) -> NSPanel {
        let size = fittingSize(of: view)
        let panel = DialogPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = window.level
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = view.dialogBackground
        panel.contentView = view
        panel.setFrameOrigin(panelOrigin(size: size, parentFrame: window.frame))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if let responder = (view as? DialogContentView)?.initialResponder { panel.makeFirstResponder(responder) }
        return panel
    }

    /// Shows `view` in its own centered window, for when there is no window to attach it to (the
    /// quit dialog from the status item's `結束` while the main window is closed, D18). Keys work
    /// as on a sheet; ✕ / ⎋ / ⌘W go to the dialog's cancel.
    @discardableResult
    public static func presentStandalone(_ view: NSView) -> NSWindow {
        let window = DialogSheetWindow(contentRect: NSRect(origin: .zero, size: fittingSize(of: view)),
                                       styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = view.dialogBackground
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let responder = (view as? DialogContentView)?.initialResponder { window.makeFirstResponder(responder) }
        return window
    }

    /// Ends a sheet or removes a child panel, then closes the dialog window.
    public static func dismiss(_ dialog: NSWindow) {
        if let parent = dialog.sheetParent {
            parent.endSheet(dialog)
        } else if let parent = dialog.parent {
            parent.removeChildWindow(dialog)
        }
        dialog.orderOut(nil)
        dialog.close()
    }

    /// D24 placement in screen coordinates (y up): right edge inset, top inset, kept inside the
    /// parent's bottom edge when the parent is short.
    public static func panelOrigin(size: NSSize, parentFrame: NSRect) -> NSPoint {
        let x = parentFrame.maxX - panelRightInset - size.width
        let top = parentFrame.maxY - panelTopInset
        var y = top - size.height
        if y < parentFrame.minY, size.height < parentFrame.height { y = parentFrame.minY }
        return NSPoint(x: max(parentFrame.minX, x), y: y)
    }

    /// A sheet's height, at most the room between its window's content top (where the sheet
    /// hangs from) and the bottom of that screen's visible frame, less 8: at UI 字級 20 a dialog can
    /// be taller than a short screen; it then scrolls its body instead of losing its buttons
    /// below the screen. At least 240 (a sheet never gets unusably small).
    public static func cappedHeight(_ height: CGFloat, under window: NSWindow) -> CGFloat {
        guard let screen = window.screen ?? NSScreen.main else { return height }
        let top = window.frame.minY + window.contentLayoutRect.maxY
        let room = top - screen.visibleFrame.minY - 8
        return min(height, max(240, room))
    }

    static func fittingSize(of view: NSView) -> NSSize {
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        let width = (view as? DialogContentView)?.dialogWidth ?? fitting.width
        return NSSize(width: width, height: ceil(fitting.height))
    }
}

private extension NSView {
    var dialogBackground: NSColor { (self as? DialogContentView)?.windowBackground ?? .black }
}

/// The sheet window: keys go to the dialog view's `performKeyEquivalent` (⏎ / ⎋); the close
/// commands (⌘W, the Esc that no view took) cancel instead of closing it directly.
final class DialogSheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (contentView as? DialogContentView)?.cancelFromKeyboard() }
    override func performClose(_ sender: Any?) { (contentView as? DialogContentView)?.cancelFromKeyboard() }
}

/// The add-account panel (D24): borderless (radius 0), key-capable for the alias field, dragged by
/// its header band; never re-takes key focus on its own.
final class DialogPanel: NSPanel {
    /// Height of the header band (from the top) that drags the panel.
    var dragRegionHeight: CGFloat { (contentView as? DialogContentView)?.headerHeight ?? 0 }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { (contentView as? DialogContentView)?.cancelFromKeyboard() }
    override func performClose(_ sender: Any?) { (contentView as? DialogContentView)?.cancelFromKeyboard() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isInDragRegion(event) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    /// In the header band and not on a working control (✕ keeps working; the title label and
    /// the chips drag).
    func isInDragRegion(_ event: NSEvent) -> Bool {
        guard dragRegionHeight > 0, let content = contentView, let frameView = content.superview else { return false }
        let point = event.locationInWindow
        guard point.y >= content.frame.maxY - dragRegionHeight else { return false }
        // hitTest takes the point in the superview's coordinates (the content view is flipped).
        guard let control = content.hitTest(frameView.convert(point, from: nil)) as? NSControl else { return true }
        if let label = control as? NSTextField, !label.isEditable, !label.isSelectable { return true }
        return false
    }
}
