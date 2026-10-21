import AppKit

/// helmet `.modal` as used by the StatusDialogs artboard (`.modal.sd-modal`): --bg-soft, 1 px
/// --amber-dim border and the amber glow; `.m-h` header (Space Mono 12.5 amber caps title, a
/// flexible gap, right-side views such as a `cswap 0.26.0` chip, `+9` / `−1` chips or a `⌘Q` kbd,
/// then the `✕` icon button) over a dashed --line-bright rule; `.m-b` body (`contentView`,
/// `padding: 16px 20px`); `.m-f` footer over a dashed --line rule (`padding: 12px 20px`, gap 8):
/// left views (a `.sd-fnote` note, a checkbox) and right views (buttons).
///
/// The width comes from the caller (a width constraint); the height follows the content. With the
/// close button the header uses `.sd-modal .m-h{padding:12px 12px 11px 20px}`, without it helmet's
/// `14px 20px 12px`. The view does not handle keys: the owner maps ⏎ / ⎋ and `onClose`.
public final class ModalFrameView: FlippedView {
    public var title: String { didSet { if title != oldValue { Label.set(titleLabel, title, style: TextStyle.modalTitle) } } }
    /// ✕ (also the owner's ⎋ / 取消 path).
    public var onClose: (() -> Void)?
    /// The `.m-b` content area (inside its padding). Add the dialog's body here.
    public let contentView = FlippedView()
    public let closeButton = CoddButton("✕", style: .glyph())
    /// `box-shadow: 0 0 60px rgba(255,184,74,.10)` (a layer shadow; visible only when the superview
    /// leaves room around the frame, e.g. not when the frame fills a sheet).
    public var castsGlow = true { didSet { updateGlow() } }
    public private(set) var headerAccessories: [NSView] = []
    public private(set) var footerLeading: [NSView] = []
    public private(set) var footerTrailing: [NSView] = []

    private let titleLabel = Label.make(style: TextStyle.modalTitle)
    private let header = hStack([], spacing: 10)
    private let footer = hStack([], spacing: 8)
    private let showsClose: Bool
    /// `.m-h` padding (top, left, bottom, right). Pinned with constraints: NSStackView lets vertical
    /// `edgeInsets` give way to its hugging, which squeezed the band.
    private let headerPadding: NSEdgeInsets
    private var bodyTop: NSLayoutConstraint!
    private var bodyBottomToFooter: NSLayoutConstraint!
    private var bodyBottomToEdge: NSLayoutConstraint!

    public init(title: String, headerAccessories: [NSView] = [], showsClose: Bool = true) {
        self.title = title
        self.showsClose = showsClose
        headerPadding = showsClose ? NSEdgeInsets(top: 12, left: 20, bottom: 11, right: 12)
                                   : NSEdgeInsets(top: 14, left: 20, bottom: 12, right: 20)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        Label.set(titleLabel, title, style: TextStyle.modalTitle)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityLabel("關閉")
        for view in [header, contentView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bodyTop = contentView.topAnchor.constraint(equalTo: header.bottomAnchor).zoomed(headerPadding.bottom + 1 + 16)
        // body padding 16, the dashed rule, `.m-f` padding 12 (design points, following the zoom).
        bodyBottomToFooter = contentView.bottomAnchor.constraint(equalTo: footer.topAnchor).zoomed(-(16 + 1 + 12))
        bodyBottomToEdge = contentView.bottomAnchor.constraint(equalTo: bottomAnchor).zoomed(-(16 + 1))
        let collapse = contentView.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .init(1)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor).zoomed(1 + headerPadding.top),
            header.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(1 + headerPadding.left),
            header.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-(1 + headerPadding.right)),
            bodyTop,
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(1 + 20),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-(1 + 20)),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(1 + 20),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-(1 + 20)),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor).zoomed(-(1 + 12)),
            collapse,
        ])
        setHeaderAccessories(headerAccessories)
        setFooter(leading: [], trailing: [])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateGlow()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header views between the flexible gap and ✕.
    public func setHeaderAccessories(_ views: [NSView]) {
        headerAccessories = views
        for view in header.arrangedSubviews { header.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in [titleLabel, spacer()] + views + (showsClose ? [closeButton] : []) { header.addArrangedSubview(view) }
        needsDisplay = true
    }

    /// Footer: `leading` at the left (a note, a checkbox), `trailing` at the right (buttons). Both empty
    /// removes the footer and its rule.
    public func setFooter(leading: [NSView], trailing: [NSView]) {
        footerLeading = leading
        footerTrailing = trailing
        for view in footer.arrangedSubviews { footer.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in leading + [spacer()] + trailing { footer.addArrangedSubview(view) }
        let shown = showsFooter
        footer.isHidden = !shown
        bodyBottomToFooter.isActive = shown
        bodyBottomToEdge.isActive = !shown
        needsDisplay = true
    }

    /// The common footer: a `.sd-fnote` at the left (`⏎ 切換 · ⎋ 取消`) and the buttons at the right.
    public func setFooter(note: String?, buttons: [NSView]) {
        setFooter(leading: note.map { [Self.noteLabel($0)] } ?? [], trailing: buttons)
    }

    /// `.sd-fnote`: 11 px dimmer.
    public static func noteLabel(_ text: String) -> NSTextField {
        Label.make(text, style: TextStyle.mono(11, Palette.dimmer))
    }

    public var showsFooter: Bool { !footerLeading.isEmpty || !footerTrailing.isEmpty }

    /// Height of the `.m-h` band including the border above it and the rule under it (the part a
    /// panel can drag by).
    public var headerBandHeight: CGFloat { header.frame.maxY + UIZoom.pt(headerPadding.bottom) + 1 }

    public override func layout() {
        super.layout()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.amberDim)
        let headerRule = header.frame.maxY + UIZoom.pt(headerPadding.bottom)
        Draw.dashedLine(from: CGPoint(x: 1, y: headerRule), to: CGPoint(x: bounds.width - 1, y: headerRule), color: Palette.lineBright)
        if showsFooter {
            let footerRule = footer.frame.minY - UIZoom.pt(12) - 1
            Draw.dashedLine(from: CGPoint(x: 1, y: footerRule), to: CGPoint(x: bounds.width - 1, y: footerRule), color: Palette.line)
        }
    }

    @objc private func closeClicked() { onClose?() }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// The title unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? title }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }

    private func updateGlow() {
        shadow = castsGlow ? Draw.glow(Palette.amber.withAlphaComponent(0.10), radius: 60) : nil
    }
}
