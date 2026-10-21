import AppKit
import CoddOnboarding
import CoddUI

/// `.ob-head`: kicker (10.5 caps .18em --amber-dim), `.h-page` title, lead (13 --bone, max 820,
/// bold numbers --cream, `code` amber).
final class StepHeadView: NSView {
    let kicker = TextLine()
    let title = TextLine()
    let lead = RichTextView(look: RichLook(size: 13, color: Palette.bone, lineHeight: 13 * 1.5))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(kicker)
        addSubview(title)
        addSubview(lead)
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("標題")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(step: OnboardingStep, lead markup: String) {
        kicker.set(step.kicker, style: TextStyle.caps(10.5, Palette.amberDim, tracking: 0.18))
        title.set(step.title, style: TextStyle.pageTitle)
        title.setAccessibilityLabel(step.title)
        lead.set(markup)
        needsLayout = true
    }

    private var kickerHeight: CGFloat { ceil(UIZoom.scaled(10.5 * 1.5)) }
    private var titleHeight: CGFloat { ceil(UIZoom.scaled(26 * 1.2)) }
    private func leadWidth(_ width: CGFloat) -> CGFloat { min(width, dz(820)) }

    func height(forWidth width: CGFloat) -> CGFloat {
        kickerHeight + dz(7) + titleHeight + dz(7) + lead.height(forWidth: leadWidth(width))
    }

    override func layout() {
        super.layout()
        kicker.place(CGRect(x: 0, y: 0, width: bounds.width, height: kickerHeight))
        title.place(CGRect(x: 0, y: kickerHeight + dz(7), width: bounds.width, height: titleHeight))
        let width = leadWidth(bounds.width)
        lead.place(CGRect(x: 0, y: title.frame.maxY + dz(7), width: width, height: lead.height(forWidth: width)))
    }
}

/// `.ob-foot`: 60 px, dashed --line-bright top rule, --bg-soft, padding 0 40, gap 10:
/// `[← 上一步]` `[略過]` · spacer · the summary · the primary · `⏎`.
final class FooterBarView: NSView {
    let back = PressButton("← 上一步", style: .bracket(.normal, small: false), accessibility: "上一步")
    let skip = PressButton("略過", style: .bracket(.normal, small: false))
    let primary = PressButton("下一步", style: .bracket(.primary, small: false))
    let summary = TextLine()
    let kbd = KbdView("⏎")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [back.button, skip.button, summary, primary.button, kbd] { addSubview(view) }
        kbd.setAccessibilityLabel("Return 鍵")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    static var height: CGFloat { dz(60) }

    private var summaryText = ""
    private var summaryFaint: String?
    private var showsFaint = true

    func apply(step: OnboardingStep, summary text: String, faint: String?) {
        back.button.isEnabled = step != .detect
        let label = step.next.map { "下一步：\($0.title) →" } ?? "開始使用 →"
        primary.button.label = label
        primary.button.setAccessibilityLabel(step.next.map { "下一步：\($0.title)" } ?? "開始使用")
        summaryText = text
        summaryFaint = faint
        showsFaint = true
        summary.set { Self.summaryRuns(text, faint: faint) }
        summary.setAccessibilityLabel(Markup.plain(text) + (faint ?? ""))
        needsLayout = true
    }

    /// `.ob-sum`: 12 --bone, numbers bold --cream (600), the faint tail --dimmer.
    static func summaryRuns(_ text: String, faint: String?) -> NSAttributedString {
        let base = TextStyle.mono(12, Palette.bone)
        let bold = TextStyle.mono(12, Palette.cream, .semibold)
        let out = NSMutableAttributedString()
        var run = ""
        var digits = false
        func flush() {
            guard !run.isEmpty else { return }
            out.append((digits ? bold : base).string(run))
            run = ""
        }
        for character in text {
            let isDigit = character.isASCII && character.isNumber
            if isDigit != digits { flush(); digits = isDigit }
            run.append(character)
        }
        flush()
        if let faint { out.append(TextStyle.mono(12, Palette.dimmer).string(faint)) }
        return out
    }

    override func layout() {
        super.layout()
        let gap = dz(10)
        let mid = bounds.height / 2
        func put(_ view: NSView, x: CGFloat) -> CGRect {
            let size = view.intrinsicContentSize
            let rect = CGRect(x: x, y: mid - size.height / 2, width: size.width, height: size.height)
            view.place(rect)
            return view.frame
        }
        let backFrame = put(back.button, x: dz(40))
        let skipFrame = put(skip.button, x: backFrame.maxX + gap)
        let kbdSize = kbd.intrinsicContentSize
        let kbdFrame = CGRect(x: bounds.width - dz(40) - kbdSize.width, y: mid - kbdSize.height / 2, width: kbdSize.width, height: kbdSize.height)
        kbd.place(kbdFrame)
        let primarySize = primary.button.intrinsicContentSize
        primary.button.place(CGRect(x: kbdFrame.minX - gap - primarySize.width, y: mid - primarySize.height / 2,
                                    width: primarySize.width, height: primarySize.height))
        let available = max(0, primary.button.frame.minX - gap - (skipFrame.maxX + gap))
        // A narrow window (1011 px) drops the faint tail whole rather than cutting the summary.
        let fits = summaryFaint == nil || Draw.width(Self.summaryRuns(summaryText, faint: summaryFaint)) <= available
        if fits != showsFaint {
            showsFaint = fits
            let text = summaryText
            let faint = fits ? summaryFaint : nil
            summary.set { Self.summaryRuns(text, faint: faint) }
        }
        let width = min(summary.textWidth, available)
        summary.place(CGRect(x: primary.button.frame.minX - gap - width, y: mid - dz(10), width: width, height: dz(20)))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright)
    }
}
