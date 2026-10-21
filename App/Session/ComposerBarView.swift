import AppKit
import CoddComposer
import CoddUI

/// The ⌘L composer bar between the tab strip's terminal and the ⌘J splitter (Split artboard
/// `.composer.sp-composer`): the field in its `.ta` box (amber-dim border and inset glow while
/// focused), the hint row `Enter 送出 · ⇧Enter 換行 · 貼上圖片會存成檔案路徑` … `Claude 工作中 ·
/// 送出後排入佇列` `⌘L`, and `[SEND]` on the right. Frames are set by hand; the bar's height
/// follows the field (1…8 lines), and `onHeightChange` tells the terminal area.
final class ComposerBarView: PanelView, ZoomRefreshing {
    let field: ComposerField
    let sendButton = CoddButton(ComposerBarView.sendLabel, style: .bracket(.primary, small: false))
    private let box = ComposerBoxView()
    private let hint = Label.make("Enter 送出 · ⇧Enter 換行 · 貼上圖片會存成檔案路徑", style: ComposerBarView.hintStyle)
    private let status = Label.make(style: ComposerBarView.hintStyle)
    private let kbd = ChipView.kbd("⌘L")
    /// The bar's height changed (the field grew or shrank).
    var onHeightChange: ((CGFloat) -> Void)?
    /// `[SEND]` was clicked.
    var onSend: (() -> Void)?
    private(set) var preferredHeight: CGFloat = 0

    /// What the hint row says on the right before `⌘L`.
    enum Status: Equatable {
        case none
        /// `Claude 工作中 · 送出後排入佇列`.
        case busy
        /// `session 沒有在執行` (the field is read-only, SEND disabled).
        case notRunning
        /// Claude shows a permission / plan / question prompt: Enter would answer it, so SEND is
        /// disabled and the field keeps the draft (review security-data-1).
        case awaitingAnswer
        /// The text is over 256 KiB (D2).
        case tooLong(Int)
    }

    private(set) var currentStatus = Status.none

    // Metrics in design points at the current interface zoom (M4).
    static var padding: NSEdgeInsets { UIZoom.insets(NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)) }
    static var minimumBoxHeight: CGFloat { UIZoom.pt(40) }
    static var hintRowHeight: CGFloat { UIZoom.pt(17) }
    static var rowGap: CGFloat { UIZoom.pt(5) }
    static var buttonGap: CGFloat { UIZoom.pt(8) }
    /// Field inside the box: 1 px border + the 1 px inset glow ring.
    static let boxInset: CGFloat = 2
    static let hintStyle = TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02)
    static let claudePlaceholder = "給 Claude 的訊息（⌘L）"
    static let shellPlaceholder = "輸入要送到 shell 的文字（⌘L）"
    static let busyText = "Claude 工作中 · 送出後排入佇列"
    static let notRunningText = "session 沒有在執行"
    static let awaitingAnswerText = "Claude 在等你確認 · 先用下方按鍵回答"

    /// The helmet `.composer .ta` look in CODD's own fonts: JetBrains Mono 12.5 on #050505,
    /// line height 1.5 (19 pt), padding 8 / 10 (minus the 2 pt the box draws), amber caret.
    /// M4 I2b: `codd://note/<id>` draws as the Split artboard's amber `.sp-ref` chip (C4; the text
    /// and what is sent stay plain).
    /// At the current interface zoom (font, insets and line height follow it).
    @MainActor static var style: ComposerStyle {
        ComposerStyle(font: Typeface.mono(12.5), textColor: Palette.cream, placeholderColor: Palette.dimmer,
                      caretColor: Palette.amber, markedTextColor: Palette.amber, background: Palette.bg,
                      insets: UIZoom.insets(NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)), minLines: 1, maxLines: 8,
                      lineHeight: UIZoom.pt(19), selectionBackground: Palette.amber, selectionTextColor: .black, referenceChips: true)
    }

    /// M4 interface zoom: the field takes the style at the new zoom (never while an input method
    /// composes: then once the composition is over), and the bar measures itself again.
    func zoomDidChange() {
        guard !field.textView.hasMarkedText() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.zoomDidChange() }
            return
        }
        field.apply(Self.style)
        updatePreferredHeight()
        needsLayout = true
    }

    /// The composer styles its own text (the generic refresh leaves its storage alone).
    var zoomRescalesTextViews: Bool { false }

    init() {
        field = ComposerField(style: Self.style)
        super.init(fill: Palette.bgSoft, edges: [.top], edgeColor: Palette.line)
        for view in [box, hint, status, kbd, sendButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        field.translatesAutoresizingMaskIntoConstraints = true
        box.addSubview(field)
        field.textView.placeholder = Self.claudePlaceholder
        field.textView.setAccessibilityLabel(Self.claudePlaceholder)
        field.onHeightChange = { [weak self] _ in self?.updatePreferredHeight() }
        field.textView.onFocusChange = { [weak self] focused in self?.box.isFocused = focused }
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.setAccessibilityLabel("送出")
        status.alignment = .right
        setAccessibilityRole(.group)
        setAccessibilityLabel("Composer")
        updatePreferredHeight()
    }

    var textView: ComposerTextView { field.textView }

    /// The composer's text view is the window's first responder.
    var hasFocus: Bool { window?.firstResponder === field.textView }

    func focus() { field.focus() }

    /// Placeholder for the target: claude's prompt or a shell (§3 copy).
    func setPlaceholder(shell: Bool) {
        let text = shell ? Self.shellPlaceholder : Self.claudePlaceholder
        guard field.textView.placeholder != text else { return }
        field.textView.placeholder = text
        field.textView.setAccessibilityLabel(text)
    }

    /// Busy / not running / too long; not running also makes the field read-only.
    func setStatus(_ next: Status) {
        guard next != currentStatus else { return }
        currentStatus = next
        let live = next != .notRunning
        field.textView.isEditable = live
        sendButton.isEnabled = live && next != .awaitingAnswer
        box.alphaValue = live ? 1 : 0.55
        switch next {
        case .none: Label.set(status, "", style: Self.hintStyle)
        case .busy: Label.set(status, Self.busyText, style: Self.hintStyle)
        case .notRunning: Label.set(status, Self.notRunningText, style: Self.hintStyle)
        case .awaitingAnswer: Label.set(status, Self.awaitingAnswerText, style: TextStyle.mono(11.5, Palette.amber, tracking: 0.02))
        case .tooLong(let bytes):
            Label.set(status, "超過 256 KB，沒有送出（\(bytes / 1024) KB）", style: TextStyle.mono(11.5, Palette.danger, tracking: 0.02))
        }
        needsLayout = true
    }

    var statusText: String { status.stringValue }

    private var boxHeight: CGFloat {
        max(Self.minimumBoxHeight, field.preferredHeight + Self.boxInset * 2)
    }

    private func updatePreferredHeight() {
        let height = Self.padding.top + boxHeight + Self.rowGap + Self.hintRowHeight + Self.padding.bottom
        guard height != preferredHeight else { return }
        preferredHeight = height
        needsLayout = true
        onHeightChange?(height)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }

    override func layout() {
        super.layout()
        layoutChildren()
    }

    private func layoutChildren() {
        let b = bounds
        let pad = Self.padding
        // A narrow composer (the notes drawer open at zoom 20 in a small window) shows `[ ⏎ ]`
        // instead of `[ SEND ]` when the field would get less than 200 pt beside the full button.
        let compact = Self.usesCompactSend(width: b.width, fullButton: sendMeasure.intrinsicContentSize.width + UIZoom.pt(8))
        let label = compact ? Self.compactSendLabel : Self.sendLabel
        if sendButton.label != label { sendButton.label = label }
        let buttonWidth = sendButton.intrinsicContentSize.width + UIZoom.pt(8)
        sendButton.frame = CGRect(x: b.width - pad.right - buttonWidth, y: pad.top, width: buttonWidth, height: Self.minimumBoxHeight)
        let wrapWidth = max(40, sendButton.frame.minX - Self.buttonGap - pad.left)
        box.frame = CGRect(x: pad.left, y: pad.top, width: wrapWidth, height: boxHeight)
        field.frame = box.bounds.insetBy(dx: Self.boxInset, dy: Self.boxInset)
        let rowY = box.frame.maxY + Self.rowGap
        let kbdSize = kbd.intrinsicContentSize
        kbd.frame = CGRect(x: box.frame.maxX - kbdSize.width, y: rowY + (Self.hintRowHeight - kbdSize.height) / 2,
                           width: kbdSize.width, height: kbdSize.height)
        let gap = UIZoom.pt(10)
        let statusNatural = Draw.width(status.attributedStringValue) + 2
        // A narrow composer (small window, zoom): the key hint only shows with room for its first
        // 120 pt; otherwise it hides and the session's status line gets the whole row.
        let room = max(0, kbd.frame.minX - gap - pad.left)
        let hintRoom = room - min(statusNatural, max(0, wrapWidth * 0.55)) - gap
        let showsHint = hintRoom >= min(Draw.width(hint.attributedStringValue), UIZoom.pt(120))
        if hint.isHidden == showsHint { hint.isHidden = !showsHint }
        let statusWidth = min(statusNatural, showsHint ? max(0, wrapWidth * 0.55) : room)
        status.frame = CGRect(x: kbd.frame.minX - gap - statusWidth, y: rowY, width: statusWidth, height: Self.hintRowHeight)
        hint.frame = CGRect(x: pad.left, y: rowY, width: max(0, status.frame.minX - gap - pad.left), height: Self.hintRowHeight)
    }

    static let sendLabel = "Send"
    static let compactSendLabel = "⏎"
    /// Measures the full `[ SEND ]` at the current zoom (never shown).
    private let sendMeasure = CoddButton(ComposerBarView.sendLabel, style: .bracket(.primary, small: false))

    /// Whether a composer `width` wide uses the compact send button (only the width decides).
    static func usesCompactSend(width: CGFloat, fullButton: CGFloat) -> Bool {
        width - padding.left - padding.right - fullButton - buttonGap < UIZoom.pt(200)
    }

    @objc private func sendPressed() { onSend?() }
}

/// The `.ta` box: #050505, 1 px line-bright border; focused: amber-dim border plus the 1 px
/// inset glow `rgba(255,184,74,.25)` (Split artboard `.sp-ta`).
final class ComposerBoxView: PanelView {
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }

    init() {
        super.init(fill: Palette.bg)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        if isFocused {
            Draw.strokeRect(bounds, color: Palette.amberDim)
            Draw.strokeRect(bounds.insetBy(dx: 1, dy: 1), color: Palette.amber.withAlphaComponent(0.25))
        } else {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
    }
}
