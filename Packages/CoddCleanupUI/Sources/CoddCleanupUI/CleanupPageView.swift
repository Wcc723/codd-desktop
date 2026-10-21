import AppKit
import CoddUI

/// The Cleanup page (Cleanup artboard `.nb-cl-page`): a scrolling page with `padding: 18px 36px`,
/// the crumb `← NOTEBOOK / CLEANUP … esc 返回筆記本`, `CLEANUP · 清理建議` and the meta rule, then
/// a grid of the review table (tabs, rows, the sticky bulk bar) and the 344 px CONDENSE card, and
/// the POLICY card under both. Without a condense model the table takes the full width; below a
/// 640 px table the card moves under the table.
///
/// `update(_:)` reconfigures only what changed and keeps the page's transient state: the
/// selection (adopted from the model only when the model's `selected` changed), the keyboard
/// focus row, the scroll offset and an open select menu. Keyboard, while the page is the first
/// responder and no field editor has marked text: space toggles the focused row, ↑ ↓ move it,
/// ⌘A selects every row of the tab, ⌫ archives the selection (`onBulk("封存", …)`), esc goes back.
@MainActor
public final class CleanupPageView: NSView {
    // MARK: Callbacks

    /// `← NOTEBOOK` and esc.
    public var onBack: (() -> Void)?
    /// `[調整規則 → 設定]`.
    public var onOpenSettings: (() -> Void)?
    /// `[✻ 產生摘要]`.
    public var onGenerate: (() -> Void)?
    /// `[取消]` while a condense run is going.
    public var onCancelRun: (() -> Void)?
    /// `[建立摘要並封存原稿]`.
    public var onApply: (() -> Void)?
    /// `[重新產生]` (preview and failed states).
    public var onRegenerate: (() -> Void)?
    /// `[捨棄]`.
    public var onDiscard: (() -> Void)?
    /// A tab other than the current one was clicked (the app answers with a model for that tab).
    public var onTab: ((CleanupTab) -> Void)?
    /// The user changed the selection (checkbox, row click, space, ⌘A, the header box, `✕`).
    public var onSelection: ((Set<String>) -> Void)?
    /// A row button: row id, action title (`保留 30 天`, `封存`, `移到垃圾桶`).
    public var onRowAction: ((String, String) -> Void)?
    /// A bulk bar button or ⌫: action title (`CleanupBulkAction`), the selected ids.
    public var onBulk: ((String, Set<String>) -> Void)?
    /// An account picked in the select's menu (its id).
    public var onCondenseAccount: ((String) -> Void)?
    /// A model picked in the select's menu.
    public var onCondenseModel: ((String) -> Void)?

    // MARK: State

    public private(set) var model: CleanupPageModel
    /// The selected row ids as shown.
    public private(set) var selection: Set<String>
    /// The row space toggles (nil until a row is clicked or a key moves the focus).
    public private(set) var focusedRowID: String?

    static var padding: NSEdgeInsets { NSEdgeInsets(top: kz(18), left: kz(36), bottom: kz(18), right: kz(36)) }
    /// `.nb-cl-grid{gap:20px 24px}`.
    static var gridColumnGap: CGFloat { kz(24) }
    static var gridRowGap: CGFloat { kz(20) }
    /// Narrower tables put the CONDENSE card under the table.
    static var minimumTableWidth: CGFloat { kz(640) }
    static var crumbHeight: CGFloat { kz(18) }
    static let titleHeight: CGFloat = 26 * 1.2
    static let metaHeight: CGFloat = 11 * 1.5

    let scroll = NSScrollView()
    let document = CleanupDocumentView()
    let crumb = CrumbView()
    let titleLine = TextLine("CLEANUP · 清理建議", style: TextStyle.pageTitle)
    let metaRule = MetaRuleView()
    let review = ReviewPanelView()
    let condense = CondenseCardView()
    let policy = PolicyCardView()
    private var toast: ToastView?
    private var hasFocus = false

    public init(model: CleanupPageModel) {
        self.model = model
        selection = model.selected.intersection(model.rows.map(\.id))
        super.init(frame: CGRect(x: 0, y: 0, width: kz(1368), height: kz(876)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("清理建議")

        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        for view: NSView in [crumb, titleLine, metaRule, review, condense, policy] { document.addSubview(view) }
        document.onMouseDown = { [weak self] in self?.focusPage() }
        wire()
        apply(old: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    private func wire() {
        crumb.onBack = { [weak self] in self?.onBack?() }
        for tab in review.tabStrip.tabs {
            let value = tab.tab
            tab.onClick = { [weak self] in
                guard let self else { return }
                self.focusPage()
                if value != self.model.tab { self.onTab?(value) }
            }
        }
        review.onToggle = { [weak self] id in
            self?.focusPage()
            self?.toggle(id)
        }
        review.onClick = { [weak self] id in
            self?.focusPage()
            self?.toggle(id)
        }
        review.onRowAction = { [weak self] id, title in self?.onRowAction?(id, title) }
        review.header.checkbox.target = self
        review.header.checkbox.action = #selector(headerCheckboxPressed)
        review.bulkBar.onAction = { [weak self] action in
            guard let self else { return }
            self.onBulk?(action, self.selection)
        }
        review.bulkBar.onClear = { [weak self] in self?.setSelection([]) }
        let body = condense.body
        body.onGenerate = { [weak self] in self?.onGenerate?() }
        body.onCancelRun = { [weak self] in self?.onCancelRun?() }
        body.onApply = { [weak self] in self?.onApply?() }
        body.onRegenerate = { [weak self] in self?.onRegenerate?() }
        body.onDiscard = { [weak self] in self?.onDiscard?() }
        body.select.onAccount = { [weak self] id in self?.onCondenseAccount?(id) }
        body.select.onModel = { [weak self] name in self?.onCondenseModel?(name) }
        policy.body.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
    }

    // MARK: Model

    /// Shows `model`; see the type's note for what the page keeps.
    public func update(_ model: CleanupPageModel) {
        let old = self.model
        guard model != old else { return }
        self.model = model
        let ids = model.rows.map(\.id)
        if model.selected != old.selected { selection = model.selected }
        selection.formIntersection(ids)
        if let focused = focusedRowID, !ids.contains(focused) {
            // Keep the focus near where it was (the row after the removed one, else the last).
            let oldIndex = old.rows.firstIndex { $0.id == focused } ?? 0
            focusedRowID = ids.isEmpty ? nil : ids[min(oldIndex, ids.count - 1)]
        }
        apply(old: old)
    }

    private func apply(old: CleanupPageModel?) {
        metaRule.set(model.meta)
        for tab in review.tabStrip.tabs {
            tab.count = model.counts[tab.tab] ?? 0
            tab.isOn = tab.tab == model.tab
        }
        review.tabStrip.needsLayout = true
        if old?.rows != model.rows || old?.emptyText != model.emptyText {
            review.setRows(model.rows, emptyText: model.emptyText)
        }
        if let condenseModel = model.condense { condense.body.configure(condenseModel) }
        condense.isHidden = model.condense == nil
        policy.body.configure(model.policy)
        refreshSelection()
        needsLayout = true
    }

    private func refreshSelection() {
        for row in review.orderedRows {
            row.isSelected = selection.contains(row.row.id)
            row.isFocused = hasFocus && row.row.id == focusedRowID
        }
        review.header.set(selected: selection.count, total: model.rows.count)
        review.showsBulkBar = !selection.isEmpty
        review.bulkBar.configure(count: selection.count, disabled: model.bulkDisabled[model.tab] ?? [])
        needsLayout = true
    }

    private func setSelection(_ value: Set<String>) {
        let next = value.intersection(model.rows.map(\.id))
        guard next != selection else { return }
        selection = next
        refreshSelection()
        onSelection?(next)
    }

    private func toggle(_ id: String) {
        focusedRowID = id
        var next = selection
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        setSelection(next)
        refreshSelection()
    }

    /// Selects every row of the tab (⌘A, the header box).
    public func selectAllRows() { setSelection(Set(model.rows.map(\.id))) }

    @objc private func headerCheckboxPressed() {
        focusPage()
        if !model.rows.isEmpty, selection.count == model.rows.count { setSelection([]) } else { selectAllRows() }
        review.header.set(selected: selection.count, total: model.rows.count)
    }

    // MARK: Toast

    /// Shows a toast at the bottom of the page (`✻ 已建立「…」· 5 則原稿已封存 [UNDO]`,
    /// `AI 存取為 OFF 的筆記不會交給 Claude`); it leaves after `seconds`.
    public func showToast(_ text: String, undo: (@MainActor () -> Void)? = nil, seconds: Double = 6) {
        toast?.removeFromSuperview()
        let view = ToastView(text: text, undo: undo)
        addSubview(view)
        toast = view
        needsLayout = true
        view.dismiss(after: seconds)
    }

    // MARK: Layout

    /// The scrolled page's height at the current width.
    public var documentHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return contentHeight(width: scroll.contentSize.width)
    }

    /// Scrolls the page to `offset` (clamped).
    public func scroll(toOffset offset: CGFloat) {
        layoutSubtreeIfNeeded()
        let maxY = max(0, document.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, offset), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateSticky()
    }

    /// The current scroll offset.
    public var scrollOffset: CGFloat { scroll.contentView.bounds.minY }

    private struct Grid {
        var review: CGRect
        var condense: CGRect?
        var policy: CGRect
        var height: CGFloat
    }

    private func grid(width: CGFloat) -> Grid {
        let p = Self.padding
        let inner = max(0, width - p.left - p.right)
        let top = (p.top + Self.crumbHeight + kz(8) + TextMeasure.zoomed(Self.titleHeight) + kz(8) + TextMeasure.zoomed(Self.metaHeight)
            + kz(18)).rounded()
        var reviewRect: CGRect
        var condenseRect: CGRect?
        var y = top
        if model.condense != nil {
            let tableWidth = inner - Self.gridColumnGap - CondenseCardView.width
            if tableWidth >= Self.minimumTableWidth {
                let row = max(review.naturalHeight(width: tableWidth), condense.naturalHeight(width: CondenseCardView.width)).rounded(.up)
                reviewRect = CGRect(x: p.left, y: y, width: tableWidth, height: row)
                condenseRect = CGRect(x: p.left + tableWidth + Self.gridColumnGap, y: y, width: CondenseCardView.width, height: row)
                y += row
            } else {
                let reviewHeight = review.naturalHeight(width: inner).rounded(.up)
                reviewRect = CGRect(x: p.left, y: y, width: inner, height: reviewHeight)
                y += reviewHeight + Self.gridRowGap
                let condenseHeight = condense.naturalHeight(width: inner).rounded(.up)
                condenseRect = CGRect(x: p.left, y: y, width: inner, height: condenseHeight)
                y += condenseHeight
            }
        } else {
            let reviewHeight = review.naturalHeight(width: inner).rounded(.up)
            reviewRect = CGRect(x: p.left, y: y, width: inner, height: reviewHeight)
            y += reviewHeight
        }
        y += Self.gridRowGap
        let policyHeight = policy.naturalHeight(width: inner).rounded(.up)
        let policyRect = CGRect(x: p.left, y: y, width: inner, height: policyHeight)
        return Grid(review: reviewRect, condense: condenseRect, policy: policyRect, height: policyRect.maxY + p.bottom)
    }

    private func contentHeight(width: CGFloat) -> CGFloat { grid(width: width).height }

    override public func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        let grid = grid(width: width)
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(grid.height, scroll.contentSize.height))
        let p = Self.padding
        let inner = max(0, width - p.left - p.right)
        crumb.frame = CGRect(x: p.left, y: p.top, width: inner, height: Self.crumbHeight)
        let titleHeight = TextMeasure.zoomed(Self.titleHeight)
        titleLine.frame = CGRect(x: p.left, y: p.top + Self.crumbHeight + kz(8), width: inner, height: titleHeight).pixelAligned
        metaRule.frame = CGRect(x: p.left, y: titleLine.frame.minY + titleHeight + kz(8), width: inner,
                                height: TextMeasure.zoomed(Self.metaHeight)).pixelAligned
        review.frame = grid.review
        if let rect = grid.condense { condense.frame = rect }
        policy.frame = grid.policy
        if let toast {
            let size = ViewSnapshot.fittingSize(of: toast)
            let toastWidth = min(size.width, bounds.width - kz(48))
            toast.frame = CGRect(x: ((bounds.width - toastWidth) / 2).rounded(), y: bounds.height - kz(24) - size.height, width: toastWidth,
                                 height: size.height)
        }
        updateSticky()
    }

    @objc private func scrolled() { updateSticky() }

    /// Pins the bulk bar to the visible bottom while the table runs below it.
    private func updateSticky() {
        let visibleBottom = scroll.contentView.bounds.maxY - review.frame.minY
        review.visibleBottom = visibleBottom < review.frame.height ? visibleBottom : nil
    }

    // MARK: Keyboard

    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        hasFocus = true
        refreshSelection()
        return true
    }

    override public func resignFirstResponder() -> Bool {
        hasFocus = false
        refreshSelection()
        return true
    }

    /// Makes the page the first responder (a click on a row or the page background).
    func focusPage() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// Whether a key belongs to the page: it is the first responder and no field editor in its
    /// window is composing (注音 keeps space, ⌫ and esc while it has marked text).
    var keyboardIsOurs: Bool {
        guard let window else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        return window.firstResponder === self
    }

    override public func keyDown(with event: NSEvent) {
        if keyboardIsOurs, handleKey(event) { return }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a", keyboardIsOurs {
            selectAllRows()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The menu's Select All (⌘A) while the page is the first responder.
    override public func selectAll(_ sender: Any?) {
        guard keyboardIsOurs else { return }
        selectAllRows()
    }

    /// Space, ↑ ↓, ⌫ / ⌦, esc. Returns whether the key was the page's.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 49 where flags.isEmpty: // space
            guard let id = focusedRowID ?? model.rows.first?.id else { return true }
            toggle(id)
            return true
        case 125 where flags.isEmpty, 126 where flags.isEmpty: // ↓ ↑
            moveFocus(by: event.keyCode == 125 ? 1 : -1)
            return true
        case 51 where flags.isEmpty, 117 where flags.isEmpty: // ⌫ ⌦
            archiveSelection()
            return true
        case 53 where flags.isEmpty: // esc
            onBack?()
            return true
        default:
            return false
        }
    }

    private func moveFocus(by delta: Int) {
        let ids = model.rows.map(\.id)
        guard !ids.isEmpty else { return }
        let current = focusedRowID.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max(0, $0 + delta), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        focusedRowID = ids[next]
        refreshSelection()
        if let row = review.rowViews[ids[next]] {
            document.scrollToVisible(row.convert(row.bounds, to: document).insetBy(dx: 0, dy: -BulkBarView.height))
        }
    }

    /// ⌫: `封存` of the selection, unless the tab has no archive (`bulkDisabled`).
    private func archiveSelection() {
        guard !selection.isEmpty, model.isBulkEnabled(CleanupBulkAction.archive) else { return }
        onBulk?(CleanupBulkAction.archive, selection)
    }

    // MARK: Tests and diagnostics

    /// Every text drawn on the page, in view order (hidden views skipped).
    var visibleTexts: [String] {
        document.cleanupVisibleTexts() + (toast.flatMap { $0.superview == nil ? nil : $0.accessibilityLabel() }.map { [$0] } ?? [])
    }
}

/// The scrolled document; a click on its background focuses the page.
final class CleanupDocumentView: FlippedView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// `.nb-cl-crumb`: `← NOTEBOOK` (a link: --dim, amber on hover) `/` (--dimmer) `CLEANUP` (bone),
/// and at the right `ESC` (kbd) `返回筆記本`. 10.5 caps .16em, gap 8.
final class CrumbView: NSView {
    let back = CrumbLinkView("← Notebook")
    let slash = TextLine("/", style: CleanupStyles.crumb(Palette.dimmer))
    let current = TextLine("Cleanup", style: CleanupStyles.crumb(Palette.bone))
    let escKey: ChipBox
    let escText = TextLine("返回筆記本", style: TextStyle.mono(10.5, Palette.dim, tracking: 0.04))
    var onBack: (() -> Void)? { didSet { back.onClick = onBack } }

    override init(frame frameRect: NSRect) {
        var kbd = KbdView.style(.regular)
        kbd.text.uppercase = true
        escKey = ChipBox("esc", style: kbd)
        super.init(frame: frameRect)
        for view: NSView in [back, slash, current, escKey, escText] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("位置")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for line in [back.line, slash, current] {
            let width = ceil(line.textWidth)
            let frame = CGRect(x: x, y: 1, width: width, height: kz(16))
            if line === back.line { back.frame = frame } else { line.frame = frame }
            x += width + kz(8)
        }
        let textWidth = ceil(escText.textWidth)
        escText.frame = CGRect(x: bounds.width - textWidth, y: 1, width: textWidth, height: kz(16))
        let key = escKey.intrinsicContentSize
        escKey.frame = CGRect(x: escText.frame.minX - kz(8) - key.width, y: 0, width: key.width, height: kz(18))
    }
}

/// A crumb link: --dim text, amber while hovered; a click runs `onClick`.
final class CrumbLinkView: KeyFocusView, CleanupTextShowing {
    let line: TextLine
    private let text: String
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(_ text: String) {
        self.text = text
        line = TextLine(text, style: CleanupStyles.crumb(Palette.dim))
        super.init(frame: .zero)
        line.setAccessibilityElement(false)
        addSubview(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel("返回筆記本")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { line.displayedText }

    override func layout() {
        super.layout()
        line.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { line.set(text, style: CleanupStyles.crumb(Palette.amber)) }
    override func mouseExited(with event: NSEvent) { line.set(text, style: CleanupStyles.crumb(Palette.dim)) }
}
