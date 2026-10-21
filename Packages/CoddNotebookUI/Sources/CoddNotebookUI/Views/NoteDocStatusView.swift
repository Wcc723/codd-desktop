import AppKit
import CoddUI

/// The doc status bar (`.nb-docstat`, 22 pt): `LIVE PREVIEW · ⌘E 原始碼` (or `SOURCE · ⌘E 即時預覽`)
/// on the left, `Ln 14, Col 38 · Markdown · ● 已儲存 10:05` on the right (`● 未儲存` amber,
/// `◌ 儲存中…`). Clicking the mode part toggles the editor mode (⌘E is the app's menu item).
public final class NoteDocStatusView: NSView {
    public static var height: CGFloat { zp(22) }

    public private(set) var model: NoteDocStatusModel
    public var onToggleMode: (() -> Void)?

    let modeControl = DrawnControl()
    private let right = InlineLabel()

    public init(model: NoteDocStatusModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: zp(608), height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        modeControl.onClick = { [weak self] in self?.onToggleMode?() }
        modeControl.drawer = { [weak self] control, rect in self?.drawMode(control, rect) }
        right.alignment = .right
        right.gap = 8
        addSubview(modeControl)
        addSubview(right)
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: NoteDocStatusModel) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    private var modePieces: [InlinePiece] {
        let base = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06)
        return [
            .text(model.sourceMode ? "SOURCE" : "LIVE PREVIEW", TextStyle.mono(10.5, Palette.amberDim, tracking: 0.16)),
            .text("·", base),
            .text(model.sourceMode ? "⌘E 即時預覽" : "⌘E 原始碼", base),
        ]
    }

    /// The save state's text (`● 已儲存 10:05`).
    public var saveText: String {
        switch model.save {
        case .saved(let time): "● 已儲存 \(time)"
        case .unsaved: "● 未儲存"
        case .saving: "◌ 儲存中…"
        }
    }

    private func apply() {
        modeControl.texts = modePieces.compactMap(\.plain)
        modeControl.setAccessibilityLabel(model.sourceMode ? "原始碼模式，按 ⌘E 切到即時預覽" : "即時預覽，按 ⌘E 切到原始碼")
        modeControl.needsDisplay = true
        let base = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06)
        var pieces: [InlinePiece] = [.text(model.position, base), .text("·", base), .text(model.language, base), .text("·", base)]
        switch model.save {
        case .saved(let time):
            pieces.append(.text("●", TextStyle.mono(10.5, Palette.success)))
            pieces.append(.text("已儲存 \(time)", base, gapBefore: 4))
        case .unsaved:
            pieces.append(.text("● 未儲存", TextStyle.mono(10.5, Palette.amber, tracking: 0.06)))
        case .saving:
            pieces.append(.text("◌ 儲存中…", base))
        }
        right.set(pieces)
        setAccessibilityLabel((modePieces.compactMap(\.plain) + pieces.compactMap(\.plain)).joined(separator: " "))
        needsLayout = true
    }

    private func drawMode(_ control: DrawnControl, _ rect: CGRect) {
        var pieces = modePieces
        if control.isHot, case .text = pieces[2].content {
            pieces[2] = .text(model.sourceMode ? "⌘E 即時預覽" : "⌘E 原始碼", TextStyle.mono(10.5, Palette.amber, tracking: 0.06))
        }
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect, gap: 8))
    }

    public override func layout() {
        super.layout()
        let modeWidth = InlineLayout.width(modePieces, gap: 8)
        modeControl.frame = CGRect(x: zp(44), y: 0, width: modeWidth, height: bounds.height)
        let rightWidth = right.intrinsicContentSize.width
        right.frame = CGRect(x: max(modeControl.frame.maxX + zp(8), bounds.width - zp(14) - rightWidth), y: 0,
                             width: min(rightWidth, bounds.width - zp(14) - modeControl.frame.maxX - zp(8)), height: bounds.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.line)
    }

    var visibleTexts: [String] { notebookVisibleTexts() }
}

/// The prompt footer (`.nb-send`): `送到` + the target pill (lamp + title ▾, a menu of the live
/// sessions) + the dim `project · state duration` + `[插入引用] [插入全文] [送出 ⌘⏎]`. Without a
/// target (or with `disabledReason`) the buttons are disabled with the reason as tooltip.
public final class PromptFooterView: NSView {
    public static var height: CGFloat { zp(41) }

    public private(set) var model: PromptFooterModel
    public var onTarget: ((String) -> Void)?
    public var onInsertRef: (() -> Void)?
    public var onInsertFull: (() -> Void)?
    public var onSend: (() -> Void)?
    public var menuPresenter: NotebookMenuPresenting = PopoverMenuPresenter()

    private let label = InlineLabel()
    let targetPill = NotebookPillButton(.init(parts: []), small: false)
    private let detail = InlineLabel()
    let insertRefButton = CoddButton("插入引用", style: .bracket(.normal, small: true))
    let insertFullButton = CoddButton("插入全文", style: .bracket(.normal, small: true))
    let sendButton = CoddButton("送出 ⌘⏎", style: .bracket(.primary, small: true))
    private(set) var targetMenu: NotebookMenuView?

    public init(model: PromptFooterModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: zp(608), height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("送到 session")
        label.set([.text("送到", TextStyle.caps(10.5, Palette.dim, tracking: 0.16))])
        targetPill.onClick = { [weak self] in self?.openTargetMenu() }
        for (button, selector) in [(insertRefButton, #selector(insertRefClicked)), (insertFullButton, #selector(insertFullClicked)),
                                   (sendButton, #selector(sendClicked))] {
            button.target = self
            button.action = selector
        }
        for view in [label, targetPill, detail, insertRefButton, insertFullButton, sendButton] as [NSView] { addSubview(view) }
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: PromptFooterModel) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    /// The reason the three buttons are disabled (nil: enabled).
    public var actionsDisabledReason: String? {
        model.disabledReason ?? (model.target == nil ? NotebookCopy.noTargetReason : nil)
    }

    private func apply() {
        if let target = model.target {
            targetPill.content = .init(lamp: target.state, parts: [.name(target.title)])
            targetPill.setAccessibilityLabel("目標 session：\(target.title)")
            detail.set([.text(target.detail, TextStyle.mono(10.5, Palette.dimmer), shrink: true)])
        } else {
            targetPill.content = .init(parts: [.name("沒有 session")], tone: .dim)
            targetPill.setAccessibilityLabel("沒有可送出的 session")
            detail.set([])
        }
        targetPill.isEnabled = !model.targets.isEmpty
        let reason = actionsDisabledReason
        for button in [insertRefButton, insertFullButton, sendButton] {
            button.isEnabled = reason == nil
            button.toolTip = reason
        }
        if reason == nil, let sendReason = model.sendDisabledReason {
            sendButton.isEnabled = false
            sendButton.toolTip = sendReason
        }
        targetMenu?.update(targetMenuModel)
        needsLayout = true
    }

    @objc private func insertRefClicked() { onInsertRef?() }
    @objc private func insertFullClicked() { onInsertFull?() }
    @objc private func sendClicked() { onSend?() }

    /// The target menu's model (live sessions, the current one checked).
    public var targetMenuModel: NotebookMenuModel {
        NotebookMenuModel(entries: [.header("送到 session", trailing: nil)] + model.targets.map { target in
            .item(NotebookMenuItem(id: target.id, glyph: .lamp(target.state), title: target.title, detail: target.detail,
                                   isChecked: target.id == model.target?.id))
        }, initialHighlight: model.target?.id)
    }

    func openTargetMenu() {
        if targetMenu != nil { menuPresenter.dismiss(); return }
        guard !model.targets.isEmpty else { return }
        let menu = NotebookMenuView(model: targetMenuModel)
        menu.onActivate = { [weak self] item in
            guard let self else { return }
            self.menuPresenter.dismiss()
            self.onTarget?(item.id)
        }
        menu.onDismiss = { [weak self] in self?.menuPresenter.dismiss() }
        targetMenu = menu
        targetPill.isOn = true
        // Opens upward: the footer sits at the window's bottom edge.
        let size = menu.preferredSize
        let origin = CGPoint(x: targetPill.frame.minX, y: targetPill.frame.minY - zp(4) - size.height)
        menuPresenter.present(menu, at: origin, in: self) { [weak self] in
            self?.targetMenu = nil
            self?.targetPill.isOn = false
        }
    }

    public override func layout() {
        super.layout()
        let centerY = 1 + zp(8) + zp(12.0)
        func place(_ view: NSView, x: CGFloat, width: CGFloat? = nil) -> CGFloat {
            let size = view.intrinsicContentSize
            let w = width ?? size.width
            view.frame = CGRect(x: x, y: round(centerY - size.height / 2), width: max(0, w), height: size.height)
            return x + w
        }
        // A narrow footer (small window, zoom) keeps 送出 and the target pill (down to 80 pt);
        // 插入引用, 插入全文 and the 送到 label follow while they fit (both inserts are in SEND TO
        // SESSION too).
        let pillMinimum = min(targetPill.intrinsicContentSize.width, zp(80))
        let fixed = zp(16) + pillMinimum + zp(8) + sendButton.intrinsicContentSize.width + zp(12)
        let shown = RowFit.shown(available: bounds.width, fixed: fixed,
                                 costs: [insertRefButton, insertFullButton, label].map { $0.intrinsicContentSize.width + zp(8) })
        for (view, show) in zip([insertRefButton, insertFullButton, label] as [NSView], shown) where view.isHidden == show {
            view.isHidden = !show
        }
        var right = bounds.width - zp(12)
        for button in [sendButton, insertFullButton, insertRefButton] where !button.isHidden {
            let width = button.intrinsicContentSize.width
            right -= width
            _ = place(button, x: right)
            right -= zp(8)
        }
        var x: CGFloat = zp(16)
        if !label.isHidden { x = place(label, x: x) + zp(8) }
        let pillWidth = min(targetPill.intrinsicContentSize.width, max(pillMinimum, right - x - zp(8)))
        x = place(targetPill, x: x, width: pillWidth) + zp(8)
        _ = place(detail, x: x, width: max(0, min(detail.intrinsicContentSize.width, right - x)))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1), Palette.lineBright)
    }

    var visibleTexts: [String] { notebookVisibleTexts() }
}
