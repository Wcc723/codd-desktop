import AppKit
import ObjectiveC

/// The accessibility audit (M5 D21, plan §2.6): every interactive element of a screen has a label,
/// and the ones keyboard navigation cannot reach are listed.
///
/// It walks the accessibility tree (`accessibilityChildren()` from the window's content view), not
/// the view tree, so labels set on a parent and AppKit internals count as VoiceOver sees them.
/// Hidden, zero-sized and fully transparent views are skipped with their subtrees; sheets and child
/// windows are screens of their own (``auditIncludingAttachedWindows(_:screen:checkKeyLoop:)``).
/// It works on windows that were never ordered in (the App audits panels laid out offscreen).
@MainActor
public enum AccessibilityAudit {
    /// One element with a problem.
    public struct Finding: Sendable, Equatable, Codable {
        /// The element's place in the accessibility tree (`Window/ContentView/CardView/CoddButton[2]`):
        /// class names (a cell is named by its control), `[n]` among same-named siblings (1-based).
        public let path: String
        /// `AXButton`, `AXCheckBox`, …
        public let role: String
        public let label: String?
        /// In window coordinates (AppKit's, origin bottom left).
        public let frame: CGRect
        /// ``unlabeled`` or ``notInKeyLoop``.
        public let problem: String

        public static let unlabeled = "unlabeled"
        public static let notInKeyLoop = "notInKeyLoop"

        public init(path: String, role: String, label: String?, frame: CGRect, problem: String) {
            self.path = path
            self.role = role
            self.label = label
            self.frame = frame
            self.problem = problem
        }
    }

    /// The result for one screen.
    public struct Report: Sendable, Equatable, Codable {
        public let screen: String
        /// Interactive elements found.
        public let interactive: Int
        public let unlabeled: [Finding]
        /// Enabled interactive elements outside the key-view loop (empty without the loop check).
        public let outsideKeyLoop: [Finding]

        public init(screen: String, interactive: Int, unlabeled: [Finding], outsideKeyLoop: [Finding]) {
            self.screen = screen
            self.interactive = interactive
            self.unlabeled = unlabeled
            self.outsideKeyLoop = outsideKeyLoop
        }
    }

    /// The App's `-codd-a11y-audit <file>` document: `{"screens":[…],"unlabeled":n,"outsideKeyLoop":n}`.
    public struct Summary: Sendable, Equatable, Codable {
        public let screens: [Report]
        public let unlabeled: Int
        public let outsideKeyLoop: Int

        public init(screens: [Report]) {
            self.screens = screens
            unlabeled = screens.reduce(0) { $0 + $1.unlabeled.count }
            outsideKeyLoop = screens.reduce(0) { $0 + $1.outsideKeyLoop.count }
        }
    }

    /// Roles that need a label (and a place in the key loop). `AXCell` counts only when the element
    /// handles press; `AXRow` and pressable `AXCell` are also labelled by the text inside them and are
    /// in the key loop through their table.
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
        "AXComboBox", "AXSlider", "AXIncrementor", "AXLink", "AXDisclosureTriangle", "AXRow", "AXCell",
    ]

    /// Audits `window`'s content view. `checkKeyLoop` walks the key-view loop with Full Keyboard
    /// Access forced on (from `initialFirstResponder`, at most 2,000 steps) and lists the enabled
    /// interactive elements it does not reach.
    public static func audit(window: NSWindow, screen: String, checkKeyLoop: Bool = true) -> Report {
        guard let content = window.contentView else {
            return Report(screen: screen, interactive: 0, unlabeled: [], outsideKeyLoop: [])
        }
        content.layoutSubtreeIfNeeded()
        let entries = collect(root: content, rootPath: "Window/ContentView")
        let loop = checkKeyLoop ? keyLoopViews(of: window) : nil
        return report(screen: screen, entries: entries, keyLoop: loop)
    }

    /// Audits a view and its accessibility subtree (no key-loop check: that needs a window).
    public static func audit(view: NSView, screen: String) -> Report {
        view.layoutSubtreeIfNeeded()
        let entries = collect(root: view, rootPath: name(of: view))
        return report(screen: screen, entries: entries, keyLoop: nil)
    }

    /// `window` and, as separate screens, its sheet (`<screen> › sheet`) and child windows
    /// (`<screen> › child <n>`), recursively.
    public static func auditIncludingAttachedWindows(_ window: NSWindow, screen: String, checkKeyLoop: Bool = true) -> [Report] {
        var reports = [audit(window: window, screen: screen, checkKeyLoop: checkKeyLoop)]
        if let sheet = window.attachedSheet {
            reports += auditIncludingAttachedWindows(sheet, screen: "\(screen) › sheet", checkKeyLoop: checkKeyLoop)
        }
        for (index, child) in (window.childWindows ?? []).enumerated() where child !== window.attachedSheet {
            reports += auditIncludingAttachedWindows(child, screen: "\(screen) › child \(index + 1)", checkKeyLoop: checkKeyLoop)
        }
        return reports
    }

    // MARK: Walk

    /// One interactive element.
    private struct Entry {
        let path: String
        let role: String
        let label: String?
        let frame: CGRect
        /// The view that stands for it in the key loop: its own view, a cell's control, or the nearest
        /// view above a plain accessibility element.
        let keyView: NSView?
        let enabled: Bool
        /// Rows and cells: reachable when any view above them is in the loop (their table).
        let reachedThroughAncestor: Bool
    }

    private static let maximumElements = 50_000
    private static let maximumDepth = 256

    private static func collect(root: NSView, rootPath: String) -> [Entry] {
        var entries: [Entry] = []
        var visited = Set<ObjectIdentifier>()
        var budget = maximumElements

        func visit(_ object: Any, path: String, hostView: NSView?, depth: Int, isRoot: Bool) {
            guard budget > 0, depth < maximumDepth, let element = object as? NSAccessibilityProtocol else { return }
            let reference = object as AnyObject
            guard visited.insert(ObjectIdentifier(reference)).inserted else { return }
            budget -= 1
            let ownView = view(of: reference)
            if let ownView, isSkipped(ownView, root: root) { return }
            // The field editor belongs to the text field it edits, which carries the label.
            if let editor = ownView as? NSTextView, editor.isFieldEditor { return }
            let frame = ownView.map { $0.convert($0.bounds, to: nil) } ?? windowFrame(of: element, near: hostView)
            if ownView == nil, frame.width <= 0 || frame.height <= 0 { return }
            let keyView = ownView ?? hostView

            if !isRoot || element.isAccessibilityElement() {
                let (roleElement, role) = resolvedRole(element, view: ownView)
                if isInteractive(role: role, object: roleElement) {
                    let isRowLike = role == "AXRow" || role == "AXCell"
                    let label = label(of: element, roleElement: roleElement, view: ownView)
                        ?? (isRowLike ? descendantText(of: element) : nil)
                    entries.append(Entry(path: path, role: role, label: label, frame: frame, keyView: keyView,
                                         enabled: isEnabled(keyView), reachedThroughAncestor: isRowLike))
                }
            }

            // A scroller's arrows and page areas are AppKit's own elements (VoiceOver reads them by
            // their subrole); they carry no label CODD could set.
            if ownView is NSScroller { return }
            let children = element.accessibilityChildren() ?? []
            let names = children.map { name(of: $0 as AnyObject) }
            var totals: [String: Int] = [:]
            for name in names { totals[name, default: 0] += 1 }
            var seen: [String: Int] = [:]
            for (child, name) in zip(children, names) {
                seen[name, default: 0] += 1
                let segment = (totals[name] ?? 0) > 1 ? "\(name)[\(seen[name] ?? 1)]" : name
                visit(child, path: path + "/" + segment, hostView: keyView, depth: depth + 1, isRoot: false)
            }
        }

        visit(root, path: rootPath, hostView: root, depth: 0, isRoot: true)
        return entries
    }

    private static func report(screen: String, entries: [Entry], keyLoop: Set<ObjectIdentifier>?) -> Report {
        let unlabeled = entries.filter { $0.label == nil }.map {
            Finding(path: $0.path, role: $0.role, label: nil, frame: $0.frame, problem: Finding.unlabeled)
        }
        var outside: [Finding] = []
        if let keyLoop {
            for entry in entries where entry.enabled && !isReachable(entry, keyLoop: keyLoop) {
                outside.append(Finding(path: entry.path, role: entry.role, label: entry.label, frame: entry.frame,
                                       problem: Finding.notInKeyLoop))
            }
        }
        return Report(screen: screen, interactive: entries.count, unlabeled: unlabeled, outsideKeyLoop: outside)
    }

    private static func isReachable(_ entry: Entry, keyLoop: Set<ObjectIdentifier>) -> Bool {
        var view = entry.keyView
        while let current = view {
            if keyLoop.contains(ObjectIdentifier(current)) { return true }
            guard entry.reachedThroughAncestor else { return false }
            view = current.superview
        }
        return false
    }

    // MARK: Elements

    /// The view an element is: the view itself, or the control a cell belongs to.
    private static func view(of object: AnyObject) -> NSView? {
        if let view = object as? NSView { return view }
        if let cell = object as? NSCell { return cell.controlView }
        return nil
    }

    /// Hidden, zero-sized or transparent (itself or a view above it, up to `root`).
    private static func isSkipped(_ view: NSView, root: NSView) -> Bool {
        if view.isHiddenOrHasHiddenAncestor { return true }
        if view !== root, view.bounds.width <= 0 || view.bounds.height <= 0 { return true }
        var current: NSView? = view
        while let candidate = current {
            if candidate.alphaValue <= 0 { return true }
            if candidate === root { break }
            current = candidate.superview
        }
        return false
    }

    /// A plain accessibility element's frame (screen coordinates) in its window's coordinates.
    private static func windowFrame(of element: NSAccessibilityProtocol, near view: NSView?) -> CGRect {
        let frame = element.accessibilityFrame()
        guard let window = view?.window else { return frame }
        return window.convertFromScreen(frame)
    }

    /// The role, asking an NSControl's cell when the control itself reports none (AppKit puts the
    /// accessibility of cell-based controls such as NSButton on the cell).
    private static func resolvedRole(_ element: NSAccessibilityProtocol, view: NSView?) -> (AnyObject, String) {
        let role = element.accessibilityRole()?.rawValue ?? NSAccessibility.Role.unknown.rawValue
        if role == NSAccessibility.Role.unknown.rawValue, let control = view as? NSControl, let cell = control.cell,
           let cellRole = cell.accessibilityRole()?.rawValue {
            return (cell, cellRole)
        }
        return (element as AnyObject, role)
    }

    private static func isInteractive(role: String, object: AnyObject) -> Bool {
        guard interactiveRoles.contains(role) else { return false }
        return role == "AXCell" ? overridesPress(object) : true
    }

    /// Whether the element's class implements `accessibilityPerformPress` itself (not the default).
    private static func overridesPress(_ object: AnyObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let cls = object_getClass(object), class_respondsToSelector(cls, selector) else { return false }
        let base: AnyClass = object is NSView ? NSView.self : (object is NSAccessibilityElement ? NSAccessibilityElement.self : NSObject.self)
        guard class_respondsToSelector(base, selector) else { return true }
        return class_getMethodImplementation(cls, selector) != class_getMethodImplementation(base, selector)
    }

    /// The first non-empty (trimmed) label, title or placeholder of the element, its cell / control
    /// view and a text field.
    private static func label(of element: NSAccessibilityProtocol, roleElement: AnyObject, view: NSView?) -> String? {
        var candidates: [String?] = [view?.accessibilityLabel(), element.accessibilityLabel(), element.accessibilityTitle(),
                                     view?.accessibilityTitle()]
        if let cell = roleElement as? NSCell, cell !== (element as AnyObject) {
            candidates += [cell.accessibilityLabel(), cell.accessibilityTitle(), cell.accessibilityPlaceholderValue()]
        }
        candidates.append(element.accessibilityPlaceholderValue())
        if let field = view as? NSTextField {
            candidates += [field.placeholderString, field.placeholderAttributedString?.string,
                           (field.cell as? NSTextFieldCell)?.placeholderString]
        }
        return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// Text inside a row or cell (VoiceOver reads it for the row): the first label, title or string
    /// value below it.
    private static func descendantText(of element: NSAccessibilityProtocol, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        for child in element.accessibilityChildren() ?? [] {
            guard let child = child as? NSAccessibilityProtocol else { continue }
            let candidates = [child.accessibilityLabel(), child.accessibilityTitle(), child.accessibilityValue() as? String]
            if let text = candidates.lazy.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
                return text
            }
            if let text = descendantText(of: child, depth: depth + 1) { return text }
        }
        return nil
    }

    /// Whether the element's control is enabled (a cell's control, the control above a plain element).
    /// Not `isAccessibilityEnabled()`: NSView and NSAccessibilityElement report false by default.
    private static func isEnabled(_ view: NSView?) -> Bool {
        switch view {
        case let control as NSControl: control.isEnabled
        case let select as SelectButton: select.isEnabled
        case let radio as RadioRowView: radio.isEnabled
        default: true
        }
    }

    /// The path segment name: the class (a cell is named by its control).
    private static func name(of object: AnyObject) -> String {
        if let cell = object as? NSCell, let control = cell.controlView { return String(describing: type(of: control)) }
        return String(describing: type(of: object))
    }

    // MARK: Key loop

    /// The views the window's key-view loop reaches with Full Keyboard Access on. A window without
    /// a loop yet (never shown) gets AppKit's automatic one first, as showing it would.
    private static func keyLoopViews(of window: NSWindow) -> Set<ObjectIdentifier> {
        guard let content = window.contentView else { return [] }
        return KeyboardFocus.withFullKeyboardAccess {
            if window.autorecalculatesKeyViewLoop || !hasKeyViewLinks(content) { window.recalculateKeyViewLoop() }
            var members = Set<ObjectIdentifier>()
            var seen = Set<ObjectIdentifier>()
            var current: NSView? = window.initialFirstResponder ?? content
            var steps = 0
            while let view = current, steps < 2_000, seen.insert(ObjectIdentifier(view)).inserted {
                if isKeyLoopMember(view) { members.insert(ObjectIdentifier(view)) }
                current = view.nextKeyView
                steps += 1
            }
            return members
        }
    }

    /// `nextValidKeyView` would stop here with Full Keyboard Access on: the view can become a key view
    /// (CoddUI controls see the forced setting), or it is an enabled AppKit control that accepts first
    /// responder and only waits for the system setting (NSButton checks the real one).
    private static func isKeyLoopMember(_ view: NSView) -> Bool {
        if view.canBecomeKeyView { return true }
        guard let control = view as? NSControl, control.isEnabled, !control.refusesFirstResponder else { return false }
        return control.acceptsFirstResponder && !control.isHiddenOrHasHiddenAncestor
    }

    private static func hasKeyViewLinks(_ view: NSView) -> Bool {
        if view.nextKeyView != nil { return true }
        return view.subviews.contains { hasKeyViewLinks($0) }
    }
}
