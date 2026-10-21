import AppKit
import CoddCore
import CoddUI

/// What the ⌘K palette's rows do (the app delegate implements them).
@MainActor
struct QuickSwitchActions {
    /// Shows a session; `withPanel` also opens (and focuses) its ⌘J panel.
    var openSession: (SessionID, _ withPanel: Bool) -> Void = { _, _ in }
    /// Opens a project: its most recent session (`shell`: its shell session, started when it has none).
    var openProject: (ProjectID, _ shell: Bool) -> Void = { _, _ in }
    /// `+ 加入`: adds a `.claude.json` folder as a project and shows it.
    var addSuggestion: (String) -> Void = { _ in }
    var perform: (QuickSwitchModel.Action) -> Void = { _ in }
    /// A NOTES row (M4 I1b): the window switches to NOTES with that note selected.
    var openNote: (String) -> Void = { _ in }
}

/// ⌘K quick switch (QuickSwitch artboard, D14): a child panel built once and shown with
/// orderFront, so it opens at once. Results come from `QuickSwitchModel` (sessions, projects,
/// actions); ↑↓ or the mouse select, ⏎ opens, ⌘⏎ opens with the ⌘J panel, esc closes. Keys are
/// read in `doCommandBy` (after the input method); the panel claims ⌘⏎ and esc before the main
/// menu sees them (⌘⏎ is the menu's 允許: it must never answer a waiting session from here).
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    private let store: any SessionStore
    private let shell: ShellState
    private let recentProjects: () -> [RecentProject]
    /// `切換帳號到 #n` actions (M3); nil lists none.
    private let accounts: (any AccountStore)?
    /// The NOTES rows' notes (M4 I1b; read inside the observation, so a new note re-ranks).
    var notes: () -> [QuickSwitchModel.Input.Note] = { [] }
    var actions: QuickSwitchActions
    let panel: PalettePanel
    let field = PaletteTextField()
    private let count = Label.make(style: TextStyle.mono(11, Palette.dim))
    let list = QuickSwitchListView()
    private let listScroll = NSScrollView()
    private let dim = DimOverlayView()
    private let footer = PaletteFooterView()
    private(set) var model = QuickSwitchModel(query: "", groups: [])
    private var input = QuickSwitchModel.Input()
    /// The project the contextual actions are about (the last highlighted session or project).
    private var context: ProjectID?
    private weak var parent: NSWindow?
    /// `orderOut` makes the panel resign key, which calls `close()` again; ignore that.
    private var isClosing = false
    /// While shown: re-ranks when a session or project changes (title, state, a new session).
    private var loop: ObservationLoop?
    /// The model changed or the palette opened or closed (state dump).
    var onChange: (() -> Void)?
    /// Last open and ranking times (DEBUG log, tests).
    private(set) var lastShowDuration: Duration?
    private(set) var lastRankDuration: Duration?

    /// Design points at the current interface zoom (M4); the gap above stays (it is the window's).
    static var width: CGFloat { UIZoom.pt(640) }
    static let topInset: CGFloat = 80
    static var inputHeight: CGFloat { UIZoom.pt(56) }
    static var footerHeight: CGFloat { UIZoom.pt(38) }

    init(store: any SessionStore, shell: ShellState, recentProjects: @escaping () -> [RecentProject] = { [] },
         accounts: (any AccountStore)? = nil, actions: QuickSwitchActions = QuickSwitchActions()) {
        self.store = store
        self.shell = shell
        self.recentProjects = recentProjects
        self.accounts = accounts
        self.actions = actions
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360), styleMask: [.borderless],
                             backing: .buffered, defer: true)
        super.init()
        buildContent()
        dim.onClick = { [weak self] in self?.close() }
    }

    var isShown: Bool { panel.isVisible }

    private func buildContent() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.close() }
        panel.onCommandReturn = { [weak self] in self?.commandReturn() }
        panel.isComposing = { [weak self] in (self?.field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }
        let root = PaletteRootView()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(16)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(16, Palette.dimmer).string("搜尋 session、筆記、專案與動作")
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("搜尋 session、筆記、專案與動作")
        let prompt = PaletteGlyphView()
        let esc = ChipView.kbd("esc")
        count.alignment = .right
        let inputRow = hStack([prompt, field, count, esc], spacing: 12, edgeInsets: NSEdgeInsets(top: 14, left: 18, bottom: 13, right: 16))
        let inputBox = PanelView(edges: [.bottom], edgeColor: Palette.lineBright, dashed: [.bottom])
        inputBox.addSubview(inputRow)
        inputRow.pinEdges(to: inputBox)
        listScroll.documentView = list
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.scrollerStyle = .overlay
        listScroll.borderType = .noBorder
        list.onHover = { [weak self] index in self?.highlight(index, scroll: false) }
        list.onClick = { [weak self] index in self?.choose(index, commandEnter: false) }
        for view in [inputBox, listScroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(view)
        }
        root.inputBox = inputBox
        root.listScroll = listScroll
        root.footer = footer
        panel.contentView = root
    }

    // MARK: Showing

    func toggle(over window: NSWindow) {
        if isShown { close() } else { show(over: window) }
    }

    func show(over window: NSWindow) {
        let start = ContinuousClock.now
        parent = window
        field.stringValue = ""
        context = nil
        rebuild(resetHighlight: true)
        loop?.cancel()
        var first = true
        loop = ObservationLoop(track: { [weak self] () -> QuickSwitchModel.Input? in
            guard let self else { return nil }
            return QuickSwitchModel.Input.make(store: self.store, shell: self.shell, recent: self.recentProjects(), accounts: self.accounts,
                                               notes: self.notes())
        }, apply: { [weak self] input in
            // The first pass only starts tracking (the model was just built).
            guard let self, let input, !first else { first = false; return }
            self.rebuild(resetHighlight: false, input: input)
        })
        if let content = window.contentView {
            dim.frame = content.bounds
            dim.autoresizingMask = [.width, .height]
            content.addSubview(dim)
        }
        position(over: window)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        lastShowDuration = ContinuousClock.now - start
        #if DEBUG
        HolderSessionStore.printLog(String(format: "PALETTE shown ms=%.2f rows=%d", TerminalHub.milliseconds(lastShowDuration ?? .zero),
                                           model.count))
        #endif
        onChange?()
    }

    func close() {
        guard isShown, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        loop?.cancel()
        loop = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        dim.removeFromSuperview()
        parent?.makeKeyAndOrderFront(nil)
        onChange?()
    }

    /// Types `query` into the field as if the user had (DEBUG `-codd-palette-query`, tests).
    func setQuery(_ query: String) {
        field.stringValue = query
        if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (query as NSString).length, length: 0) }
        context = nil
        rebuild(resetHighlight: true)
    }

    private func position(over window: NSWindow) {
        let maxHeight = max(200, window.frame.height - Self.topInset - 40)
        let listHeight = min(list.contentHeight, maxHeight - Self.inputHeight - Self.footerHeight)
        let height = Self.inputHeight + listHeight + Self.footerHeight
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - Self.width / 2, y: frame.maxY - Self.topInset - height, width: Self.width, height: height),
                       display: true)
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Model

    private func rebuild(resetHighlight: Bool, input fresh: QuickSwitchModel.Input? = nil) {
        let start = ContinuousClock.now
        input = fresh ?? QuickSwitchModel.Input.make(store: store, shell: shell, recent: recentProjects(), accounts: accounts, notes: notes())
        model = QuickSwitchModel.build(query: field.stringValue, input: input, context: context)
        lastRankDuration = ContinuousClock.now - start
        #if DEBUG
        if !model.query.isEmpty {
            HolderSessionStore.printLog(String(format: "PALETTE ranked n=%d query=%@ ms=%.2f", model.count, model.query,
                                               TerminalHub.milliseconds(lastRankDuration ?? .zero)))
        }
        #endif
        let highlighted = resetHighlight ? 0 : min(list.highlighted, max(0, model.count - 1))
        list.show(model, highlighted: highlighted, now: store.clock.now())
        Label.set(count, "\(model.count) 筆", style: TextStyle.mono(11, Palette.dim))
        if let parent, isShown { position(over: parent) }
        onChange?()
    }

    /// Moves the highlight; a session or project row also becomes the actions' context.
    private func highlight(_ index: Int, scroll: Bool) {
        let rows = model.rows
        guard rows.indices.contains(index) else { return }
        list.setHighlighted(index)
        if scroll { list.scrollRowToVisible(index) }
        let project: ProjectID?
        switch rows[index].item {
        case .session(let id): project = input.sessions.first { $0.id == id }?.projectID
        case .project(let id): project = id
        case .note, .suggestion, .action: project = context
        }
        if project != context, project != nil {
            context = project
            rebuild(resetHighlight: false)
            list.setHighlighted(index)
        }
    }

    // MARK: Choosing

    private func choose(_ index: Int, commandEnter: Bool) {
        let rows = model.rows
        guard rows.indices.contains(index) else { NSSound.beep(); return }
        let item = rows[index].item
        let behavior = commandEnter ? QuickSwitchModel.commandEnter(item, input: input) : .same
        close()
        switch behavior {
        case .openWithPanel(let id): actions.openSession(id, true)
        case .open(let id): actions.openSession(id, false)
        case .projectShell(let id): actions.openProject(id, true)
        case .same:
            switch item {
            case .session(let id): actions.openSession(id, false)
            case .note(let id): actions.openNote(id)
            case .project(let id): actions.openProject(id, false)
            case .suggestion(let path): actions.addSuggestion(path)
            case .action(let action): actions.perform(action)
            }
        }
    }

    /// ⌘⏎ (claimed by the panel before the main menu).
    private func commandReturn() {
        choose(list.highlighted, commandEnter: true)
    }

    /// The `palette` state dump entry.
    var dump: [String: Any] {
        ["shown": isShown, "query": model.query, "rows": model.dumpRows, "highlighted": list.highlighted]
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // While 注音 composes, the marked text is not the query yet: rank when it is committed.
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        context = nil
        rebuild(resetHighlight: true)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            choose(list.highlighted, commandEnter: false)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.moveDown(_:)):
            highlight(min(list.highlighted + 1, max(0, model.count - 1)), scroll: true)
        case #selector(NSResponder.moveUp(_:)):
            highlight(max(list.highlighted - 1, 0), scroll: true)
        default:
            return false
        }
        return true
    }
}

/// The query field (a plain text field: the input method composes in its field editor).
final class PaletteTextField: NSTextField {}

/// Borderless panel that can take keyboard focus. It answers ⌘⏎ and esc itself in
/// `performKeyEquivalent` (AppKit asks the key window before the main menu), so the menu's
/// 允許 ⌘⏎ never sees a ⌘⏎ typed here; esc is left to the input method while it composes.
final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var isComposing: () -> Bool = { false }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let isReturn = event.keyCode == 0x24 || event.keyCode == 0x4C
        if isReturn, modifiers == .command {
            if !isComposing() { onCommandReturn?() }
            return true
        }
        if event.keyCode == 0x35, modifiers.isEmpty, !isComposing() {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// `.backdrop` dimming of the main window behind the palette (`rgba(0,0,0,.72)`).
final class DimOverlayView: NSView {
    var onClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) { Draw.fill(bounds, NSColor.black.withAlphaComponent(0.72)) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// `.modal.qs-pal`: bg-soft, amber-dim border; lays out the input row, the list and the footer.
final class PaletteRootView: PanelView {
    weak var inputBox: NSView?
    weak var listScroll: NSView?
    weak var footer: NSView?

    init() {
        super.init(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.amberDim)
    }

    override func layout() {
        super.layout()
        let b = bounds.insetBy(dx: 1, dy: 1)
        inputBox?.frame = CGRect(x: b.minX, y: b.minY, width: b.width, height: CommandPaletteController.inputHeight)
        let footerTop = b.maxY - CommandPaletteController.footerHeight
        footer?.frame = CGRect(x: b.minX, y: footerTop, width: b.width, height: CommandPaletteController.footerHeight)
        listScroll?.frame = CGRect(x: b.minX, y: b.minY + CommandPaletteController.inputHeight, width: b.width,
                                   height: max(0, footerTop - b.minY - CommandPaletteController.inputHeight))
        (listScroll as? NSScrollView)?.documentView?.setFrameSize(
            NSSize(width: b.width, height: max((listScroll as? NSScrollView)?.documentView?.frame.height ?? 0, 1)))
    }
}

/// The amber `>` (display 18 with its glow).
final class PaletteGlyphView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: UIZoom.pt(12), height: UIZoom.pt(24)) }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        var style = TextStyle(font: Typeface.display(18), color: Palette.amber)
        style.shadow = HomeHeaderView.glow(Palette.amberGlow, radius: 10)
        Draw.text(style.string(">"), x: 0, centerY: bounds.midY)
    }
}

/// `↑↓ 選擇 · ⏎ 開啟 · ⌘⏎ 在下方終端機開啟 … esc 關閉` (`.qs-foot`).
final class PaletteFooterView: PanelView {
    init() {
        super.init(edges: [.top], edgeColor: Palette.line, dashed: [.top])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let mid = bounds.midY
        let kbd = ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 5)
        let label = TextStyle.mono(11, Palette.dim)
        let z = UIZoom.pt
        var x = z(16)
        for (key, text) in [("↑↓", "選擇"), ("⏎", "開啟"), ("⌘⏎", "在下方終端機開啟")] {
            x += kbd.draw(key, x: x, centerY: mid) + z(5)
            x += Draw.text(label.string(text), x: x, centerY: mid) + z(14)
        }
        let close = label.string("關閉")
        let right = bounds.width - z(16) - Draw.width(close)
        Draw.text(close, x: right, centerY: mid)
        let width = kbd.size(for: "esc").width
        kbd.draw("esc", x: right - z(5) - width, centerY: mid)
    }
}

/// The result list (`.menu.qs-list`), drawn in one view: `.mh` section heads with counts and 36 pt
/// rows (glyph cell, tag square, title with the matched characters in amber, detail with the
/// group square, then the state pill, duration and `⌘n`, or the action's hint, or `+ 加入`).
final class QuickSwitchListView: FlippedView, SecondTicking {
    private(set) var model = QuickSwitchModel(query: "", groups: [])
    private(set) var highlighted = 0
    private var rowFrames: [CGRect] = []
    private var now = Date()
    private var trackingArea: NSTrackingArea?
    private var lastMouse: NSPoint?
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    // Design points at the current interface zoom (M4).
    static var rowHeight: CGFloat { UIZoom.pt(36) }
    static var headHeight: CGFloat { UIZoom.pt(27) }
    static var padding: NSEdgeInsets { UIZoom.insets(NSEdgeInsets(top: 4, left: 6, bottom: 8, right: 6)) }
    static var emptyHeight: CGFloat { UIZoom.pt(44) }

    var contentHeight: CGFloat {
        guard model.count > 0 else { return Self.emptyHeight }
        let heads = CGFloat(model.groups.count) * Self.headHeight
        return Self.padding.top + heads + CGFloat(model.count) * Self.rowHeight + Self.padding.bottom
    }

    func show(_ model: QuickSwitchModel, highlighted: Int, now: Date) {
        self.model = model
        self.highlighted = highlighted
        self.now = now
        var frames: [CGRect] = []
        var y = Self.padding.top
        for group in model.groups {
            y += Self.headHeight
            for _ in group.rows {
                frames.append(CGRect(x: Self.padding.left, y: y, width: 0, height: Self.rowHeight))
                y += Self.rowHeight
            }
        }
        rowFrames = frames
        setFrameSize(NSSize(width: max(frame.width, 1), height: contentHeight))
        updateAccessibility()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { UITicker.shared.addSecond(self) } else { UITicker.shared.removeSecond(self) }
    }

    /// The durations tick while the palette is up.
    func secondTick(now: Date) {
        guard model.rows.contains(where: { $0.since != nil }) else { return }
        self.now = now
        needsDisplay = true
    }

    func setHighlighted(_ index: Int) {
        guard index != highlighted, rowFrames.indices.contains(index) else { return }
        highlighted = index
        updateAccessibility()
        needsDisplay = true
    }

    func scrollRowToVisible(_ index: Int) {
        guard rowFrames.indices.contains(index) else { return }
        var rect = rowFrames[index]
        rect.size.width = bounds.width
        // The section head above the first row of a section stays in view too.
        rect.origin.y -= Self.headHeight
        rect.size.height += Self.headHeight
        scrollToVisible(rect)
    }

    private func updateAccessibility() {
        setAccessibilityRole(.list)
        setAccessibilityLabel("快速切換結果，\(model.count) 筆")
        let rows = model.rows
        let value = rows.indices.contains(highlighted) ? rows[highlighted].title : ""
        let changed = (accessibilityValue() as? String) != value
        setAccessibilityValue(value)
        rowElements = drawnRowElements(reusing: rowElements)
        // M5 D21: ↑ ↓ in the search field move the highlight; VoiceOver hears the new row.
        if changed { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    /// One VoiceOver element per row (M5 D21).
    private var rowElements: [DrawnRowElement] = []
    override func accessibilityChildren() -> [Any]? { rowElements }

    private func index(at point: NSPoint) -> Int? {
        rowFrames.firstIndex { point.y >= $0.minY && point.y < $0.maxY }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Only a real move selects (the pointer resting where the panel opened does not).
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastMouse = point }
        guard let last = lastMouse, last != point, let index = index(at: point) else { return }
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onClick?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard model.count > 0 else {
            Draw.text(TextStyle.mono(12, Palette.dimmer).string("// 沒有符合的結果"), x: UIZoom.pt(22), centerY: Self.emptyHeight / 2)
            return
        }
        let width = bounds.width - Self.padding.left - Self.padding.right
        var y = Self.padding.top
        var index = 0
        let z = UIZoom.pt
        for group in model.groups {
            let headY = y + z(9 + 7)
            var x = Self.padding.left + z(10)
            x += Draw.text(TextStyle.caps(9.5, Palette.dim, tracking: 0.2).string(group.section.title), x: x, centerY: headY) + z(8)
            Draw.text(TextStyle.mono(9.5, Palette.dimmer, tracking: 0.04).string("\(group.rows.count)"), x: x, centerY: headY)
            y += Self.headHeight
            for row in group.rows {
                let rect = CGRect(x: Self.padding.left, y: y, width: width, height: Self.rowHeight)
                if rect.intersects(dirtyRect) { draw(row, in: rect, highlighted: index == highlighted) }
                y += Self.rowHeight
                index += 1
            }
        }
    }

    private func stateStyle(_ row: QuickSwitchModel.Row) -> StateStyle? {
        guard let state = row.state else { return nil }
        return row.unreachable ? StateStyle.unreachable : StateStyle.of(state)
    }

    private func draw(_ row: QuickSwitchModel.Row, in rect: CGRect, highlighted: Bool) {
        if highlighted {
            Draw.fill(rect, Palette.bgRaise)
            Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height), Palette.amber)
        }
        let z = UIZoom.pt
        let mid = rect.midY
        let cell = z(14)
        let side = z(8)
        let gap = z(10)
        var x = rect.minX + gap
        // Glyph cell (14 pt): lamp, folder icon or `>`.
        switch row.item {
        case .session:
            if let style = stateStyle(row) {
                let glyph = TextStyle.mono(11, style.color).string(style.glyph)
                Draw.text(glyph, x: x + (cell - Draw.width(glyph)) / 2, centerY: mid)
            }
        case .note:
            IconRenderer.draw(.notes, in: CGRect(x: x, y: mid - cell / 2, width: cell, height: cell), color: Palette.dim, flipped: true)
        case .project, .suggestion:
            IconRenderer.draw(.folder, in: CGRect(x: x, y: mid - cell / 2, width: cell, height: cell), color: Palette.dim, flipped: true)
        case .action:
            let glyph = TextStyle.mono(12, Palette.dim).string(">")
            Draw.text(glyph, x: x + (cell - Draw.width(glyph)) / 2, centerY: mid)
        }
        x += cell + gap
        if let tag = row.tag {
            Draw.fill(CGRect(x: x, y: round(mid - side / 2), width: side, height: side), tag.color)
            x += side + gap
        }
        // Right side first (it never truncates).
        var right = rect.maxX - gap
        switch row.item {
        case .session:
            if let shortcut = row.shortcut {
                let kbd = ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 5)
                right -= kbd.size(for: shortcut).width
                kbd.draw(shortcut, x: right, centerY: mid)
                right -= z(8)
            }
            if let style = stateStyle(row) {
                if let since = row.since {
                    let dur = TextStyle.mono(11, style.color).string(DurationFormat.compact(now.timeIntervalSince(since)))
                    right -= Draw.width(dur)
                    Draw.text(dur, x: right, centerY: mid)
                    right -= z(8)
                }
                let pill = ChipStyle.statePill(style)
                right -= pill.size(for: style.pill).width
                pill.draw(style.pill, x: right, centerY: mid)
                right -= gap
            }
        case .suggestion:
            if let chip = row.chip {
                let style = ChipStyle(text: TextStyle.mono(11, Palette.amber, tracking: 0.03), border: Palette.amberDim, fill: nil,
                                      height: 20, padding: 7)
                right -= style.size(for: chip).width
                style.draw(chip, x: right, centerY: mid)
                right -= gap
            }
        case .note:
            // `.qs-r`: the note's time (11 px, dim).
            if let time = row.shortcut {
                let text = TextStyle.mono(11, Palette.dim).string(time)
                right -= Draw.width(text)
                Draw.text(text, x: right, centerY: mid)
                right -= gap
            }
        case .action, .project:
            if let hint = row.shortcut {
                let text = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string(hint)
                right -= Draw.width(text)
                Draw.text(text, x: right, centerY: mid)
                right -= gap
            }
        }
        // Title (prefix dim, matched characters amber with their glow), then the detail.
        let title = NSMutableAttributedString()
        if let prefix = row.prefix { title.append(TextStyle.mono(12.5, Palette.dim).string(prefix)) }
        let body = NSMutableAttributedString(attributedString: TextStyle.mono(12.5, highlighted ? Palette.cream : Palette.bone).string(row.title))
        let glow = HomeHeaderView.glow(Palette.amberGlow, radius: 8)
        for span in row.spans where span.location + span.length <= body.length {
            let range = NSRange(location: span.location, length: span.length)
            body.addAttribute(.foregroundColor, value: Palette.amber, range: range)
            body.addAttribute(.shadow, value: glow, range: range)
        }
        title.append(body)
        let room = max(0, right - x)
        let titleWidth = Draw.text(title, x: x, centerY: mid, maxWidth: room)
        x += titleWidth + gap
        guard !row.detail.isEmpty, right - x > z(24) else { return }
        if let tag = row.detailTag {
            Draw.fill(CGRect(x: x, y: round(mid - side / 2), width: side, height: side), tag.color)
            x += side + z(6)
        }
        Draw.text(TextStyle.mono(11, Palette.dim).string(row.detail), x: x, centerY: mid, maxWidth: max(0, right - x))
    }
}

// MARK: - Accessibility (M5 D21)

extension QuickSwitchListView: DrawnRowsHost {
    var drawnRowCount: Int { min(model.rows.count, rowFrames.count) }

    /// `修正登入 API 401，等待中 · 3 分鐘，個人 · Github / backend，⌘1`.
    func drawnRowLabel(_ index: Int) -> String? {
        let rows = model.rows
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        var parts = [(row.prefix ?? "") + row.title]
        if let state = row.state {
            let name = row.unreachable ? StateStyle.unreachableSpokenName : StateStyle.spokenName(state)
            parts.append(([name] + (row.since.map { [SpokenDuration.text(now.timeIntervalSince($0))] } ?? [])).joined(separator: " · "))
        }
        parts += [row.detail, row.chip ?? "", row.shortcut ?? ""]
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    func drawnRowFrame(_ index: Int) -> CGRect {
        guard rowFrames.indices.contains(index) else { return .zero }
        var rect = rowFrames[index]
        rect.size.width = bounds.width - Self.padding.left - Self.padding.right
        return rect
    }

    func isDrawnRowSelected(_ index: Int) -> Bool { index == highlighted }
    func pressDrawnRow(_ index: Int) { onClick?(index) }
}
