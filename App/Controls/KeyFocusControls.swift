import AppKit
import CoddUI

/// The App's own custom controls under CoddUI's keyboard rules (M5 D21, ``KeyboardFocus``): they
/// take the focus only while Full Keyboard Access is on (like AppKit buttons), press on space / ⏎,
/// and show the helmet focus style while keyboard navigation (not a click) put them in focus in the
/// key window (``KeyboardFocusTracker``). The style goes on the view's layer (two amber pixels inside
/// the bounds, ``KeyboardFocus/ringGlow`` outside), so no control changes its own drawing.
@MainActor
enum AppKeyFocus {
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

    /// Moves the keyboard focus to the next (`delta` 1) or previous (-1) focusable sibling of `view`
    /// of the same kind, in reading order (top to bottom, then left to right): ↑ ↓ in a list the
    /// artboard draws as rows, ← → in a row of items.
    @discardableResult
    static func moveAmongSiblings(from view: NSView, by delta: Int, vertical: Bool = true) -> Bool {
        guard let parent = view.superview, view.window != nil else { return false }
        let peers = parent.subviews
            .filter { $0 === view || (type(of: $0) == type(of: view) && $0.canBecomeKeyView && !$0.isHiddenOrHasHiddenAncestor) }
            .sorted { vertical ? ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
                               : ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        guard let index = peers.firstIndex(where: { $0 === view }) else { return false }
        // A flipped parent lays rows top down; an unflipped one bottom up.
        let step = vertical && !parent.isFlipped ? -delta : delta
        let next = index + step
        guard peers.indices.contains(next) else { return false }
        return KeyboardFocus.focusAsKeyboardNavigation(peers[next])
    }
}

/// An `NSControl` the keyboard can reach (the rail's items and account chip, the footer's usage
/// toggle). Subclasses press through ``keyPress()`` (default: `accessibilityPerformPress`).
class KeyFocusControl: NSControl, KeyboardFocusTracking {
    private(set) lazy var focusTracker: KeyboardFocusTracker = AppKeyFocus.tracker(for: self)

    /// False keeps the control out of the key loop even with Full Keyboard Access (an inert state).
    var takesKeyboardFocus: Bool { true }

    override var acceptsFirstResponder: Bool {
        KeyboardFocus.acceptsFocus(enabled: isEnabled && takesKeyboardFocus, refuses: refusesFirstResponder)
    }
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

    /// Space / ⏎ (and, in subclasses, arrows). Returns whether the key was used.
    func keyPress() -> Bool { accessibilityPerformPress() }

    /// Arrows a subclass handles (rail ↑ ↓); false passes them up the responder chain.
    func handleArrow(_ key: KeyboardFocus.Key) -> Bool { false }

    override func keyDown(with event: NSEvent) {
        if AppKeyFocus.isPressKey(event) {
            focusTracker.noteKeyboardInteraction()
            if !keyPress() { NSSound.beep() }
            return
        }
        if let key = KeyboardFocus.key(of: event), [.up, .down, .left, .right].contains(key), handleArrow(key) {
            focusTracker.noteKeyboardInteraction()
            return
        }
        super.keyDown(with: event)
    }

    /// Space's key-up would otherwise reach the next responder.
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 0x31, focusTracker.isFirstResponder { return }
        super.keyUp(with: event)
    }
}

/// A flipped view the keyboard can reach (account rows, the menu bar panel's session rows, Home's
/// `◇ n 個待看` line). Same rules as ``KeyFocusControl``.
class KeyFocusView: FlippedView, KeyboardFocusTracking {
    private(set) lazy var focusTracker: KeyboardFocusTracker = AppKeyFocus.tracker(for: self)

    /// False keeps the view out of the key loop even with Full Keyboard Access.
    var takesKeyboardFocus: Bool { true }

    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: takesKeyboardFocus, refuses: false) }
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

    /// Space / ⏎. Returns whether the key was used (false beeps).
    func keyPress() -> Bool { accessibilityPerformPress() }

    override func keyDown(with event: NSEvent) {
        if AppKeyFocus.isPressKey(event) {
            focusTracker.noteKeyboardInteraction()
            if !keyPress() { NSSound.beep() }
            return
        }
        switch KeyboardFocus.key(of: event) {
        case .up?, .down?:
            // Rows of one list step with ↑ ↓ (the account rows, the panel's session rows).
            if AppKeyFocus.moveAmongSiblings(from: self, by: KeyboardFocus.key(of: event) == .down ? 1 : -1) {
                focusTracker.noteKeyboardInteraction()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

/// A view that draws a list of rows itself (the ⌘K results, the ⌘N project list): VoiceOver gets
/// one element per row through ``DrawnRowElement`` (M5 D21). The keyboard moves through the rows
/// from the view's search field (↑ ↓ ⏎), so the rows are static texts with a press action, not key
/// views of their own.
@MainActor
protocol DrawnRowsHost: NSView {
    var drawnRowCount: Int { get }
    func drawnRowLabel(_ index: Int) -> String?
    /// The row's frame in the host's coordinates.
    func drawnRowFrame(_ index: Int) -> CGRect
    func isDrawnRowSelected(_ index: Int) -> Bool
    func pressDrawnRow(_ index: Int)
}

extension DrawnRowsHost {
    /// One element per row, rebuilt only when the count changed (labels and frames are read live).
    /// `.radioButton` for a row of choices (color swatches): selected = chosen.
    func drawnRowElements(reusing old: [DrawnRowElement], role: NSAccessibility.Role = .staticText) -> [DrawnRowElement] {
        guard old.count != drawnRowCount else { return old }
        return (0..<drawnRowCount).map { DrawnRowElement(host: self, index: $0, role: role) }
    }
}

/// One drawn row as VoiceOver sees it: the host's label, frame, selection and press. The host (a
/// main-actor view, Sendable) is read before the isolated closures, which never capture `self`.
final class DrawnRowElement: NSAccessibilityElement {
    private weak var host: (any DrawnRowsHost)?
    let index: Int

    private let isChoice: Bool

    @MainActor
    init(host: any DrawnRowsHost, index: Int, role: NSAccessibility.Role = .staticText) {
        self.host = host
        self.index = index
        isChoice = role == .radioButton
        super.init()
        setAccessibilityParent(host)
        setAccessibilityRole(role)
    }

    /// A choice reports 1 while chosen (radio-button semantics).
    override func accessibilityValue() -> Any? {
        guard isChoice else { return nil }
        return isAccessibilitySelected() ? 1 : 0
    }

    override func accessibilityLabel() -> String? {
        let host = host, index = index
        return MainActor.assumeIsolated { host?.drawnRowLabel(index) }
    }

    override func accessibilityFrame() -> NSRect {
        let host = host, index = index
        return MainActor.assumeIsolated {
            guard let host, let window = host.window else { return .zero }
            return window.convertToScreen(host.convert(host.drawnRowFrame(index), to: nil))
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let host = host, index = index
        return MainActor.assumeIsolated { host?.isDrawnRowSelected(index) ?? false }
    }

    override func accessibilityPerformPress() -> Bool {
        let host = host, index = index
        return MainActor.assumeIsolated {
            guard let host, index < host.drawnRowCount else { return false }
            host.pressDrawnRow(index)
            return true
        }
    }
}
