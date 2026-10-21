import AppKit
import CoddUI

/// The pane's terminal area: the tab strip's terminal on top, the ⌘L composer bar under it while
/// open and, while ⌘J is on, a splitter and the bottom panel (its own tab strip and terminal)
/// under that (SPEC §7.2, Split artboard). A maximized panel (D11) fills the whole area: the top
/// terminal (occluded, still hot), the composer and the splitter are hidden.
///
/// Frames are set by hand. A closed panel keeps its last frame (only hidden), and so does the top
/// terminal while the panel is maximized, so the hot terminals inside never shrink to nothing and
/// never send a bogus size to their PTYs.
final class TerminalAreaView: FlippedView {
    let top: TerminalHostView
    let panel: BottomPanelView
    let splitter = PanelSplitterView()
    /// The ⌘L composer bar (nil until `install(composer:)`).
    private(set) var composer: ComposerBarView?
    /// Height chosen by dragging the splitter (on mouse-up).
    var onPanelHeightChange: ((CGFloat) -> Void)?

    private(set) var isPanelOpen = false
    /// The open panel fills the area (D11).
    private(set) var isPanelMaximized = false
    private var panelHeight = CGFloat(PaneLayout.defaultPanelHeight)
    private var dragStartHeight: CGFloat = 0
    /// The session's composer is open (`PaneLayout.composerOpen`).
    private(set) var isComposerOpen = false
    /// Hides the composer without changing what the session saved (the maximized panel sets it).
    var isComposerSuppressed = false {
        didSet { if isComposerSuppressed != oldValue { applyComposerVisibility() } }
    }
    /// The composer takes room under the top terminal.
    var isComposerShown: Bool { composer != nil && isComposerOpen && !isComposerSuppressed }

    static let minimumTopHeight: CGFloat = 120
    static let minimumPanelHeight: CGFloat = 96

    init(top: TerminalHostView, panelHost: TerminalHostView) {
        self.top = top
        panel = BottomPanelView(host: panelHost)
        super.init(frame: .zero)
        for view in [top, splitter, panel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        splitter.isHidden = true
        panel.isHidden = true
        splitter.onDrag = { [weak self] delta in self?.drag(by: delta) }
        splitter.onDragBegan = { [weak self] in self.map { $0.dragStartHeight = $0.panelHeight } }
        splitter.onDragEnded = { [weak self] in self.map { $0.onPanelHeightChange?($0.panelHeight) } }
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(composer bar: ComposerBarView) {
        guard composer == nil else { return }
        composer = bar
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.isHidden = true
        addSubview(bar)
        bar.onHeightChange = { [weak self] _ in
            guard let self, self.isComposerShown else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    /// Shows or hides the composer bar (laid out at once, so the terminal resizes in the same turn).
    func setComposer(open: Bool) {
        guard open != isComposerOpen else { return }
        isComposerOpen = open
        applyComposerVisibility()
    }

    private func applyComposerVisibility() {
        composer?.isHidden = !isComposerShown
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private var composerHeight: CGFloat { isComposerShown ? (composer?.preferredHeight ?? 0) : 0 }

    func setPanel(open: Bool, height: CGFloat, maximized: Bool = false) {
        let maximized = open && maximized
        let changed = open != isPanelOpen || maximized != isPanelMaximized || (open && abs(height - panelHeight) >= 1)
        let maximizing = maximized && !isPanelMaximized
        isPanelOpen = open
        if open { panelHeight = height }
        if maximizing {
            // A hidden view's subtree is not laid out: lay the split out once more first, so the top
            // terminal keeps the size it will have on restore (not whatever it had before the split).
            isPanelMaximized = false
            layoutChildren()
            top.layoutSubtreeIfNeeded()
        }
        isPanelMaximized = maximized
        splitter.isHidden = !open || maximized
        panel.isHidden = !open
        top.isHidden = maximized
        // Occluded while hidden; it keeps streaming as a hot terminal and shows again on restore.
        top.isSuppressed = maximized
        isComposerSuppressed = maximized
        if changed {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    // A frame change does not mark a hand-laid-out view as needing layout: lay out on both.
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }

    override func layout() {
        super.layout()
        layoutChildren()
    }

    private func layoutChildren() {
        let b = bounds
        if isPanelMaximized {
            panel.frame = b
            return
        }
        let composerHeight = self.composerHeight
        guard isPanelOpen else {
            top.frame = CGRect(x: 0, y: 0, width: b.width, height: max(0, b.height - composerHeight))
            if isComposerShown { composer?.frame = CGRect(x: 0, y: top.frame.maxY, width: b.width, height: composerHeight) }
            return
        }
        let height = clampedPanelHeight(panelHeight)
        let splitterHeight = PanelSplitterView.thickness
        top.frame = CGRect(x: 0, y: 0, width: b.width, height: max(0, b.height - height - splitterHeight - composerHeight))
        if isComposerShown { composer?.frame = CGRect(x: 0, y: top.frame.maxY, width: b.width, height: composerHeight) }
        splitter.frame = CGRect(x: 0, y: top.frame.maxY + composerHeight, width: b.width, height: splitterHeight)
        panel.frame = CGRect(x: 0, y: splitter.frame.maxY, width: b.width, height: height)
    }

    private func clampedPanelHeight(_ height: CGFloat) -> CGFloat {
        let maximum = bounds.height - PanelSplitterView.thickness - Self.minimumTopHeight - composerHeight
        return max(Self.minimumPanelHeight, min(height, max(Self.minimumPanelHeight, maximum)))
    }

    private func drag(by delta: CGFloat) {
        guard !isPanelMaximized else { return }
        // Dragging down (positive y in this flipped view) makes the panel smaller.
        let height = clampedPanelHeight(dragStartHeight - delta)
        guard height != panelHeight else { return }
        panelHeight = height
        layoutChildren()
    }
}

/// The ⌘J panel: its tab strip (`$ ZSH 1_` · `$ NPM RUN DEV ●` · `+` … cwd `⤢` `✕ ⌘J`) above its
/// terminal host.
final class BottomPanelView: FlippedView {
    let strip = PanelStripView()
    let host: TerminalHostView

    init(host: TerminalHostView) {
        self.host = host
        super.init(frame: .zero)
        for view in [strip, host] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }

    override func layout() {
        super.layout()
        layoutChildren()
    }

    private func layoutChildren() {
        let stripHeight = Metrics.tabStripHeight
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        host.frame = CGRect(x: 0, y: stripHeight, width: bounds.width, height: max(0, bounds.height - stripHeight))
    }
}

/// The bottom panel's own `.tabs` strip (Split artboard `.sp-bottom`): its shell tabs (`$` + the
/// OSC title or `zsh n`, the green `●` lamp while a job runs, the amber `◆` after a bell, and the
/// `✕` that closes the tab while it is hovered or shown), `+` (`新增終端機`), then the `.tfill`:
/// the shown tab's folder, the maximize icon button and `✕ ⌘J`. A tab's context menu has
/// `新增終端機` and `關閉終端機`.
///
/// Tab buttons are rebuilt only when the set of tabs changes; labels, selection and marks are
/// updated in place (a click in progress survives re-renders, titles can change every second).
final class PanelStripView: PanelView {
    struct Tab: Equatable {
        var id: String
        var label: String
        var marks: [CoddButton.TabMark] = []
    }

    /// A tab was clicked (its id).
    var onSelect: ((String) -> Void)?
    /// `+`.
    var onAdd: (() -> Void)?
    /// A tab's `✕` or its menu's `關閉終端機` (its id): the pane ends that tab's shell.
    var onCloseTab: ((String) -> Void)?
    /// The maximize / restore icon button.
    var onToggleMaximize: (() -> Void)?
    /// `✕ ⌘J` (same as ⌘J: hides the panel, its shells keep running).
    var onClose: (() -> Void)?

    let addTab = CoddButton("+", style: .tab(lamp: "", lampColor: Palette.dim))
    let maximizeButton = CoddButton(PanelStripView.maximizeLabel, style: .icon(.maximize, size: 24))
    let closeButton = CoddButton("✕ ⌘J", style: .smallPill)
    private let tabStack = hStack([], spacing: 0)
    private let cwdLabel = Label.make("", style: TextStyle.mono(10.5, Palette.dimmer))
    private var shownTabs: [Tab] = []
    private(set) var isMaximized = false

    static let maximizeLabel = "最大化下方終端機"
    static let restoreLabel = "還原下方終端機"
    static let addTabTitle = "新增終端機"
    static let closeTabTitle = "關閉終端機"

    /// The tabs in strip order (tests).
    var tabItems: [PanelTabItemView] { tabStack.arrangedSubviews.compactMap { $0 as? PanelTabItemView } }
    /// The tab buttons in strip order (tests).
    var tabButtons: [CoddButton] { tabItems.map(\.tab) }
    /// Each tab's `✕`, in strip order (tests).
    var closeButtons: [CoddButton] { tabItems.map(\.close) }
    /// The folder shown in the fill (tests, dumps).
    var cwdText: String { cwdLabel.stringValue }

    init() {
        super.init(fill: Palette.bgSoft, edges: [.bottom], edgeColor: Palette.lineBright)
        addTab.setAccessibilityLabel(Self.addTabTitle)
        addTab.toolTip = "\(Self.addTabTitle) ⌘T"
        addTab.target = self
        addTab.action = #selector(addPressed)
        maximizeButton.target = self
        maximizeButton.action = #selector(maximizePressed)
        closeButton.setAccessibilityLabel("關閉下方終端機 ⌘J")
        closeButton.toolTip = "關閉下方終端機 ⌘J"
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        setMaximized(false)
        let fill = hStack([spacer(), cwdLabel, maximizeButton, closeButton], spacing: 10,
                          edgeInsets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10))
        fill.alignment = .centerY
        tabStack.alignment = .height
        let stack = hStack([tabStack, addTab, fill], spacing: 0)
        stack.alignment = .height
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))
    }

    func update(tabs: [Tab], selected: String?, cwd: String, maximized: Bool) {
        if tabs.map(\.id) != shownTabs.map(\.id) {
            tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, tab) in tabs.enumerated() {
                let button = CoddButton(tab.label, style: .tab(lamp: "$", lampColor: Palette.dim), target: self,
                                        action: #selector(tabPressed(_:)))
                button.tag = index
                button.setAccessibilityRole(.radioButton)
                let close = CoddButton("✕", style: .glyph(size: 18), target: self, action: #selector(closeTabPressed(_:)))
                close.tag = index
                close.toolTip = Self.closeTabTitle
                button.menu = tabMenu(tab.id)
                tabStack.addArrangedSubview(PanelTabItemView(tab: button, close: close))
            }
        }
        shownTabs = tabs
        for (item, tab) in zip(tabItems, tabs) {
            let button = item.tab
            let on = tab.id == selected
            let resized = button.label != tab.label || button.tabMarks != tab.marks
            button.label = tab.label
            button.isOn = on
            button.setAccessibilityValue(on)
            // `$` takes the tab's own color (Split artboard: a plain span in the `.tab`).
            let style = CoddButton.Style.tab(lamp: "$", lampColor: on ? Palette.amber : Palette.dim)
            if !TabStripView.sameTabStyle(button.style, style) { button.style = style }
            button.tabMarks = tab.marks
            let accessibility = tabAccessibilityLabel(tab.label, marks: tab.marks)
            if button.accessibilityLabel() != accessibility { button.setAccessibilityLabel(accessibility) }
            let closeLabel = "\(Self.closeTabTitle)「\(tab.label)」"
            if item.close.accessibilityLabel() != closeLabel { item.close.setAccessibilityLabel(closeLabel) }
            item.isSelected = on
            if resized { item.invalidateIntrinsicContentSize() }
        }
        Label.set(cwdLabel, cwd, style: TextStyle.mono(10.5, Palette.dimmer))
        if cwdLabel.toolTip != cwd { cwdLabel.toolTip = cwd }
        setMaximized(maximized)
    }

    private func setMaximized(_ maximized: Bool) {
        let label = maximized ? Self.restoreLabel : Self.maximizeLabel
        if maximized != isMaximized || maximizeButton.accessibilityLabel() != label {
            isMaximized = maximized
            maximizeButton.style = .icon(maximized ? .restore : .maximize, size: 24)
            maximizeButton.label = label
            maximizeButton.setAccessibilityLabel(label)
            maximizeButton.toolTip = label
        }
    }

    @objc private func tabPressed(_ sender: CoddButton) {
        guard shownTabs.indices.contains(sender.tag) else { return }
        onSelect?(shownTabs[sender.tag].id)
    }

    @objc private func closeTabPressed(_ sender: CoddButton) {
        guard shownTabs.indices.contains(sender.tag) else { return }
        onCloseTab?(shownTabs[sender.tag].id)
    }

    /// A tab's context menu (right click or ⌃ click): `新增終端機`, then `關閉終端機` for that tab.
    private func tabMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: Self.addTabTitle) { [weak self] in self?.onAdd?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Self.closeTabTitle) { [weak self] in self?.onCloseTab?(id) })
        return menu
    }

    @objc private func addPressed() { onAdd?() }
    @objc private func maximizePressed() { onToggleMaximize?() }
    @objc private func closePressed() { onClose?() }
}

/// One tab of the panel strip: its `.tab` button over the whole item and, inside the tab's right
/// edge, the `✕` that closes it (the Files tabs' place: 18 pt, 6 pt from the edge). The `✕` shows
/// while the tab is hovered or shown; its room is always kept, so tabs never shift under the mouse.
final class PanelTabItemView: NSView {
    let tab: CoddButton
    let close: CoddButton
    /// The panel shows this tab (its `✕` stays visible).
    var isSelected = false {
        didSet { if isSelected != oldValue { updateClose() } }
    }
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    /// Design points: the `✕` square, and its distance from the tab's right edge.
    static let closeSize: CGFloat = 18
    static let closeInset: CGFloat = 6

    init(tab: CoddButton, close: CoddButton) {
        self.tab = tab
        self.close = close
        super.init(frame: .zero)
        for view in [tab, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        close.isHidden = true
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The tab's own width with its 14 pt end padding turned into `4 + ✕ + 6`.
    override var intrinsicContentSize: NSSize {
        let z = UIZoom.pt
        let size = tab.intrinsicContentSize
        return NSSize(width: size.width - z(14) + z(4) + z(Self.closeSize) + z(Self.closeInset), height: size.height)
    }

    // A frame change does not mark a hand-laid-out view as needing layout: lay out on both.
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }

    override func layout() {
        super.layout()
        layoutChildren()
    }

    private func layoutChildren() {
        tab.frame = bounds
        let side = UIZoom.pt(Self.closeSize)
        // 1 pt for the tab's right rule.
        close.frame = CGRect(x: bounds.width - 1 - UIZoom.pt(Self.closeInset) - side, y: floor((bounds.height - side) / 2),
                             width: side, height: side)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    /// The pointer is over the tab (tests call it directly).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateClose()
    }

    private func updateClose() {
        let hidden = !(isSelected || isHovered)
        if close.isHidden != hidden { close.isHidden = hidden }
    }
}

/// 6 px horizontal splitter: a dashed line with a centered `⋯` grip (`aria-label` 調整高度).
final class PanelSplitterView: NSView {
    static let thickness: CGFloat = 6

    var onDragBegan: (() -> Void)?
    /// Vertical distance from the mouse-down point (positive = down).
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var startY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("調整高度")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// `.sp-split`: bg-soft, a dashed line 2 px from the top, the `⋯` grip on bg-soft.
    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        let lineY: CGFloat = 2.5
        Draw.dashedLine(from: CGPoint(x: 0, y: lineY), to: CGPoint(x: bounds.width, y: lineY), color: Palette.lineBright)
        let grip = TextStyle.mono(9, Palette.dim).string("⋯")
        let width = Draw.width(grip)
        let x = floor((bounds.width - width) / 2)
        Draw.fill(CGRect(x: x - 10, y: 0, width: width + 20, height: bounds.height), Palette.bgSoft)
        Draw.text(grip, x: x, centerY: bounds.midY)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        startY = event.locationInWindow.y
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Window coordinates grow upward.
        onDrag?(startY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
