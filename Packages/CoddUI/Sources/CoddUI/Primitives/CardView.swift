import AppKit

/// `.card` (helmet): --bg-soft box, 1 px --line-bright border (`.hot`: --amber-dim), `padding: 16px 18px`,
/// the ASCII corners `┌─` (top left) and `─┘` (bottom right) drawn over the border on a --bg patch,
/// and an optional `.card-h` header row: title (Space Mono 12 amber caps), chips after it, views
/// pushed to the right (a `[SWITCH]` button, a status chip), a 1 px dashed --line-bright rule 6 px
/// below it and 12 px (`headerSpacing`) to the content.
///
/// The corners stick out of the box by half a line, as in CSS. The view is therefore `outset` taller
/// above and below than the card, and reports that as `alignmentRectInsets`: Auto Layout (stack
/// views included) places and sizes the card box itself, exactly like the CSS layout, while the
/// frame keeps room for the corners. Put content in `contentView` and constrain it there.
public final class CardView: FlippedView, ZoomRefreshing {
    /// Extra frame height above and below the card box (room for the corner glyphs), in design
    /// points (``zoomedOutset`` at the current zoom).
    public static let outset: CGFloat = 7
    /// ``outset`` at the current interface zoom.
    public static var zoomedOutset: CGFloat { UIZoom.pt(outset) }
    /// `.card{padding:16px 18px}`.
    public static let defaultPadding = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)

    /// `.card.hot`: --amber-dim border (active account, waiting session).
    public var isHot: Bool { didSet { if isHot != oldValue { needsDisplay = true } } }
    /// Border override (e.g. danger); nil uses the `.hot` rule.
    public var borderColor: NSColor? { didSet { needsDisplay = true } }
    /// Draw `┌─` / `─┘`.
    public var showsCorners = true { didSet { if showsCorners != oldValue { needsDisplay = true } } }
    /// The page color behind the corner glyphs (`.card::before{background:var(--bg)}`).
    public var cornerBackground: NSColor = Palette.bg { didSet { needsDisplay = true } }
    /// Header title, drawn with `TextStyle.cardTitle` (uppercased).
    public var title: String { didSet { if title != oldValue { updateTitle() } } }
    /// Replaces `title` when set (mixed styles, e.g. Status `#2` 15 px + cream alias).
    public var attributedTitle: NSAttributedString? { didSet { updateTitle() } }
    /// Space between the header rule and the content (`.card-h{margin-bottom:12px}`; account cards 4 + 7).
    public var headerSpacing: CGFloat = 12 { didSet { contentBelowHeader.constant = UIZoom.pt(7 + headerSpacing) } }
    public var padding: NSEdgeInsets { didSet { applyPadding() } }
    /// VoiceOver label (`帳號 #2 藍鵲 · 每週重置最快（1d12h後）`); the title otherwise.
    public var accessibilityText: String?

    /// Put the card's body here (pinned inside the padding, below the header when there is one).
    public let contentView = FlippedView()
    public private(set) var headerLeading: [NSView] = []
    public private(set) var headerTrailing: [NSView] = []

    private let titleLabel = Label.make(style: TextStyle.cardTitle)
    private let header = hStack([], spacing: 8)
    private var headerTop: NSLayoutConstraint!
    private var headerLeft: NSLayoutConstraint!
    private var headerRight: NSLayoutConstraint!
    private var contentBelowHeader: NSLayoutConstraint!
    private var contentAtTop: NSLayoutConstraint!
    private var contentLeft: NSLayoutConstraint!
    private var contentRight: NSLayoutConstraint!
    private var contentBottom: NSLayoutConstraint!

    public init(title: String = "", hot: Bool = false, padding: NSEdgeInsets = CardView.defaultPadding) {
        self.title = title
        self.isHot = hot
        self.padding = padding
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(contentView)
        headerTop = header.topAnchor.constraint(equalTo: topAnchor)
        headerLeft = header.leadingAnchor.constraint(equalTo: leadingAnchor)
        headerRight = header.trailingAnchor.constraint(equalTo: trailingAnchor)
        contentBelowHeader = contentView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: UIZoom.pt(7 + headerSpacing))
        contentAtTop = contentView.topAnchor.constraint(equalTo: topAnchor)
        contentLeft = contentView.leadingAnchor.constraint(equalTo: leadingAnchor)
        contentRight = contentView.trailingAnchor.constraint(equalTo: trailingAnchor)
        contentBottom = contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        // An empty body collapses instead of being ambiguous.
        let collapse = contentView.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .init(1)
        NSLayoutConstraint.activate([headerTop, headerLeft, headerRight, contentLeft, contentRight, contentBottom, collapse,
                                     header.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).zoomed(18)])
        applyPadding()
        updateTitle()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header views: `leading` right after the title (`MAX 20x` chip), `trailing` pushed to the right
    /// edge (`[SWITCH]`, `◆ 1 項需要更新`).
    public func setHeader(leading: [NSView] = [], trailing: [NSView] = []) {
        headerLeading = leading
        headerTrailing = trailing
        rebuildHeader()
    }

    /// The card box inside the view (the frame minus `outset` above and below).
    public var box: CGRect { bounds.insetBy(dx: 0, dy: Self.zoomedOutset) }

    /// Whether the header row is shown (a title or any header view).
    public var showsHeader: Bool { !title.isEmpty || attributedTitle != nil || !headerLeading.isEmpty || !headerTrailing.isEmpty }

    public override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: Self.zoomedOutset, left: 0, bottom: Self.zoomedOutset, right: 0)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let card = box
        Draw.fill(card, Palette.bgSoft)
        Draw.strokeRect(card, color: borderColor ?? (isHot ? Palette.amberDim : Palette.lineBright))
        if showsHeader, !header.isHidden {
            let y = header.frame.maxY + UIZoom.pt(6)
            Draw.dashedLine(from: CGPoint(x: header.frame.minX, y: y), to: CGPoint(x: header.frame.maxX, y: y), color: Palette.lineBright)
        }
        guard showsCorners else { return }
        // `.card::before` / `::after`: `padding:0 4px`, 11 px, line-height 1, centered on the border.
        let style = TextStyle.mono(11, Palette.amberDim)
        let inset = UIZoom.scaled(4)
        let patch = UIZoom.scaled(11)
        let open = style.string("┌─")
        let openWidth = Draw.width(open) + inset * 2
        Draw.fill(CGRect(x: card.minX, y: card.minY - patch / 2, width: openWidth, height: patch), cornerBackground)
        Self.drawCorner(open, x: card.minX + inset, edge: card.minY, font: style.font)
        let close = style.string("─┘")
        let closeWidth = Draw.width(close) + inset * 2
        Draw.fill(CGRect(x: card.maxX - closeWidth, y: card.maxY - patch / 2, width: closeWidth, height: patch), cornerBackground)
        Self.drawCorner(close, x: card.maxX - closeWidth + inset, edge: card.maxY, font: style.font)
    }

    /// CSS centers the glyph's content box (ascent + descent) on the border edge (`line-height:1`,
    /// `translateY(∓50%)`), which puts the box-drawing stroke on the border line. `Draw.text`
    /// centers a rounded line box instead (a point or two higher), so place it from the metrics.
    private static func drawCorner(_ text: NSAttributedString, x: CGFloat, edge: CGFloat, font: NSFont) {
        let top = edge - (font.ascender - font.descender) / 2
        text.draw(with: CGRect(x: x, y: top, width: Draw.width(text) + 2, height: font.ascender - font.descender + 2),
                  options: [.usesLineFragmentOrigin])
    }

    public override func layout() {
        super.layout()
        // The header rule follows the header's frame.
        needsDisplay = true
    }

    /// The padding is in design points: applied at the current zoom, again after a zoom change.
    private func applyPadding() {
        let padding = UIZoom.insets(padding)
        headerTop.constant = 1 + padding.top
        headerLeft.constant = 1 + padding.left
        headerRight.constant = -(1 + padding.right)
        contentAtTop.constant = 1 + padding.top
        contentLeft.constant = 1 + padding.left
        contentRight.constant = -(1 + padding.right)
        contentBottom.constant = -(1 + padding.bottom)
    }

    public func zoomDidChange() {
        applyPadding()
        contentBelowHeader.constant = UIZoom.pt(7 + headerSpacing)
        invalidateIntrinsicContentSize()
    }

    private func updateTitle() {
        if let attributedTitle {
            if titleLabel.attributedStringValue != attributedTitle { titleLabel.attributedStringValue = attributedTitle }
        } else {
            Label.set(titleLabel, title, style: TextStyle.cardTitle)
        }
        rebuildHeader()
    }

    private func rebuildHeader() {
        for view in header.arrangedSubviews { header.removeArrangedSubview(view); view.removeFromSuperview() }
        var views: [NSView] = []
        if !title.isEmpty || attributedTitle != nil { views.append(titleLabel) }
        views += headerLeading
        views.append(spacer())
        views += headerTrailing
        for view in views { header.addArrangedSubview(view) }
        let shown = showsHeader
        header.isHidden = !shown
        contentBelowHeader.isActive = shown
        contentAtTop.isActive = !shown
        needsDisplay = true
    }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// ``accessibilityText``, else the title, unless a caller set a label (theirs wins).
    public override func accessibilityLabel() -> String? {
        explicitAccessibilityLabel ?? accessibilityText ?? (attributedTitle?.string ?? title)
    }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }
}
