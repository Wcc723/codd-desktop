import AppKit
import CoddUI

/// This package's custom controls under CoddUI's keyboard rules (M5 D21, ``KeyboardFocus``): a
/// control takes the focus only while Full Keyboard Access is on, presses on space / ⏎, and shows
/// the helmet focus style while keyboard navigation (not a click) put it in focus in the key
/// window (``KeyboardFocusTracker``). The style goes on the view's layer (two amber pixels inside
/// the bounds, ``KeyboardFocus/ringGlow`` outside), so no control changes its drawing.
@MainActor
enum KeyFocus {
    static var isFullKeyboardAccessOn: Bool { KeyboardFocus.isFullKeyboardAccessOn }

    /// Space or ⏎ / keypad enter without ⌘ ⌥ ⌃.
    static func isPressKey(_ event: NSEvent) -> Bool {
        switch KeyboardFocus.key(of: event) {
        case .space?, .return?: true
        default: false
        }
    }

    /// A tracker for `view` that shows or clears the focus style whenever CoddUI says it changed.
    static func tracker(for view: NSView) -> KeyboardFocusTracker {
        let tracker = KeyboardFocusTracker(view: view)
        tracker.onChange = { [weak view, weak tracker] in
            guard let view, let tracker else { return }
            showRing(on: view, tracker.showsFocusRing)
        }
        return tracker
    }

    /// `KeyboardFocus.drawRing` as a 2 pt amber layer border plus the ring glow as the view's shadow.
    static func showRing(on view: NSView, _ shown: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.borderColor = Palette.amber.cgColor
        layer.borderWidth = shown ? 2 : 0
        view.shadow = shown ? KeyboardFocus.ringGlow : nil
    }
}

/// A view that draws several pressable items itself (crumbs, status items): VoiceOver gets one
/// button per item through ``DrawnItemElement``, and the keyboard a cursor (← → and ⏎ / space).
@MainActor
protocol DrawnItemsHost: NSView {
    var drawnItemCount: Int { get }
    func drawnItemLabel(_ index: Int) -> String?
    /// The item's frame in the host's coordinates.
    func drawnItemFrame(_ index: Int) -> CGRect
    func pressDrawnItem(_ index: Int)
}

/// One drawn item as VoiceOver sees it: a button with the host's label, frame and press. The host
/// (a main-actor view, Sendable) is read before the isolated closures, which never capture `self`.
final class DrawnItemElement: NSAccessibilityElement {
    private weak var host: (any DrawnItemsHost)?
    let index: Int

    @MainActor
    init(host: any DrawnItemsHost, index: Int, role: NSAccessibility.Role = .button) {
        self.host = host
        self.index = index
        super.init()
        setAccessibilityParent(host)
        setAccessibilityRole(role)
    }

    override func accessibilityLabel() -> String? {
        let host = host, index = index
        return MainActor.assumeIsolated { host?.drawnItemLabel(index) }
    }

    override func accessibilityFrame() -> NSRect {
        let host = host, index = index
        return MainActor.assumeIsolated {
            guard let host, let window = host.window else { return .zero }
            return window.convertToScreen(host.convert(host.drawnItemFrame(index), to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let host = host, index = index
        return MainActor.assumeIsolated {
            guard let host else { return false }
            host.pressDrawnItem(index)
            return true
        }
    }
}
