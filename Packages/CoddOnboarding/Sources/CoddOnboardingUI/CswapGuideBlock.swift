import AppKit
import CoddOnboarding
import CoddUI

/// FB 「引導安裝 cswap」 on step 5, under the cswap note: a dashed `.sx-info` box with `INSTALL
/// cswap · claude-swap` and the project link, the lead, each command in a code box with `[複製]` (the
/// first also `[在終端機執行]`), the uv hint, the note and `[↻ 重新偵測]`. A command row too narrow
/// for its buttons puts them under the command.
final class CswapGuideBlock: NSView {
    private let title = TextLine()
    private let link = TextLine()
    private let lead = RichTextView(look: RichLook(size: 12.5, color: Palette.bone, lineHeight: 12.5 * 1.5))
    private let uvHint = TextLine()
    private let note = RichTextView(look: RichLook(size: 11.5, color: Palette.dimmer, lineHeight: 11.5 * 1.5))
    let redetect = PressButton("↻ 重新偵測", style: .bracket(.normal, small: true), accessibility: "重新偵測 cswap")
    private(set) var rows: [(command: String, code: RichTextView, copy: PressButton, run: PressButton?)] = []
    private(set) var guide: OnboardingCswapGuide?
    var onCopy: (String) -> Void = { _ in }
    var onRun: (String) -> Void = { _ in }

    private var pad: CGFloat { dz(14) }
    private var lineHeight: CGFloat { dz(18) }
    private var buttonHeight: CGFloat { dz(24) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        link.alignment = .right
        link.set(OnboardingCswapGuide.projectURL.replacingOccurrences(of: "https://", with: ""), style: TextStyle.hint)
        uvHint.set(OnboardingCswapGuide.uvHint, style: TextStyle.hint)
        note.set(OnboardingCswapGuide.note)
        for view: NSView in [title, link, lead, uvHint, note, redetect.button] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("安裝 cswap")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(_ guide: OnboardingCswapGuide) {
        guard guide != self.guide else { return }
        self.guide = guide
        title.set { runs([(guide.label, TextStyle.caps(10.5, Palette.amber, tracking: 0.16)),
                          ("  cswap · claude-swap", TextStyle.mono(11.5, Palette.cream))]) }
        lead.set(guide.lead)
        uvHint.isHidden = guide.uvCommands.isEmpty
        for row in rows {
            row.code.removeFromSuperview()
            row.copy.button.removeFromSuperview()
            row.run?.button.removeFromSuperview()
        }
        rows = guide.commands.enumerated().map { index, command in
            let code = RichTextView("`\(command)`", look: RichLook(size: 12, color: Palette.amber, lineHeight: 18))
            code.setAccessibilityLabel(command)
            let copy = PressButton("複製", style: .bracket(.normal, small: true), accessibility: "複製 \(command)")
            copy.run = { [weak self] in self?.onCopy(command) }
            var run: PressButton?
            if index == 0 {
                let button = PressButton("在終端機執行", style: .bracket(.accent, small: true),
                                         accessibility: "在終端機打好 \(command)（按 Return 才會執行）")
                button.run = { [weak self] in self?.onRun(command) }
                run = button
            }
            for view in [code, copy.button, run?.button].compactMap({ $0 }) { addSubview(view) }
            return (command, code, copy, run)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// The guide's buttons in reading order (step 5's key views).
    var buttons: [NSView] { rows.flatMap { [$0.copy.button] + ($0.run.map { [$0.button] } ?? []) } + [redetect.button] }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = [title, lead]
        for row in rows {
            children.append(row.code)
            children.append(row.copy.button)
            if let run = row.run { children.append(run.button) }
        }
        if !uvHint.isHidden { children.append(uvHint) }
        children.append(note)
        children.append(redetect.button)
        return children
    }

    func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let x = pad
        let inner = max(0, width - pad * 2)
        var y = dz(12)
        if apply {
            let linkWidth = min(link.textWidth, max(0, inner - title.textWidth - dz(16)))
            link.isHidden = linkWidth < dz(60)
            link.place(CGRect(x: x + inner - linkWidth, y: y, width: linkWidth, height: lineHeight))
            title.place(CGRect(x: x, y: y, width: link.isHidden ? inner : max(0, inner - linkWidth - dz(16)), height: lineHeight))
        }
        y += lineHeight + dz(6)
        let leadHeight = max(lineHeight, lead.height(forWidth: inner))
        if apply { lead.place(CGRect(x: x, y: y, width: inner, height: leadHeight)) }
        y += leadHeight + dz(8)
        for (index, row) in rows.enumerated() {
            if index == 1, !uvHint.isHidden {
                y += dz(4)
                if apply { uvHint.place(CGRect(x: x, y: y, width: inner, height: lineHeight)) }
                y += lineHeight + dz(4)
            }
            // The code box starts 5 before its text (`padding: 0 5px`).
            let codeX = x + dz(5)
            let codeWidth = min(row.code.naturalWidth, max(0, inner - dz(5)))
            let codeHeight = max(buttonHeight, row.code.height(forWidth: codeWidth))
            let buttons = [row.copy.button] + (row.run.map { [$0.button] } ?? [])
            let buttonsWidth = buttons.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + dz(8) }
            let beside = dz(5) + codeWidth + dz(12) + buttonsWidth <= inner
            if apply { row.code.place(CGRect(x: codeX, y: y + (codeHeight - row.code.height(forWidth: codeWidth)) / 2, width: codeWidth,
                                             height: row.code.height(forWidth: codeWidth))) }
            var bx = beside ? codeX + codeWidth + dz(12) : x
            let by = beside ? y : y + codeHeight + dz(4)
            if apply {
                for button in buttons {
                    let size = button.intrinsicContentSize
                    button.place(CGRect(x: bx, y: by + (buttonHeight - size.height) / 2, width: min(size.width, x + inner - bx), height: size.height))
                    bx += size.width + dz(8)
                }
            }
            y += (beside ? codeHeight : codeHeight + dz(4) + buttonHeight) + dz(6)
        }
        y += dz(2)
        let redetectWidth = redetect.button.intrinsicContentSize.width
        let noteWidth = max(0, inner - redetectWidth - dz(12))
        let noteHeight = max(lineHeight, note.height(forWidth: noteWidth))
        if apply {
            note.place(CGRect(x: x, y: y, width: noteWidth, height: noteHeight))
            let size = redetect.button.intrinsicContentSize
            redetect.button.place(CGRect(x: x + inner - min(size.width, inner), y: y + (max(noteHeight, buttonHeight) - size.height) / 2,
                                         width: min(size.width, inner), height: size.height))
        }
        y += max(noteHeight, buttonHeight)
        return ceil(y + dz(12))
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.dashedRect(bounds, color: Palette.lineBright)
    }

    var commandTexts: [String] { rows.map(\.command) }
    var texts: [String] {
        [title.displayedText, lead.displayedText] + rows.map(\.code.displayedText) + (uvHint.isHidden ? [] : [uvHint.displayedText])
            + [note.displayedText]
    }
}
