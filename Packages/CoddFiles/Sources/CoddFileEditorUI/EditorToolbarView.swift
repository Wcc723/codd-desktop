import AppKit
import CoddUI

/// The breadcrumb and editor toolbar (`.fe-bar`, 30 pt, --bg, a dashed --line-bright rule below):
/// `src › pages › punch.vue › <style> › .punch-sticky` (the app passes the parts), then on the
/// right `AI 變更 n 段` ↑ ↓, the `SHOW AI CHANGES` switch, the baseline select and `[⌘F]`.
public final class EditorToolbarView: FlippedView {
    public static var height: CGFloat { fz(30) }

    public private(set) var model: EditorToolbarModel
    /// A folder crumb was clicked (index into `crumbs`).
    public var onCrumb: ((Int) -> Void)?
    public var onPreviousChange: (() -> Void)?
    public var onNextChange: (() -> Void)?
    public var onShowAIChanges: ((Bool) -> Void)?
    public var onBaseline: ((Int) -> Void)?
    public var onFind: (() -> Void)?

    let crumbs = CrumbsView()
    let changesLabel = DrawnLabel(style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
    let previousButton = FileEditorIconButton(.glyph("↑"), label: "上一段 AI 變更")
    let nextButton = FileEditorIconButton(.glyph("↓"), label: "下一段 AI 變更")
    let rule = PanelView(fill: Palette.lineBright)
    let switchLabel = DrawnLabel("Show AI changes", style: TextStyle.caps(10, Palette.bone, tracking: 0.14))
    let aiSwitch = SwitchToggle(label: "SHOW AI CHANGES")
    let baselineSelect = CompactSelectView(accessibilityLabel: "比較基準")
    let findButton = CoddButton("⌘F", style: .bracket(.normal, small: true))

    public init(model: EditorToolbarModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: fz(800), height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [crumbs, changesLabel, previousButton, nextButton, rule, switchLabel, aiSwitch, baselineSelect, findButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        previousButton.toolTip = "上一段 AI 變更"
        nextButton.toolTip = "下一段 AI 變更"
        findButton.setAccessibilityLabel("尋找 ⌘F")
        crumbs.onClick = { [weak self] index in self?.onCrumb?(index) }
        previousButton.onClick = { [weak self] in self?.onPreviousChange?() }
        nextButton.onClick = { [weak self] in self?.onNextChange?() }
        aiSwitch.target = self
        aiSwitch.action = #selector(switchToggled)
        baselineSelect.onSelect = { [weak self] index in self?.onBaseline?(index) }
        findButton.target = self
        findButton.action = #selector(findClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("檔案路徑")
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    public func update(_ model: EditorToolbarModel) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    private func apply() {
        crumbs.crumbs = model.crumbs
        // The model's part of what shows; `layout()` also hides what the width cannot hold.
        let hasChanges = model.aiChangeCount != nil
        for view in [changesLabel, previousButton, nextButton, rule] as [NSView] where !hasChanges { view.isHidden = true }
        if model.baselines.isEmpty { baselineSelect.isHidden = true }
        needsLayout = true
        if let count = model.aiChangeCount {
            changesLabel.text = "AI 變更 \(count) 段"
            previousButton.isEnabled = count > 0
            nextButton.isEnabled = count > 0
        }
        aiSwitch.isOn = model.showAIChanges
        baselineSelect.setItems(model.baselines, selected: model.selectedBaseline, enabled: model.baselineEnabled)
        needsLayout = true
    }

    /// A narrow toolbar (small window, zoom) keeps ⌘F and the SHOW AI CHANGES switch; the
    /// baseline select, the ↑ ↓ steps, the switch's label and `AI 變更 n 段` follow while they
    /// fit, then the crumbs take what is left.
    public override func layout() {
        super.layout()
        let height = bounds.height - 1
        let mid = height / 2
        let gap = fz(10)
        let hasChanges = model.aiChangeCount != nil
        let baselineWanted = !model.baselines.isEmpty
        let label = switchLabel.intrinsicContentSize
        let changes = changesLabel.intrinsicContentSize
        let fixed = fz(10) + findButton.intrinsicContentSize.width + gap + fz(30) + fz(7) + fz(14)
        var pieces: [(views: [NSView], cost: CGFloat)] = []
        if baselineWanted { pieces.append(([baselineSelect], baselineSelect.intrinsicContentSize.width + gap)) }
        if hasChanges { pieces.append(([rule, nextButton, previousButton], 1 + gap + fz(22) + fz(22) + gap)) }
        pieces.append(([switchLabel], ceil(label.width) + gap))
        if hasChanges { pieces.append(([changesLabel], ceil(changes.width) + gap)) }
        let shown = RowFit.shown(available: bounds.width, fixed: fixed, costs: pieces.map(\.cost))
        var hidden = Set<ObjectIdentifier>()
        if !baselineWanted { hidden.insert(ObjectIdentifier(baselineSelect)) }
        if !hasChanges { [rule, nextButton, previousButton, changesLabel].forEach { hidden.insert(ObjectIdentifier($0)) } }
        for (piece, show) in zip(pieces, shown) where !show { piece.views.forEach { hidden.insert(ObjectIdentifier($0)) } }
        for view in [baselineSelect, rule, nextButton, previousButton, switchLabel, changesLabel] as [NSView] {
            let hide = hidden.contains(ObjectIdentifier(view))
            if view.isHidden != hide { view.isHidden = hide }
        }
        var right = bounds.width - fz(10)
        func place(_ view: NSView, width: CGFloat, height h: CGFloat, gap: CGFloat = fz(10)) {
            guard !view.isHidden else { return }
            view.frame = CGRect(x: right - width, y: round(mid - h / 2), width: width, height: h)
            right -= width + gap
        }
        let find = findButton.intrinsicContentSize
        place(findButton, width: find.width, height: find.height)
        place(baselineSelect, width: baselineSelect.intrinsicContentSize.width, height: fz(22))
        place(aiSwitch, width: fz(30), height: fz(16), gap: fz(7))
        place(switchLabel, width: ceil(label.width), height: ceil(label.height))
        place(rule, width: 1, height: fz(14))
        place(nextButton, width: fz(22), height: fz(22), gap: 0)
        place(previousButton, width: fz(22), height: fz(22))
        place(changesLabel, width: ceil(changes.width), height: ceil(changes.height))
        crumbs.frame = CGRect(x: fz(14), y: 0, width: max(0, right - fz(14)), height: height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.lineBright)
    }

    @objc private func switchToggled() { onShowAIChanges?(aiSwitch.isOn) }
    @objc private func findClicked() { onFind?() }
}

/// `.fe-crumb`: 11.5 px parts separated by a dimmer `›` (gap 6); folders are links (amber on
/// hover), the file is cream, symbols dim. Clipped at its width.
final class CrumbsView: FlippedView {
    var crumbs: [EditorCrumb] = [] { didSet { if crumbs != oldValue { needsDisplay = true } } }
    var onClick: ((Int) -> Void)?
    private(set) var frames: [CGRect] = []
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("檔案路徑")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func color(_ crumb: EditorCrumb, hot: Bool) -> NSColor {
        switch crumb.kind {
        case .folder: hot ? Palette.amber : Palette.dim
        case .file: Palette.cream
        case .symbol: Palette.dim
        }
    }

    /// The frame of every crumb (computed in `draw`, also for hit tests before the first draw).
    func computeFrames() -> [CGRect] {
        var x: CGFloat = 0
        var out: [CGRect] = []
        let separator = Draw.width(TextStyle.mono(11.5, Palette.dimmer).string("›"))
        for (index, crumb) in crumbs.enumerated() {
            let width = Draw.width(TextStyle.mono(11.5, Palette.dim).string(crumb.title))
            out.append(CGRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + fz(6)
            if index < crumbs.count - 1 { x += separator + 6 }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        frames = computeFrames()
        let separator = TextStyle.mono(11.5, Palette.dimmer).string("›")
        for (index, crumb) in crumbs.enumerated() {
            let frame = frames[index]
            guard frame.minX < bounds.width else { break }
            Draw.text(TextStyle.mono(11.5, color(crumb, hot: hovered == index)).string(crumb.title), x: frame.minX, centerY: bounds.midY,
                      maxWidth: bounds.width - frame.minX)
            if index < crumbs.count - 1, frame.maxX + 6 < bounds.width {
                Draw.text(separator, x: frame.maxX + fz(6), centerY: bounds.midY)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { click(at: convert(event.locationInWindow, from: nil)) }

    func click(at point: CGPoint) {
        let frames = computeFrames()
        guard let index = frames.firstIndex(where: { $0.contains(point) }), crumbs[index].kind == .folder else { return }
        onClick?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = computeFrames().firstIndex { $0.contains(point) }.flatMap { crumbs[$0].kind == .folder ? $0 : nil }
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    // MARK: Keyboard and VoiceOver (D21)

    private var folderIndices: [Int] { crumbs.indices.filter { crumbs[$0].kind == .folder } }

    /// A key view while Full Keyboard Access is on and a folder crumb exists: ← → move over the
    /// folders (shown like a hover), ⏎ / space open the one under the cursor.
    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: !folderIndices.isEmpty, refuses: false) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        hovered = folderIndices.last
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        hovered = nil
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        let folders = folderIndices
        let position = hovered.flatMap { folders.firstIndex(of: $0) } ?? max(0, folders.count - 1)
        switch event.keyCode {
        case 123, 124:
            let next = min(max(0, position + (event.keyCode == 124 ? 1 : -1)), folders.count - 1)
            if folders.indices.contains(next) { hovered = folders[next]; needsDisplay = true }
        case 36, 76, 49:
            if folders.indices.contains(position) { onClick?(folders[position]) }
        default:
            super.keyDown(with: event)
        }
    }

    private var crumbElements: [DrawnItemElement] = []

    /// One element per crumb: folders are links that open them, the file and symbols static text.
    override func accessibilityChildren() -> [Any]? {
        if crumbElements.count != crumbs.count || zip(crumbElements, crumbs).contains(where: { ($0.accessibilityRole() == .link) != ($1.kind == .folder) }) {
            crumbElements = crumbs.indices.map { DrawnItemElement(host: self, index: $0, role: crumbs[$0].kind == .folder ? .link : .staticText) }
        }
        return crumbElements
    }
}

extension CrumbsView: DrawnItemsHost {
    var drawnItemCount: Int { crumbs.count }

    func drawnItemLabel(_ index: Int) -> String? {
        guard crumbs.indices.contains(index) else { return nil }
        let crumb = crumbs[index]
        return crumb.kind == .folder ? "資料夾 \(crumb.title)" : crumb.title
    }

    func drawnItemFrame(_ index: Int) -> CGRect {
        let frames = computeFrames()
        return frames.indices.contains(index) ? frames[index] : .zero
    }

    func pressDrawnItem(_ index: Int) {
        guard crumbs.indices.contains(index), crumbs[index].kind == .folder else { return }
        onClick?(index)
    }
}
