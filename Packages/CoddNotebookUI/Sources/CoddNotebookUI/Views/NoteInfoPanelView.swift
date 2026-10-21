import AppKit
import CoddUI

/// The editor's info panel (`.nb-info`, 240 pt): LINKS n (session / project rows,
/// `+ 連結 session / 專案`), AI ACTIVITY `codd MCP` (讀取 / 附加 rows, the hint), HISTORY `n 版`
/// (the timeline with the current `.on` and selected `.sel` dots, `[比較]`), ASSETS
/// (thumbnails), RETENTION (the dl rows, `[釘選以保留]` / `[取消釘選]`).
public final class NoteInfoPanelView: NSView {
    public static var preferredWidth: CGFloat { zp(240) }

    public private(set) var model: NoteInfoPanelModel
    public var onOpenLink: ((NotebookLink) -> Void)?
    public var onAddLink: (() -> Void)?
    public var onSelectHistory: ((String) -> Void)?
    public var onCompare: (() -> Void)?
    public var onOpenAsset: ((String) -> Void)?
    public var onTogglePin: (() -> Void)?

    private let scroll = NSScrollView()
    private let document = InfoDocumentView()
    private var headers: [InfoHeaderLabel] = []
    private(set) var linkRows: [DrawnControl] = []
    let addLinkButton = DashedAddButton("+ 連結 session / 專案")
    private var activityRows: [InlineLabel] = []
    private let activityHint = InlineLabel()
    private(set) var historyRows: [DrawnControl] = []
    let compareButton = CoddButton("比較", style: .bracket(.normal, small: true))
    private(set) var assetViews: [DrawnControl] = []
    private let retention = RetentionGridView()
    let pinButton = CoddButton("釘選以保留", style: .bracket(.normal, small: true))

    static var rowHeight: CGFloat { zp(17) }
    static var headerHeight: CGFloat { zp(16) }

    public init(model: NoteInfoPanelModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(824)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("筆記資訊")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        addLinkButton.onClick = { [weak self] in self?.onAddLink?() }
        compareButton.target = self
        compareButton.action = #selector(compareClicked)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        for view in [addLinkButton, activityHint, compareButton, retention, pinButton] as [NSView] { document.addSubview(view) }
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: NoteInfoPanelModel) {
        guard model != self.model else { return }
        self.model = model
        rebuild()
    }

    @objc private func compareClicked() { onCompare?() }
    @objc private func pinClicked() { onTogglePin?() }

    private func rebuild() {
        headers.forEach { $0.removeFromSuperview() }
        headers = [
            InfoHeaderLabel(title: "Links", trailing: String(model.links.count)),
            InfoHeaderLabel(title: "AI activity", trailing: "codd MCP"),
            InfoHeaderLabel(title: "History", trailing: model.historyCount),
            InfoHeaderLabel(title: "Assets", trailing: model.assetsSummary),
            InfoHeaderLabel(title: "Retention", trailing: nil),
        ]
        headers.forEach { document.addSubview($0) }
        let disabled = model.actionsDisabledReason

        linkRows.forEach { $0.removeFromSuperview() }
        linkRows = model.links.map { link in
            let row = DrawnControl()
            switch link {
            case .session(_, let title, let state):
                row.texts = [title, "session"]
                row.drawer = { control, rect in
                    Self.drawRow([.lamp(state, size: 11, width: 13), .text(title, TextStyle.mono(11.5, control.isHot ? Palette.cream : Palette.bone),
                                                                         shrink: true), .flex,
                                  .text("session", TextStyle.mono(10.5, Palette.dimmer))], in: rect)
                }
            case .project(_, let name, let tag):
                row.texts = [name, "project"]
                row.drawer = { control, rect in
                    Self.drawRow([.box(CGSize(width: zp(13), height: zp(8))) { box in
                        NotebookDraw.tagSquare(tag, in: CGRect(x: box.minX + zp(2.5), y: round(box.midY - zp(4)), width: zp(8), height: zp(8)))
                    }, .text(name, TextStyle.mono(11.5, control.isHot ? Palette.cream : Palette.bone), shrink: true), .flex,
                    .text("project", TextStyle.mono(10.5, Palette.dimmer))], in: rect)
                }
            }
            row.onClick = { [weak self] in self?.onOpenLink?(link.link) }
            document.addSubview(row)
            return row
        }
        addLinkButton.isEnabled = disabled == nil
        addLinkButton.toolTip = disabled

        activityRows.forEach { $0.removeFromSuperview() }
        activityRows = model.aiActivity.map { row in
            var pieces: [InlinePiece] = [.icon(row.kind.icon, size: 13, color: Palette.dim), .text(row.kind.title, TextStyle.mono(11.5, Palette.bone))]
            if let who = row.who {
                pieces.append(.text(who, TextStyle.mono(11.5, Palette.dim), shrink: true))
            }
            if let time = row.time {
                pieces.append(.flex)
                pieces.append(.text(time, TextStyle.mono(10.5, Palette.dimmer)))
            } else if row.who == nil {
                pieces.append(.text("—", TextStyle.mono(11.5, Palette.dimmer)))
            }
            let label = InlineLabel(pieces, gap: 7)
            document.addSubview(label)
            return label
        }
        activityHint.set([.text(model.aiActivityHint, TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))])

        historyRows.forEach { $0.removeFromSuperview() }
        historyRows = model.history.map { entry in
            let row = DrawnControl()
            row.texts = [entry.time, entry.label]
            row.drawer = { control, rect in
                Self.drawRow([.box(CGSize(width: zp(7), height: zp(7))) { box in
                    let dot = CGRect(x: box.minX, y: round(box.midY - zp(3.5)), width: zp(7), height: zp(7))
                    if entry.isCurrent {
                        Draw.fill(dot, Palette.amber)
                    } else {
                        Draw.fill(dot, Palette.bg)
                        Draw.strokeRect(dot, color: entry.isSelected ? Palette.amber : Palette.dim)
                    }
                }, .text(entry.time, TextStyle.mono(11.5, control.isHot ? Palette.cream : Palette.bone)),
                .text(entry.label, TextStyle.mono(11.5, Palette.dim), shrink: true)], in: rect)
            }
            row.onClick = { [weak self] in self?.onSelectHistory?(entry.id) }
            row.setAccessibilitySelected(entry.isSelected)
            document.addSubview(row)
            return row
        }
        compareButton.isEnabled = disabled == nil && model.history.count > 1
        compareButton.toolTip = disabled

        assetViews.forEach { $0.removeFromSuperview() }
        assetViews = model.assets.map { asset in
            let view = DrawnControl()
            view.texts = [asset.name]
            view.drawer = { control, rect in
                let thumb = CGRect(x: 0, y: 0, width: rect.width, height: zp(58))
                Draw.fill(thumb, NSColor.black)
                Draw.strokeRect(thumb, color: control.isHot ? Palette.amberDim : Palette.lineBright)
                let size = asset.orientation == .portrait ? CGSize(width: zp(26), height: zp(46)) : CGSize(width: zp(62), height: zp(35))
                let inner: CGRect
                if asset.image != nil {
                    inner = thumb.insetBy(dx: zp(2), dy: zp(2))
                } else {
                    inner = CGRect(x: thumb.midX - size.width / 2, y: thumb.midY - size.height / 2, width: size.width, height: size.height)
                }
                NotebookDraw.thumbnail(asset.image, orientation: asset.orientation, in: inner, schematic: .infoPanel)
                Draw.text(TextStyle.mono(10, control.isHot ? Palette.cream : Palette.dim).string(asset.name), x: 0, centerY: zp(58) + zp(4) + zp(7.5),
                          maxWidth: rect.width)
            }
            view.onClick = { [weak self] in self?.onOpenAsset?(asset.id) }
            document.addSubview(view)
            return view
        }

        retention.rows = model.retention
        pinButton.label = model.pinned ? "取消釘選" : "釘選以保留"
        pinButton.isEnabled = disabled == nil
        pinButton.toolTip = disabled
        needsLayout = true
    }

    private static func drawRow(_ pieces: [InlinePiece], in rect: CGRect) {
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect, gap: 7))
    }

    // MARK: Layout

    /// A new width (window resize, a column folding, zoom) lays the hand-placed rows out again:
    /// AppKit does not always ask a frame-laid view for layout when only its frame changed.
    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsLayout = true }
    }

    public override func layout() {
        super.layout()
        scroll.frame = CGRect(x: 1, y: 0, width: bounds.width - 1, height: bounds.height)
        // The clip's width: a legacy (always shown) scroller takes its share of the frame.
        let width = scroll.contentSize.width
        let x: CGFloat = zp(14)
        let inner = width - zp(28)
        var y: CGFloat = 0
        var separators: [CGFloat] = []
        var historyLine: (CGFloat, CGFloat)?

        func header(_ index: Int) {
            y += zp(12)
            headers[index].frame = CGRect(x: x, y: y, width: inner, height: Self.headerHeight)
            y += Self.headerHeight
        }
        func endSection(last: Bool = false) {
            y += zp(13)
            if !last {
                separators.append(y)
                y += 1
            }
        }

        // LINKS
        header(0)
        for row in linkRows {
            y += zp(7)
            row.frame = CGRect(x: x, y: y, width: inner, height: Self.rowHeight)
            y += Self.rowHeight
        }
        y += zp(7)
        addLinkButton.frame = CGRect(x: x, y: y, width: inner, height: zp(24))
        y += zp(24)
        endSection()

        // AI ACTIVITY
        header(1)
        if !activityRows.isEmpty { y += zp(7) }
        for (index, row) in activityRows.enumerated() {
            if index > 0 { y += 6 }
            row.frame = CGRect(x: x, y: y, width: inner, height: Self.rowHeight)
            y += Self.rowHeight
        }
        y += zp(7)
        activityHint.frame = CGRect(x: x, y: y, width: inner, height: zp(16))
        y += zp(16)
        endSection()

        // HISTORY
        header(2)
        if !historyRows.isEmpty {
            y += zp(7)
            let top = y
            for (index, row) in historyRows.enumerated() {
                if index > 0 { y += 6 }
                row.frame = CGRect(x: x, y: y, width: inner, height: Self.rowHeight)
                y += Self.rowHeight
            }
            historyLine = (top + zp(8), y - zp(8))
        }
        y += zp(7)
        let compareSize = compareButton.intrinsicContentSize
        compareButton.frame = CGRect(x: x, y: y, width: compareSize.width, height: compareSize.height)
        y += compareSize.height
        endSection()

        // ASSETS
        header(3)
        if !assetViews.isEmpty {
            y += zp(7)
            let count = CGFloat(max(assetViews.count, 2))
            let itemWidth = floor((inner - 8 * (count - 1)) / count)
            for (index, view) in assetViews.enumerated() {
                view.frame = CGRect(x: x + CGFloat(index) * (itemWidth + zp(8)), y: y, width: itemWidth, height: zp(58) + zp(4) + zp(15))
            }
            y += zp(58) + zp(4) + zp(15)
        }
        endSection()

        // RETENTION
        header(4)
        y += zp(7)
        let gridHeight = retention.height
        retention.frame = CGRect(x: x, y: y, width: inner, height: gridHeight)
        y += gridHeight + zp(7)
        let pinSize = pinButton.intrinsicContentSize
        pinButton.frame = CGRect(x: x, y: y, width: pinSize.width, height: pinSize.height)
        y += pinSize.height
        endSection(last: true)

        document.separators = separators
        document.historyLine = historyLine.map { (x + zp(3), $0.0, $0.1) }
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
        document.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height), Palette.line)
    }

    /// The panel's content height (tests: it fits the artboard's 824 pt body).
    var contentHeight: CGFloat { document.frame.height }
    var visibleTexts: [String] { notebookVisibleTexts() }
}

/// The scroll document: draws the sections' dashed bottom borders and the history timeline.
final class InfoDocumentView: FlippedView {
    var separators: [CGFloat] = []
    var historyLine: (x: CGFloat, top: CGFloat, bottom: CGFloat)?

    override func draw(_ dirtyRect: NSRect) {
        for y in separators {
            Draw.dashedLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: bounds.width, y: y), color: Palette.line)
        }
        if let line = historyLine, line.bottom > line.top {
            NotebookDraw.vline(x: line.x, from: line.top, to: line.bottom, color: Palette.lineBright, dashed: true)
        }
    }
}

/// `.sec.nb-ih`: caps title (500) and the right count (`.c`: normal case, dimmer).
final class InfoHeaderLabel: CanvasView, NotebookTextProviding {
    let title: String
    let trailing: String?

    init(title: String, trailing: String?) {
        self.title = title
        self.trailing = trailing
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title.uppercased(), trailing].compactMap { $0 }.joined(separator: " "))
    }

    var drawnTexts: [String] { [title.uppercased()] + (trailing.map { [$0] } ?? []) }

    override func draw(_ dirtyRect: NSRect) {
        let titleWidth = Draw.text(TextStyle.caps(10.5, Palette.dim, tracking: 0.18, .medium).string(title), x: 0, centerY: bounds.midY)
        if let trailing {
            let text = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string(trailing)
            let width = min(Draw.width(text), bounds.width - titleWidth - zp(8))
            Draw.text(text, x: bounds.width - width, centerY: bounds.midY, maxWidth: width)
        }
    }
}

/// `.nb-ret`: `grid-template-columns:auto 1fr; gap:5px 10px; font-size:11px`.
final class RetentionGridView: CanvasView, NotebookTextProviding {
    var rows: [NoteRetentionRow] = [] { didSet { if rows != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } } }
    static var lineHeight: CGFloat { zp(16.5) }

    var height: CGFloat { rows.isEmpty ? 0 : ceil(CGFloat(rows.count) * Self.lineHeight + CGFloat(rows.count - 1) * zp(5)) }
    var drawnTexts: [String] { rows.flatMap { [$0.term, $0.value] } }

    override func draw(_ dirtyRect: NSRect) {
        let termStyle = TextStyle.mono(11, Palette.dim)
        let termWidth = rows.map { Draw.width(termStyle.string($0.term)) }.max() ?? 0
        var y: CGFloat = 0
        for row in rows {
            let center = y + Self.lineHeight / 2
            Draw.text(termStyle.string(row.term), x: 0, centerY: center)
            let value = TextStyle.mono(11, row.ok ? Palette.success : Palette.bone).string(row.value)
            let maxWidth = bounds.width - termWidth - zp(10)
            let width = min(Draw.width(value), maxWidth)
            Draw.text(value, x: bounds.width - width, centerY: center, maxWidth: maxWidth)
            y += Self.lineHeight + zp(5)
        }
    }
}
