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

/// A custom-drawn Settings control under the D21 keyboard rules: a key view while Full Keyboard Access is
/// on and `acceptsKeyFocus`, the focus style while keyboard navigation focused it, and
/// `handleKey(_:)` for its keys (the default presses on space / ⏎).
class SxKeyView: FlippedView, KeyboardFocusTracking {
    private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

    /// Whether the control can take the focus now (subclasses: enabled, pressable).
    var acceptsKeyFocus: Bool { true }

    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: acceptsKeyFocus, refuses: false) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusTracker.becameFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusTracker.resignedFirstResponder() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) {
            focusTracker.noteKeyboardInteraction()
        } else {
            super.keyDown(with: event)
        }
    }

    /// The control's keys; true when handled.
    func handleKey(_ event: NSEvent) -> Bool {
        guard KeyFocus.isPressKey(event) else { return false }
        return accessibilityPerformPress()
    }

    /// The arrow of `event` as a step: ← ↑ = -1, → ↓ = 1, nil for any other key.
    static func arrowStep(_ event: NSEvent) -> Int? {
        switch KeyboardFocus.key(of: event) {
        case .left?, .up?: -1
        case .right?, .down?: 1
        default: nil
        }
    }
}
