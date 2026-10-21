import AppKit
import Synchronization

/// Interface zoom: Settings › 外觀 › UI 字級 and 顯示方式 › 放大 ⌘+ / 縮小 ⌘− / 實際大小 ⌘0.
///
/// Every CODD length is a design point at UI 字級 13 (the helmet's px). `scale` is
/// `uiFontSize / 13`: ``Typeface`` makes every font at `size × scale`, ``pt(_:)`` turns a design
/// length (row and bar heights, paddings and offsets tied to the type) into the current one, and
/// stored ``TextStyle``s and ``ChipStyle``s follow at their next use. At the default the scale is
/// exactly 1 and every value is used as given (nothing is rounded), so the app looks as before.
///
/// ``apply(fontSize:)`` changes the scale and refreshes every window in place (no relaunch, no
/// rebuilt hierarchy): ``refresh(_:)-(NSView)`` re-makes the fonts of labels, buttons and plain
/// text views, re-sets ``NSLayoutConstraint/zoomed(_:)`` constraints, re-measures table rows and
/// invalidates every view's size, layout and display; views with state of their own adopt
/// ``ZoomRefreshing``. Terminals are not part of it: they keep their own size (the app steps it
/// together with this one).
public enum UIZoom {
    /// The UI 字級 the design is drawn at.
    public static let defaultFontSize = 13
    /// Settings › 外觀 › UI 字級 and the ⌘+ / ⌘− steps.
    public static let fontSizeRange: ClosedRange<Int> = 10...20
    /// Posted on the main thread after the scale changed, before the windows are refreshed;
    /// `userInfo` has `old` and `new` (CGFloat scales).
    public static let didChangeNotification = Notification.Name("app.codd.CoddUI.UIZoomDidChange")

    /// Written on the main actor only; read from anywhere (lengths are computed off the main
    /// actor too, e.g. in measurements), hence the lock instead of main-actor isolation.
    private static let state = Mutex<CGFloat>(1)

    /// `uiFontSize / 13`; exactly 1 at the default.
    public static var scale: CGFloat { state.withLock { $0 } }

    /// The UI font size the current scale stands for.
    public static var fontSize: Int { Int((scale * CGFloat(defaultFontSize)).rounded()) }

    /// `size` inside ``fontSizeRange``.
    public static func clamped(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// The scale for a UI font size (clamped first).
    public static func scale(forFontSize size: Int) -> CGFloat {
        let clamped = clamped(size)
        return clamped == defaultFontSize ? 1 : CGFloat(clamped) / CGFloat(defaultFontSize)
    }

    /// A design length at the current zoom: `value` itself at the default, else `value × scale`
    /// rounded to whole points (edges stay on the pixel grid, 1 px rules stay 1 px).
    public static func pt(_ value: CGFloat) -> CGFloat { length(value, scale: scale) }

    /// ``pt(_:)`` at a given scale (tests, measurements for another zoom).
    public static func length(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        scale == 1 ? value : (value * scale).rounded()
    }

    /// `value × scale`, unrounded: drawn sizes that are not layout edges (a caret triangle, an
    /// icon's box, a CSS `line-height`).
    public static func scaled(_ value: CGFloat) -> CGFloat {
        let scale = scale
        return scale == 1 ? value : value * scale
    }

    /// `insets` in design points at the current zoom (each edge through ``pt(_:)``).
    public static func insets(_ insets: NSEdgeInsets) -> NSEdgeInsets {
        NSEdgeInsets(top: pt(insets.top), left: pt(insets.left), bottom: pt(insets.bottom), right: pt(insets.right))
    }

    /// Sets the zoom for UI font size `size` (clamped to ``fontSizeRange``). When it changed, posts
    /// ``didChangeNotification`` and refreshes every window. Returns whether it changed.
    @MainActor @discardableResult
    public static func apply(fontSize size: Int) -> Bool {
        let new = scale(forFontSize: size)
        let old = state.withLock { value -> CGFloat in
            let old = value
            value = new
            return old
        }
        guard old != new else { return false }
        NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: ["old": old, "new": new])
        refreshAllWindows()
        return true
    }

    /// Runs `body` with the scale set to `scale` (fonts and lengths made inside use it) and
    /// restores it, without a refresh or a notification: design-size styles for a view that
    /// scales them itself (``unzoomed(_:)``), and tests.
    @MainActor
    public static func withScale<T>(_ scale: CGFloat, _ body: () throws -> T) rethrows -> T {
        let old = state.withLock { value -> CGFloat in
            let old = value
            value = scale
            return old
        }
        defer { state.withLock { $0 = old } }
        return try body()
    }

    /// `body` at the design size (scale 1).
    @MainActor
    public static func unzoomed<T>(_ body: () throws -> T) rethrows -> T { try withScale(1, body) }

    // MARK: Refresh

    /// Refreshes every window of the app (``refresh(_:)-(NSWindow)``), then every tracked view
    /// that is out of a window right now (``track(_:)``).
    @MainActor
    public static func refreshAllWindows() {
        for window in NSApp.windows { refresh(window) }
        for view in tracked.allObjects where view.window == nil { refresh(view) }
    }

    /// Views that leave the window and come back (a background tab's editor, a mode's page that
    /// is swapped out): a zoom change while they are out refreshes them too. Held weakly.
    @MainActor private static let tracked = NSHashTable<NSView>.weakObjects()

    /// Keeps `view` in the refresh while it is out of every window (see ``refreshAllWindows()``).
    @MainActor
    public static func track(_ view: NSView) { tracked.add(view) }

    /// Refreshes the window's content view tree.
    @MainActor
    public static func refresh(_ window: NSWindow) {
        guard let root = window.contentView else { return }
        refresh(root)
    }

    /// Refreshes `view` and everything under it: ``ZoomRefreshing`` views first get their
    /// ``ZoomRefreshing/zoomDidChange()``; labels, buttons and text views get their fonts made
    /// again (``Typeface/rescaled(_:)``); ``NSLayoutConstraint/zoomed(_:)`` constraints get their
    /// constant again; tables re-measure their rows; then size, constraints, layout and display
    /// are invalidated.
    @MainActor
    public static func refresh(_ view: NSView) {
        refresh(view, rescalesTextViews: true)
    }

    @MainActor
    private static func refresh(_ view: NSView, rescalesTextViews: Bool) {
        var textViews = rescalesTextViews
        if let zoomable = view as? ZoomRefreshing {
            zoomable.zoomDidChange()
            if !zoomable.zoomRescalesTextViews { textViews = false }
        }
        ZoomText.rescale(view, textViews: textViews)
        for constraint in view.constraints { ZoomConstraint.update(constraint) }
        if let table = view as? NSTableView, table.numberOfRows > 0 {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
        view.invalidateIntrinsicContentSize()
        view.needsUpdateConstraints = true
        view.needsLayout = true
        view.needsDisplay = true
        for subview in view.subviews { refresh(subview, rescalesTextViews: textViews) }
    }
}

/// A view with zoom-dependent state of its own: stored fonts or frames from design points, a text
/// view's styling, a cached measurement. ``UIZoom/refresh(_:)-(NSView)`` calls
/// ``zoomDidChange()`` before it invalidates the view and walks on into its subviews.
@MainActor
public protocol ZoomRefreshing: AnyObject {
    /// The interface zoom changed (``UIZoom/scale``): restyle and re-measure what was made at the
    /// old one.
    func zoomDidChange()
    /// false: text views under this view style their own text (an editor with its own styler);
    /// the refresh leaves their text storage alone. Labels and buttons are still refreshed.
    var zoomRescalesTextViews: Bool { get }
}

extension ZoomRefreshing {
    public var zoomRescalesTextViews: Bool { true }
}

@MainActor
extension NSLayoutConstraint {
    /// Keeps the constant at `designValue` design points (``UIZoom/pt(_:)``) now and after every
    /// zoom change (the refresh sets it again). Only for constraints whose constant never changes
    /// otherwise: code that later sets `constant` itself must do its own zoom handling. Uses the
    /// constraint's `identifier`.
    @discardableResult
    public func zoomed(_ designValue: CGFloat) -> NSLayoutConstraint {
        identifier = ZoomConstraint.prefix + String(Double(designValue))
        constant = UIZoom.pt(designValue)
        return self
    }

    /// The design value given to ``zoomed(_:)`` (nil for any other constraint).
    public var zoomDesignValue: CGFloat? { ZoomConstraint.designValue(self) }
}

@MainActor
enum ZoomConstraint {
    static let prefix = "codd.zoom:"

    static func designValue(_ constraint: NSLayoutConstraint) -> CGFloat? {
        guard let identifier = constraint.identifier, identifier.hasPrefix(prefix),
              let value = Double(identifier.dropFirst(prefix.count)) else { return nil }
        return CGFloat(value)
    }

    static func update(_ constraint: NSLayoutConstraint) {
        guard let design = designValue(constraint) else { return }
        let value = UIZoom.pt(design)
        if constraint.constant != value { constraint.constant = value }
    }
}

/// Fonts in AppKit's own text holders (labels, buttons, text views) made again at the current zoom.
@MainActor
enum ZoomText {
    static func rescale(_ view: NSView, textViews: Bool) {
        if let field = view as? NSTextField {
            rescale(field)
        } else if let button = view as? NSButton, !(button is CoddButton) {
            if let title = Typeface.rescaled(button.attributedTitle) { button.attributedTitle = title }
            if let font = button.font { button.font = Typeface.current(font) }
        } else if textViews, let text = view as? NSTextView {
            rescale(text)
        }
    }

    private static func rescale(_ field: NSTextField) {
        if let font = field.font {
            let now = Typeface.current(font)
            if now !== font { field.font = now }
        }
        if let placeholder = field.placeholderAttributedString, let scaled = Typeface.rescaled(placeholder) {
            field.placeholderAttributedString = scaled
        }
        // A field being edited keeps its text in the field editor; it is rescaled next time.
        guard field.currentEditor() == nil else { return }
        if let value = Typeface.rescaled(field.attributedStringValue) { field.attributedStringValue = value }
    }

    private static func rescale(_ text: NSTextView) {
        guard !text.isFieldEditor, !text.hasMarkedText(), let storage = text.textStorage else { return }
        if let typing = text.typingAttributes[.font] as? NSFont {
            let now = Typeface.current(typing)
            if now !== typing {
                var attributes = text.typingAttributes
                attributes[.font] = now
                text.typingAttributes = attributes
            }
        }
        guard storage.length > 0, let scaled = Typeface.rescaled(storage) else { return }
        let selection = text.selectedRanges
        storage.beginEditing()
        scaled.enumerateAttributes(in: NSRange(location: 0, length: scaled.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        text.selectedRanges = selection
    }
}
