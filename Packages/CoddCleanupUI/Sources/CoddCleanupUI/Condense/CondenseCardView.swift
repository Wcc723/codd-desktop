import AppKit
import CoddUI

/// The CONDENSE · PREVIEW card (`.card.hot.nb-cl-cond`, 344 px): `✻ CONDENSE … PREVIEW`, the big
/// `濃縮 5 則 → 1 則摘要`, the source list, the `帳號 / 模型 · Account` select with its hint,
/// `摘要預覽` + the note reference, the preview box (bottom fade), the cyan
/// `◇ 原稿會移到封存（不刪除），摘要連回原稿` note and the state's buttons. The card box and its
/// ASCII corners are CoddUI's `CardView`; the body is laid out here by frames.
final class CondenseCardView: NSView {
    static var width: CGFloat { kz(344) }
    static var padding: NSEdgeInsets { NSEdgeInsets(top: kz(16), left: kz(18), bottom: kz(16), right: kz(18)) }
    /// `.nb-cl-cond{gap:10px}`.
    static var gap: CGFloat { kz(10) }
    /// `.nb-cl-prev{min-height:120px}`; at rest the box shows up to the artboard's 264 px of
    /// summary and scrolls beyond (it grows further when the grid row is taller).
    static var previewMinHeight: CGFloat { kz(120) }
    static var previewMaxNaturalHeight: CGFloat { kz(264) }
    static let noteText = "原稿會移到封存（不刪除），摘要連回原稿"
    static let idleHint = "claude -p · 掛載 codd MCP"
    static let placeholder = "// 尚未產生摘要"

    let card = CardView(title: "", hot: true, padding: CondenseCardView.padding)
    let body = CondenseBodyView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        card.addSubview(body)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("交給 Claude 濃縮")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The card box height its content needs at `width`.
    func naturalHeight(width: CGFloat) -> CGFloat {
        2 + Self.padding.top + Self.padding.bottom + body.naturalHeight(width: width - 2 - Self.padding.left - Self.padding.right)
    }

    override func layout() {
        super.layout()
        // The card's frame keeps room for its corner glyphs above and below the box.
        card.frame = CGRect(x: 0, y: -CardView.outset, width: bounds.width, height: bounds.height + CardView.outset * 2)
        body.frame = CGRect(x: 1 + Self.padding.left, y: CardView.outset + 1 + Self.padding.top,
                            width: max(0, bounds.width - 2 - Self.padding.left - Self.padding.right),
                            height: max(0, bounds.height - 2 - Self.padding.top - Self.padding.bottom))
    }
}

/// The card's body (inside the padding); the preview box takes the height the body gets beyond
/// its natural height (`.nb-cl-prev{flex:1}`).
final class CondenseBodyView: NSView {
    private(set) var model: CondenseModel?

    let titleLine = TextLine("✻ Condense", style: TextStyle.cardTitle)
    let previewTag = TextLine("Preview", style: TextStyle.caps(10, Palette.dim, tracking: 0.12))
    let bigTitle = TextLine(style: TextStyle(font: Typeface.display(15), color: Palette.cream))
    let sources = SourceListView()
    let fieldLabel = TextLine("帳號 / 模型 · Account", style: TextStyle.fieldLabel)
    let select = CondenseSelectView()
    let accountHint = TextBlock(style: TextStyle.hint, lineHeight: CleanupStyles.hintLineHeight)
    let previewLabel = TextLine("摘要預覽", style: TextStyle.fieldLabel)
    let previewRef = TextLine(style: TextStyle.hint)
    let previewBox = PreviewBoxView()
    let note = CondenseNoteView(text: CondenseCardView.noteText)

    // State rows.
    let generate: ActionButton
    let idleHint = TextBlock(CondenseCardView.idleHint, style: TextStyle.hint, lineHeight: CleanupStyles.hintLineHeight)
    let runningLabel = TextLine(style: TextStyle.mono(11.5, Palette.bone))
    let cancel: ActionButton
    let apply: ActionButton
    let regenerate: ActionButton
    let discard: ActionButton
    let errorText = TextBlock(style: TextStyle.mono(11.5, Palette.bone), lineHeight: CleanupStyles.hintLineHeight)

    var onGenerate: (() -> Void)?
    var onCancelRun: (() -> Void)?
    var onApply: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onDiscard: (() -> Void)?

    override init(frame frameRect: NSRect) {
        generate = ActionButton("✻ 產生摘要", style: .bracket(.primary, small: false), accessibility: "產生摘要")
        cancel = ActionButton("取消", style: .bracket(.normal, small: false), accessibility: "取消產生")
        apply = ActionButton("建立摘要並封存原稿", style: .bracket(.primary, small: false))
        regenerate = ActionButton("重新產生", style: .bracket(.normal, small: false))
        discard = ActionButton("捨棄", style: .bracket(.normal, small: false), accessibility: "捨棄摘要")
        super.init(frame: frameRect)
        generate.run = { [weak self] in self?.onGenerate?() }
        cancel.run = { [weak self] in self?.onCancelRun?() }
        apply.run = { [weak self] in self?.onApply?() }
        regenerate.run = { [weak self] in self?.onRegenerate?() }
        discard.run = { [weak self] in self?.onDiscard?() }
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        previewTag.alignRight = true
        for view: NSView in [titleLine, previewTag, bigTitle, sources, fieldLabel, select, accountHint, previewLabel, previewRef,
                             previewBox, note, generate.button, idleHint, runningLabel, cancel.button, apply.button,
                             regenerate.button, discard.button, errorText] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Model

    func configure(_ model: CondenseModel) {
        guard model != self.model else { return }
        self.model = model
        bigTitle.set(attributed: Self.bigTitle(model.title))
        sources.sources = model.sources
        select.configure(model)
        accountHint.set(model.accountHint, style: TextStyle.hint)
        previewRef.set(model.previewRef, style: TextStyle.hint)
        previewBox.set(preview: model.preview, placeholder: CondenseCardView.placeholder)
        previewBox.setAccessibilityLabel("摘要預覽內容")

        let disabled = model.disabledReason != nil
        generate.button.isEnabled = !disabled
        generate.button.toolTip = model.disabledReason
        regenerate.button.isEnabled = !disabled
        regenerate.button.toolTip = model.disabledReason
        if let reason = model.disabledReason {
            idleHint.set(reason, style: TextStyle.hint.with(color: Palette.amberDim))
        } else {
            idleHint.set(CondenseCardView.idleHint, style: TextStyle.hint)
        }
        switch model.state {
        case .running(let elapsed):
            runningLabel.set(runs: [("◌ ", TextStyle.mono(11.5, Palette.amber)), ("產生中… \(elapsed)", TextStyle.mono(11.5, Palette.bone))])
        case .failed(let text):
            errorText.set(runs: [("[ERROR] ", TextStyle.caps(11.5, Palette.danger, tracking: 0.04, .medium)),
                                 (text, TextStyle.mono(11.5, Palette.bone))])
        case .idle, .preview:
            break
        }
        select.isEnabled = !isRunning
        needsLayout = true
    }

    private var isRunning: Bool { if case .running = model?.state { return true } else { return false } }

    /// `濃縮 5 則 → 1 則摘要`: the arrow amber with 10 px on each side (`.nb-cl-big{gap:10px}`).
    static func bigTitle(_ title: String) -> NSAttributedString {
        let base = TextStyle(font: Typeface.display(15), color: Palette.cream)
        let parts = title.components(separatedBy: "→")
        guard parts.count == 2 else { return base.string(title) }
        let out = NSMutableAttributedString()
        // A space kerned to exactly 10 px.
        let spaceWidth = Draw.width(base.string(" "))
        let gap = NSAttributedString(string: " ", attributes: base.attributes().merging([.kern: 10 - spaceWidth]) { $1 })
        out.append(base.string(parts[0].trimmingCharacters(in: .whitespaces)))
        out.append(gap)
        out.append(base.with(color: Palette.amber).string("→"))
        out.append(gap)
        out.append(base.string(parts[1].trimmingCharacters(in: .whitespaces)))
        return out
    }

    /// The views of the state's go row (`.nb-cl-go`), in order (tests, accessibility order).
    var stateViews: [NSView] {
        guard let model else { return [] }
        switch model.state {
        case .idle: return [generate.button, idleHint]
        case .running: return [runningLabel, cancel.button]
        case .preview: return [apply.button, regenerate.button, discard.button]
        case .failed: return [errorText, regenerate.button]
        }
    }

    // MARK: Layout

    private struct Plan {
        var frames: [ObjectIdentifier: CGRect] = [:]
        var height: CGFloat = 0
    }

    func naturalHeight(width: CGFloat) -> CGFloat { plan(width: width, height: nil).height }

    override func layout() {
        super.layout()
        // Views without a frame in the plan (other states' buttons, an empty hint) are hidden.
        let plan = plan(width: bounds.width, height: bounds.height)
        for view in subviews {
            if let frame = plan.frames[ObjectIdentifier(view)] {
                view.frame = frame
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        needsDisplay = true
    }

    /// Frames of every shown view at `width`; with `height` the preview box absorbs the extra.
    private func plan(width: CGFloat, height: CGFloat?) -> Plan {
        var plan = Plan()
        guard let model else { return plan }
        // Whole points: the select's and the boxes' 1 px borders stay crisp.
        func put(_ view: NSView, _ rect: CGRect) { plan.frames[ObjectIdentifier(view)] = rect.pixelAligned }
        let gap = CondenseCardView.gap
        var y: CGFloat = 0
        // `.card-h`: 18 px line, 6 px padding, the dashed rule.
        put(titleLine, CGRect(x: 0, y: 0, width: width * 0.7, height: kz(18)))
        put(previewTag, CGRect(x: width * 0.7, y: 0, width: width * 0.3, height: kz(18)))
        y = kz(25) + gap
        put(bigTitle, CGRect(x: 0, y: y, width: width, height: kz(22.5)))
        y += kz(22.5) + gap
        let listHeight = sources.preferredHeight
        put(sources, CGRect(x: 0, y: y, width: width, height: listHeight))
        y += listHeight + gap
        // `.field{gap:6px}`: label · select · hint.
        put(fieldLabel, CGRect(x: 0, y: y, width: width, height: kz(15.75)))
        y += kz(15.75) + kz(6)
        put(select, CGRect(x: 0, y: y, width: width, height: kz(30)))
        y += kz(30)
        if !model.accountHint.isEmpty {
            let hintHeight = accountHint.height(forWidth: width)
            put(accountHint, CGRect(x: 0, y: y + kz(6), width: width, height: hintHeight))
            y += kz(6) + hintHeight
        }
        y += gap
        // `.nb-cl-prevh{gap:8px}`.
        let labelWidth = previewLabel.textWidth
        put(previewLabel, CGRect(x: 0, y: y + kz(0.75), width: labelWidth, height: kz(15.75)))
        put(previewRef, CGRect(x: labelWidth + kz(8), y: y, width: max(0, width - labelWidth - kz(8)), height: kz(17.25)))
        y += kz(17.25) + gap
        let previewTop = y
        let content = previewBox.contentHeight(width: width)
        var previewHeight = max(CondenseCardView.previewMinHeight, min(content, CondenseCardView.previewMaxNaturalHeight))
        y += previewHeight + gap
        let noteHeight = note.height(forWidth: width)
        let noteTop = y
        y += noteHeight + gap
        let goTop = y
        var goFrames: [(NSView, CGRect)] = []
        var goHeight: CGFloat = kz(28)
        switch model.state {
        case .idle:
            // The hint next to the button when it fits (`.nb-cl-go{gap:10px}`), else wrapped below it
            // (a long `disabledReason`).
            let button = generate.button.intrinsicContentSize.width
            goFrames.append((generate.button, CGRect(x: 0, y: 0, width: button, height: kz(28))))
            let beside = max(0, width - button - kz(10))
            if Draw.width(idleHint.attributed) <= beside {
                goFrames.append((idleHint, CGRect(x: button + kz(10), y: kz(5.5), width: beside, height: TextMeasure.zoomed(CleanupStyles.hintLineHeight))))
            } else {
                let hintHeight = idleHint.height(forWidth: width)
                goFrames.append((idleHint, CGRect(x: 0, y: kz(28) + kz(6), width: width, height: hintHeight)))
                goHeight = kz(28) + kz(6) + hintHeight
            }
        case .running:
            let cancelWidth = cancel.button.intrinsicContentSize.width
            goFrames.append((runningLabel, CGRect(x: 0, y: kz(5), width: max(0, width - cancelWidth - kz(10)), height: kz(18))))
            goFrames.append((cancel.button, CGRect(x: min(runningLabel.textWidth + kz(10), width - cancelWidth), y: 0, width: cancelWidth, height: kz(28))))
        case .preview:
            // One line when the three fit (gap 10); else the primary alone and the other two below.
            let widths = [apply.button, regenerate.button, discard.button].map { $0.intrinsicContentSize.width }
            if widths.reduce(0, +) + 20 <= width {
                var x: CGFloat = 0
                for (button, buttonWidth) in zip([apply.button, regenerate.button, discard.button], widths) {
                    goFrames.append((button, CGRect(x: x, y: 0, width: buttonWidth, height: kz(28))))
                    x += buttonWidth + kz(10)
                }
            } else {
                goFrames.append((apply.button, CGRect(x: 0, y: 0, width: widths[0], height: kz(28))))
                goFrames.append((regenerate.button, CGRect(x: 0, y: kz(36), width: widths[1], height: kz(28))))
                goFrames.append((discard.button, CGRect(x: widths[1] + kz(10), y: kz(36), width: widths[2], height: kz(28))))
                goHeight = kz(64)
            }
        case .failed:
            let errorHeight = errorText.height(forWidth: width)
            goFrames.append((errorText, CGRect(x: 0, y: 0, width: width, height: errorHeight)))
            let button = regenerate.button.intrinsicContentSize.width
            goFrames.append((regenerate.button, CGRect(x: 0, y: errorHeight + kz(8), width: button, height: kz(28))))
            goHeight = errorHeight + kz(8) + kz(28)
        }
        y += goHeight
        if let height, height > y {
            previewHeight += height - y
            y = height
        }
        put(previewBox, CGRect(x: 0, y: previewTop, width: width, height: previewHeight).pixelAligned)
        let shift = previewTop + previewHeight + gap - noteTop
        put(note, CGRect(x: 0, y: noteTop + shift, width: width, height: noteHeight).pixelAligned)
        for (view, frame) in goFrames { put(view, frame.offsetBy(dx: 0, dy: goTop + shift).pixelAligned) }
        plan.height = (y).rounded(.up)
        return plan
    }

    override func draw(_ dirtyRect: NSRect) {
        // The card header's dashed rule (`.card-h{padding-bottom:6px;border-bottom:1px dashed}`).
        Draw.dashedLine(from: CGPoint(x: 0, y: kz(24)), to: CGPoint(x: bounds.width, y: kz(24)), color: Palette.lineBright)
    }
}

/// `.nb-cl-src`: the source notes, 20 px each (tag square · title · kind), dashed separators,
/// 1 px --line border on --bg.
final class SourceListView: NSView, CleanupTextShowing {
    static var rowHeight: CGFloat { kz(20) }

    var sources: [CondenseSource] = [] { didSet { if sources != oldValue { needsDisplay = true; setAccessibilityValue(sources.map(\.title).joined(separator: "、")) } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("來源筆記")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat { CGFloat(sources.count) * Self.rowHeight + 2 }

    /// `title KIND`, one source per line.
    var displayedText: String { sources.map { "\($0.title) \($0.kind.uppercased())" }.joined(separator: "\n") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.line)
        let kindStyle = TextStyle.caps(10, Palette.dim, tracking: 0.12)
        let titleStyle = TextStyle.mono(11.5, Palette.bone)
        for (index, source) in sources.enumerated() {
            let top = 1 + CGFloat(index) * Self.rowHeight
            let mid = top + Self.rowHeight / 2
            if index < sources.count - 1 {
                Draw.dashedLine(from: CGPoint(x: 1, y: top + Self.rowHeight - 1), to: CGPoint(x: bounds.width - 1, y: top + Self.rowHeight - 1),
                                color: Palette.line)
            }
            let square = CGRect(x: kz(9), y: (mid - kz(4)).rounded(), width: kz(8), height: kz(8))
            if let color = source.tagColor { Draw.fill(square, color) } else { Draw.dashedRect(square, color: Palette.dimmer, dash: [2, 1]) }
            let kind = kindStyle.string(source.kind)
            let kindWidth = Draw.width(kind)
            Draw.text(kind, x: bounds.width - kz(9) - kindWidth, centerY: mid)
            Draw.text(titleStyle.string(source.title), x: square.maxX + kz(8), centerY: mid, maxWidth: max(0, bounds.width - kz(9) - kindWidth - kz(8) - square.maxX - kz(8)))
        }
    }
}

/// `.nb-cl-note`: `◇` (cyan) and the wrapping text, `padding: 7px 10px`, 1 px --line-bright border
/// with a 2 px cyan left border, on --bg.
final class CondenseNoteView: NSView, CleanupTextShowing {
    private let text: TextBlock

    init(text value: String) {
        text = TextBlock(value, style: TextStyle.mono(11.5, Palette.bone), lineHeight: CleanupStyles.hintLineHeight)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { "◇ " + text.displayedText }

    /// The text's left edge: 2 px cyan border · 10 padding · `◇` · gap 8; 10 + 1 on the right.
    private static var textX: CGFloat { 2 + kz(10) + kz(7) + kz(8) }
    private static var textRight: CGFloat { kz(11) }

    func height(forWidth width: CGFloat) -> CGFloat {
        1 + kz(7) + text.height(forWidth: max(0, width - Self.textX - Self.textRight)) + kz(7) + 1
    }

    override func layout() {
        super.layout()
        text.frame = CGRect(x: Self.textX, y: kz(8), width: max(0, bounds.width - Self.textX - Self.textRight), height: max(0, bounds.height - kz(16)))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        Draw.fill(CGRect(x: 0, y: 0, width: kz(2), height: bounds.height), Palette.cyan)
        Draw.text(TextStyle.mono(11.5, Palette.cyan).string("◇"), x: kz(12), centerY: kz(8) + TextMeasure.zoomed(CleanupStyles.hintLineHeight) / 2)
    }

    override func accessibilityChildren() -> [Any]? { [] }
}
