import AppKit
import CoddUI

/// Dialog B · Hook 差異 (StatusDialogs artboard B, D10): `預覽 ~/.claude/settings.json 變更`, the
/// plan's summary lines, the event chips, the hooks / statusLine diff with foreign handlers
/// elided, `foreign hooks 保持不動：…`, the backup path, `只動 hooks 與 statusLine，其他 key 不碰`
/// and `[套用並備份]`. Nothing is written by this view; `onApply` asks the app to apply the plan
/// it previewed. 640 pt wide (artboard cell 644 pt): the diff lines need the width.
@MainActor
public final class HookDiffDialogView: DialogContentView {
    public static let width: CGFloat = 640
    /// The diff box scrolls beyond this height (the artboard shows 15 lines).
    static var maxDiffHeight: CGFloat { dz(340) }
    /// The diff box's one line when the plan changes nothing.
    public static let noChangesText = "// 沒有需要變更的地方：hooks 與 statusLine 已是最新"

    public private(set) var model: HookDiffModel
    private let onApply: () -> Void
    private let onCancel: () -> Void

    private let addedChip = ChipView("", style: DialogChipStyle.header(.ok))
    private let removedChip = ChipView("", style: DialogChipStyle.header(.bad))
    private let questionLead = NSTextField(labelWithString: "")
    private let pathChip = ChipView("", style: DialogChipStyle.questionCode)
    private let questionTail = NSTextField(labelWithString: "")
    private let summary = DialogListView()
    private let chipsRow = FlowChipsView()
    private let diff = DiffBoxView()
    private let foreignRow = KeyValueRow(label: "Foreign")
    private let backupRow = KeyValueRow(label: "Backup")
    private let errorBox = StatusLineBox(kind: .error)
    let cancelButton = CoddButton("取消", style: .bracket(.normal, small: false))
    let applyButton = CoddButton(HookDiffModel.defaultApplyTitle, style: .bracket(.primary, small: false))

    /// - Parameters:
    ///   - onApply: `套用並備份` / ⏎ (enabled only when `canApply` and the plan changes something).
    ///   - onCancel: ✕, ⎋ and `取消` alike.
    public init(model: HookDiffModel, onApply: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onApply = onApply
        self.onCancel = onCancel
        super.init(width: Self.width, title: model.dialogTitle)
        build()
        apply(model, previous: nil)
    }

    private func build() {
        frameView.setHeader(chips: [addedChip, removedChip])

        questionLead.attributedStringValue = DialogText.question.string("預覽")
        questionTail.attributedStringValue = DialogText.question.string("變更")
        let question = hStack([questionLead, pathChip, questionTail, spacer()], spacing: dz(8))
        // A long backup path ends in `…` inside the dialog instead of running past its edge.
        pathChip.truncates = true

        frameView.addBody([question, summary, chipsRow, diff, columnStack([foreignRow, backupRow], spacing: dz(6)), errorBox])

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        frameView.setFooter(note: model.footerNote, buttons: [cancelButton, applyButton])
    }

    /// Applies a new model; only the parts that changed are touched.
    public func update(_ next: HookDiffModel) {
        let previous = model
        model = next
        apply(next, previous: previous)
    }

    private func apply(_ m: HookDiffModel, previous p: HookDiffModel?) {
        if changed(p, m, \.added) {
            addedChip.set("+\(m.added)")
            addedChip.isHidden = m.added == 0
        }
        if changed(p, m, \.removed) {
            removedChip.set("−\(m.removed)")
            removedChip.isHidden = m.removed == 0
        }
        if changed(p, m, \.settingsPath) { pathChip.set(m.settingsPath) }
        if changed(p, m, \.summary) {
            summary.set(m.summary.map { .init(text: DialogText.listItem.string($0, lineBreak: .byWordWrapping)) })
            summary.isHidden = m.summary.isEmpty
        }
        if changed(p, m, \.chips) || changed(p, m, \.resolvedChipsLabel) {
            chipsRow.set(label: m.resolvedChipsLabel, chips: m.chips.map { ($0.text, DialogChipStyle.style($0.kind)) })
            chipsRow.isHidden = m.chips.isEmpty
        }
        if changed(p, m, \.lines) || changed(p, m, \.hasChanges) || changed(p, m, \.noChangesText) {
            diff.set(m.lines, emptyText: m.hasChanges ? nil : (m.noChangesText ?? Self.noChangesText))
        }
        if changed(p, m, \.foreignKept) || changed(p, m, \.foreignChanged) {
            foreignRow.set(m.foreignChanged.isEmpty ? Self.foreignText(m.foreignKept) : Self.foreignChangedText(m.foreignChanged))
            foreignRow.isHidden = m.foreignKept.isEmpty && m.foreignChanged.isEmpty
        }
        if changed(p, m, \.backupPath) {
            backupRow.setPath(m.backupPath)
            backupRow.isHidden = m.backupPath.isEmpty
        }
        if changed(p, m, \.error) {
            errorBox.isHidden = m.error == nil
            if let error = m.error { errorBox.set(DialogText.error(error)) }
        }
        if changed(p, m, \.applyTitle) { applyButton.label = m.applyTitle }
        applyButton.isEnabled = m.canConfirm
        if changed(p, m, \.lines.count) || changed(p, m, \.error) || changed(p, m, \.summary)
            || changed(p, m, \.chips.isEmpty) || changed(p, m, \.foreignKept.isEmpty) || changed(p, m, \.foreignChanged.isEmpty)
            || changed(p, m, \.backupPath.isEmpty) {
            fitWindow()
        }
    }

    /// `✓ foreign hooks 保持不動：hook-tap ×11 · osascript ×2` (each part bold).
    /// `◆ foreign hooks 會變動：移除 hook-tap ×2` (amber): a restore removes or adds other tools' hooks.
    static func foreignChangedText(_ changed: String) -> NSAttributedString {
        let normal = TextStyle.mono(12, Palette.bone)
        var parts: [(String, TextStyle)] = [("◆ ", TextStyle.mono(12, Palette.amber)), ("foreign hooks 會變動：", normal)]
        for (index, part) in changed.components(separatedBy: " · ").enumerated() {
            if index > 0 { parts.append((" · ", normal)) }
            parts.append((part, DialogText.bold(12)))
        }
        return DialogText.runs(parts, lineBreak: .byTruncatingTail)
    }

    static func foreignText(_ kept: String) -> NSAttributedString {
        let normal = TextStyle.mono(12, Palette.bone)
        var parts: [(String, TextStyle)] = [("✓ ", TextStyle.mono(12, Palette.success)), ("foreign hooks 保持不動：", normal)]
        for (index, part) in kept.components(separatedBy: " · ").enumerated() {
            if index > 0 { parts.append((" · ", normal)) }
            parts.append((part, DialogText.bold(12)))
        }
        return DialogText.runs(parts, lineBreak: .byTruncatingTail)
    }

    // MARK: Actions

    override var isPrimaryEnabled: Bool { applyButton.isEnabled }
    override func performPrimary() { onApply() }
    override func performCancel() { onCancel() }

    @objc private func cancelClicked() { performCancel() }
    @objc private func applyClicked() { if isPrimaryEnabled { performPrimary() } }

    // MARK: Testing

    var questionText: String { "\(questionLead.stringValue) \(model.settingsPath) \(questionTail.stringValue)" }
    var headerChipTexts: [String] {
        (addedChip.isHidden ? [] : ["+\(model.added)"]) + (removedChip.isHidden ? [] : ["−\(model.removed)"])
    }
    var summaryTexts: [String] { summary.isHidden ? [] : summary.texts }
    var chipsRowTexts: [String] { chipsRow.isHidden ? [] : [chipsRow.label] + chipsRow.chipTexts }
    var foreignText: String? { foreignRow.isHidden ? nil : foreignRow.valueText }
    var backupText: String? { backupRow.isHidden ? nil : backupRow.valueText }
    var errorText: String? { errorBox.isHidden ? nil : errorBox.text }
    var diffBox: DiffBoxView { diff }
}

/// `.sd-kv`: a 64 pt `.lbl` and a value (rich text or a `.path` chip), gap 10.
final class KeyValueRow: NSView {
    private let labelField: NSTextField
    private let value = NSTextField(labelWithString: "")
    private let pathChip = ChipView("", style: ChipStyle.path)

    init(label: String) {
        labelField = Label.make(label, style: DialogText.label)
        super.init(frame: .zero)
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The backup path ends in `…` at the dialog's edge (zoom 20) instead of drawing past it.
        pathChip.truncates = true
        pathChip.isHidden = true
        for view in [labelField, value, pathChip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.widthAnchor.constraint(equalToConstant: 64).zoomed(64),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: dz(10)),
            value.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathChip.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: dz(10)),
            pathChip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pathChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20).zoomed(20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var pathText = ""
    var valueText: String { pathChip.isHidden ? value.attributedStringValue.string : pathText }

    func set(_ text: NSAttributedString) {
        value.isHidden = false
        pathChip.isHidden = true
        if value.attributedStringValue != text { value.attributedStringValue = text }
    }

    func setPath(_ path: String) {
        value.isHidden = true
        pathChip.isHidden = false
        pathText = path
        pathChip.set(path)
    }
}

/// `.sd-chips`: a `.lbl` (margin-right 4) then chips, gap 6, wrapping onto more rows.
final class FlowChipsView: FlippedView {
    private(set) var label = ""
    private var chips: [(String, ChipStyle)] = []
    private static var rowHeight: CGFloat { dz(20) }
    private static var gap: CGFloat { dz(6) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var chipTexts: [String] { chips.map(\.0) }

    func set(label: String, chips: [(String, ChipStyle)]) {
        self.label = label
        self.chips = chips
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(([label] + chips.map(\.0)).joined(separator: " "))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var lastWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: lastWidth > 0 ? lastWidth : dz(600)))
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    /// Chip origins for `width` (row by row).
    private func positions(for width: CGFloat) -> (label: CGFloat, chips: [CGPoint]) {
        let labelWidth = Draw.width(DialogText.label.string(label)) + dz(4)
        var x = labelWidth + Self.gap
        var y: CGFloat = 0
        var points: [CGPoint] = []
        for (text, style) in chips {
            let w = style.size(for: text).width
            if x + w > width, x > 0, !points.isEmpty || x > labelWidth + Self.gap {
                x = 0
                y += Self.rowHeight + Self.gap
            }
            points.append(CGPoint(x: x, y: y))
            x += w + Self.gap
        }
        return (labelWidth, points)
    }

    private func height(for width: CGFloat) -> CGFloat {
        let last = positions(for: width).chips.last?.y ?? 0
        return last + Self.rowHeight
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = positions(for: bounds.width)
        Draw.text(DialogText.label.string(label), x: 0, centerY: Self.rowHeight / 2)
        for ((text, style), point) in zip(chips, layout.chips) {
            style.draw(text, x: point.x, centerY: point.y + Self.rowHeight / 2)
        }
    }
}
