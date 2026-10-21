import AppKit
import CoddUI

/// Base of the four dialog views: keyboard (⏎ = the primary button when it is enabled, ⎋ =
/// cancel), the fixed width, the header band height (the panel drags by it) and window fitting.
///
/// Keys are taken in `performKeyEquivalent`, which AppKit calls on the key window's views before
/// the first responder sees the key, so the dialog works the same as a sheet, a panel or in a
/// test window. While an input method composes (注音) in a text field, ⏎ and ⎋ belong to the
/// input method (they commit / cancel the composition) and are passed on untouched.
@MainActor
public class DialogContentView: NSView {
    /// The dialog's fixed width in design points (artboard grid, see each dialog).
    let designWidth: CGFloat
    /// The dialog's width at the interface zoom (`designWidth` at UI 字級 13).
    public var dialogWidth: CGFloat { UIZoom.pt(designWidth) }
    /// The `.modal` frame filling the view.
    let frameView: DialogFrame

    init(width: CGFloat, title: String) {
        designWidth = width
        frameView = DialogFrame(title: title)
        super.init(frame: NSRect(x: 0, y: 0, width: UIZoom.pt(width), height: 200))
        translatesAutoresizingMaskIntoConstraints = false
        // M4 zoom: the width follows the UI 字級 like the type inside it (at 20 a 640 dialog is
        // 985, still inside the 1011 pt minimum window).
        widthAnchor.constraint(equalToConstant: width).zoomed(width).isActive = true
        addSubview(frameView.view)
        frameView.view.pinEdges(to: self)
        frameView.onClose = { [weak self] in self?.performCancel() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    /// Height of the `.m-h` band (the panel drags by it).
    var headerHeight: CGFloat { frameView.headerHeight }

    /// The `.m-h` title as given (`Switch account · 切換帳號`; drawn uppercase).
    public var title: String { frameView.title }
    /// The `.sd-fnote` text (tests).
    var footerNote: String? { frameView.footerNote }
    /// The header's ✕ (tests).
    var frameCloseButton: CoddButton { frameView.closeButton }
    /// Window background behind the frame (`.modal` is bg-soft).
    var windowBackground: NSColor { Palette.bgSoft }
    /// The view that gets keyboard focus when the dialog is shown.
    var initialResponder: NSView? { nil }

    /// Whether ⏎ may trigger the primary button now.
    var isPrimaryEnabled: Bool { false }
    /// Runs the primary button's action (only called while it is enabled).
    func performPrimary() {}
    /// ✕ / ⎋ / 取消.
    func performCancel() {}

    /// ⎋ that reached the window (`cancelOperation`, ⌘W through `performClose`).
    func cancelFromKeyboard() {
        guard !isComposing else { return }
        performCancel()
    }

    /// An input method has marked text in the focused text field.
    public var isComposing: Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case Self.returnKey, Self.enterKey:
            guard !isComposing else { return false }
            if isPrimaryEnabled { performPrimary() }
            return true
        case Self.escapeKey:
            guard !isComposing else { return false }
            performCancel()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// True on the first apply (no previous model) or when the value at `key` differs, so
    /// `update(_:)` touches only the parts that changed.
    func changed<M, V: Equatable>(_ previous: M?, _ next: M, _ key: KeyPath<M, V>) -> Bool {
        guard let previous else { return true }
        return previous[keyPath: key] != next[keyPath: key]
    }

    static let returnKey: UInt16 = 0x24
    static let enterKey: UInt16 = 0x4C
    static let escapeKey: UInt16 = 0x35

    /// Resizes the hosting sheet / panel to the content's fitting height, keeping the top edge
    /// (a progress or error line appearing grows the dialog downwards).
    func fitWindow() {
        guard let window, window.contentView === self else { return }
        layoutSubtreeIfNeeded()
        var height = ceil(fittingSize.height)
        if let parent = window.sheetParent { height = DialogPresenter.cappedHeight(height, under: parent) }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - height) >= 0.5 || abs(content.width - dialogWidth) >= 0.5 else { return }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: dialogWidth, height: height)).size
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                        display: true)
    }
}
