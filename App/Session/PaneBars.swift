import AppKit
import CoddUI

/// One tab of a strip: what it opens, its label (`zsh 2`, or the shell's OSC title, D11) and the
/// marks after the label (the running lamp, D25; the bell, D12).
struct TabStripEntry: Equatable {
    var item: PaneTabItem
    var label: String
    var marks: [CoddButton.TabMark] = []
}

/// Accessibility text of a tab: its label, then `執行中` (the lamp's aria) and `響鈴`.
func tabAccessibilityLabel(_ label: String, marks: [CoddButton.TabMark]) -> String {
    ([label] + marks.map { $0 == .running ? "執行中" : "響鈴" }).joined(separator: "，")
}

/// Tab strip (`.tabs`, 30 px): `◆ CLAUDE_` · `+` … `120×38 · ⌘L composer · ⌘J 終端機`. Every extra
/// terminal opens in the ⌘J panel (`+` = ⌘T adds one there); shell tabs only show here while an
/// older panes.json still lists them, until the terminal hub moves them into the panel.
///
/// Buttons are rebuilt only when the set of tabs changes; labels, selection, the main tab's state
/// lamp and the marks are updated in place, so a click in progress survives the pane's frequent
/// re-renders.
final class TabStripView: PanelView {
    /// A tab was clicked.
    var onSelect: ((PaneTabItem) -> Void)?
    /// `+` (same as ⌘T: a new terminal in the bottom panel).
    var onAdd: (() -> Void)?
    /// `⌘J 終端機` on the right (same as ⌘J).
    var onTogglePanel: (() -> Void)?
    /// `⌘L composer` on the right (same as ⌘L).
    var onToggleComposer: (() -> Void)?

    let addTab = CoddButton("+", style: .tab(lamp: "", lampColor: Palette.dim))
    private let tabs = hStack([], spacing: 0)
    private let gridLabel = Label.make("", style: TextStyle.mono(10.5, Palette.dimmer))
    /// `⌘L composer` (Split artboard `.tfill`); hidden where there is no composer (externals).
    let composerLink = StripTextButton("⌘L composer")
    private let composerDot = Label.make("·", style: TextStyle.mono(10.5, Palette.dimmer))
    private let toggleDot = Label.make("·", style: TextStyle.mono(10.5, Palette.dimmer))
    private var toggle: StripTextButton?
    private var hints: NSStackView?
    private var row: NSStackView?
    /// `⌘L composer` belongs to this session (`setComposerLinkVisible`); the width decides the rest.
    private var wantsComposerLink = true
    private var items: [PaneTabItem] = []

    /// The tab buttons in strip order (tests).
    var tabButtons: [CoddButton] { tabs.arrangedSubviews.compactMap { $0 as? CoddButton } }

    /// `+`'s label: it opens a new terminal in the bottom panel.
    static let addTitle = "新增終端機 ⌘T"

    init() {
        super.init(fill: Palette.bgSoft, edges: [.bottom], edgeColor: Palette.lineBright)
        addTab.setAccessibilityLabel(Self.addTitle)
        addTab.toolTip = Self.addTitle
        addTab.target = self
        addTab.action = #selector(addPressed)
        // `.tfill`: `100×22 · ⌘L composer · ⌘J 終端機`, plain dimmer text (the two shortcuts click).
        let toggle = StripTextButton("⌘J 終端機")
        toggle.toolTip = "下方終端機 ⌘J"
        toggle.setAccessibilityLabel("下方終端機 ⌘J")
        toggle.target = self
        toggle.action = #selector(togglePressed)
        composerLink.toolTip = "Composer ⌘L"
        composerLink.setAccessibilityLabel("Composer ⌘L")
        composerLink.target = self
        composerLink.action = #selector(composerPressed)
        let fill = hStack([spacer(), gridLabel, composerDot, composerLink, toggleDot, toggle],
                          spacing: 10, edgeInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10))
        tabs.alignment = .height
        let stack = hStack([tabs, addTab, fill], spacing: 0)
        stack.alignment = .height
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))
        self.toggle = toggle
        hints = fill
        row = stack
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToWidth()
    }

    /// Narrow panes: the tabs and `+` always show; then, while they fit, `⌘J 終端機`, `⌘L composer`
    /// and the grid size (from the right, so the shortcuts stay where they were).
    private func fitToWidth() {
        guard let hints, let toggle else { return }
        let spacing = hints.spacing
        let fixed = tabs.fittingSize.width + addTab.intrinsicContentSize.width + hints.edgeInsets.right
        var pieces: [[NSView]] = [[toggle]]
        if wantsComposerLink { pieces.append([composerLink, toggleDot]) }
        pieces.append([gridLabel, wantsComposerLink ? composerDot : toggleDot])
        let costs = pieces.map { views in views.reduce(0) { $0 + $1.intrinsicContentSize.width + spacing } }
        let shown = RowFit.shown(available: bounds.width, fixed: fixed, costs: costs)
        var visible = Set<ObjectIdentifier>()
        for (views, show) in zip(pieces, shown) where show { views.forEach { visible.insert(ObjectIdentifier($0)) } }
        for view in [toggle, composerLink, toggleDot, gridLabel, composerDot] as [NSView] {
            let hidden = !visible.contains(ObjectIdentifier(view))
            if view.isHidden != hidden { view.isHidden = hidden }
        }
    }

    /// The right-hand hints shown at the current width (tests): `⌘J`, `⌘L`, the grid size.
    var shownHints: (toggle: Bool, composer: Bool, grid: Bool) {
        (!(toggle?.isHidden ?? true), !composerLink.isHidden, !gridLabel.isHidden)
    }

    /// - Parameters:
    ///   - isShellSession: the session's own tab is `$ zsh` instead of `◆ Claude`.
    ///   - lamp: the session's state style (drawn on the CLAUDE tab).
    func update(entries: [TabStripEntry], isShellSession: Bool, lamp: StateStyle, selected: PaneTab) {
        let items = entries.map(\.item)
        let newLabels = entries.map(\.label)
        // A new title only relabels its button (titles can change every second).
        if items != self.items {
            self.items = items
            tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, label) in newLabels.enumerated() {
                let button = CoddButton(label, style: .tab(lamp: "$", lampColor: Palette.bone), target: self,
                                        action: #selector(tabPressed(_:)))
                button.tag = index
                button.setAccessibilityRole(.radioButton)
                tabs.addArrangedSubview(button)
            }
        }
        for (index, button) in tabButtons.enumerated() {
            let item = items[index]
            let style: CoddButton.Style
            if case .main = item, !isShellSession {
                style = .tab(lamp: lamp.glyph, lampColor: lamp.color)
            } else {
                style = .tab(lamp: "$", lampColor: Palette.bone)
            }
            if !Self.sameTabStyle(button.style, style) { button.style = style }
            button.label = newLabels[index]
            let marks = entries[index].marks
            button.tabMarks = marks
            let accessibility = tabAccessibilityLabel(entries[index].label, marks: marks)
            if button.accessibilityLabel() != accessibility { button.setAccessibilityLabel(accessibility) }
            let on: Bool
            switch item {
            case .main: on = selected == .claude
            case .shell(let tab): on = selected == .shell(tab.id)
            case .pendingShell: on = false
            }
            button.isOn = on
            button.setAccessibilityValue(on)
        }
        fitToWidth()
    }

    func setGrid(_ grid: TerminalGridSize) {
        Label.set(gridLabel, "\(grid.columns)×\(grid.rows)", style: TextStyle.mono(10.5, Palette.dimmer))
        fitToWidth()
    }

    /// The label without an OSC title (`ShellState.label(for:inPanel:)` adds titles).
    static func label(_ item: PaneTabItem, isShellSession: Bool) -> String {
        switch item {
        case .main: isShellSession ? "zsh" : "Claude"
        case .shell(let tab): tab.number <= 1 ? "zsh" : "zsh \(tab.number)"
        case .pendingShell: "zsh"
        }
    }

    static func sameTabStyle(_ a: CoddButton.Style, _ b: CoddButton.Style) -> Bool {
        guard case .tab(let lampA, let colorA) = a, case .tab(let lampB, let colorB) = b else { return false }
        return lampA == lampB && colorA == colorB
    }

    @objc private func tabPressed(_ sender: CoddButton) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect?(items[sender.tag])
    }

    /// Shows or hides `⌘L composer` (no composer for externals; I4).
    func setComposerLinkVisible(_ visible: Bool) {
        wantsComposerLink = visible
        fitToWidth()
    }

    @objc private func addPressed() { onAdd?() }
    @objc private func togglePressed() { onTogglePanel?() }
    @objc private func composerPressed() { onToggleComposer?() }
}

/// Plain `.tfill` text that acts like a link (`⌘L composer`, `⌘J 終端機`): dimmer, cream on hover.
final class StripTextButton: NSButton {
    private var hovered = false
    private var trackingArea: NSTrackingArea?
    private let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        title = text
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setContentHuggingPriority(.required, for: .horizontal)
        // Below the window's stay-put priority: the strip hides a hint that does not fit
        // (`TabStripView.fitToWidth`) instead of the hint holding the window wide.
        setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func style(_ hot: Bool) -> TextStyle { TextStyle.mono(10.5, hot ? Palette.cream : Palette.dimmer) }

    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(style(false).string(text)), height: 18) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(style(hovered || isHighlighted).string(text), x: 0, centerY: bounds.midY)
    }
}

/// One banner button: title, action (sent to the banner's target) and look. A disabled one says
/// why in `toolTip` (`沒有可重送的 prompt`).
struct BannerAction: Equatable {
    var title: String
    var action: Selector
    var variant: CoddButton.Variant = .normal
    var isEnabled = true
    var toolTip: String?
}

/// Banner under the header (`.banner.bad` error, info banners for EXT / exited sessions) and
/// the cyan DONE note under the tab strip.
///
/// `show` may run every second (the message carries a duration); the buttons are rebuilt only
/// when the set of actions changes, so hover state and an in-flight click survive the ticks.
final class BannerView: PanelView {
    enum Kind { case error, info, doneNote }

    private let lamp = Label.make(style: TextStyle.mono(11, Palette.danger))
    private let message = Label.make(style: TextStyle.mono(12, Palette.cream))
    private let detail = Label.make(style: TextStyle.mono(11.5, Palette.dimmer))
    /// `.hint` before the buttons (why one is disabled).
    private let hint = Label.make(style: TextStyle.mono(11.5, Palette.dimmer))
    private let buttons = hStack([], spacing: 6)
    private var kind: Kind = .info
    private var shownActions: [BannerAction] = []
    private weak var shownTarget: AnyObject?

    /// The current action buttons (tests).
    var actionButtons: [CoddButton] { buttons.arrangedSubviews.compactMap { $0 as? CoddButton } }

    init() {
        super.init(fill: Palette.bgSoft, edges: [.bottom], edgeColor: Palette.lineBright)
        let stack = hStack([lamp, message, detail, spacer(), hint, buttons], spacing: 10,
                           edgeInsets: NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12))
        addSubview(stack)
        stack.pinEdges(to: self)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kind == .doneNote ? 26 : 38)
    }

    /// The hint shown before the buttons (tests).
    var hintText: String { hint.isHidden ? "" : hint.stringValue }

    func show(_ kind: Kind, glyph: String, glyphColor: NSColor, message text: String, detail detailText: String = "",
              hint hintText: String? = nil, actions: [BannerAction] = [], target: AnyObject? = nil) {
        if kind != self.kind {
            self.kind = kind
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
        Label.set(lamp, glyph, style: TextStyle.mono(11, glyphColor))
        let messageColor = kind == .doneNote ? Palette.cyan : Palette.cream
        Label.set(message, text, style: TextStyle.mono(kind == .doneNote ? 11 : 12, messageColor))
        Label.set(detail, detailText, style: TextStyle.mono(11.5, Palette.dimmer))
        Label.set(hint, hintText ?? "", style: TextStyle.mono(11.5, Palette.dimmer))
        hint.isHidden = hintText?.isEmpty ?? true
        let sameButtons = target === shownTarget && actions.count == shownActions.count
            && zip(actions, shownActions).allSatisfy { $0.action == $1.action && $0.variant == $1.variant }
        if sameButtons {
            // Titles tick (`⟲ 42s 後重試`): updated in place, so hover and a click in flight survive.
            for (button, action) in zip(actionButtons, actions) { Self.apply(action, to: button) }
            shownActions = actions
        } else if actions != shownActions || target !== shownTarget {
            shownActions = actions
            shownTarget = target
            buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for action in actions {
                let button = CoddButton(action.title, style: .bracket(action.variant, small: true), target: target, action: action.action)
                Self.apply(action, to: button)
                buttons.addArrangedSubview(button)
            }
        }
        let edge = kind == .error ? Palette.danger.withAlphaComponent(0.45) : (kind == .doneNote ? Palette.line : Palette.lineBright)
        if edge != edgeColor { edgeColor = edge }
        setAccessibilityRole(kind == .error ? .group : .staticText)
        if accessibilityLabel() != text { setAccessibilityLabel(text) }
    }

    private static func apply(_ action: BannerAction, to button: CoddButton) {
        button.label = action.title
        if button.isEnabled != action.isEnabled { button.isEnabled = action.isEnabled }
        if button.toolTip != action.toolTip { button.toolTip = action.toolTip }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .error:
            Draw.hGradient(bounds, from: Palette.danger.withAlphaComponent(0.12), to: Palette.danger.withAlphaComponent(0.02))
        case .info:
            Draw.fill(bounds, Palette.bgSoft)
        case .doneNote:
            Draw.fill(bounds, Palette.bg)
            Draw.hGradient(CGRect(x: 0, y: 0, width: bounds.width * 0.6, height: bounds.height),
                           from: Palette.cyan.withAlphaComponent(0.08), to: Palette.cyan.withAlphaComponent(0))
        }
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), edgeColor)
    }
}

/// App status bar (`.statusbar`, 24 px): MCP · hooks · [mode · mode detail] · counts · ⌘K.
final class StatusBarView: PanelView {
    private let mcp = Label.make(style: TextStyle.mono(10.5, Palette.dim))
    private let hooks = Label.make(style: TextStyle.mono(10.5, Palette.dim))
    /// A mode's own items after hooks (ImageAnnotate: amber `標註模式`, then `3 個標註 · ● 已儲存 10:46`).
    private let mode = Label.make(style: TextStyle.mono(10.5, Palette.amber))
    private let modeDetail = Label.make(style: TextStyle.mono(10.5, Palette.bone))
    private let counts = Label.make(style: TextStyle.mono(10.5, Palette.dim))
    private let flexible = spacer()
    private var stack: NSStackView?
    /// A mode's own status items in place of hooks, the mode label and the counts (Files: C6's
    /// `EditorStatusItemsView`, which brings its own flexible space).
    private(set) var accessory: NSView?
    private var loop: ObservationLoop?

    /// The mode items as shown (tests, the dump).
    private(set) var modeTexts: [String] = []

    /// Shows a mode's items (nil hides them).
    func setMode(_ title: String?, detail: NSAttributedString?) {
        mode.isHidden = title == nil
        modeDetail.isHidden = detail == nil
        if let title { Label.set(mode, title, style: TextStyle.mono(10.5, Palette.amber)) }
        if let detail { modeDetail.attributedStringValue = detail }
        modeTexts = [title, detail?.string].compactMap { $0 }
    }

    /// Shows `view` between the MCP item and ⌘K, hiding hooks, the mode items and the counts (nil
    /// brings them back).
    func setAccessory(_ view: NSView?) {
        guard view !== accessory, let stack else { return }
        if let accessory { stack.removeArrangedSubview(accessory); accessory.removeFromSuperview() }
        accessory = view
        if let view {
            // It grows into the bar's free width; its own essentials (its intrinsic width) win over
            // the MCP item (250), never over the window's stay-put priority (500).
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            view.setContentCompressionResistancePriority(.init(255), for: .horizontal)
            stack.insertArrangedSubview(view, at: 1)
        }
        for part in [hooks, counts, flexible] { part.isHidden = view != nil }
        if view != nil {
            mode.isHidden = true
            modeDetail.isHidden = true
        }
    }

    init(store: any SessionStore) {
        super.init(fill: Palette.bgSoft, edges: [.top], edgeColor: Palette.line)
        mode.isHidden = true
        modeDetail.isHidden = true
        let stack = hStack([mcp, hooks, mode, modeDetail, flexible, counts, ChipView.kbd("⌘K")], spacing: 14,
                           edgeInsets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12))
        addSubview(stack)
        stack.pinEdges(to: self)
        self.stack = stack
        // A narrow bar truncates the long MCP endpoint first, then hooks; the session counts and a
        // mode's name last (all below the window's stay-put priority: the bar never holds it wide).
        counts.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        mode.setContentCompressionResistancePriority(.init(290), for: .horizontal)
        hooks.setContentCompressionResistancePriority(.init(280), for: .horizontal)
        loop = ObservationLoop { [weak self, weak store] in
            guard let self, let store else { return }
            self.render(host: store.host, counts: SessionCounts(sessions: store.allSessions))
        }
    }

    private func render(host: HostSummary, counts c: SessionCounts) {
        let base = TextStyle.mono(10.5, Palette.dim)
        let m = NSMutableAttributedString(attributedString: TextStyle.mono(10.5, host.mcpRunning ? Palette.success : Palette.dimmer).string("● "))
        m.append(base.string("MCP \(host.mcpEndpoint) · \(host.mcpClients) clients"))
        mcp.attributedStringValue = m
        // M5 D21: each item is a static text that says its dot (the color) as a word.
        mcp.setAccessibilityLabel("MCP \(host.mcpEndpoint) \(host.mcpRunning ? "執行中" : "未啟動")，\(host.mcpClients) 個 client")

        let h = NSMutableAttributedString(attributedString: base.string("hooks "))
        if let status = host.hookStatus, let glyph = status.first {
            // Real mode: the endpoint's own state (degraded = registry only).
            let color = glyph == "●" ? Palette.success : glyph == "▲" ? Palette.danger : Palette.amber
            h.append(TextStyle.mono(10.5, color).string(String(glyph)))
            h.append(base.string(String(status.dropFirst())))
        } else if host.hooksInstalled {
            h.append(TextStyle.mono(10.5, host.hooksHealthy ? Palette.success : Palette.amber).string("●"))
            h.append(base.string(host.hooksHealthy ? " ok" : " 需要更新"))
        } else {
            h.append(TextStyle.mono(10.5, Palette.amber).string("!"))
            h.append(base.string(" 未安裝"))
        }
        hooks.attributedStringValue = h
        hooks.setAccessibilityLabel(Self.spokenHooks(host))

        let n = NSMutableAttributedString(attributedString: base.string("\(c.live) live · "))
        n.append(TextStyle.mono(10.5, Palette.amber).string("◆ \(c.attention)"))
        n.append(base.string(" · "))
        n.append(TextStyle.mono(10.5, Palette.success).string("● \(c.working)"))
        counts.attributedStringValue = n
        counts.setAccessibilityLabel("\(c.live) 個 session 執行中，\(c.attention) 個需要你，\(c.working) 個工作中")
    }

    /// `hooks 正常`, `hooks 需要更新`, `hooks 未安裝`; real mode's own status with its glyph as a word.
    static func spokenHooks(_ host: HostSummary) -> String {
        if let status = host.hookStatus, let glyph = status.first {
            let word = glyph == "●" ? "正常" : glyph == "▲" ? "錯誤" : "注意"
            let rest = status.dropFirst().trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "hooks \(word)" : "hooks \(word)，\(rest)"
        }
        if host.hooksInstalled { return host.hooksHealthy ? "hooks 正常" : "hooks 需要更新" }
        return "hooks 未安裝"
    }
}
