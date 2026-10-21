import AppKit
import CoddOnboarding
import CoddUI

/// The boot block on every step (`.ob-boot`): a 28 px header (`BOOT · 偵測環境`, the counts, the
/// time, `[↻ 重新偵測]`) over `.term` lines. VoiceOver: a group `環境偵測結果` whose lines read
/// `<tag> <name> <value>`.
final class BootBlockView: NSView {
    let term = BootTermView()
    let redetect = PressButton("↻ 重新偵測", style: .bracket(.normal, small: true), accessibility: "重新偵測環境")
    private(set) var report: EnvironmentReport?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(term)
        addSubview(redetect.button)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("環境偵測結果")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { term.lineViews + [redetect.button] }

    func apply(_ report: EnvironmentReport) {
        guard report != self.report else { return }
        self.report = report
        term.apply(report.lines)
        setAccessibilityValue(report.header)
        needsLayout = true
        needsDisplay = true
    }

    static var headerHeight: CGFloat { dz(28) }

    /// Border, header, term (padding 9 14 11, 18 px lines), border.
    func height() -> CGFloat { 1 + Self.headerHeight + term.height() + 1 }

    override func layout() {
        super.layout()
        let button = redetect.button
        let size = button.intrinsicContentSize
        button.place(CGRect(x: bounds.width - 1 - dz(6) - size.width, y: 1 + (Self.headerHeight - 1 - size.height) / 2,
                            width: size.width, height: size.height))
        term.place(CGRect(x: 1, y: 1 + Self.headerHeight, width: bounds.width - 2, height: term.height()))
    }

    var headerTexts: [String] {
        guard let report else { return [] }
        return ["BOOT · 偵測環境", report.header, report.checked]
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, .black)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        let header = CGRect(x: 1, y: 1, width: bounds.width - 2, height: Self.headerHeight)
        Draw.fill(header, Palette.bgSoft)
        Draw.fill(CGRect(x: 1, y: header.maxY - 1, width: header.width, height: 1), Palette.line)
        guard let report else { return }
        let mid = header.minY + (header.height - 1) / 2
        var x = header.minX + dz(12)
        x += Draw.text(TextStyle.caps(10, Palette.dim, tracking: 0.18).string("BOOT · 偵測環境"), x: x, centerY: mid) + dz(12)
        let base = TextStyle.mono(10.5, Palette.dimmer)
        var parts: [(String, TextStyle)] = [("\(report.ok) OK", base.with(color: Palette.success))]
        if report.pending > 0 { parts += [(" · ", base), ("\(report.pending) 待處理", base.with(color: Palette.amber))] }
        if report.failed > 0 { parts += [(" · ", base), ("\(report.failed) 失敗", base.with(color: Palette.danger))] }
        let counts = runs(parts)
        Draw.text(counts, x: x, centerY: mid)
        let time = base.string(report.checked)
        let right = redetect.button.frame.minX - dz(12)
        Draw.text(time, x: right - Draw.width(time), centerY: mid)
    }
}

/// `.term.ob-term`: lines in the 64 · 158 · 236 · rest grid, padding 9 14 11, 12 px / 1.5.
final class BootTermView: NSView {
    private(set) var lineViews: [BootLineView] = []
    /// The blinking `_` of the waiting line.
    var cursorVisible = true {
        didSet { if cursorVisible != oldValue { for line in lineViews where line.line.cursor { line.cursorVisible = cursorVisible } } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(_ lines: [BootLine]) {
        while lineViews.count > lines.count { lineViews.removeLast().removeFromSuperview() }
        while lineViews.count < lines.count {
            let view = BootLineView()
            lineViews.append(view)
            addSubview(view)
        }
        for (view, line) in zip(lineViews, lines) {
            view.line = line
            view.cursorVisible = cursorVisible
        }
        needsLayout = true
    }

    static var lineHeight: CGFloat { UIZoom.scaled(12 * 1.5) }

    func height() -> CGFloat { ceil(dz(9) + Self.lineHeight * CGFloat(lineViews.count) + dz(11)) }

    override func layout() {
        super.layout()
        let line = Self.lineHeight
        for (index, view) in lineViews.enumerated() {
            view.place(CGRect(x: dz(14), y: dz(9) + line * CGFloat(index), width: bounds.width - dz(28), height: ceil(line)))
        }
    }
}

/// One `.ob-bl` line in the artboard's grid. A path name wider than its 158 px column (the data
/// root, `~/Library/Application Support/CODD`) is front-elided by whole components to fit
/// (`~/…/CODD`) and its full path leads the detail column, as the claude and cswap lines show
/// theirs; any other too-wide name is cut at the column (`.ob-bl > span` ellipsis).
final class BootLineView: NSView, OnboardingTextShowing {
    var line = BootLine(tag: .ok, name: "", value: "") {
        didSet {
            guard line != oldValue else { return }
            setAccessibilityLabel(line.spoken)
            setAccessibilityValue(line.detail)
            needsDisplay = true
        }
    }

    var cursorVisible = true { didSet { if cursorVisible != oldValue, line.cursor { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String {
        let shown = shownNameAndDetail()
        return [line.tag.label, shown.name, line.value + (line.cursor ? "_" : ""), shown.detail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static var style: TextStyle { TextStyle(font: Typeface.mono(12), color: Palette.termForeground) }

    /// The name as the column shows it, and the detail (the full path first when it was elided).
    func shownNameAndDetail() -> (name: String, detail: String) {
        let style = Self.style
        let column = dz(158) - Draw.width(style.string(" "))
        let name = line.name
        guard Draw.width(style.string(name)) > column, name.hasPrefix("~/") || name.hasPrefix("/") else { return (name, line.detail) }
        let elided = PathText.elide(name) { Draw.width(style.string($0)) <= column }
        guard elided != name else { return (name, line.detail) }
        return (elided, line.detail.isEmpty ? name : "\(name) · \(line.detail)")
    }

    static func tagColor(_ tag: BootLine.Tag) -> NSColor {
        switch tag {
        case .ok: Palette.success
        case .pending, .waiting: Palette.amber
        case .fail: Palette.danger
        case .skipped: Palette.termDim
        }
    }

    static func valueColor(_ tag: BootLine.Tag) -> NSColor {
        switch tag {
        case .ok: Palette.termForeground
        case .pending, .waiting: Palette.amber
        case .fail: Palette.danger
        case .skipped: Palette.termDim
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        let style = Self.style
        let space = Draw.width(style.string(" "))
        let shown = shownNameAndDetail()
        Draw.text(style.with(color: Self.tagColor(line.tag)).string(line.tag.label), x: 0, centerY: mid, maxWidth: dz(64))
        Draw.text(style.string(shown.name), x: dz(64), centerY: mid, maxWidth: dz(158) - space)
        let valueX = dz(64 + 158)
        let detailX = dz(64 + 158 + 236)
        let value = style.with(color: Self.valueColor(line.tag)).string(line.value)
        let drawn = Draw.text(value, x: valueX, centerY: mid, maxWidth: max(0, detailX - valueX))
        if line.cursor, cursorVisible {
            Draw.text(style.with(color: Palette.amber).string("_"), x: valueX + drawn, centerY: mid)
        }
        if !shown.detail.isEmpty {
            Draw.text(style.with(color: Palette.termDim).string(shown.detail), x: detailX, centerY: mid, maxWidth: max(0, bounds.width - detailX))
        }
    }
}
