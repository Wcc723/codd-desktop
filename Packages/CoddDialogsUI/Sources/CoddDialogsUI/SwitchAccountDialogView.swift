import AppKit
import CoddUI

/// Dialog A · 切換帳號 (StatusDialogs artboard A): only when 設定 › 帳號 › 切換前確認 is ON (R3).
/// `切換到 #2 藍鵲？`, the from / to cards, the consequences, `同時暫停自動切換`, the D5 progress
/// line while cswap runs, an error line after a failure, `⏎ 切換 · ⎋ 取消`. 640 pt wide: the
/// artboard draws each dialog in a 644 pt grid cell ((1440 − 2 × 56 − 40) / 2); 640 is the
/// closest width of the 560–640 range and keeps the two cards' bars as long as drawn.
@MainActor
public final class SwitchAccountDialogView: DialogContentView, SecondTicking {
    public static let width: CGFloat = 640

    public private(set) var model: SwitchAccountModel
    private let onConfirm: (Bool) -> Void
    private let onCancel: () -> Void

    private let versionChip = ChipView("", style: DialogChipStyle.header(.plain))
    private let question = RichWrappingLabel()
    private let fromCard: AccountMiniCardView
    private let toCard: AccountMiniCardView
    private let list = DialogListView()
    private let checkbox = CheckboxButton(title: "同時暫停自動切換", hint: "AUTO-SWITCH 目前 OFF", style: .plain)
    private let progressBox = StatusLineBox(kind: .progress)
    private let errorBox = StatusLineBox(kind: .error)
    let cancelButton = CoddButton("取消", style: .bracket(.normal, small: false))
    let confirmButton = CoddButton("切換", style: .bracket(.primary, small: false))

    /// - Parameters:
    ///   - onConfirm: `切換` / ⏎, with the `同時暫停自動切換` checkbox.
    ///   - onCancel: ✕, ⎋ and `取消` alike.
    public init(model: SwitchAccountModel, onConfirm: @escaping (Bool) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        appliedPause = model.pauseAutoSwitch
        let now = UITicker.shared.clock.now()
        fromCard = AccountMiniCardView(role: .from, account: model.from, now: now)
        toCard = AccountMiniCardView(role: .to, account: model.to, now: now)
        super.init(width: Self.width, title: "Switch account · 切換帳號")
        build()
        apply(model, previous: nil)
    }

    private func build() {
        frameView.setHeader(chips: [versionChip])

        let arrow = NSTextField(labelWithAttributedString: {
            var style = TextStyle.mono(16, Palette.amber)
            style.shadow = Draw.glow(Palette.amberGlow, radius: 8)
            return style.string("→")
        }())
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        arrow.setAccessibilityElement(false)
        let swap = NSStackView(views: [fromCard, arrow, toCard])
        swap.orientation = .horizontal
        swap.alignment = .centerY
        swap.spacing = 10
        swap.distribution = .fill
        fromCard.widthAnchor.constraint(equalTo: toCard.widthAnchor).isActive = true

        let consequences = columnStack([Label.make("切換後", style: DialogText.section), list], spacing: dz(6))

        checkbox.target = self
        checkbox.action = #selector(pauseToggled)
        let checkRow = hStack([checkbox, spacer()], spacing: 0)

        frameView.addBody([question, swap, consequences, checkRow, progressBox, errorBox])

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        frameView.setFooter(note: "⏎ 切換 · ⎋ 取消", buttons: [cancelButton, confirmButton])
    }

    /// The last `pauseAutoSwitch` the app passed: a new model overrides the checkbox only when
    /// this changes, so a progress update never clears what the user ticked.
    private var appliedPause: Bool

    /// Applies a new model; only the parts that changed are touched.
    public func update(_ next: SwitchAccountModel) {
        let previous = model
        var merged = next
        if next.pauseAutoSwitch != appliedPause {
            appliedPause = next.pauseAutoSwitch
        } else {
            merged.pauseAutoSwitch = previous.pauseAutoSwitch
        }
        model = merged
        apply(merged, previous: previous)
    }

    private func apply(_ m: SwitchAccountModel, previous p: SwitchAccountModel?) {
        let now = UITicker.shared.clock.now()
        if changed(p, m, \.cswapVersion) {
            versionChip.set(m.cswapVersion ?? "")
            versionChip.isHidden = m.cswapVersion == nil
        }
        if changed(p, m, \.to.name) {
            question.set(DialogText.runs([("切換到 ", DialogText.question), (m.to.name, DialogText.question.with(color: Palette.cyan)),
                                          ("？", DialogText.question)]))
        }
        if changed(p, m, \.from) { fromCard.update(m.from, now: now) }
        if changed(p, m, \.to) { toCard.update(m.to, now: now) }
        if changed(p, m, \.followingCount) || changed(p, m, \.pinnedTitles) || changed(p, m, \.to.slot) {
            list.set(Self.consequences(m))
        }
        if changed(p, m, \.pauseAutoSwitch) { checkbox.isOn = m.pauseAutoSwitch }
        if changed(p, m, \.autoSwitchOn) { checkbox.hint = "AUTO-SWITCH 目前 \(m.autoSwitchOn ? "ON" : "OFF")" }
        if changed(p, m, \.progress) {
            progressBox.isHidden = m.progress == nil
            tickProgress(now: now)
        }
        if changed(p, m, \.error) {
            errorBox.isHidden = m.error == nil
            if let error = m.error { errorBox.set(DialogText.error("切換失敗：" + error)) }
        }
        let busy = m.progress != nil
        confirmButton.isEnabled = m.canConfirm
        checkbox.isEnabled = !busy
        if changed(p, m, \.progress) || changed(p, m, \.error) { fitWindow() }
        updateTicking()
    }

    /// `▸ 12 個跟隨全域登入的 session 約 30 秒內改用 #2` · `▸ 第一則訊息可能需要重建快取` ·
    /// `▸ 固定帳號的 session（…）不受影響` (faint glyph; only with pinned sessions).
    static func consequences(_ m: SwitchAccountModel) -> [DialogListView.Item] {
        let normal = DialogText.listItem
        let bold = DialogText.bold(12.5)
        var items: [DialogListView.Item] = []
        if m.followingCount > 0 {
            items.append(.init(text: DialogText.runs([("\(m.followingCount) 個", bold), ("跟隨全域登入的 session 約 ", normal),
                                                      ("30 秒", bold), ("內改用 \(m.to.slot)", normal)])))
        } else {
            items.append(.init(text: DialogText.runs([("目前沒有跟隨全域登入的 session；之後開的 session 會用 \(m.to.slot)", normal)])))
        }
        items.append(.init(text: normal.string("第一則訊息可能需要重建快取", lineBreak: .byWordWrapping)))
        if !m.pinnedTitles.isEmpty {
            let titles = m.pinnedTitles.joined(separator: "、")
            items.append(.init(text: normal.string("固定帳號的 session（\(titles)）不受影響", lineBreak: .byWordWrapping), faint: true))
        }
        return items
    }

    // MARK: Ticking (progress seconds, countdowns, source ages)

    private var ticking = false

    private var needsTicks: Bool {
        model.progress != nil || model.from.resetsAt != nil || model.from.sourceAt != nil
            || model.to.resetsAt != nil || model.to.sourceAt != nil
    }

    private func updateTicking() {
        let want = window != nil && needsTicks
        if want, !ticking { ticking = true; UITicker.shared.addSecond(self) }
        if !want, ticking { ticking = false; UITicker.shared.removeSecond(self) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
    }

    public func secondTick(now: Date) {
        fromCard.tick(now: now)
        toCard.tick(now: now)
        tickProgress(now: now)
    }

    private func tickProgress(now: Date) {
        guard let progress = model.progress else { return }
        let seconds = DurationFormat.compact(now.timeIntervalSince(progress.since))
        progressBox.set(DialogText.runs([
            (progress.label + " ", TextStyle.mono(12, Palette.bone)), (seconds, TextStyle.mono(12, Palette.bone)),
            ("（\(progress.attempt)/\(progress.of)）", TextStyle.mono(12, Palette.bone)),
        ]))
    }

    // MARK: Actions

    override var isPrimaryEnabled: Bool { confirmButton.isEnabled }
    override func performPrimary() { onConfirm(model.pauseAutoSwitch) }
    override func performCancel() { onCancel() }

    @objc private func pauseToggled() { model.pauseAutoSwitch = checkbox.isOn }
    @objc private func cancelClicked() { performCancel() }
    @objc private func confirmClicked() { if isPrimaryEnabled { performPrimary() } }

    // MARK: Testing

    var progressText: String? { progressBox.isHidden ? nil : progressBox.text }
    var errorText: String? { errorBox.isHidden ? nil : errorBox.text }
    var questionText: String { question.attributedStringValue.string }
    var consequenceTexts: [String] { list.texts }
    var consequenceRowViews: [NSView] { list.arrangedSubviews }
    var autoSwitchText: String { checkbox.hint ?? "" }
    var cards: (from: AccountMiniCardView, to: AccountMiniCardView) { (fromCard, toCard) }
    var pauseCheckbox: CheckboxButton { checkbox }
    var versionChipText: String? { versionChip.isHidden ? nil : model.cswapVersion }
}
