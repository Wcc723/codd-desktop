import AppKit
import CoddUI

/// Answer bar under the terminal while Claude is waiting (from CODD's KeyBar):
/// permission → `[1] Yes [2] Always [3] No [ESC] 取消 ⌘⏎`; question → `[1]…[n] [ESC]` (only `[ESC]`
/// and a note when its options are unknown).
/// Buttons only send keys; typing into the TUI stays with the terminal engine (IME rule).
final class AnswerBarView: PanelView {
    /// Called with the key name (`1`…`9`, `esc`).
    var onAnswer: ((String) -> Void)?

    private let lamp = LampView()
    private let message = Label.make(style: TextStyle.mono(12, Palette.cream))
    private let codeChip = ChipView("", style: ChipStyle(text: TextStyle.mono(12, Palette.amber), border: Palette.line, fill: Palette.bg,
                                                         height: 20, padding: 5))
    private let question = Label.make(style: TextStyle.mono(11.5, Palette.dim))
    private let keys = hStack([], spacing: 8)
    private let allowHint = ChipView.kbd("⌘⏎")
    private var configured: Configuration?
    private var row: NSStackView?
    /// What the configuration shows; `fitToWidth` hides what does not fit (narrow panes).
    private var wantsChip = false
    private var wantsQuestion = false
    private var wantsAllowHint = false
    /// The narrowest a truncated command chip or question line may get before it hides.
    private static var minimumFlexible: CGFloat { UIZoom.pt(80) }

    /// What the bar currently shows. The pane re-renders on any change of the session
    /// (cost, context…); the key buttons are rebuilt only when this changes, so a hover or a
    /// click in progress is never interrupted.
    private struct Configuration: Equatable {
        var reason: WaitingReason?
        var tool: String?
        var detail: String?
        var options: [String]
    }

    /// The current key buttons (tests).
    var keyButtons: [CoddButton] { keys.arrangedSubviews.compactMap { $0 as? CoddButton } }
    /// The message and the question line as shown (tests).
    var messageText: String { message.stringValue }
    var questionText: String { question.stringValue }

    init() {
        super.init(fill: nil, edges: [.top], edgeColor: Palette.amberDim)
        lamp.configure(StateStyle.of(.waiting))
        // A long command truncates (`…`) before anything else gives way.
        codeChip.truncates = true
        allowHint.setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
        let stack = hStack([lamp, message, codeChip, question, spacer(), keys, allowHint], spacing: 8,
                           edgeInsets: NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 12))
        addSubview(stack)
        stack.pinEdges(to: self)
        row = stack
        setAccessibilityRole(.group)
        setAccessibilityLabel("回應 Claude")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    /// Configures for a waiting session.
    func configure(reason: WaitingReason?, tool: String?, detail: String?, options: [String]) {
        let configuration = Configuration(reason: reason, tool: tool, detail: detail, options: options)
        guard configuration != configured else { return }
        configured = configuration
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if reason == .question {
            Label.set(message, "Claude 在問你 · 回答問題", style: TextStyle.mono(12, Palette.cream))
            wantsChip = false
            wantsQuestion = true
            // Without the question's options (they come only with its hook) the keys would be
            // guesses: `1 Yes 2 No` picked Claude's first and second option under wrong labels.
            let note = options.isEmpty ? "選項沒有收到 · 請在終端機裡選擇" : nil
            Label.set(question, [detail, note].compactMap { $0 }.joined(separator: " · "), style: TextStyle.mono(11.5, Palette.dim))
            for (i, label) in options.prefix(9).enumerated() { keys.addArrangedSubview(key("\(i + 1)", label)) }
            keys.addArrangedSubview(key("ESC", "取消", name: "esc"))
            wantsAllowHint = false
        } else {
            let showsChip = tool != nil || detail != nil
            let text = reason == .plan ? "Claude 等你核准計畫" : "Claude 需要授權"
            Label.set(message, showsChip ? text + " ·" : text, style: TextStyle.mono(12, Palette.cream))
            wantsChip = showsChip
            codeChip.set([tool, detail].compactMap { $0 }.joined(separator: ": "))
            wantsQuestion = false
            keys.addArrangedSubview(key("1", "Yes"))
            keys.addArrangedSubview(key("2", "Always"))
            keys.addArrangedSubview(key("3", "No", danger: true))
            keys.addArrangedSubview(key("ESC", "取消", name: "esc"))
            wantsAllowHint = true
        }
        fitToWidth()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToWidth()
    }

    /// Narrow panes (a small window, the interface zoom): the key buttons always show; then, while
    /// they fit, the command chip or question (truncated down to `minimumFlexible`), `⌘⏎` and the
    /// message. Only the width decides (`RowFit`), so dragging the window never flickers.
    private func fitToWidth() {
        guard let row else { return }
        let spacing = row.spacing
        // lamp · spacer · keys, with the spacing on both sides of the spacer.
        let fixed = row.edgeInsets.left + row.edgeInsets.right + lamp.intrinsicContentSize.width + spacing * 2
            + keys.fittingSize.width
        var pieces: [(view: NSView, cost: CGFloat)] = []
        if wantsChip { pieces.append((codeChip, min(codeChip.intrinsicContentSize.width, Self.minimumFlexible) + spacing)) }
        if wantsQuestion, !question.stringValue.isEmpty {
            pieces.append((question, min(question.intrinsicContentSize.width, Self.minimumFlexible) + spacing))
        }
        if wantsAllowHint { pieces.append((allowHint, allowHint.intrinsicContentSize.width + spacing)) }
        pieces.append((message, message.intrinsicContentSize.width + spacing))
        let shown = RowFit.shown(available: bounds.width, fixed: fixed, costs: pieces.map(\.cost))
        var visible = Set<ObjectIdentifier>()
        for (piece, show) in zip(pieces, shown) where show { visible.insert(ObjectIdentifier(piece.view)) }
        for view in [codeChip, question, allowHint, message] as [NSView] {
            let hidden = !visible.contains(ObjectIdentifier(view))
            if view.isHidden != hidden { view.isHidden = hidden }
        }
    }

    /// Whether the command chip, `⌘⏎` and the message show at the current width (tests).
    var shownOptionalParts: (chip: Bool, allowHint: Bool, message: Bool) {
        (!codeChip.isHidden, !allowHint.isHidden, !message.isHidden)
    }

    private func key(_ cap: String, _ label: String, name: String? = nil, danger: Bool = false) -> CoddButton {
        let button = CoddButton(label, style: .key(cap: cap, danger: danger), target: self, action: #selector(keyPressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(name ?? cap)
        button.setAccessibilityLabel("\(cap) \(label)")
        return button
    }

    @objc private func keyPressed(_ sender: CoddButton) {
        if let name = sender.identifier?.rawValue { onAnswer?(name) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.hGradient(bounds, from: Palette.amber.withAlphaComponent(0.10), to: Palette.amber.withAlphaComponent(0.02))
        Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1), Palette.amberDim)
    }
}
