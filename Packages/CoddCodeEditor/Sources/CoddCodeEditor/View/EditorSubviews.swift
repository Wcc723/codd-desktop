import AppKit
import CoddUI

/// Line numbers and the marker column (`.fe-l .n` / `.m`), drawn by the editor from the same rows
/// as the text; follows vertical scrolling only (it sits beside the scroll view).
final class GutterView: FlippedView {
    weak var editor: CodeEditorView?

    override func draw(_ dirtyRect: NSRect) {
        editor?.drawGutter(in: dirtyRect)
    }

    override func scrollWheel(with event: NSEvent) {
        editor?.scrollView.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        editor?.gutterClicked(at: convert(event.locationInWindow, from: nil))
    }
}

/// The 14 pt overview ruler (`.fe-ruler`): viewport thumb, find hits, AI changes, added / removed
/// blocks and the caret; a click or drag scrolls there.
final class OverviewRulerView: FlippedView {
    weak var editor: CodeEditorView?

    override func draw(_ dirtyRect: NSRect) {
        editor?.drawRuler(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        editor?.rulerScroll(toFraction: convert(event.locationInWindow, from: nil).y / max(1, bounds.height))
    }

    override func mouseDragged(with event: NSEvent) {
        editor?.rulerScroll(toFraction: convert(event.locationInWindow, from: nil).y / max(1, bounds.height))
    }

    override func scrollWheel(with event: NSEvent) {
        editor?.scrollView.scrollWheel(with: event)
    }
}

/// Holds the hunk bars above the gutter and the text; transparent to clicks except on a bar.
final class HunkOverlayView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One hunk bar (`.fe-hunk`), 26 pt: tag square, `AI` chip, who, range, `−n +m`, position and the
/// `[還原此段]` `[接受]` buttons. The gradient, the dashed top rule and the 2 pt inset bar take the
/// session's tag color. Horizontal scrolling never moves it (the buttons stay in reach).
final class HunkBarView: FlippedView {
    let hunkID: Int
    private(set) var header: InlineDiffHeader
    var textLeft: CGFloat { didSet { needsLayout = true; needsDisplay = true } }
    let style: CodeEditorStyle
    let revertButton = CoddButton("還原此段", style: .bracket(.normal, small: true))
    let acceptButton = CoddButton("接受", style: .bracket(.accent, small: true))
    var onAction: ((Int, HunkAction) -> Void)?
    weak var editor: CodeEditorView?

    init(hunkID: Int, header: InlineDiffHeader, textLeft: CGFloat, style: CodeEditorStyle) {
        self.hunkID = hunkID
        self.header = header
        self.textLeft = textLeft
        self.style = style
        super.init(frame: .zero)
        revertButton.target = self
        revertButton.action = #selector(revert)
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        revertButton.setAccessibilityLabel("還原此段")
        acceptButton.setAccessibilityLabel("接受")
        clipsToBounds = true
        addSubview(revertButton)
        addSubview(acceptButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("AI 變更 \(header.range)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(header: InlineDiffHeader) {
        guard header != self.header else { return }
        self.header = header
        setAccessibilityLabel("AI 變更 \(header.range)")
        needsLayout = true
        needsDisplay = true
    }

    @objc private func revert() { onAction?(hunkID, .revert) }
    @objc private func accept() { onAction?(hunkID, .accept) }

    override func layout() {
        super.layout()
        let accept = acceptButton.intrinsicContentSize
        let revert = revertButton.intrinsicContentSize
        let y = (bounds.height - accept.height) / 2
        acceptButton.frame = NSRect(x: bounds.width - style.hunkBarRightPadding - accept.width, y: y, width: accept.width, height: accept.height)
        revertButton.frame = NSRect(x: acceptButton.frame.minX - style.hunkBarGap - revert.width, y: y, width: revert.width, height: revert.height)
    }

    private func text(_ string: String, _ color: NSColor, size: CGFloat = 10.5, weight: Typeface.Weight = .regular, tracking: CGFloat = 0.02) -> NSAttributedString {
        TextStyle(font: Typeface.mono(size, weight), color: color, tracking: tracking).string(string)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tag = header.tagColor
        let width = bounds.width
        Draw.hGradient(NSRect(x: 0, y: 0, width: width * 0.55, height: bounds.height),
                       from: tag.withAlphaComponent(0.08), to: tag.withAlphaComponent(0))
        Draw.dashedLine(from: .zero, to: CGPoint(x: width, y: 0), color: tag.withAlphaComponent(0.35))
        Draw.fill(NSRect(x: 0, y: 0, width: style.hunkBarInset, height: bounds.height), tag)
        let midY = bounds.height / 2
        var x = textLeft
        Draw.fill(NSRect(x: x, y: round(midY - 4), width: 8, height: 8), tag)
        x += 8 + style.hunkBarGap
        if header.showAIChip {
            let label = text("AI", tag, size: 9, weight: .bold, tracking: 0.1)
            let chip = NSRect(x: x, y: round(midY - 7), width: Draw.width(label) + 8, height: 14)
            Draw.fill(chip, tag.withAlphaComponent(0.08))
            Draw.strokeRect(chip, color: tag.withAlphaComponent(0.5))
            Draw.text(label, x: chip.minX + 4, centerY: chip.midY)
            x = chip.maxX + style.hunkBarGap
        }
        // Right side first: position, then what is left for who / range / counts.
        let position = text(header.position, style.hunkFaint)
        let positionX = revertButton.frame.minX - style.hunkBarGap - Draw.width(position)
        if !header.position.isEmpty { Draw.text(position, x: positionX, centerY: midY) }
        let limit = (header.position.isEmpty ? revertButton.frame.minX : positionX) - style.hunkBarGap
        let range = text(header.range, style.hunkFaint)
        let counts = NSMutableAttributedString(attributedString: text("−\(header.removed)", Palette.danger))
        counts.append(text(" ", style.hunkBarText))
        counts.append(text("+\(header.added)", Palette.success))
        let tail = Draw.width(range) + style.hunkBarGap + Draw.width(counts)
        let who = text(header.who, style.hunkWho)
        let whoWidth = min(Draw.width(who), max(0, limit - x - tail - style.hunkBarGap))
        if whoWidth > 0 {
            Draw.text(who, x: x, centerY: midY, maxWidth: whoWidth)
            x += whoWidth + style.hunkBarGap
        }
        guard x + tail <= limit + 0.5 else { return }
        x += Draw.text(range, x: x, centerY: midY) + style.hunkBarGap
        Draw.text(counts, x: x, centerY: midY)
    }

    override func scrollWheel(with event: NSEvent) {
        editor?.scrollView.scrollWheel(with: event)
    }
}
