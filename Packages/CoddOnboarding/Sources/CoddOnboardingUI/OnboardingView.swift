import AppKit
import CoddOnboarding
import CoddUI

/// The first-launch wizard (the frozen Onboarding artboard, M5 §2.4): the 260 px stepper, the boot
/// block, the step head, the six step bodies and the 60 px footer bar. Drawn from
/// `OnboardingViewModel`; every effect goes through `OnboardingActions` (the App owns the window,
/// probes, import and `onboarding.json`, I2). It never activates the app or orders a window front.
///
/// Every length goes through `dz` / `UIZoom.pt` and every font through `Typeface`, so the interface
/// zoom works; the blinking `_` runs on `UITicker` (stopped while the window is hidden,
/// miniaturized or occluded). The App adds its scanline overlay; this view draws none.
@MainActor
public final class OnboardingView: NSView, SecondTicking {
    public static let defaultContentSize = NSSize(width: 1240, height: 820)
    public static let minimumContentSize = NSSize(width: 1011, height: 640)

    public private(set) var model: OnboardingViewModel
    public var actions: OnboardingActions

    let stepper = StepperView()
    let boot = BootBlockView()
    let head = StepHeadView()
    let footer = FooterBarView()
    let groupMenu = GroupMenuOverlay()
    let detectView = DetectStepView()
    let importView = ImportStepView()
    let hooksView = HooksStepView()
    let notebookView = NotebookStepView()
    let accountsView = AccountsStepView()
    let doneView = DoneStepView()
    let bodyScroll = NSScrollView()
    private let bodyDocument = FlippedView()
    private var shownStep: OnboardingStep?
    private var cursorOn = true
    private weak var responderBeforeMenu: NSResponder?
    private lazy var importBody: StepBodyView = ImportBodyAdapter(importView)

    public init(model: OnboardingViewModel, actions: OnboardingActions = OnboardingActions()) {
        self.model = model
        self.actions = actions
        super.init(frame: CGRect(origin: .zero, size: Self.defaultContentSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.borderType = .noBorder
        bodyScroll.contentView.drawsBackground = false
        bodyScroll.documentView = bodyDocument
        for view in [stepper, boot, head, bodyScroll, importView, footer, groupMenu] as [NSView] { addSubview(view) }
        wire()
        apply(model, previous: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Applies only what changed (no flicker): unchanged parts keep their views, the focused control
    /// stays focused, step 2's rows are reused by path.
    public func update(_ model: OnboardingViewModel) {
        guard model != self.model else { return }
        let previous = self.model
        self.model = model
        apply(model, previous: previous)
    }

    /// The control to focus when the window opens or the step changes (step 2: the table, else the
    /// first control of the step).
    public var initialFirstResponder: NSView? {
        switch model.flow.current {
        case .importProjects:
            return importView.table.rows.acceptsFirstResponder ? importView.table.rows : importView.filter.field
        default:
            return currentBody.keyViews.first ?? footer.primary.button
        }
    }

    // MARK: Group menu

    public var isGroupMenuOpen: Bool { groupMenu.isOpen }

    /// Opens step 2's group menu for the row of `path` (⌥↓, a click, the App's actions). A row that
    /// is not shown or not checked has no menu.
    public func openGroupMenu(for path: String) {
        guard model.flow.current == .importProjects, let row = importView.table.rows.row(for: path), row.select.isEnabled else { return }
        if groupMenu.isOpen { closeGroupMenu() }
        importView.table.rows.scrollToVisible(row.frame)
        layoutSubtreeIfNeeded()
        row.select.isOpen = true
        groupMenu.show(path: path, model: model.importStep, anchor: row.select.convert(row.select.bounds, to: self))
        responderBeforeMenu = window?.firstResponder
        window?.makeFirstResponder(groupMenu)
        needsLayout = true
    }

    public func closeGroupMenu() {
        guard groupMenu.isOpen else { return }
        if let path = groupMenu.path { importView.table.rows.row(for: path)?.select.isOpen = false }
        groupMenu.hide()
        if let window {
            var back: NSResponder = responderBeforeMenu ?? importView.table.rows
            // A field editor goes back through its text field (the filter keeps editing).
            if let editor = back as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField { back = field }
            if back === groupMenu || !window.makeFirstResponder(back) { window.makeFirstResponder(importView.table.rows) }
        }
        responderBeforeMenu = nil
    }

    // MARK: Wiring

    private func wire() {
        stepper.onSelect = { [weak self] step in self?.actions.goTo(step) }
        stepper.link.run = { [weak self] in self?.actions.importWeb() }
        boot.redetect.run = { [weak self] in self?.actions.redetect() }
        footer.back.run = { [weak self] in self?.pressBack() }
        footer.skip.run = { [weak self] in self?.actions.skip() }
        footer.primary.run = { [weak self] in self?.pressPrimary() }
        detectView.onButton = { [weak self] item in
            guard let self else { return }
            if let target = item.target { self.actions.goTo(target) } else { self.actions.redetect() }
        }
        importView.onChange = { [weak self] selection in self?.changeImport(selection) }
        importView.onSuggest = { [weak self] in self?.actions.suggestGroups() }
        importView.onOpenMenu = { [weak self] path in self?.openGroupMenu(for: path) }
        importView.onSubmit = { [weak self] in self?.pressPrimary() }
        groupMenu.onPick = { [weak self] path, key in
            guard let self else { return }
            self.closeGroupMenu()
            self.changeImport(self.model.importStep.selection.assigning(key, to: path))
        }
        groupMenu.onCreate = { [weak self] path, name in
            guard let self else { return }
            let step = self.model.importStep
            let (selection, _) = step.selection.addingGroup(named: name, for: path, catalog: step.catalog, options: step.options)
            self.closeGroupMenu()
            self.actions.newGroup(path, name)
            self.changeImport(selection)
        }
        groupMenu.onClose = { [weak self] in self?.closeGroupMenu() }
        groupMenu.anchorProvider = { [weak self] in self?.menuAnchor() }
        hooksView.preview.run = { [weak self] in self?.actions.previewHooks() }
        notebookView.reveal.run = { [weak self] in self?.actions.revealNotes() }
        notebookView.register.run = { [weak self] in self?.actions.registerClaudeCode() }
        notebookView.codex.run = { [weak self] in self?.actions.copyCodexSnippet() }
        accountsView.add.run = { [weak self] in self?.actions.addAccount() }
        accountsView.guide.onCopy = { [weak self] command in self?.actions.copyCommand(command) }
        accountsView.guide.onRun = { [weak self] command in self?.actions.runInTerminal(command) }
        accountsView.guide.redetect.run = { [weak self] in self?.actions.redetect() }
        doneView.allow.run = { [weak self] in self?.actions.requestNotifications() }
    }

    /// A step 2 change the view made: shown at once, then reported.
    private func changeImport(_ selection: ImportSelection) {
        let updated = Self.locallyUpdated(model.importStep, selection: selection)
        var next = model
        next.importStep = updated
        next.stepDetails[.importProjects] = "已選 \(updated.checkedCount) / \(updated.catalog.visibleTotal)"
        let previous = model
        model = next
        apply(next, previous: previous)
        actions.importChanged(updated.selection)
    }

    /// The model after a local change: suggestions are recomputed when the model knows the sidebar's
    /// groups (`ImportStepModel.make` fills `existing`); otherwise the App's options and suggestions
    /// stay and only the selection, the user's new groups and the summary change.
    static func locallyUpdated(_ step: ImportStepModel, selection: ImportSelection) -> ImportStepModel {
        let hasExistingOptions = step.options.contains { if case .existing = $0.kind { return true } else { return false } }
        if !step.existing.isEmpty || !hasExistingOptions { return step.with(selection) }
        var copy = step
        copy.selection = selection
        let known = Set(copy.options.map(\.key))
        let added = selection.newGroups.filter { !known.contains($0.key) }
        if !added.isEmpty {
            let ungrouped = copy.options.firstIndex { $0.kind == .ungrouped } ?? copy.options.endIndex
            copy.options.insert(contentsOf: added, at: ungrouped)
        }
        copy.summary = ImportStepModel.summaryText(selection, catalog: copy.catalog, options: copy.options)
        return copy
    }

    private func pressPrimary() {
        guard footer.primary.button.isEnabled else { return }
        if model.flow.current == .done { actions.finish() } else { actions.next() }
    }

    private func pressBack() {
        guard model.flow.current != .detect else { return }
        actions.back()
    }

    // MARK: Apply

    private var currentBody: StepBodyView {
        switch model.flow.current {
        case .detect: detectView
        case .importProjects: importBody
        case .hooks: hooksView
        case .notebook: notebookView
        case .accounts: accountsView
        case .done: doneView
        }
    }

    static let leads: [OnboardingStep: String] = [
        .detect: "CODD 先看看這台 Mac：Claude Code、cswap、hooks 與資料夾。這一步只讀，不會改動任何檔案。",
        .hooks: "CODD 開的 session 會自動帶上 hooks 與狀態列，不必改全域設定。這一步只整理 `~/.claude/settings.json`：移除舊版 CODD web 的 hooks，或安裝全域狀態列，讓 CODD 以外的 claude 也回報用量。",
        .notebook: "筆記是一般的 Markdown 檔，存在 CODD 的資料夾裡；CODD 開的 claude session 會自動掛上 CODD 的 MCP，可以搜尋與讀取筆記。",
        .accounts: "CODD 透過 cswap 管理多個 Claude 帳號：只讀 cswap 的狀態檔，只顯示別名，不顯示 email。",
        .done: "設定好了。每一步都能之後在 SETTINGS 調整，或從 說明 › 首次啟動設定 重來一次。",
    ]

    static func lead(for model: OnboardingViewModel) -> String {
        let step = model.flow.current
        if step == .importProjects { return ImportStepView.lead(for: model.importStep.catalog) }
        return leads[step] ?? ""
    }

    /// The footer summary and its faint tail for the current step.
    static func summary(for model: OnboardingViewModel) -> (String, String?) {
        switch model.flow.current {
        case .detect: return (model.boot.summary, nil)
        case .importProjects: return (model.importStep.summary, " · 之後可用 ⌘N 或側欄加入更多")
        case .hooks: return (model.hooks.pending > 0 ? "◆ \(model.hooks.pending) 項待處理" : "● 已是最新", nil)
        case .notebook: return (model.notebook.mcpRunning ? "● MCP 運作中" : "○ MCP 未啟動", nil)
        case .accounts:
            if model.accounts.rows.isEmpty { return (model.accounts.availabilityNote ?? "", nil) }
            return ("\(model.accounts.rows.count) 個帳號", nil)
        case .done: return ("", nil)
        }
    }

    private func apply(_ model: OnboardingViewModel, previous: OnboardingViewModel?) {
        let step = model.flow.current
        if previous?.flow != model.flow || previous?.stepDetails != model.stepDetails || previous?.versionLine != model.versionLine
            || previous?.showsWebImportLink != model.showsWebImportLink {
            stepper.apply(model)
        }
        boot.apply(model.boot)
        head.apply(step: step, lead: Self.lead(for: model))
        detectView.apply(model.detect)
        importView.apply(model.importStep)
        hooksView.apply(model.hooks)
        notebookView.apply(model.notebook)
        accountsView.apply(model.accounts)
        doneView.apply(model.done)
        let (summary, faint) = Self.summary(for: model)
        footer.apply(step: step, summary: summary, faint: faint)
        if shownStep != step { show(step) }
        if groupMenu.isOpen, step != .importProjects || groupMenu.path.flatMap(importView.table.rows.row(for:)) == nil { closeGroupMenu() }
        needsLayout = true
        rebuildKeyLoop()
    }

    private func show(_ step: OnboardingStep) {
        let focusInside = (window?.firstResponder as? NSView).map { view in
            ([bodyDocument, importView] as [NSView]).contains { view.isDescendant(of: $0) }
        } ?? false
        for body in [detectView, hooksView, notebookView, accountsView, doneView] as [NSView] where body.superview != nil {
            body.removeFromSuperview()
        }
        shownStep = step
        if step == .importProjects {
            importView.isHidden = false
            bodyScroll.isHidden = true
        } else {
            importView.isHidden = true
            bodyScroll.isHidden = false
            bodyDocument.addSubview(currentBody)
            bodyScroll.contentView.scroll(to: .zero)
        }
        if focusInside, let window { window.makeFirstResponder(initialFirstResponder ?? self) }
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let stepperWidth = dz(StepperView.width)
        stepper.place(CGRect(x: 0, y: 0, width: stepperWidth, height: height))
        let mainWidth = max(0, width - stepperWidth)
        footer.place(CGRect(x: stepperWidth, y: height - FooterBarView.height, width: mainWidth, height: FooterBarView.height))
        let content = CGRect(x: stepperWidth + dz(40), y: dz(28), width: max(0, mainWidth - dz(80)),
                             height: max(0, height - FooterBarView.height - dz(28) - dz(14)))
        boot.place(CGRect(x: content.minX, y: content.minY, width: content.width, height: boot.height()))
        let headHeight = head.height(forWidth: content.width)
        head.place(CGRect(x: content.minX, y: boot.frame.maxY + dz(20), width: content.width, height: headHeight))
        let top = head.frame.maxY + dz(20)
        let area = CGRect(x: content.minX, y: top, width: content.width, height: max(0, content.maxY - top))
        if model.flow.current == .importProjects {
            importView.place(CGRect(x: area.minX, y: area.minY, width: area.width, height: importView.height(available: area.height)))
        } else {
            bodyScroll.place(area)
            let body = currentBody
            let bodyHeight = body.height(forWidth: area.width)
            bodyDocument.setFrameSize(NSSize(width: area.width, height: max(bodyHeight, area.height)))
            body.place(CGRect(x: 0, y: 0, width: area.width, height: bodyHeight))
        }
        groupMenu.place(bounds)
        // The overlay (the last subview) asks for its anchor in its own layout, after the rows.
        if groupMenu.isOpen { groupMenu.needsLayout = true }
    }

    /// The open menu's select in this view's coordinates (kept on screen while the window resizes).
    private func menuAnchor() -> CGRect? {
        guard let path = groupMenu.path, let row = importView.table.rows.row(for: path) else { return nil }
        importView.table.rows.scrollToVisible(row.frame)
        return row.select.convert(row.select.bounds, to: self)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }

    // MARK: Keyboard

    /// Tab order: stepper → body controls → footer (§2.4).
    private func rebuildKeyLoop() {
        var chain: [NSView] = stepper.rows.filter(\.isClickable)
        if !stepper.link.isHidden { chain.append(stepper.link) }
        chain.append(boot.redetect.button)
        chain.append(contentsOf: currentBody.keyViews)
        chain.append(contentsOf: [footer.back.button, footer.skip.button, footer.primary.button])
        for (index, view) in chain.enumerated() { view.nextKeyView = chain[(index + 1) % chain.count] }
    }

    /// The key-view order (tests, the App's audit).
    var keyLoop: [NSView] {
        var chain: [NSView] = stepper.rows.filter(\.isClickable)
        if !stepper.link.isHidden { chain.append(stepper.link) }
        chain.append(boot.redetect.button)
        chain.append(contentsOf: currentBody.keyViews)
        chain.append(contentsOf: [footer.back.button, footer.skip.button, footer.primary.button])
        return chain
    }

    /// A text field composing with an input method (注音) owns ⏎.
    var isComposingText: Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false }

    static func isReturn(_ event: NSEvent) -> Bool {
        event.type == .keyDown && (event.specialKey == .carriageReturn || event.specialKey == .enter || event.keyCode == 36 || event.keyCode == 76)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if groupMenu.isOpen {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command, event.charactersIgnoringModifiers == "[" {
            pressBack()
            return true
        }
        if flags.isEmpty, Self.isReturn(event), !isComposingText {
            pressPrimary()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if !groupMenu.isOpen, flags.isEmpty, Self.isReturn(event), !isComposingText {
            pressPrimary()
            return
        }
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        if groupMenu.isOpen { closeGroupMenu() } else { super.cancelOperation(sender) }
    }

    // MARK: Cursor blink

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, UITicker.shared.pulsesAllowed {
            UITicker.shared.addSecond(self)
        } else {
            UITicker.shared.removeSecond(self)
            setCursor(true)
        }
        UITicker.shared.updateTimers()
    }

    public func secondTick(now: Date) {
        guard UITicker.shared.pulsesAllowed else { setCursor(true); return }
        setCursor(!cursorOn)
    }

    private func setCursor(_ on: Bool) {
        cursorOn = on
        stepper.cursorVisible = on
        boot.term.cursorVisible = on
    }
}

/// Lets step 2 answer the body questions (key views) without being in the scroll view.
@MainActor
private final class ImportBodyAdapter: NSView, StepBodyView {
    private weak var view: ImportStepView?

    init(_ view: ImportStepView) {
        self.view = view
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func height(forWidth width: CGFloat) -> CGFloat { view?.height(available: .greatestFiniteMagnitude) ?? 0 }

    var keyViews: [NSView] {
        guard let view else { return [] }
        var views: [NSView] = [view.filter.field, view.suggest.button]
        if view.table.rows.acceptsFirstResponder { views.append(view.table.rows) }
        views.append(view.table.foot.hiddenToggle)
        if !view.table.foot.more.button.isHidden { views.append(view.table.foot.more.button) }
        return views
    }
}
