import AppKit
import CoddUI

/// The note editor's chrome (the Notebook artboard's `.main`): the 52 pt top bar (`.nb-top`:
/// crumb, the AI / scope pills and the id; COPY REF split button, SEND TO SESSION, ⋯), the body
/// with the `documentView` slot (C4's editor) and the info panel, the doc status bar and the
/// prompt footer. Menus are `NotebookMenuView`s shown through `menuPresenter` (a non-activating
/// child `PopoverPanel` by default). The app status bar is not part of it.
///
/// D15: an unsaved note (`noteID` nil) shows `id —` and has COPY REF and SEND disabled; an OFF
/// note's URL form is disabled with `AI 存取為 OFF，不提供網址`.
public final class NoteEditorChromeView: NSView {
    public static var topBarHeight: CGFloat { zp(52) }

    /// The info panel has room (false: a narrow window or a large interface zoom folds it away so
    /// the document keeps its width; the owner decides from the space it has).
    public var showsInfoPanel = true {
        didSet {
            guard showsInfoPanel != oldValue else { return }
            infoPanel.isHidden = model.info == nil || !showsInfoPanel
            needsLayout = true
        }
    }
    public static var refMenuWidth: CGFloat { zp(404) }

    public private(set) var model: NoteEditorChromeModel

    public var onCrumb: (() -> Void)?
    public var onAIAccess: ((NotebookAIAccess) -> Void)?
    /// A scope option's id (`global` or a project id).
    public var onScope: ((String) -> Void)?
    public var onCopyRef: ((NotebookRefForm) -> Void)?
    /// Session id and action.
    public var onSend: ((String, NotebookSendAction) -> Void)?
    public var onMore: ((NotebookMoreAction) -> Void)?

    /// Where menus go. Setting it also sets the prompt footer's.
    public var menuPresenter: NotebookMenuPresenting = PopoverMenuPresenter() {
        didSet { promptFooter.menuPresenter = menuPresenter }
    }

    /// The editor (C4's `MarkdownEditorView`), filling the document area.
    public var documentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let documentView {
                documentView.frame = documentSlot.bounds
                documentView.autoresizingMask = [.width, .height]
                documentSlot.addSubview(documentView)
            }
        }
    }

    public let infoPanel: NoteInfoPanelView
    public let docStatus: NoteDocStatusView
    public let promptFooter: PromptFooterView
    /// The area the document view fills (tests, the demo's placeholder).
    public let documentSlot = PanelView(fill: Palette.bgSoft)

    let crumb = DrawnControl()
    let aiPill = NotebookPillButton(.init(parts: []), small: true)
    let scopePill = NotebookPillButton(.init(parts: []), small: true)
    private let idLabel = InlineLabel()
    let copyRef = CopyRefSplitButton()
    let sendButton = CoddButton("Send to session ▾", style: .bracket(.normal, small: true))
    let moreButton = CoddButton("⋯", style: .glyph())
    private let topBar = PanelView(fill: Palette.bgSoft, edges: [.bottom], edgeColor: Palette.lineBright)

    public private(set) var presentedMenu: NoteChromeMenu?
    public private(set) var menuView: NotebookMenuView?

    public init(model: NoteEditorChromeModel) {
        self.model = model
        infoPanel = NoteInfoPanelView(model: model.info ?? NoteEditorChromeView.emptyInfo)
        docStatus = NoteDocStatusView(model: model.status)
        promptFooter = PromptFooterView(model: model.footer ?? PromptFooterModel(target: nil, targets: []))
        super.init(frame: CGRect(x: 0, y: 0, width: zp(848), height: zp(876)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("筆記編輯器")
        promptFooter.menuPresenter = menuPresenter

        crumb.onClick = { [weak self] in self?.onCrumb?() }
        crumb.drawer = { [weak self] control, rect in self?.drawCrumb(control, rect) }
        aiPill.onClick = { [weak self] in self?.toggleMenu(.ai) }
        scopePill.onClick = { [weak self] in self?.toggleMenu(.scope) }
        copyRef.mainPart.onClick = { [weak self] in self?.copyDefaultRef() }
        copyRef.menuPart.onClick = { [weak self] in self?.toggleMenu(.copyRef) }
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.setAccessibilityLabel("Send to session")
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.setAccessibilityLabel("更多動作")
        documentSlot.setAccessibilityLabel("筆記內容")

        for view in [crumb, aiPill, scopePill, idLabel, copyRef, sendButton, moreButton] as [NSView] { topBar.addSubview(view) }
        for view in [documentSlot, docStatus, promptFooter, infoPanel, topBar] as [NSView] { addSubview(view) }
        apply(force: true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    static let emptyInfo = NoteInfoPanelModel(links: [], aiActivity: [], historyCount: "", history: [], assetsSummary: "", assets: [],
                                              retention: [], pinned: false)

    public func update(_ model: NoteEditorChromeModel) {
        guard model != self.model else { return }
        self.model = model
        apply(force: false)
    }

    private func apply(force: Bool) {
        crumb.texts = [model.crumb.uppercased(), "/", model.title]
        crumb.setAccessibilityLabel("回到 \(model.crumb.uppercased())")
        crumb.needsDisplay = true

        aiPill.content = .init(icon: model.ai.icon, parts: [.caps(model.ai.pillTitle)], tone: model.ai == .off ? .dim : .cyan)
        aiPill.setAccessibilityLabel("AI 存取權限：\(model.ai.pillTitle)")
        aiPill.isEnabled = model.aiDisabledReason == nil
        aiPill.toolTip = model.aiDisabledReason
        if let scope = model.scope, scope.isProject {
            scopePill.content = .init(parts: [.caps("Project:"), .name(scope.title)])
            scopePill.setAccessibilityLabel("範圍：PROJECT \(scope.title)")
        } else {
            scopePill.content = .init(parts: [.caps(model.scope?.title ?? "Global")])
            scopePill.setAccessibilityLabel("範圍：GLOBAL")
        }
        scopePill.isEnabled = model.scopeDisabledReason == nil
        scopePill.toolTip = model.scopeDisabledReason
        idLabel.set([.text("id \(model.noteID ?? "—")", TextStyle.mono(10.5, Palette.dimmer))])

        let refReason = model.isSaved ? model.copyRefDisabledReason : NotebookCopy.unsavedReason
        copyRef.isEnabled = refReason == nil
        copyRef.mainPart.toolTip = refReason ?? model.refs?.uri
        copyRef.menuPart.toolTip = refReason
        let sendReason = model.isSaved ? model.sendDisabledReason : NotebookCopy.unsavedReason
        sendButton.isEnabled = sendReason == nil
        sendButton.toolTip = sendReason
        moreButton.isEnabled = model.moreDisabledReason == nil
        moreButton.toolTip = model.moreDisabledReason

        infoPanel.isHidden = model.info == nil || !showsInfoPanel
        if let info = model.info { infoPanel.update(info) }
        docStatus.update(model.status)
        promptFooter.isHidden = model.footer == nil
        if let footer = model.footer { promptFooter.update(footer) }

        // An open menu follows the model (or closes when its button turned disabled).
        if let open = presentedMenu {
            if isMenuEnabled(open), let menu = menuView {
                menu.update(menuModel(for: open))
            } else {
                closeMenu()
            }
        }
        needsLayout = true
    }

    // MARK: Crumb

    private func drawCrumb(_ control: DrawnControl, _ rect: CGRect) {
        let listColor = control.isHot ? Palette.amber : Palette.dim
        let pieces: [InlinePiece] = [
            .text(model.crumb, TextStyle.caps(10.5, listColor, tracking: 0.16)),
            .text("/", TextStyle.mono(10.5, Palette.dimmer)),
            .text(model.title, TextStyle.mono(12, Palette.cream, tracking: 0.02), shrink: true),
        ]
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
        let width = bounds.width
        topBar.frame = CGRect(x: 0, y: 0, width: width, height: Self.topBarHeight)
        layoutTopBar(width: width)
        let bodyTop = Self.topBarHeight
        let infoWidth: CGFloat = infoPanel.isHidden ? 0 : NoteInfoPanelView.preferredWidth
        let docWidth = width - infoWidth
        infoPanel.frame = CGRect(x: docWidth, y: bodyTop, width: infoWidth, height: max(0, bounds.height - bodyTop))
        let footerHeight: CGFloat = promptFooter.isHidden ? 0 : PromptFooterView.height
        promptFooter.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: docWidth, height: footerHeight)
        docStatus.frame = CGRect(x: 0, y: promptFooter.frame.minY - NoteDocStatusView.height, width: docWidth, height: NoteDocStatusView.height)
        documentSlot.frame = CGRect(x: 0, y: bodyTop, width: docWidth, height: max(0, docStatus.frame.minY - bodyTop))
        documentView?.frame = documentSlot.bounds
        if let menuView, let open = presentedMenu, menuView.superview === self {
            menuView.setFrameOrigin(menuOrigin(for: open, size: menuView.preferredSize))
        }
    }

    private func layoutTopBar(width: CGFloat) {
        // A narrow chrome (small window, zoom) keeps ⋯ and at least 120 pt of crumb; SEND TO
        // SESSION (the footer sends too), then COPY REF (⌘⇧C) give way.
        let fixed = zp(20) + zp(120) + zp(12) + moreButton.intrinsicContentSize.width + zp(10)
        let shown = RowFit.shown(available: width, fixed: fixed,
                                 costs: [copyRef, sendButton].map { $0.intrinsicContentSize.width + zp(6) })
        for (view, show) in zip([copyRef, sendButton] as [NSView], shown) where view.isHidden == show { view.isHidden = !show }
        // `.nb-acts` (gap 6), right padding 10.
        var right = width - zp(10)
        for view in [moreButton, sendButton, copyRef] as [NSView] where !view.isHidden {
            let size = view.intrinsicContentSize
            right -= size.width
            view.frame = CGRect(x: right, y: round((Self.topBarHeight - size.height) / 2), width: size.width, height: size.height)
            right -= zp(6)
        }
        // `.nb-ident`: crumb (18) + gap 4 + props (20), centered in 52.
        let left: CGFloat = zp(20)
        let identWidth = max(0, right - zp(12) - left + zp(6))
        let top = round((Self.topBarHeight - (zp(18) + zp(4) + zp(20))) / 2)
        crumb.frame = CGRect(x: left, y: top, width: identWidth, height: zp(18))
        var x = left
        let propsY = top + zp(18) + zp(4)
        for view in [aiPill, scopePill, idLabel] as [NSView] {
            let size = view.intrinsicContentSize
            let w = min(size.width, max(0, left + identWidth - x))
            view.frame = CGRect(x: x, y: propsY + round((zp(20) - size.height) / 2), width: w, height: size.height)
            x += w + zp(6)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }

    // MARK: Menus

    private func isMenuEnabled(_ menu: NoteChromeMenu) -> Bool {
        switch menu {
        case .ai: aiPill.isEnabled
        case .scope: scopePill.isEnabled
        case .copyRef: copyRef.isEnabled
        case .send: sendButton.isEnabled
        case .more: moreButton.isEnabled
        }
    }

    @objc private func sendClicked() { toggleMenu(.send) }
    @objc private func moreClicked() { toggleMenu(.more) }

    private func toggleMenu(_ menu: NoteChromeMenu) {
        if presentedMenu == menu { closeMenu() } else { openMenu(menu) }
    }

    /// Opens `menu` (nothing when its button is disabled).
    public func openMenu(_ menu: NoteChromeMenu) {
        closeMenu()
        guard isMenuEnabled(menu) else { return }
        let view = NotebookMenuView(model: menuModel(for: menu))
        view.onActivate = { [weak self] item in self?.activate(item, in: menu) }
        view.onDismiss = { [weak self] in self?.closeMenu() }
        presentedMenu = menu
        menuView = view
        setIndicator(menu, on: true)
        menuPresenter.present(view, at: menuOrigin(for: menu, size: view.preferredSize), in: self) { [weak self, weak view] in
            guard let self, self.menuView === view else { return }
            self.setIndicator(menu, on: false)
            self.presentedMenu = nil
            self.menuView = nil
        }
    }

    public func closeMenu() {
        guard let open = presentedMenu else { return }
        presentedMenu = nil
        menuView = nil
        setIndicator(open, on: false)
        menuPresenter.dismiss()
    }

    private func setIndicator(_ menu: NoteChromeMenu, on: Bool) {
        switch menu {
        case .ai: aiPill.isOn = on
        case .scope: scopePill.isOn = on
        case .copyRef: copyRef.menuPart.isOn = on
        case .send, .more: break
        }
    }

    /// The menu's top-left corner in this view (`.nb-refmenu{top:46px;right:10px}`; the pills'
    /// menus open under them).
    func menuOrigin(for menu: NoteChromeMenu, size: NSSize) -> CGPoint {
        switch menu {
        case .ai: CGPoint(x: aiPill.frame.minX, y: aiPill.frame.maxY + zp(4))
        case .scope: CGPoint(x: scopePill.frame.minX, y: scopePill.frame.maxY + zp(4))
        case .copyRef, .more: CGPoint(x: bounds.width - zp(10) - size.width, y: zp(46))
        case .send: CGPoint(x: min(bounds.width - zp(10) - size.width, sendButton.frame.maxX - size.width), y: zp(46))
        }
    }

    private func copyDefaultRef() {
        guard copyRef.isEnabled else { return }
        onCopyRef?(.uri)
    }

    private func activate(_ item: NotebookMenuItem, in menu: NoteChromeMenu) {
        closeMenu()
        let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
        switch (menu, parts.first) {
        case (.ai, "ai"):
            if parts.count > 1, let access = NotebookAIAccess(rawValue: parts[1]) { onAIAccess?(access) }
        case (.scope, "scope"):
            onScope?(String(item.id.dropFirst("scope.".count)))
        case (.copyRef, "ref"):
            if parts.count > 1, let raw = Int(parts[1]), let form = NotebookRefForm(rawValue: raw) { onCopyRef?(form) }
        case (.send, "send"):
            // `send.<action>.<session id>` (session ids may contain dots).
            if parts.count > 2, let action = NotebookSendAction(rawValue: parts[1]) { onSend?(parts[2], action) }
        case (.more, "more"):
            if let action = Self.moreAction(item.id) { onMore?(action) }
        default:
            break
        }
    }

    static func moreAction(_ id: String) -> NotebookMoreAction? {
        switch id {
        case "more.pin": .togglePin
        case "more.archive": .archive
        case "more.unarchive": .unarchive
        case "more.trash": .trash
        case "more.restore": .restore
        case "more.reveal": .revealInFinder
        case "more.source": .toggleSource
        case "more.copyID": .copyID
        default:
            id.hasPrefix("more.kind.") ? NotebookNoteKind(rawValue: String(id.dropFirst("more.kind.".count))).map { .kind($0) } : nil
        }
    }

    /// The model of each chrome menu, built from the chrome model.
    public func menuModel(for menu: NoteChromeMenu) -> NotebookMenuModel {
        switch menu {
        case .ai: aiMenuModel
        case .scope: scopeMenuModel
        case .copyRef: copyRefMenuModel
        case .send: sendMenuModel
        case .more: moreMenuModel
        }
    }

    var aiMenuModel: NotebookMenuModel {
        NotebookMenuModel(entries: [.header("AI 存取 · AI access", trailing: nil)] + NotebookAIAccess.allCases.map { access in
            .item(NotebookMenuItem(id: "ai.\(access.rawValue)", glyph: .icon(access.icon), title: access.pillTitle,
                                   tone: access == .off ? .dim : .normal, hint: access.hint, isChecked: access == model.ai))
        }, width: 320, initialHighlight: "ai.\(model.ai.rawValue)")
    }

    var scopeMenuModel: NotebookMenuModel {
        var entries: [NotebookMenuEntry] = [.header("範圍 · Scope", trailing: nil)]
        for option in model.scopeOptions {
            entries.append(.item(NotebookMenuItem(id: "scope.\(option.id)", glyph: option.isProject ? .tag(option.tag) : .text("◇"),
                                                  title: option.isProject ? option.title : "Global",
                                                  isChecked: option.id == model.scopeID)))
        }
        return NotebookMenuModel(entries: entries, initialHighlight: "scope.\(model.scopeID)")
    }

    var copyRefMenuModel: NotebookMenuModel {
        let refs = model.refs ?? NotebookRefTexts(uri: "codd://note/—", mention: "@codd:codd://note/—", path: "—", url: "—")
        let saved = model.isSaved
        let unsaved = saved ? nil : NotebookCopy.unsavedReason
        func item(_ form: NotebookRefForm, glyph: NotebookMenuGlyph, title: String, tone: NotebookMenuTone = .normal) -> NotebookMenuEntry {
            var enabled = saved
            var hint = form.hint
            var reason = unsaved
            if form == .url, model.ai == .off {
                enabled = false
                hint = NotebookRefForm.urlOffHint
                reason = reason ?? NotebookRefForm.urlOffHint
            }
            return .item(NotebookMenuItem(id: "ref.\(form.rawValue)", glyph: glyph, title: title, tone: tone,
                                          chip: form == .uri ? "推薦" : nil, hint: hint, shortcut: form == .uri ? "⌘⇧C" : nil,
                                          isEnabled: enabled, disabledReason: enabled ? nil : reason))
        }
        return NotebookMenuModel(entries: [
            .header("Copy reference · 複製引用", trailing: model.noteID ?? "—"),
            item(.uri, glyph: .icon(.link), title: refs.uri, tone: .amber),
            item(.mention, glyph: .text("@"), title: refs.mention),
            item(.path, glyph: .icon(.file), title: refs.path),
            item(.markdown, glyph: .icon(.copy), title: "複製全文 Markdown"),
            .separator,
            item(.url, glyph: .icon(.globe), title: refs.url, tone: .dim),
        ], width: Self.refMenuWidth, initialHighlight: "ref.1")
    }

    var sendMenuModel: NotebookMenuModel {
        var entries: [NotebookMenuEntry] = [.header("Send to session", trailing: nil)]
        if model.sessions.isEmpty {
            entries.append(.item(NotebookMenuItem(id: "send.none", title: NotebookCopy.noTargetReason, tone: .dim, isEnabled: false)))
        }
        for session in model.sessions {
            let reason = model.sendActionsDisabledReason
            let actions: [NotebookMenuEntry] = NotebookSendAction.allCases.map { action in
                .item(NotebookMenuItem(id: "send.\(action.rawValue).\(session.id)", title: action.title, isEnabled: reason == nil,
                                       disabledReason: reason))
            }
            entries.append(.item(NotebookMenuItem(id: "session.\(session.id)", glyph: .lamp(session.state), title: session.title,
                                                  detail: session.detail.isEmpty ? nil : session.detail,
                                                  submenu: NotebookMenuModel(entries: actions))))
        }
        return NotebookMenuModel(entries: entries, width: 340)
    }

    var moreMenuModel: NotebookMenuModel {
        let saved = model.isSaved
        let unsaved = saved ? nil : NotebookCopy.unsavedReason
        var entries: [NotebookMenuEntry] = [
            .item(NotebookMenuItem(id: "more.pin", glyph: .icon(.star), title: model.pinned ? "取消釘選" : "釘選")),
            .item(NotebookMenuItem(id: "more.kind", glyph: .text("❯"), title: "類型", detail: model.kind.title,
                                   submenu: NotebookMenuModel(entries: NotebookNoteKind.allCases.map { kind in
                                       .item(NotebookMenuItem(id: "more.kind.\(kind.rawValue)", title: kind.title, isChecked: kind == model.kind))
                                   }))),
        ]
        switch model.location {
        case .active:
            entries.append(.item(NotebookMenuItem(id: "more.archive", glyph: .icon(.archive), title: "封存", isEnabled: saved,
                                                  disabledReason: unsaved)))
            entries.append(.item(NotebookMenuItem(id: "more.trash", glyph: .icon(.trash), title: "移到垃圾桶", tone: .danger, isEnabled: saved,
                                                  disabledReason: unsaved)))
        case .archived:
            entries.append(.item(NotebookMenuItem(id: "more.unarchive", glyph: .icon(.archive), title: "取消封存")))
            entries.append(.item(NotebookMenuItem(id: "more.trash", glyph: .icon(.trash), title: "移到垃圾桶", tone: .danger)))
        case .trashed:
            entries.append(.item(NotebookMenuItem(id: "more.restore", glyph: .icon(.trash), title: "還原")))
        }
        entries.append(.separator)
        entries.append(.item(NotebookMenuItem(id: "more.reveal", glyph: .icon(.file), title: "在 Finder 顯示", isEnabled: saved,
                                              disabledReason: unsaved)))
        entries.append(.item(NotebookMenuItem(id: "more.source", glyph: .text("#"), title: model.sourceMode ? "即時預覽" : "原始碼",
                                              shortcut: "⌘E")))
        entries.append(.item(NotebookMenuItem(id: "more.copyID", glyph: .icon(.copy), title: "複製 ID", isEnabled: saved,
                                              disabledReason: unsaved)))
        return NotebookMenuModel(entries: entries, width: 240)
    }

    // MARK: Test access

    var visibleTexts: [String] { notebookVisibleTexts() }
    var topBarTexts: [String] { topBar.notebookVisibleTexts() }
}
