import AppKit
import CoddUI

/// Dialog D · 結束 (StatusDialogs artboard D with D18): `結束 CODD？`, the running / needs
/// summary, the NEEDS YOU rows, four stacked choices (`全部停止並結束` danger, D18's `結束 · session
/// 繼續執行`, `保留在選單列（關閉視窗）` primary, `取消`), the `下次直接保留在選單列` checkbox and
/// the `設定 › 一般 › 結束時` footnote. 560 pt wide (the artboard grid's minimum cell): one column
/// of stacked buttons needs no more.
@MainActor
public final class QuitDialogView: DialogContentView, SecondTicking {
    public static let width: CGFloat = 560
    /// More NEEDS YOU rows than this scroll inside the panel.
    static let maxVisibleRows = 5

    public static let stopAllHint = "（外部 session 不受影響），下次開啟可 ⟲ 接續"
    public static let keepSessionsHint = "holder 會繼續執行；CODD 關閉期間不更新狀態、不通知，下次開啟自動接回"
    public static let menuBarHint = "session 繼續在背景執行，選單列圖示亮琥珀色提醒你"

    public private(set) var model: QuitModel
    private let onChoice: (QuitChoice, Bool) -> Void

    private let summary = Label.make(style: TextStyle.mono(12.5, Palette.bone))
    private let needsPanel = NeedsPanelView()
    private let stopHint = RichWrappingLabel()
    let stopAllButton = CoddButton("全部停止並結束", style: .bracket(.danger, small: false))
    let keepSessionsButton = CoddButton("結束 · session 繼續執行", style: .bracket(.normal, small: false))
    let menuBarButton = CoddButton("保留在選單列（關閉視窗）", style: .bracket(.primary, small: false))
    let cancelButton = CoddButton("取消", style: .bracket(.normal, small: false))
    private let checkbox = CheckboxButton(title: "下次直接保留在選單列", style: .plain)

    /// - Parameter onChoice: the choice (✕ / ⎋ / `取消` = `.cancel`, ⏎ = `.keepInMenuBar`) with the
    ///   `下次直接保留在選單列` checkbox.
    public init(model: QuitModel, onChoice: @escaping (QuitChoice, Bool) -> Void) {
        self.model = model
        self.onChoice = onChoice
        appliedKeep = model.keepNextTime
        super.init(width: Self.width, title: "Quit · 結束")
        build()
        apply(model, previous: nil)
    }

    private func build() {
        frameView.setHeader(chips: [KbdView("⌘Q")])

        let head = columnStack([Label.make("結束 CODD？", style: DialogText.question), summary], spacing: dz(6))

        for (button, action) in [(stopAllButton, #selector(stopAllClicked)), (keepSessionsButton, #selector(keepSessionsClicked)),
                                 (menuBarButton, #selector(menuBarClicked)), (cancelButton, #selector(cancelClicked))] {
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 34).zoomed(34).isActive = true
        }
        let choices = columnStack([
            choice(stopAllButton, hint: stopHint),
            choice(keepSessionsButton, hint: RichWrappingLabel(DialogText.hint.string(Self.keepSessionsHint, lineBreak: .byWordWrapping))),
            choice(menuBarButton, hint: RichWrappingLabel(DialogText.hint.string(Self.menuBarHint, lineBreak: .byWordWrapping))),
            cancelButton,
        ], spacing: dz(10))

        frameView.addBody([head, needsPanel, choices])

        checkbox.target = self
        checkbox.action = #selector(keepToggled)
        frameView.setFooter(leading: checkbox, trailingNote: "設定 › 一般 › 結束時")
    }

    /// `.sd-choice`: the full-width button and its hint (padding-left 2), gap 5.
    private func choice(_ button: CoddButton, hint: NSView) -> NSView {
        let hintBox = NSView()
        hintBox.addSubview(hint)
        hint.pinEdges(to: hintBox, insets: NSEdgeInsets(top: 0, left: dz(2), bottom: 0, right: 0))
        return columnStack([button, hintBox], spacing: dz(5))
    }

    /// The last `keepNextTime` the app passed: a new model overrides the checkbox only when this
    /// changes, so a refreshed row list never clears what the user ticked.
    private var appliedKeep: Bool

    /// Applies a new model; only the parts that changed are touched.
    public func update(_ next: QuitModel) {
        let previous = model
        var merged = next
        if next.keepNextTime != appliedKeep {
            appliedKeep = next.keepNextTime
        } else {
            merged.keepNextTime = previous.keepNextTime
        }
        model = merged
        apply(merged, previous: previous)
    }

    private func apply(_ m: QuitModel, previous p: QuitModel?) {
        if changed(p, m, \.running) || changed(p, m, \.needs) {
            summary.attributedStringValue = Self.summaryText(m)
        }
        if changed(p, m, \.rows) {
            needsPanel.set(m.rows, now: UITicker.shared.clock.now())
            needsPanel.isHidden = m.rows.isEmpty
        }
        if changed(p, m, \.stoppable) {
            stopHint.set(DialogText.hint.string("停止 CODD 啟動的 \(m.stoppable) 個 session" + Self.stopAllHint, lineBreak: .byWordWrapping))
        }
        if changed(p, m, \.keepNextTime) { checkbox.isOn = m.keepNextTime }
        if changed(p, m, \.rows.count) { fitWindow() }
        updateTicking()
    }

    /// `13 個 session 執行中 · ◆ 3 需要你` (the needs part amber, hidden at zero).
    static func summaryText(_ m: QuitModel) -> NSAttributedString {
        let normal = TextStyle.mono(12.5, Palette.bone)
        var parts: [(String, TextStyle)] = [("\(m.running)", normal), (" 個 session 執行中", normal)]
        if m.needs > 0 { parts += [(" · ", normal), ("◆ \(m.needs) 需要你", TextStyle.mono(12.5, Palette.amber))] }
        return DialogText.runs(parts, lineBreak: .byTruncatingTail)
    }

    private func choose(_ choice: QuitChoice) { onChoice(choice, model.keepNextTime) }

    /// A choice made from code (the app's DEBUG `-codd-quit-choice`, its tests): the checkbox is
    /// set first, then the same callback as a click.
    public func choose(_ choice: QuitChoice, keepNextTime: Bool) {
        if keepNextTime != model.keepNextTime {
            model.keepNextTime = keepNextTime
            checkbox.isOn = keepNextTime
        }
        onChoice(choice, model.keepNextTime)
    }

    // MARK: Ticking (the rows' durations)

    private var ticking = false

    private func updateTicking() {
        let want = window != nil && !model.rows.isEmpty
        if want, !ticking { ticking = true; UITicker.shared.addSecond(self) }
        if !want, ticking { ticking = false; UITicker.shared.removeSecond(self) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
    }

    public func secondTick(now: Date) { needsPanel.tick(now: now) }

    // MARK: Actions

    override var isPrimaryEnabled: Bool { true }
    override func performPrimary() { choose(.keepInMenuBar) }
    override func performCancel() { choose(.cancel) }

    @objc private func keepToggled() { model.keepNextTime = checkbox.isOn }
    @objc private func stopAllClicked() { choose(.stopAllAndQuit) }
    @objc private func keepSessionsClicked() { choose(.quitKeepingSessions) }
    @objc private func menuBarClicked() { choose(.keepInMenuBar) }
    @objc private func cancelClicked() { choose(.cancel) }

    // MARK: Testing

    var summaryString: String { summary.stringValue }
    var stopHintText: String { stopHint.attributedStringValue.string }
    var rowViews: [DialogSessionRowView] { needsPanel.rowViews }
    var needsPanelShown: Bool { !needsPanel.isHidden }
    var keepCheckbox: CheckboxButton { checkbox }
}

/// `.panel.sd-needs`: bg-soft, 1 px line-bright border, padding 3 / 0, the rows stacked; more than
/// `QuitDialogView.maxVisibleRows` rows scroll.
final class NeedsPanelView: PanelView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint?
    private(set) var rowViews: [DialogSessionRowView] = []

    init() {
        super.init(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let document = FlippedView()
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
        scroll.pinEdges(to: self, insets: NSEdgeInsets(top: dz(4), left: 1, bottom: dz(4), right: 1))
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let height = heightAnchor.constraint(equalToConstant: 8)
        height.isActive = true
        heightConstraint = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ rows: [DialogSessionRow], now: Date) {
        if rows.map(\.id) == rowViews.map(\.row.id) {
            for (view, row) in zip(rowViews, rows) { view.update(row, now: now) }
            return
        }
        for view in rowViews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rowViews = rows.map { DialogSessionRowView($0, now: now) }
        for view in rowViews { stack.addFullWidth(view) }
        let visible = min(rows.count, QuitDialogView.maxVisibleRows)
        heightConstraint?.constant = CGFloat(visible) * DialogSessionRowView.height + dz(8)
    }

    func tick(now: Date) {
        for view in rowViews { view.tick(now: now) }
    }
}
