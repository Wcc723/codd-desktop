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

    /// Moves the focus to the next (`delta` 1) or previous (-1) focusable sibling row of `view`
    /// in reading order (top to bottom): ↑ ↓ in a column that the artboard draws as a list.
    @discardableResult
    static func moveInList(from view: NSView, by delta: Int) -> Bool {
        guard let parent = view.superview, view.window != nil else { return false }
        let rows = parent.subviews
            .filter { $0 === view || isListPeer($0) }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard let index = rows.firstIndex(where: { $0 === view }) else { return false }
        let next = index + delta
        guard rows.indices.contains(next) else { return false }
        return KeyboardFocus.focusAsKeyboardNavigation(rows[next])
    }

    private static func isListPeer(_ candidate: NSView) -> Bool {
        guard let row = candidate as? KeyListRow, row.isKeyListRow else { return false }
        return candidate.canBecomeKeyView && !candidate.isHiddenOrHasHiddenAncestor
    }
}

/// A row that ↑ ↓ step through with its sibling rows (smart lists, projects, files in one column).
@MainActor
protocol KeyListRow: AnyObject {
    var isKeyListRow: Bool { get }
}
