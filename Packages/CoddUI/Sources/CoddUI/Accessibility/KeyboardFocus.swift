import AppKit

/// Keyboard focus for CODD's custom controls (M5 D21, plan §2.6).
///
/// The controls take focus like AppKit buttons: only while Full Keyboard Access is on (System
/// Settings › 鍵盤 › 鍵盤導覽); text inputs always. They draw the helmet focus style (`.input:focus`:
/// amber border, a 1 px amber inset and `0 0 8px var(--amber-glow)`, square) only while keyboard
/// navigation put them in focus in the key window, like CSS `:focus-visible`: a click that happens
/// to focus a control draws nothing, so nothing changes for mouse users.
@MainActor
public enum KeyboardFocus {
    /// Posted on the main thread when Full Keyboard Access or one of the overrides changed. Focus
    /// trackers redraw on it.
    nonisolated public static let didChangeNotification = Notification.Name("app.codd.CoddUI.KeyboardFocusDidChange")

    /// Tests and DEBUG runs: forces Full Keyboard Access on or off; nil follows the system setting.
    /// Setting it re-evaluates every window (``refresh()``).
    public static var fullKeyboardAccessOverride: Bool? {
        get { storedOverride }
        set {
            storedOverride = newValue
            refresh(force: true)
        }
    }

    /// `fullKeyboardAccessOverride ?? NSApp.isFullKeyboardAccessEnabled`.
    public static var isFullKeyboardAccessOn: Bool {
        storedOverride ?? (NSApp?.isFullKeyboardAccessEnabled ?? false)
    }

    /// Tests and offscreen snapshots: true draws focus as if every window were key (a window that is
    /// never ordered in never becomes key); nil reads `NSWindow.isKeyWindow`.
    public static var keyWindowOverride: Bool? {
        didSet { if keyWindowOverride != oldValue { post() } }
    }

    /// Whether `window` counts as the key window for focus drawing.
    public static func isKey(_ window: NSWindow) -> Bool { keyWindowOverride ?? window.isKeyWindow }

    // MARK: Eligibility

    /// `acceptsFirstResponder` of a custom control: enabled, not refused, and Full Keyboard Access on
    /// (`textInput` controls take focus without it, like AppKit text fields).
    public static func acceptsFocus(enabled: Bool, refuses: Bool, textInput: Bool = false) -> Bool {
        enabled && !refuses && (textInput || isFullKeyboardAccessOn)
    }

    /// Re-evaluates focus after Full Keyboard Access may have changed: a focused control that no
    /// longer accepts focus hands it back to its window, and trackers redraw. Posts
    /// ``didChangeNotification`` only when the effective value changed. Key-view eligibility itself
    /// is computed on every `nextValidKeyView`, so the loops need no rebuild.
    public static func refresh() { refresh(force: false) }

    private static func refresh(force: Bool) {
        let on = isFullKeyboardAccessOn
        if !on {
            for window in NSApp?.windows ?? [] {
                guard let view = window.firstResponder as? any KeyboardFocusTracking, !view.acceptsFirstResponder else { continue }
                window.makeFirstResponder(nil)
            }
        }
        guard force || on != lastEffective else { return }
        lastEffective = on
        post()
    }

    /// Follows the system setting from now on (idempotent): app activation and AppKit's
    /// `com.apple.KeyboardUIModeDidChange` both run ``refresh()``. Trackers call it when their
    /// control first moves into a window; the App may call it at launch.
    public static func observeSystemSetting() {
        guard observers.isEmpty else { return }
        lastEffective = isFullKeyboardAccessOn
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        })
        // AppKit updates `isFullKeyboardAccessEnabled` from the same notification: read it a turn later.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.KeyboardUIModeDidChange"),
                                                                             object: nil, queue: .main) { _ in
            Task { @MainActor in refresh() }
        })
    }

    // MARK: Focus origin

    /// What made a control the first responder.
    public enum Origin: Sendable, Equatable {
        /// Tab, ⇧Tab or another key (draws the focus style).
        case keyboard
        /// A click inside the control (draws nothing, `:focus-visible`).
        case mouse
        /// Code (`makeFirstResponder`, a window's initial first responder): draws the style, since a
        /// non-text control only takes focus while Full Keyboard Access is on.
        case program
    }

    /// Tests: the origin of the next first-responder changes; nil reads `NSApp.currentEvent`.
    public static var focusOriginOverride: Origin?

    /// The origin of a focus change to `view` that happens while `event` is handled: key events are
    /// keyboard focus; a mouse event in the view's window inside the view is mouse focus; anything
    /// else (no event, a click elsewhere that focuses the view from code) counts as code.
    public static func origin(of event: NSEvent?, for view: NSView) -> Origin {
        guard let event else { return .program }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            return .keyboard
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let window = view.window, event.windowNumber == window.windowNumber else { return .program }
            let point = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(point) ? .mouse : .program
        default:
            return .program
        }
    }

    /// ``focusOriginOverride`` or the origin of the event being handled.
    public static func currentOrigin(for view: NSView) -> Origin {
        focusOriginOverride ?? origin(of: NSApp?.currentEvent, for: view)
    }

    /// Makes `view` its window's first responder the way Tab would (tests, snapshots, DEBUG). A
    /// non-text control needs Full Keyboard Access (or the override) to accept.
    @discardableResult
    public static func focusAsKeyboardNavigation(_ view: NSView) -> Bool {
        let saved = focusOriginOverride
        focusOriginOverride = .keyboard
        defer { focusOriginOverride = saved }
        return view.window?.makeFirstResponder(view) ?? false
    }

    // MARK: Keys

    /// The keys the custom controls handle themselves.
    public enum Key: Sendable, Equatable {
        case space, `return`, left, right, up, down
    }

    /// `event`'s key when it is one of ``Key`` without ⌘ ⌃ ⌥ (⇧ is allowed); nil otherwise, so
    /// shortcuts keep reaching the menus and the window.
    public static func key(of event: NSEvent) -> Key? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .shift])
        guard modifiers.isEmpty else { return nil }
        switch event.specialKey {
        case .leftArrow?: return .left
        case .rightArrow?: return .right
        case .upArrow?: return .up
        case .downArrow?: return .down
        case .carriageReturn?, .enter?, .newline?: return .return
        default: break
        }
        switch event.keyCode {
        case 0x31: return .space
        case 0x24, 0x4C: return .return
        case 0x7B: return .left
        case 0x7C: return .right
        case 0x7E: return .up
        case 0x7D: return .down
        default: return event.charactersIgnoringModifiers == " " ? .space : nil
        }
    }

    // MARK: Drawing

    /// helmet `.input:focus` inside `rect`: the 1 px amber border plus `inset 0 0 0 1px` amber (two
    /// amber pixels, radius 0). The glow is ``ringGlow``, a layer shadow outside the bounds.
    public static func drawRing(in rect: CGRect) {
        Draw.strokeRect(rect, color: Palette.amber)
        Draw.strokeRect(rect.insetBy(dx: 1, dy: 1), color: Palette.amber)
    }

    /// `0 0 8px var(--amber-glow)` as a view shadow (the render server blurs it).
    public static var ringGlow: NSShadow { Draw.glow(Palette.amberGlow, radius: 8) }

    // MARK: Private

    private static var storedOverride: Bool?
    private static var lastEffective: Bool?
    private static var observers: [any NSObjectProtocol] = []

    private static func post() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Runs `body` with Full Keyboard Access forced on, without notifying or moving any focus (the
    /// audit's key-loop walk).
    static func withFullKeyboardAccess<T>(_ body: () -> T) -> T {
        let saved = storedOverride
        storedOverride = true
        defer { storedOverride = saved }
        return body()
    }
}

/// A view with a ``KeyboardFocusTracker``: ``KeyboardFocus/refresh()`` moves the focus off such a
/// view when it stops accepting it. App views can adopt it too.
@MainActor
public protocol KeyboardFocusTracking: NSView {
    var focusTracker: KeyboardFocusTracker { get }
}

/// A view that can be kept out of keyboard focus without being disabled (FormRowView's disabled
/// rows, which must not dim their controls twice). NSControl has the property already.
@MainActor
public protocol KeyboardFocusRefusing: AnyObject {
    var refusesFirstResponder: Bool { get set }
}

extension NSControl: KeyboardFocusRefusing {}

/// The focus bookkeeping of one custom control: whether keyboard navigation (not a click) made it
/// the first responder, and whether its window is key. The control forwards
/// `becomeFirstResponder` / `resignFirstResponder` / `viewDidMoveToWindow` and draws the focus
/// style while ``showsFocusRing``; the tracker redraws the control (and calls ``onChange``, e.g.
/// for the glow) whenever that value changes: on focus changes, key-window changes and
/// ``KeyboardFocus/didChangeNotification``. Nothing here touches layout.
@MainActor
public final class KeyboardFocusTracker: NSObject {
    public private(set) weak var view: NSView?
    /// The control is its window's first responder (between become and resign).
    public private(set) var isFirstResponder = false
    /// Keyboard navigation, code, or a key the control handled put the focus there (not a click).
    public private(set) var isKeyboardFocus = false
    /// Called after ``showsFocusRing`` changed (the view is already marked for display).
    public var onChange: (() -> Void)?

    private weak var observedWindow: NSWindow?
    private var lastShown = false

    public init(view: NSView) {
        self.view = view
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(stateMayHaveChanged(_:)),
                                               name: KeyboardFocus.didChangeNotification, object: nil)
    }

    /// Draw the focus style now: first responder by keyboard, in a key window.
    public var showsFocusRing: Bool {
        guard isFirstResponder, isKeyboardFocus, let window = view?.window else { return false }
        return KeyboardFocus.isKey(window)
    }

    /// From the control's `becomeFirstResponder` once super accepted.
    public func becameFirstResponder() {
        isFirstResponder = true
        isKeyboardFocus = view.map { KeyboardFocus.currentOrigin(for: $0) != .mouse } ?? false
        update()
    }

    /// From the control's `resignFirstResponder` once super accepted.
    public func resignedFirstResponder() {
        isFirstResponder = false
        isKeyboardFocus = false
        update()
    }

    /// The control handled a key while focused: from now on the focus is the keyboard's
    /// (`:focus-visible` after a click followed by Space).
    public func noteKeyboardInteraction() {
        guard isFirstResponder, !isKeyboardFocus else { return }
        isKeyboardFocus = true
        update()
    }

    /// From the control's `viewDidMoveToWindow`: follows the new window's key state.
    public func viewDidMoveToWindow() {
        let window = view?.window
        if observedWindow !== window {
            let center = NotificationCenter.default
            if let observedWindow {
                center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
                center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            }
            observedWindow = window
            if let window {
                center.addObserver(self, selector: #selector(stateMayHaveChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
                center.addObserver(self, selector: #selector(stateMayHaveChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
            }
            // A view that leaves its window (or moves to another) is no longer its first responder.
            isFirstResponder = window != nil && window?.firstResponder === view
            if !isFirstResponder { isKeyboardFocus = false }
        }
        if window != nil { KeyboardFocus.observeSystemSetting() }
        update()
    }

    @objc private func stateMayHaveChanged(_ notification: Notification) { update() }

    private func update() {
        let shown = showsFocusRing
        guard shown != lastShown else { return }
        lastShown = shown
        view?.needsDisplay = true
        onChange?()
    }
}
