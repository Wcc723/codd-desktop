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
