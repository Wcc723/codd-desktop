import AppKit
import CoddUI

/// The history compare sheet's content (D8, D34): `HISTORY · 比較版本`, two version selects
/// (older → newer) with a dim summary, the CoddUI `DiffLinesView` over the lines the app passes
/// (CoddFiles `LineDiff` mapped to `DiffLinesView.Line`), and `[關閉]` `[還原這一版]`. The app
/// presents it as a sheet; ⎋ = 關閉.
public final class HistoryCompareView: NSView {
    public static var preferredWidth: CGFloat { zp(680) }
    public static var diffHeight: CGFloat { zp(380) }

    public private(set) var model: HistoryCompareModel
    public var onSelectFrom: ((String) -> Void)?
    public var onSelectTo: ((String) -> Void)?
    public var onRestore: (() -> Void)?
    public var onClose: (() -> Void)?

    let frameView = ModalFrameView(title: "History · 比較版本")
    let fromSelect = SelectButton(titles: [], accessibilityLabel: "較舊的版本")
    let toSelect = SelectButton(titles: [], accessibilityLabel: "較新的版本")
    let diff = DiffLinesView(accessibilityLabel: "版本差異")
    let restoreButton = CoddButton("還原這一版", style: .bracket(.accent, small: false))
    let closeButton = CoddButton("關閉", style: .bracket(.normal, small: false))
    private let body = HistoryBodyView()
    private let note = InlineLabel()

    public init(model: HistoryCompareModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(560)))
        wantsLayer = true
        frameView.castsGlow = false
        frameView.onClose = { [weak self] in self?.onClose?() }
        frameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frameView)
        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(equalTo: leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: trailingAnchor),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.preferredWidth),
        ])
        body.fromSelect = fromSelect
        body.toSelect = toSelect
        body.diff = diff
        body.translatesAutoresizingMaskIntoConstraints = false
        frameView.contentView.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: frameView.contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: frameView.contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: frameView.contentView.topAnchor),
            body.bottomAnchor.constraint(equalTo: frameView.contentView.bottomAnchor),
            body.heightAnchor.constraint(equalToConstant: HistoryBodyView.height),
        ])
        fromSelect.onSelect = { [weak self] index in
            guard let self, self.model.versions.indices.contains(index) else { return }
            self.onSelectFrom?(self.model.versions[index].id)
        }
        toSelect.onSelect = { [weak self] index in
            guard let self, self.model.versions.indices.contains(index) else { return }
            self.onSelectTo?(self.model.versions[index].id)
        }
        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        note.set([.text("還原前會先儲存目前的內容", TextStyle.mono(11, Palette.dimmer))])
        note.translatesAutoresizingMaskIntoConstraints = false
        frameView.setFooter(leading: [note], trailing: [closeButton, restoreButton])
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: HistoryCompareModel) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    private func apply() {
        let titles = model.versions.map(\.title)
        fromSelect.setItems(titles, selected: model.versions.firstIndex { $0.id == model.fromID } ?? 0)
        toSelect.setItems(titles, selected: model.versions.firstIndex { $0.id == model.toID } ?? 0)
        diff.lines = model.lines
        body.summary = model.summary
        restoreButton.isEnabled = model.restoreEnabled
        restoreButton.toolTip = model.restoreEnabled ? nil : model.restoreDisabledReason
        body.needsLayout = true
        body.needsDisplay = true
    }

    @objc private func restoreClicked() { onRestore?() }
    @objc private func closeClicked() { onClose?() }

    public override func cancelOperation(_ sender: Any?) { onClose?() }

    /// The sheet's size (fitting height at 680).
    public var preferredSize: NSSize { ViewSnapshot.fittingSize(of: self, width: Self.preferredWidth) }

    var visibleTexts: [String] { notebookVisibleTexts() }
}

/// The sheet body: `[from ▾] → [to ▾]  summary`, then the diff in a scroll view.
final class HistoryBodyView: FlippedView, NotebookTextProviding {
    static var height: CGFloat { zp(30) + zp(12) + HistoryCompareView.diffHeight }
    weak var fromSelect: SelectButton? { didSet { adopt(fromSelect) } }
    weak var toSelect: SelectButton? { didSet { adopt(toSelect) } }
    weak var diff: DiffLinesView? { didSet { if let diff { scroll.documentView = diff } } }
    var summary = "" { didSet { needsDisplay = true } }
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var drawnTexts: [String] { ["→"] + (summary.isEmpty ? [] : [summary]) }

    /// SelectButton pins its own 30 pt height; the frame here is 30 too, so frames are fine.
    private func adopt(_ select: SelectButton?) {
        guard let select else { return }
        select.translatesAutoresizingMaskIntoConstraints = true
        addSubview(select)
    }

    override func layout() {
        super.layout()
        let selectWidth: CGFloat = zp(230)
        fromSelect?.frame = CGRect(x: 0, y: 0, width: selectWidth, height: zp(30))
        toSelect?.frame = CGRect(x: selectWidth + zp(28), y: 0, width: selectWidth, height: zp(30))
        scroll.frame = CGRect(x: 0, y: zp(42), width: bounds.width, height: HistoryCompareView.diffHeight)
        if let diff {
            let height = max(scroll.contentSize.height, diff.contentHeight + diff.verticalChrome)
            diff.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let arrow = TextStyle.mono(12.5, Palette.dim).string("→")
        Draw.text(arrow, x: zp(230) + zp(14) - Draw.width(arrow) / 2, centerY: zp(15))
        if !summary.isEmpty {
            let text = TextStyle.mono(11, Palette.dimmer).string(summary)
            Draw.text(text, x: bounds.width - Draw.width(text), centerY: zp(15))
        }
    }
}
