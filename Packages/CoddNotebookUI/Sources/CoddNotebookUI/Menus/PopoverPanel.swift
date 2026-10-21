import AppKit
import CoddUI

/// A borderless, non-activating panel that hosts a popover's content (a `NotebookMenuView`, the
/// link picker, the tag editor) as a child window of the window it opens from, so it moves and
/// closes with it.
///
/// It never activates the app and never uses `orderFrontRegardless`: `show` adds it as a child
/// window (which orders it above its parent only), and it becomes key only when the app is
/// already active and the parent is its key window (a click in CODD opened it), so a background
/// or DEBUG run can never take the user's keyboard focus. It closes on ⎋ (the content decides),
/// when it resigns key (a click elsewhere), and when its parent closes.
public final class PopoverPanel: NSPanel {
    /// Called once when the panel closes for any reason.
    public var onClose: (() -> Void)?
    public let content: NSView
    private var closing = false

    public init(content: NSView) {
        self.content = content
        let size = content.fittingSize.width > 0 ? content.fittingSize : content.frame.size
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]
        isFloatingPanel = false
        appearance = NSAppearance(named: .darkAqua)
        let container = FlippedView(frame: CGRect(origin: .zero, size: size))
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// Shows the panel with its top-left corner at `topLeft` in `view`'s (flipped or not)
    /// coordinates. Does nothing when `view` is not in a visible window (offscreen tests, demos).
    @discardableResult
    public func show(at topLeft: CGPoint, in view: NSView) -> Bool {
        guard let parent = view.window, parent.isVisible else { return false }
        let size = frame.size
        let inWindow = view.convert(topLeft, to: nil)
        let onScreen = parent.convertPoint(toScreen: inWindow)
        var origin = CGPoint(x: onScreen.x, y: onScreen.y - size.height)
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY + 4 { origin.y = screen.minY + 4 }
        }
        setFrameOrigin(origin)
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        if NSApp.isActive, parent.isKeyWindow {
            makeKey()
            if let content = content as? NotebookPopoverContent {
                content.takeFocus()
            } else if content.acceptsFirstResponder {
                makeFirstResponder(content)
            }
        }
        return true
    }

    /// Resizes keeping the top edge (a submenu opened in a menu).
    public func resize(to size: NSSize) {
        var rect = frame
        rect.origin.y += rect.height - size.height
        rect.size = size
        setFrame(rect, display: true)
    }

    public override func resignKey() {
        super.resignKey()
        dismiss()
    }

    public override func cancelOperation(_ sender: Any?) { dismiss() }

    /// Removes the panel from its parent and hides it; the parent gets the key status back.
    public func dismiss() {
        guard !closing else { return }
        closing = true
        let parentWindow = parent
        let wasKey = isKeyWindow
        parentWindow?.removeChildWindow(self)
        orderOut(nil)
        if wasKey, NSApp.isActive, let parentWindow, parentWindow.isVisible { parentWindow.makeKey() }
        let handler = onClose
        onClose = nil
        handler?()
    }
}

/// Content a presenter can size: menus and pickers report their size and its changes (a
/// submenu opened, a picker filtered its list).
@MainActor
public protocol NotebookPopoverContent: NSView {
    var preferredSize: NSSize { get }
    var onSizeChange: ((NSSize) -> Void)? { get set }
    /// Called once the panel became key: menus take the keyboard, pickers focus their field.
    func takeFocus()
}

extension NotebookMenuView: NotebookPopoverContent {
    public func takeFocus() { window?.makeFirstResponder(self) }
}

extension LinkPickerView: NotebookPopoverContent {
    public func takeFocus() { focus() }
}

extension TagEditorView: NotebookPopoverContent {
    public func takeFocus() { focus() }
}

/// Where a chrome view's menus go. The default (`PopoverMenuPresenter`) hosts them in a
/// `PopoverPanel`; tests record them; the demo draws them in place for a snapshot.
@MainActor
public protocol NotebookMenuPresenting: AnyObject {
    /// Shows `menu` with its top-left corner at `topLeft` in `host`'s coordinates. `onClose` runs
    /// once when the menu goes away (chosen, ⎋, a click elsewhere, `dismiss()`).
    func present(_ menu: NSView, at topLeft: CGPoint, in host: NSView, onClose: @escaping () -> Void)
    func dismiss()
}

/// Presents menus in a `PopoverPanel` child window.
@MainActor
public final class PopoverMenuPresenter: NotebookMenuPresenting {
    public private(set) var panel: PopoverPanel?

    public init() {}

    public func present(_ menu: NSView, at topLeft: CGPoint, in host: NSView, onClose: @escaping () -> Void) {
        dismiss()
        let panel = PopoverPanel(content: menu)
        if let content = menu as? NotebookPopoverContent {
            panel.setContentSize(content.preferredSize)
            content.onSizeChange = { [weak panel] size in panel?.resize(to: size) }
        }
        panel.onClose = { [weak self, weak panel] in
            if let self, self.panel === panel { self.panel = nil }
            onClose()
        }
        self.panel = panel
        if !panel.show(at: topLeft, in: host) {
            // Not in a visible window: nothing is ordered in (offscreen tests and snapshots).
            self.panel = nil
            panel.onClose = nil
            onClose()
        }
    }

    public func dismiss() {
        panel?.dismiss()
        panel = nil
    }
}

/// Draws menus as a subview of the host (the demo's snapshots, and hosts that want the menu
/// inside their own view tree).
@MainActor
public final class InlineMenuPresenter: NotebookMenuPresenting {
    public private(set) var menu: NSView?
    private var onClose: (() -> Void)?

    public init() {}

    public func present(_ menu: NSView, at topLeft: CGPoint, in host: NSView, onClose: @escaping () -> Void) {
        dismiss()
        let size = (menu as? NotebookPopoverContent)?.preferredSize ?? menu.fittingSize
        let y = host.isFlipped ? topLeft.y : topLeft.y - size.height
        menu.frame = CGRect(origin: CGPoint(x: topLeft.x, y: y), size: size)
        host.addSubview(menu, positioned: .above, relativeTo: nil)
        self.menu = menu
        self.onClose = onClose
        if let content = menu as? NotebookPopoverContent {
            content.onSizeChange = { [weak content] size in content?.setFrameSize(size) }
        }
    }

    public func dismiss() {
        guard let menu else { return }
        menu.removeFromSuperview()
        self.menu = nil
        let handler = onClose
        onClose = nil
        handler?()
    }
}
