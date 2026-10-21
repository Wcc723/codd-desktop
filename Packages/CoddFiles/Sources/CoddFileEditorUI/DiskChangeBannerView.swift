import AppKit
import CoddUI

/// `.banner.warn` for a file that changed on disk while the tab is dirty (D25): the `!` box, the
/// title from the model (`磁碟上的檔案已被 AI 變更（<session> · HH:mm）`, `磁碟上的檔案已變更`, or the
/// notes editor's `磁碟上的筆記已變更`, D7), `· 你有未儲存的修改`, and `[重新載入] [保留我的] [比較]`
/// (比較 accent).
public final class DiskChangeBannerView: FlippedView {
    /// `padding: 7px 12px 7px 16px` around a 22 pt `.btn.sm`, plus the 1 pt rule.
    public static var height: CGFloat { fz(37) }

    public private(set) var model: DiskChangeBannerModel
    public var onReload: (() -> Void)?
    public var onKeepMine: (() -> Void)?
    public var onCompare: (() -> Void)?

    let titleLabel = DrawnLabel(style: TextStyle.mono(12, Palette.cream))
    let unsavedLabel = DrawnLabel("· 你有未儲存的修改", style: TextStyle.mono(11.5, Palette.dim))
    let reloadButton = CoddButton("重新載入", style: .bracket(.normal, small: true))
    let keepButton = CoddButton("保留我的", style: .bracket(.normal, small: true))
    let compareButton = CoddButton("比較", style: .bracket(.accent, small: true))

    public init(model: DiskChangeBannerModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: fz(800), height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [titleLabel, unsavedLabel, reloadButton, keepButton, compareButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)
        keepButton.target = self
        keepButton.action = #selector(keepClicked)
        compareButton.target = self
        compareButton.action = #selector(compareClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    public func update(_ model: DiskChangeBannerModel) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    private func apply() {
        titleLabel.text = model.title
        unsavedLabel.isHidden = !model.showsUnsaved
        reloadButton.isEnabled = model.canReload
        setAccessibilityLabel(model.title + (model.showsUnsaved ? "，你有未儲存的修改" : ""))
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let mid = (bounds.height - 1) / 2
        // A narrow banner (small window, zoom) keeps 重新載入 and 保留我的 and at least 120 pt of
        // its message; 比較 goes first.
        let fixed = fz(16) + fz(16) + fz(10) + fz(120) + fz(12) + reloadButton.intrinsicContentSize.width + fz(10)
            + keepButton.intrinsicContentSize.width + fz(10)
        let showsCompare = RowFit.shownCount(available: bounds.width, fixed: fixed,
                                             costs: [compareButton.intrinsicContentSize.width + fz(10)]) == 1
        if compareButton.isHidden == showsCompare { compareButton.isHidden = !showsCompare }
        var right = bounds.width - fz(12)
        for button in [compareButton, keepButton, reloadButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: right - size.width, y: round(mid - size.height / 2), width: size.width, height: size.height)
            right -= size.width + fz(10)
        }
        var x: CGFloat = fz(16) + fz(16) + fz(10)
        let title = titleLabel.intrinsicContentSize
        let titleWidth = min(ceil(title.width), max(0, right - x))
        titleLabel.frame = CGRect(x: x, y: round(mid - title.height / 2), width: titleWidth, height: ceil(title.height))
        x += titleWidth + fz(10)
        let unsaved = unsavedLabel.intrinsicContentSize
        unsavedLabel.frame = CGRect(x: x, y: round(mid - unsaved.height / 2), width: min(ceil(unsaved.width), max(0, right - x)),
                                    height: ceil(unsaved.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.hGradient(CGRect(x: 0, y: 0, width: bounds.width * 0.7, height: bounds.height), from: Palette.amberGlow,
                       to: Palette.amberGlow.withAlphaComponent(0))
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Palette.amberDim)
        // `.fe-bang`: 16 px amber box with a glow and a bold `!`.
        let box = CGRect(x: fz(16), y: round((bounds.height - 1) / 2 - fz(8)), width: fz(16), height: fz(16))
        NSGraphicsContext.current?.saveGraphicsState()
        Draw.glow(Palette.amberGlow, radius: 8).set()
        Draw.strokeRect(box, color: Palette.amber)
        NSGraphicsContext.current?.restoreGraphicsState()
        let bang = TextStyle.mono(11, Palette.amber, .bold).string("!")
        Draw.text(bang, x: box.midX - Draw.width(bang) / 2, centerY: box.midY)
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeepMine?() }
    @objc private func compareClicked() { onCompare?() }
}
