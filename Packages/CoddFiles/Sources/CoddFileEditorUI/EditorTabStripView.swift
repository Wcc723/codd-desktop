import AppKit
import CoddUI

/// The editor's tab strip (`.tabs`, 30 pt, --bg-soft, a --line-bright rule below): `.fe-tab`s
/// (ext label or the note icon, the name, `●` when dirty / `✕`; the active tab on --bg with the
/// 2 pt amber top line; preview tabs italic and dim) and the `.tfill` on the right: the session
/// pill `● ▪ <title> <tool · 6m> ⌘9`, the split-editor icon (disabled in M4, tooltip
/// `分割編輯器（之後提供）`) and `⋯`.
public final class EditorTabStripView: FlippedView {
    public static var height: CGFloat { Metrics.tabStripHeight }

    public private(set) var model: EditorTabStripModel
    public var onSelect: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    /// A double click on a tab (pins a preview tab).
    public var onPin: ((String) -> Void)?
    public var onOpenSession: (() -> Void)?
    public var onMore: (() -> Void)?

    let tabsArea = TabsAreaView()
    let sessionPill = SessionPillButton()
    let splitButton = FileEditorIconButton(.icon(.splitEditor), side: 28, label: "分割編輯器")
    let moreButton = FileEditorIconButton(.glyph("⋯"), side: 28, label: "更多動作")

    public init(model: EditorTabStripModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: fz(800), height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        splitButton.isEnabled = false
        splitButton.toolTip = "分割編輯器（之後提供）"
        moreButton.toolTip = "更多動作"
        for view in [tabsArea, sessionPill, splitButton, moreButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        tabsArea.onSelect = { [weak self] id in self?.onSelect?(id) }
        tabsArea.onClose = { [weak self] id in self?.onClose?(id) }
        tabsArea.onPin = { [weak self] id in self?.onPin?(id) }
        sessionPill.onClick = { [weak self] in self?.onOpenSession?() }
        moreButton.onClick = { [weak self] in self?.onMore?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("已開啟的檔案")
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    public func update(_ model: EditorTabStripModel) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    private func apply() {
        tabsArea.model = model
        sessionPill.pill = model.session
        if model.session == nil { sessionPill.isHidden = true }
        needsLayout = true
        needsDisplay = true
    }

    /// A narrow strip (small window, zoom) keeps the tabs and `⋯`: the (disabled) split icon goes
    /// first, then the session pill shrinks to 120 pt and goes while the tabs need the room; tabs
    /// that still do not fit are cut at the strip's edge.
    public override func layout() {
        super.layout()
        let height = bounds.height - 1
        var right = bounds.width - fz(10)
        moreButton.frame = CGRect(x: right - fz(28), y: (height - fz(28)) / 2, width: fz(28), height: fz(28))
        right -= fz(28) + fz(10)
        let tabsNeed = tabsArea.naturalWidth
        let pillNatural = model.session == nil ? 0 : sessionPill.intrinsicContentSize.width + fz(10)
        let showsSplit = right - fz(28) - fz(10) - pillNatural >= tabsNeed
        if splitButton.isHidden == showsSplit { splitButton.isHidden = !showsSplit }
        if showsSplit {
            splitButton.frame = CGRect(x: right - fz(28), y: (height - fz(28)) / 2, width: fz(28), height: fz(28))
            right -= fz(28) + fz(10)
        }
        if model.session != nil {
            let minimum = min(sessionPill.intrinsicContentSize.width, fz(120))
            let width = min(sessionPill.intrinsicContentSize.width, max(minimum, right - fz(10) - tabsNeed))
            let shows = right - fz(10) - width >= min(tabsNeed, fz(160))
            if sessionPill.isHidden == shows { sessionPill.isHidden = !shows }
            if shows {
                sessionPill.frame = CGRect(x: right - width, y: (height - fz(24)) / 2, width: width, height: fz(24))
                right -= width + fz(10)
            }
        }
        tabsArea.frame = CGRect(x: 0, y: 0, width: max(0, right), height: height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Palette.lineBright)
    }
}

/// The tabs themselves, custom-drawn with their hit regions.
final class TabsAreaView: FlippedView, KeyboardFocusTracking {
    struct Placed {
        var tab: EditorTab
        var frame: CGRect
        var close: CGRect
    }

    var model: EditorTabStripModel? { didSet { relayout() } }
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onPin: ((String) -> Void)?
    private(set) var placed: [Placed] = []
    private var hoveredTab: Int?
    private var hoveredClose: Int?
    private var trackingArea: NSTrackingArea?
    static var maxNameWidth: CGFloat { fz(220) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Tabs past the area's edge are cut there, never drawn over the session pill.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The width every tab takes at its natural size.
    var naturalWidth: CGFloat { placed.last?.frame.maxX ?? 0 }

    static func nameStyle(_ color: NSColor) -> TextStyle { TextStyle(font: Typeface.mono(11.5), color: color, tracking: 0.02) }

    private func relayout() {
        guard let model else { placed = []; return }
        var x: CGFloat = 0
        placed = model.tabs.map { tab in
            var width: CGFloat = fz(12)
            if tab.isNote {
                width += fz(13) + fz(7)
            } else if let ext = tab.ext, !ext.isEmpty {
                width += Draw.width(Parts.extStyle.string(ext)) + fz(7)
            }
            width += min(Self.maxNameWidth, Draw.width(Self.nameStyle(Palette.dim).string(tab.title)))
            if tab.ai != nil { width += fz(6) + Parts.aiChipWidth() }
            width += fz(4) + fz(18) + fz(6) + 1
            let frame = CGRect(x: x, y: 0, width: ceil(width), height: bounds.height)
            x += frame.width
            let close = CGRect(x: frame.maxX - 1 - fz(6) - fz(18), y: (bounds.height - fz(18)) / 2, width: fz(18), height: fz(18))
            return Placed(tab: tab, frame: frame, close: close)
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.height != frame.height
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    func tabIndex(at point: CGPoint) -> Int? { placed.firstIndex { $0.frame.contains(point) } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil), count: event.clickCount)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click closes, like every editor.
        guard event.buttonNumber == 2, let index = tabIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onClose?(placed[index].tab.id)
    }

    /// A click at `point` (tests call this directly).
    func click(at point: CGPoint, count: Int) {
        guard let index = tabIndex(at: point) else { return }
        let id = placed[index].tab.id
        if placed[index].close.insetBy(dx: -fz(2), dy: -fz(4)).contains(point) {
            if count == 1 { onClose?(id) }
            return
        }
        if count >= 2 { onPin?(id) } else { onSelect?(id) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let tab = tabIndex(at: point)
        let close = tab.flatMap { placed[$0].close.insetBy(dx: -fz(2), dy: -fz(4)).contains(point) ? $0 : nil }
        guard tab != hoveredTab || close != hoveredClose else { return }
        hoveredTab = tab
        hoveredClose = close
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTab = nil
        hoveredClose = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        for (index, entry) in placed.enumerated() where entry.frame.intersects(dirtyRect) {
            let tab = entry.tab
            let on = tab.id == model.selectedID
            let hot = hoveredTab == index
            let frame = entry.frame
            if on {
                Draw.fill(frame, Palette.bg)
                Draw.fill(CGRect(x: frame.minX, y: 0, width: frame.width, height: fz(2)), Palette.amber)
            }
            Draw.fill(CGRect(x: frame.maxX - 1, y: 0, width: 1, height: frame.height), Palette.line)
            let centerY = frame.midY
            var x = frame.minX + fz(12)
            if tab.isNote {
                FileEditorIcon.note.draw(in: CGRect(x: x, y: centerY - fz(6.5), width: fz(13), height: fz(13)), color: on ? Palette.amber : Palette.dim)
                x += fz(13) + fz(7)
            } else if let ext = tab.ext, !ext.isEmpty {
                x += Parts.drawExt(ext, x: x, centerY: centerY, maxWidth: fz(40)) + fz(7)
            }
            let color: NSColor = tab.isPreview ? Palette.dim : (on ? Palette.amber : (hot ? Palette.cream : Palette.dim))
            var name = Self.nameStyle(color).string(tab.title)
            if tab.isPreview { name = Parts.italic(name) }
            x += Draw.text(name, x: x, centerY: centerY, maxWidth: Self.maxNameWidth)
            if let ai = tab.ai {
                x += fz(6)
                Parts.drawAIChip(x: x, centerY: centerY, color: ai.color)
            }
            let close = entry.close
            let closeHot = hoveredClose == index
            if closeHot { Draw.fill(close, Palette.bgRaise) }
            let glyph: NSAttributedString
            if tab.isDirty, !closeHot {
                glyph = TextStyle.mono(11, Palette.amber).string("●")
            } else {
                glyph = TextStyle.mono(10, closeHot ? Palette.amber : Palette.dimmer).string("✕")
            }
            Draw.text(glyph, x: close.midX - Draw.width(glyph) / 2, centerY: close.midY)
        }
    }

    // MARK: Keyboard (D21)

    private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

    /// A key view while Full Keyboard Access is on: ← → select the previous / next tab.
    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: !placed.isEmpty, refuses: false) }
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

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty, event.keyCode == 123 || event.keyCode == 124,
              let model else { return super.keyDown(with: event) }
        let index = placed.firstIndex { $0.tab.id == model.selectedID } ?? -1
        let next = index + (event.keyCode == 124 ? 1 : -1)
        focusTracker.noteKeyboardInteraction()
        if placed.indices.contains(next) { onSelect?(placed[next].tab.id) }
    }

    // MARK: Accessibility

    /// The area is no element of its own; each tab is (a tab button in the strip's tab group).
    override func isAccessibilityElement() -> Bool { false }

    private var tabElements: [EditorTabElement] = []

    override func accessibilityChildren() -> [Any]? {
        if tabElements.map(\.tabID) != placed.map(\.tab.id) {
            tabElements = placed.map { EditorTabElement(area: self, tabID: $0.tab.id) }
        }
        return tabElements
    }

    func tabLabel(_ id: String) -> String? {
        guard let tab = placed.first(where: { $0.tab.id == id })?.tab else { return nil }
        var parts = [tab.title]
        if tab.isNote { parts.append("筆記") }
        if tab.isPreview { parts.append("預覽") }
        if tab.isDirty { parts.append("未儲存") }
        if tab.ai != nil { parts.append("AI 改過") }
        return parts.joined(separator: "，")
    }

    func tabIsSelected(_ id: String) -> Bool { model?.selectedID == id }

    func tabFrame(_ id: String) -> CGRect {
        guard let frame = placed.first(where: { $0.tab.id == id })?.frame, let window else { return .zero }
        return window.convertToScreen(convert(frame, to: nil))
    }

    func selectTab(_ id: String) { onSelect?(id) }
    func closeTab(_ id: String) { onClose?(id) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }
}

/// One editor tab as VoiceOver sees it (D21): a tab button labeled with its title and state
/// (preview, unsaved, AI), selected when it is the open one; press selects it and the `關閉`
/// action closes it (the ✕ is a mouse target only). The area (a main-actor view, Sendable) is
/// read before the isolated closures, which never capture `self`.
final class EditorTabElement: NSAccessibilityElement {
    private weak var area: TabsAreaView?
    let tabID: String

    @MainActor
    init(area: TabsAreaView, tabID: String) {
        self.area = area
        self.tabID = tabID
        super.init()
        setAccessibilityParent(area)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
        let title = area.tabLabel(tabID)?.components(separatedBy: "，").first ?? tabID
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "關閉 \(title)") { [weak area] in
            MainActor.assumeIsolated { area?.closeTab(tabID) }
            return true
        }])
    }

    override func accessibilityLabel() -> String? {
        let area = area, id = tabID
        return MainActor.assumeIsolated { area?.tabLabel(id) }
    }

    override func accessibilityValue() -> Any? {
        let area = area, id = tabID
        let selected: Int? = MainActor.assumeIsolated { area.map { $0.tabIsSelected(id) ? 1 : 0 } }
        return selected
    }

    override func isAccessibilitySelected() -> Bool {
        let area = area, id = tabID
        return MainActor.assumeIsolated { area?.tabIsSelected(id) ?? false }
    }

    override func accessibilityFrame() -> NSRect {
        let area = area, id = tabID
        return MainActor.assumeIsolated { area?.tabFrame(id) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let area = area, id = tabID
        return MainActor.assumeIsolated {
            guard let area else { return false }
            area.selectTab(id)
            return true
        }
    }
}

/// `.pillbtn.fe-sess`: the session the open project belongs to; a click shows it.
final class SessionPillButton: NSControl, KeyboardFocusTracking {
    var pill: EditorSessionPill? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; updateAccessibility() } }
    var onClick: (() -> Void)?
    private var hot = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func titleStyle(_ color: NSColor) -> TextStyle { TextStyle(font: Typeface.mono(11), color: color, tracking: 0.02) }

    override var intrinsicContentSize: NSSize {
        guard let pill else { return .zero }
        var width: CGFloat = fz(8) + fz(12) + fz(6) + fz(8) + fz(6) + Draw.width(titleStyle(Palette.bone).string(pill.title))
        if let detail = pill.detail { width += fz(6) + Draw.width(titleStyle(Palette.dimmer).string(detail)) }
        if let shortcut = pill.shortcut { width += fz(6) + KbdView.style(.regular).size(for: shortcut).width }
        return NSSize(width: ceil(width + fz(8)), height: fz(24))
    }

    private func updateAccessibility() {
        guard let pill else { return }
        setAccessibilityLabel("前往 session \(pill.title)" + (pill.shortcut.map { "（\($0)）" } ?? ""))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hot = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hot = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    // MARK: Keyboard (D21): a key view under Full Keyboard Access, the focus style, space / ⏎ press.

    private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: !isHidden, refuses: false) }
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

    override func keyDown(with event: NSEvent) {
        if KeyFocus.isPressKey(event) {
            focusTracker.noteKeyboardInteraction()
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pill else { return }
        Draw.strokeRect(bounds, color: hot ? Palette.amberDim : Palette.lineBright)
        let centerY = bounds.midY
        var x: CGFloat = fz(8)
        x += Parts.drawLamp(pill.lamp, color: pill.lampColor, x: x, centerY: centerY) + fz(6)
        Parts.drawTag(pill.tag, x: x, centerY: centerY)
        x += fz(8) + fz(6)
        let limit = bounds.width - fz(8)
        x += Draw.text(titleStyle(hot ? Palette.amber : Palette.bone).string(pill.title), x: x, centerY: centerY, maxWidth: max(0, limit - x))
        // The detail and the shortcut only where they fit whole (a pill narrowed by the strip).
        let kbdWidth = pill.shortcut.map { KbdView.style(.regular).size(for: $0).width + fz(6) } ?? 0
        if let detail = pill.detail, x + fz(6) + fz(24) + kbdWidth < limit {
            x += fz(6) + Draw.text(titleStyle(Palette.dimmer).string(detail), x: x + fz(6), centerY: centerY,
                                   maxWidth: limit - x - fz(6) - kbdWidth)
        }
        if let shortcut = pill.shortcut, x + kbdWidth <= limit {
            KbdView.style(.regular).draw(shortcut, x: x + fz(6), centerY: centerY)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }
}
