import AppKit
import CoddUI

/// The Settings sidebar (230 pt): `CODD / Settings ⌘,`, the search field, the numbered
/// nav with its group heads and tails, and the `Saved` footer with the preferences path.
final class SettingsSidebarView: FlippedView {
    var onSelect: ((SettingsSection) -> Void)?
    let search = SidebarSearchField()
    private(set) var items: [SettingsSection: NavItemView] = [:]
    private var heads: [(head: NavGroupHeadView, members: [SettingsSection])] = []
    private let footer = SidebarFooterView()
    private let topSpacer = WindowDragView(fill: nil)
    private var topHeight: NSLayoutConstraint?

    var topInset: CGFloat = 0 { didSet { topHeight?.constant = topInset } }

    static var width: CGFloat { xz(230) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let head = SidebarHeadView()
        let searchBox = FlippedView()
        searchBox.addSubview(search)
        search.pinEdges(to: searchBox, insets: NSEdgeInsets(top: xz(8), left: xz(8), bottom: xz(2), right: xz(8)))
        let nav = vStack([], spacing: 1, edgeInsets: NSEdgeInsets(top: xz(8), left: xz(6), bottom: xz(12), right: xz(6)))
        var currentHead: NavGroupHeadView?
        for section in SettingsSection.allCases {
            if let title = section.navGroupHead {
                let view = NavGroupHeadView(title)
                nav.addFullWidth(view)
                heads.append((view, []))
                currentHead = view
            }
            let item = NavItemView(section: section)
            item.onClick = { [weak self] in self?.onSelect?(section) }
            item.onStep = { [weak self] delta in self?.step(from: section, by: delta) }
            items[section] = item
            nav.addFullWidth(item)
            if currentHead != nil { heads[heads.count - 1].members.append(section) }
        }
        let navScroll = NSScrollView()
        let navDocument = FlippedView()
        navDocument.addSubview(nav)
        nav.pinEdges(to: navDocument)
        navScroll.documentView = navDocument
        navScroll.drawsBackground = false
        navScroll.hasVerticalScroller = true
        navScroll.scrollerStyle = .overlay
        navScroll.borderType = .noBorder
        navDocument.translatesAutoresizingMaskIntoConstraints = false
        let clip = navScroll.contentView
        NSLayoutConstraint.activate([
            navDocument.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            navDocument.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            navDocument.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        for view in [topSpacer, head, searchBox, navScroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let top = topSpacer.heightAnchor.constraint(equalToConstant: topInset)
        topHeight = top
        NSLayoutConstraint.activate([
            topSpacer.topAnchor.constraint(equalTo: topAnchor),
            topSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSpacer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            top,
            head.topAnchor.constraint(equalTo: topSpacer.bottomAnchor),
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            head.heightAnchor.constraint(equalToConstant: 52).zoomed(52),
            searchBox.topAnchor.constraint(equalTo: head.bottomAnchor),
            searchBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            navScroll.topAnchor.constraint(equalTo: searchBox.bottomAnchor),
            navScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            navScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            navScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
    }

    func setSelected(_ section: SettingsSection) {
        for (id, item) in items { item.isOn = id == section }
    }

    /// Shows only `sections` (search); nil shows every item. A group head hides with its items.
    func setVisible(_ sections: Set<SettingsSection>?) {
        for (id, item) in items { item.isHidden = !(sections?.contains(id) ?? true) }
        for entry in heads { entry.head.isHidden = !entry.members.contains { sections?.contains($0) ?? true } }
    }

    var visibleSections: [SettingsSection] { SettingsSection.allCases.filter { !(items[$0]?.isHidden ?? true) } }

    /// ↑ ↓ on a focused nav item: selects the neighbouring shown section and keeps the focus on
    /// the nav (its item), like a sidebar list.
    func step(from section: SettingsSection, by delta: Int) {
        let shown = visibleSections
        guard let index = shown.firstIndex(of: section), shown.indices.contains(index + delta) else { return }
        let next = shown[index + delta]
        onSelect?(next)
        if let item = items[next] { window?.makeFirstResponder(item) }
    }

    func apply(_ info: SettingsInfo) {
        items[.hooks]?.tail = info.hooks.navTail.map { NavItemView.Tail(text: $0, style: .warn) }
        items[.remote]?.tail = NavItemView.Tail(text: "FUTURE", style: .future)
        items[.about]?.tail = info.appVersion.isEmpty ? nil : NavItemView.Tail(text: info.appVersion, style: .plain)
        footer.update(savedAt: info.savedAt, problem: info.saveProblem, path: info.preferencesPath)
    }

    var footerText: String { footer.statusText }
}

/// `.side-head`: the brand, `/ Settings`, `⌘,`; dashed --line rule under it; drags the window.
final class SidebarHeadView: WindowDragView {
    init() {
        super.init(fill: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("CODD / Settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var brand = TextStyle(font: Typeface.display(15), color: Palette.amber, tracking: 0.04)
        brand.shadow = Draw.glow(Palette.amberGlow, radius: 8)
        var x: CGFloat = xz(14)
        x += Draw.text(brand.string("CODD"), x: x, centerY: mid) + xz(6)
        Draw.text(TextStyle.caps(9.5, Palette.dim, tracking: 0.18).string("/ Settings"), x: x, centerY: mid)
        let kbd = ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 5)
        kbd.draw("⌘,", x: bounds.width - xz(10) - kbd.size(for: "⌘,").width, centerY: mid)
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.line)
    }
}

/// The `/ 搜尋設定…` field (26 pt, bg-soft, line-bright border). ⏎ jumps to the first match, ⎋
/// clears.
final class SidebarSearchField: FlippedView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(11.5)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(11.5, Palette.dimmer).string("搜尋設定…")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("搜尋設定")
        let slash = SxLabel(SxRich("/").attributed(TextStyle.mono(11.5, Palette.dimmer), lineBreak: .byClipping), wraps: false)
        for view in [slash, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26).zoomed(26),
            slash.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            slash.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: slash.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit?()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            text = ""
            onChange?("")
            return true
        }
        return false
    }
}

/// `.sbsec.sx-navh`: 10 px caps .18em dim with the dashed rule (padding 10 / 8 / 4).
final class NavGroupHeadView: FlippedView {
    let title: String

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 29).zoomed(29).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let mid = xz(10) + xz(7.5)
        let width = Draw.text(TextStyle.caps(10, Palette.dim, tracking: 0.18).string(title), x: xz(8), centerY: mid)
        let start = xz(8) + width + xz(6) + xz(4)
        if bounds.width - 8 > start {
            Draw.dashedLine(from: CGPoint(x: start, y: round(mid)), to: CGPoint(x: bounds.width - xz(8), y: round(mid)), color: Palette.line)
        }
    }
}

/// `.sx-nav`: `01 一般 GENERAL … tail`, 30 pt. On: amber, the 10 % amber gradient and the 2 pt
/// amber inset bar, the zh label glowing, the EN label amber-dim with a static `_`.
final class NavItemView: SxKeyView {
    struct Tail: Equatable {
        enum Style: Equatable { case plain, warn, future }
        var text: String
        var style: Style
    }

    let section: SettingsSection
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isOn ? 1 : 0)
            setAccessibilitySelected(isOn)
        }
    }
    var tail: Tail? { didSet { if tail != oldValue { needsDisplay = true; updateHelp() } } }
    var onClick: (() -> Void)?
    /// ↑ ↓ while the item has the keyboard focus: the sidebar selects the previous / next shown
    /// section and moves the focus there (the nav is a list, D21).
    var onStep: ((Int) -> Void)?
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).zoomed(30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(section.number) \(section.navTitle) \(section.navEnglish)".trimmingCharacters(in: .whitespaces))
        setAccessibilityValue(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            Draw.hGradient(CGRect(x: 0, y: 0, width: bounds.width * 0.85, height: bounds.height),
                           from: Palette.amber.withAlphaComponent(0.10), to: Palette.amber.withAlphaComponent(0))
            Draw.fill(CGRect(x: 0, y: 0, width: xz(2), height: bounds.height), Palette.amber)
        } else if hovered {
            Draw.fill(bounds, Palette.bgSoft)
        }
        let mid = bounds.midY
        var x: CGFloat = xz(12)
        Draw.text(TextStyle.mono(10.5, isOn ? Palette.amberDim : Palette.dimmer).string(section.number), x: x, centerY: mid)
        x += xz(18) + xz(8)
        var zh = TextStyle.mono(12.5, isOn ? Palette.amber : (hovered ? Palette.cream : Palette.bone))
        if isOn { zh.shadow = Draw.glow(Palette.amberGlow, radius: 8) }
        x += Draw.text(zh.string(section.navTitle), x: x, centerY: mid) + xz(8)
        var right = bounds.width - xz(10)
        if let tail {
            switch tail.style {
            case .future:
                let style = ChipStyle(text: TextStyle.caps(9, Palette.dim, tracking: 0.12), border: Palette.lineBright, dashed: true, height: 14,
                                      padding: 4)
                right -= style.size(for: tail.text).width
                style.draw(tail.text, x: right, centerY: mid)
            case .plain, .warn:
                let text = TextStyle.mono(10.5, tail.style == .warn ? Palette.amber : Palette.dimmer).string(tail.text)
                right -= Draw.width(text)
                Draw.text(text, x: right, centerY: mid)
            }
            right -= xz(8)
        }
        if !section.navEnglish.isEmpty {
            let en = TextStyle.caps(10.5, isOn ? Palette.amberDim : Palette.dimmer, tracking: 0.14).string(section.navEnglish)
            let drawn = Draw.text(en, x: x, centerY: mid, maxWidth: max(0, right - x))
            if isOn, x + drawn + 2 < right { Draw.text(TextStyle.mono(10.5, Palette.amber).string("_"), x: x + drawn + xz(2), centerY: mid) }
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 125 || event.keyCode == 126, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onStep?(event.keyCode == 125 ? 1 : -1)
            return true
        }
        return super.handleKey(event)
    }

    /// The tail (`◆ 1 處不同`, `FUTURE`, the version) as the item's help text.
    private func updateHelp() { setAccessibilityHelp(tail?.text) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

/// `.side-foot`: `SAVED` and `● 變更即時儲存 · 10:41` (or `▲ <problem>`), then the preferences
/// path in --dimmer, truncated.
final class SidebarFooterView: FlippedView {
    private(set) var statusText = ""
    private var problem: String?
    private var path = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 8 + 17 + 6 + 16 + 10).zoomed(8 + 17 + 6 + 16 + 10).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("SAVED")
        update(savedAt: nil, problem: nil, path: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    func update(savedAt: Date?, problem: String?, path: String) {
        let status = problem.map { "▲ \($0)" } ?? ("● 變更即時儲存" + (savedAt.map { " · \(Self.clock($0))" } ?? ""))
        guard status != statusText || problem != self.problem || path != self.path else { return }
        statusText = status
        self.problem = problem
        self.path = path
        setAccessibilityValue("\(status)，\(path)")
        toolTip = "\(status)\n\(path)"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.line)
        let first: CGFloat = xz(8) + xz(8.5)
        Draw.text(TextStyle.caps(9.5, Palette.dim, tracking: 0.18).string("Saved"), x: xz(12), centerY: first)
        let status = NSMutableAttributedString()
        if let problem {
            status.append(TextStyle.mono(11, Palette.amber).string("▲ " + problem))
        } else {
            status.append(TextStyle.mono(11, Palette.success).string("●"))
            status.append(TextStyle.mono(11, Palette.dim).string(String(statusText.dropFirst())))
        }
        let width = min(Draw.width(status), bounds.width - xz(12) - xz(12) - xz(50))
        Draw.text(status, x: bounds.width - xz(12) - width, centerY: first, maxWidth: width)
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(path), x: xz(12), centerY: first + xz(8.5) + xz(6) + xz(8), maxWidth: bounds.width - xz(24))
    }
}
