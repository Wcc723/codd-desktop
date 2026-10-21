import AppKit
import CoddUI

/// Multi-select action bar at the bottom of the sidebar list: `已選 4 [封存] [停止] [顏色] ✕`.
final class SelectionBarView: PanelView {
    weak var controller: SidebarViewController?
    private let countLabel = Label.make(style: TextStyle.mono(11, Palette.bone))
    private let badge = Label.make(style: TextStyle.mono(10, .black, .bold))
    private lazy var colorButton = CoddButton("顏色", style: .bracket(.normal, small: true), target: self, action: #selector(color(_:)))
    private var row: NSStackView?
    private var fixedButtons: [NSView] = []
    /// Hidden (fewer than two selected), the bar collapses to no height: the list reaches the
    /// footer instead of leaving the bar's band blank under it.
    private var rowBottom: NSLayoutConstraint?
    private lazy var collapsed = heightAnchor.constraint(equalToConstant: 0)

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            rowBottom?.isActive = !isHidden
            collapsed.isActive = isHidden
        }
    }

    init() {
        super.init(fill: Palette.bgSoft, edges: [.top], edgeColor: Palette.amberDim)
        let badgeBox = PanelView(fill: Palette.amber)
        badgeBox.addSubview(badge)
        badge.pinEdges(to: badgeBox, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        let archive = CoddButton("封存", style: .bracket(.normal, small: true), target: self, action: #selector(archive))
        let stop = CoddButton("停止", style: .bracket(.normal, small: true), target: self, action: #selector(stop))
        let clear = CoddButton("✕", style: .glyph(size: 22), target: self, action: #selector(clear))
        clear.setAccessibilityLabel("取消選取")
        let stack = hStack([countLabel, badgeBox, spacer(), archive, stop, colorButton, clear], spacing: 6,
                           edgeInsets: NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8))
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        rowBottom = bottom
        row = stack
        fixedButtons = [badgeBox, archive, stop, clear]
        // The bar keeps its constraints while hidden: `顏色` must never hold the sidebar wider
        // than its minimum (the swatches are in the rows' context menu too).
        colorButton.setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
        Label.set(countLabel, "已選", style: TextStyle.mono(11, Palette.bone))
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("已選取 session 的動作")
    }

    func update(count: Int) {
        isHidden = count < 2
        Label.set(badge, "\(count)", style: TextStyle.mono(10, .black, .bold))
        fitToWidth()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToWidth()
    }

    /// A narrow sidebar (its minimum, the interface zoom): 封存 停止 ✕ and the count always show;
    /// `顏色`, then `已選`, while they fit.
    private func fitToWidth() {
        guard let row else { return }
        let spacing = row.spacing
        let fixed = row.edgeInsets.left + row.edgeInsets.right + spacing * CGFloat(fixedButtons.count)
            + fixedButtons.reduce(0) { $0 + $1.fittingSize.width }
        let costs = [colorButton.intrinsicContentSize.width + spacing, countLabel.intrinsicContentSize.width + spacing]
        let shown = RowFit.shown(available: bounds.width, fixed: fixed, costs: costs)
        if colorButton.isHidden == shown[0] { colorButton.isHidden = !shown[0] }
        if countLabel.isHidden == shown[1] { countLabel.isHidden = !shown[1] }
    }

    private var selected: [SessionID] {
        guard let controller else { return [] }
        var seen = Set<SessionID>()
        return controller.outline.selectedRowIndexes.compactMap { controller.kind(atRow: $0)?.sessionID }.filter { seen.insert($0).inserted }
    }

    @objc private func archive() { controller?.archive(selected) }
    @objc private func stop() { controller?.confirmStop(selected) }
    @objc private func clear() { controller?.outline.deselectAll(nil) }

    @objc private func color(_ sender: CoddButton) {
        let ids = selected
        guard let controller else { return }
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = SwatchMenuItemView(current: nil) { [weak controller] tag in controller?.store.setTag(tag, sessions: ids) }
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}
