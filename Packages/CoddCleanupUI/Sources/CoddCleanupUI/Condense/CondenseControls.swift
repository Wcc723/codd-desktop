import AppKit
import CoddUI

/// The `帳號 / 模型 · Account` select: a `.select` box showing `accountTitle` that pops a native
/// menu with two sections, 帳號 (the accounts, disabled ones dimmed with their hint as tooltip)
/// and 模型 (the models), checkmarks on the selected ones. Popping a menu never activates the app.
final class CondenseSelectView: FieldBoxView, CleanupTextShowing, KeyboardFocusTracking {
    /// Keyboard focus shows the box's own focused look (FieldBoxView, like CoddUI's SelectButton).
    private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in
            guard let self else { return }
            self.isFocused = self.focusTracker.showsFocusRing && self.isEnabled
        }
        return tracker
    }()
    private(set) var model: CondenseModel?
    var onAccount: ((String) -> Void)?
    var onModel: ((String) -> Void)?
    var isEnabled = true { didSet { if isEnabled != oldValue { isDimmed = !isEnabled; needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("濃縮使用的帳號與模型")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var displayedText: String { model?.accountTitle ?? "" }

    func configure(_ model: CondenseModel) {
        self.model = model
        setAccessibilityValue(model.accountTitle)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.text(TextStyle.mono(12.5, Palette.cream).string(model?.accountTitle ?? ""), x: kz(9), centerY: bounds.midY,
                  maxWidth: max(0, bounds.width - kz(9) - kz(26)))
        // helmet `.select`: one amber ▼ (10 × 5) centered 13 px from the right edge.
        let x = bounds.maxX - kz(13)
        let y = bounds.midY
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x - kz(5), y: y - kz(2.5)))
        chevron.line(to: CGPoint(x: x + kz(5), y: y - kz(2.5)))
        chevron.line(to: CGPoint(x: x, y: y + kz(2.5)))
        chevron.close()
        Palette.amber.setFill()
        chevron.fill()
    }

    /// The two-section menu (tests read and run its items without popping it).
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let model else { return menu }
        menu.addItem(NSMenuItem.sectionHeader(title: "帳號"))
        for account in model.accounts {
            let id = account.id
            let item = ClosureMenuItem(title: account.title) { [weak self] in self?.onAccount?(id) }
            item.isEnabled = account.enabled
            item.state = account.id == model.selectedAccountID ? .on : .off
            item.toolTip = account.hint
            item.representedObject = "account:\(id)"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "模型"))
        for name in model.models {
            let item = ClosureMenuItem(title: name) { [weak self] in self?.onModel?(name) }
            item.state = name == model.selectedModel ? .on : .off
            item.representedObject = "model:\(name)"
            menu.addItem(item)
        }
        return menu
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showMenu()
        return true
    }

    // MARK: Keyboard (D21): a key view under Full Keyboard Access; space, ⏎ and ↓ open the menu.

    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: isEnabled, refuses: false) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusTracker.becameFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusTracker.resignedFirstResponder() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if isEnabled, KeyFocus.isPressKey(event) || KeyboardFocus.key(of: event) == .down {
            focusTracker.noteKeyboardInteraction()
            showMenu()
        } else {
            super.keyDown(with: event)
        }
    }

    private func showMenu() {
        let menu = makeMenu()
        menu.minimumWidth = bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + kz(2)), in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }
}

/// `.nb-cl-prev`: the summary on #000 in a 1 px dashed --line-bright box (`padding: 10px 12px`), its
/// bottom 28 % fading into the card (`mask-image: linear-gradient(180deg,#000 72%,transparent)`,
/// drawn as a --bg-soft overlay so offscreen snapshots show it too). A summary longer than the
/// box scrolls; it then gets the fade's height of room below so its last line can be read.
final class PreviewBoxView: NSView, CleanupTextShowing {
    static var inset: NSSize { NSSize(width: kz(12), height: kz(10)) }
    /// `#000 72%` → transparent.
    static let fadeStart: CGFloat = 0.72

    let scroll = NSScrollView()
    let textView: NSTextView
    private let placeholderLine = TextLine(style: TextStyle.mono(11, Palette.dimmer))
    private let fade = FadeOverlayView()
    private(set) var preview: NSAttributedString?
    private var measured: (width: CGFloat, height: CGFloat)?

    override init(frame frameRect: NSRect) {
        // TextKit 1 (as the rest of CODD's text views): text blocks such as the quote bar render.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: kz(280), height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = NSTextView(frame: CGRect(x: 0, y: 0, width: kz(304), height: kz(120)), textContainer: container)
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.selectedTextAttributes = [.backgroundColor: Palette.amber, .foregroundColor: NSColor.black]
        textView.setAccessibilityLabel("摘要預覽內容")
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        addSubview(scroll)
        addSubview(placeholderLine)
        addSubview(fade)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { preview?.string ?? placeholderLine.displayedText }

    func set(preview: NSAttributedString?, placeholder: String) {
        placeholderLine.set(placeholder, style: TextStyle.mono(11, Palette.dimmer))
        if let preview, preview.isEqual(to: self.preview ?? NSAttributedString()) { return }
        self.preview = preview
        measured = nil
        textView.textStorage?.setAttributedString(preview ?? NSAttributedString())
        textView.scroll(.zero)
        scroll.isHidden = preview == nil
        placeholderLine.isHidden = preview != nil
        needsLayout = true
    }

    /// The summary's laid-out height at `width` (box width) including insets and the border.
    func contentHeight(width: CGFloat) -> CGFloat {
        guard let preview, preview.length > 0 else { return CondenseCardView.previewMinHeight }
        return textHeight(width: width) + kz(2)
    }

    /// Measured on a TextKit 1 stack of its own: the text view's own layout answers short until
    /// it has laid out once in a window (the first grid pass then made the card too short).
    private func textHeight(width: CGFloat) -> CGFloat {
        guard let preview, preview.length > 0 else { return 0 }
        let textWidth = max(0, width - kz(2) - Self.inset.width * 2)
        if let measured, measured.width == textWidth { return measured.height }
        let storage = NSTextStorage(attributedString: preview)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        _ = layout.glyphRange(for: container)
        let height = ceil(layout.usedRect(for: container).height) + Self.inset.height * 2
        measured = (textWidth, height)
        return height
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: 1, dy: 1)
        scroll.frame = inner
        let text = textHeight(width: bounds.width)
        let fadeHeight = inner.height * (1 - Self.fadeStart)
        let documentHeight = text > inner.height - fadeHeight ? text + fadeHeight : inner.height
        textView.frame = CGRect(x: 0, y: 0, width: inner.width, height: documentHeight)
        placeholderLine.frame = CGRect(x: 1 + Self.inset.width, y: 1 + Self.inset.height, width: max(0, inner.width - Self.inset.width * 2),
                                       height: 16.5)
        fade.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, .black)
        Draw.dashedRect(bounds, color: Palette.lineBright)
    }
}

/// The preview's bottom fade: clear down to 72 %, then --bg-soft (the card) to 100 %. Ignores the
/// mouse, so scrolling and selection reach the text below.
final class FadeOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let top = (bounds.height * PreviewBoxView.fadeStart).rounded()
        let rect = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        // In a flipped view angle 90 runs downward: clear at 72 %, the card color at the bottom edge.
        NSGradient(starting: Palette.bgSoft.withAlphaComponent(0), ending: Palette.bgSoft)?.draw(in: rect, angle: 90)
    }
}
