import AppKit
import CoddCore
import CoddUI

/// Settings › 啟動設定檔 (Settings artboard 04 PROFILES, SPEC §7.12, D5 / D30): the `PROFILES`
/// `啟動設定檔` head with `+ New profile`, the lead, the `Launch profiles n` card of rows (glyph,
/// name, kind and `Default` chips, the profile's own command, `cwd · 帳號 · 模型`, `複製` `編輯`
/// `刪除`) and the `Preview 實際啟動指令` box (the default profile with typical ⌘N options). Every
/// change goes through `LaunchProfiles` (profiles.json, then the launcher). A profiles.json from
/// a newer CODD shows the list read-only with a problem line.
@MainActor
final class ProfilesSettingsView: FlippedView {
    private let profiles: LaunchProfiles
    private let claudeSettings: @MainActor () -> ClaudeUserSettingsSummary
    /// The meta line's account (`跟隨全域（#3 工作）`), read while tracked: it follows a switch.
    private let accountLabel: @MainActor () -> String
    private let newButton = CoddButton("+ New profile", style: .bracket(.accent, small: true))
    private let problemLine = WrappingLabel("", style: TextStyle.mono(11.5, Palette.danger))
    private let listHead = SettingsGroupHeadView(title: "Launch profiles")
    private let card = SettingsCardView()
    private let previewHead = SettingsGroupHeadView(title: "Preview", cjk: "實際啟動指令")
    private let previewBox = SettingsTermView()
    private let stack: NSStackView
    /// The head's CJK name: a narrow page (small window, zoom 20) drops it, never the button.
    private let headZh: NSTextField
    private let heading: NSTextField
    private var loop: ObservationLoop?
    private(set) var model = ProfilesSettingsModel(rows: [], defaultName: "", preview: "", readOnly: false)
    /// The editor sheet asks for the window (the settings window hosts it).
    var onEdit: ((String?) -> Void)?

    init(profiles: LaunchProfiles, claudeSettings: @escaping @MainActor () -> ClaudeUserSettingsSummary,
         accountLabel: @escaping @MainActor () -> String) {
        self.profiles = profiles
        self.claudeSettings = claudeSettings
        self.accountLabel = accountLabel
        var title = TextStyle(font: Typeface.display(26), color: Palette.amber, tracking: 0.02)
        title.shadow = HomeHeaderView.glow(Palette.amberGlow, radius: 12)
        let heading = Label.make("PROFILES", style: title)
        let zh = Label.make("啟動設定檔", style: TextStyle(font: Typeface.mono(15, .medium), color: Palette.bone, tracking: 0.04))
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
        zh.setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
        let l1 = hStack([heading, zh, spacer(), newButton], spacing: UIZoom.pt(12))
        l1.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).zoomed(32).isActive = true
        // Wraps at the page's width (a plain label kept one line and cut the flags off).
        let lead = WrappingLabel("", style: TextStyle.mono(12, Palette.dim))
        lead.attributedStringValue = Self.leadText()
        let headBlock = columnStack([l1, lead, problemLine], spacing: UIZoom.pt(6))
        let listGroup = columnStack([listHead, card], spacing: UIZoom.pt(8))
        let previewGroup = columnStack([previewHead, previewBox], spacing: UIZoom.pt(8))
        stack = columnStack([headBlock, listGroup, previewGroup], spacing: UIZoom.pt(20),
                            edgeInsets: Self.insets(width: .greatestFiniteMagnitude))
        self.heading = heading
        headZh = zh
        super.init(frame: .zero)
        problemLine.isHidden = true
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.setAccessibilityLabel("新增啟動設定檔")
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 880 + 80).zoomed(880 + 80),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let fill = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true
        loop = ObservationLoop(track: { [weak self] () -> (LaunchProfileDocument, Bool, ClaudeUserSettingsSummary, String)? in
            guard let self else { return nil }
            return (self.profiles.document, !self.profiles.canEdit, self.claudeSettings(), self.accountLabel())
        }, apply: { [weak self] value in
            guard let self, let value else { return }
            self.rebuild(document: value.0, readOnly: value.1, settings: value.2, account: value.3)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `.sx-body` padding 26 / 40 (20 at the sides of a narrow page), as the package's sections.
    static func insets(width: CGFloat) -> NSEdgeInsets {
        let side = width < UIZoom.pt(600) ? UIZoom.pt(20) : UIZoom.pt(40)
        return NSEdgeInsets(top: UIZoom.pt(26), left: side, bottom: UIZoom.pt(28), right: side)
    }

    /// A narrow page: 20 at the sides, and the head drops its CJK name before the title cuts.
    override func layout() {
        let insets = Self.insets(width: bounds.width)
        if insets.left != stack.edgeInsets.left { stack.setFullWidthInsets(insets) }
        let available = min(bounds.width, UIZoom.pt(880 + 80)) - insets.left - insets.right
        let needed = heading.intrinsicContentSize.width + headZh.intrinsicContentSize.width + newButton.intrinsicContentSize.width
            + 2 * UIZoom.pt(12)
        let showsZh = needed <= available
        if headZh.isHidden == showsZh { headZh.isHidden = !showsZh }
        super.layout()
    }

    /// `⌘N 新增 session 時可選的啟動方式。CODD 會自動補上 --session-id 與 -n 名稱。` with the
    /// flags as `code`.
    static func leadText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let plain = TextStyle.mono(12, Palette.dim)
        var code = TextStyle.mono(12, Palette.amber)
        code.tracking = 0
        func codeSpan(_ s: String) -> NSAttributedString {
            let span = NSMutableAttributedString(attributedString: code.string(" \(s) "))
            span.addAttribute(.backgroundColor, value: Palette.bg, range: NSRange(location: 0, length: span.length))
            return span
        }
        text.append(plain.string("⌘N 新增 session 時可選的啟動方式。CODD 會自動補上 "))
        text.append(codeSpan("--session-id"))
        text.append(plain.string(" 與 "))
        text.append(codeSpan("-n"))
        text.append(plain.string(" 名稱。"))
        // Wraps at the page's width (the pieces' own paragraph style truncates).
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let paragraph = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return text
    }

    private func rebuild(document: LaunchProfileDocument, readOnly: Bool, settings: ClaudeUserSettingsSummary, account: String) {
        let next = ProfilesSettingsModel.build(document: document, settingsModel: settings.model, accountLabel: account, readOnly: readOnly)
        guard next != model || card.rowViews.isEmpty else { return }
        model = next
        listHead.count = "\(next.rows.count)"
        previewHead.right = "\(next.defaultName) + ⌘N 對話框的選項"
        previewBox.show(next.preview)
        problemLine.isHidden = !readOnly
        if readOnly {
            problemLine.attributedStringValue = TextStyle.mono(11.5, Palette.danger).string("▲ " + (profiles.editRefusal ?? LaunchProfiles.readOnlyMessage),
                                                                                            lineBreak: .byWordWrapping)
        }
        newButton.isEnabled = !readOnly
        card.show(next.rows.map { row in
            let view = ProfileRowView(row: row, readOnly: readOnly)
            view.onCopy = { [weak self] in self?.duplicate(row.id) }
            view.onEdit = { [weak self] in self?.onEdit?(row.id) }
            view.onDelete = { [weak self] in self?.confirmDelete(row.id) }
            return view
        })
    }

    @objc private func newClicked() { onEdit?(nil) }

    func duplicate(_ id: String) {
        guard let copy = profiles.duplicate(id) else { NSSound.beep(); return }
        HolderSessionStore.printLog("profiles duplicated \(id) as \(copy)")
    }

    /// `刪除`: refused (with the reason) for the last claude profile, else confirmed first.
    func confirmDelete(_ id: String) {
        guard let profile = profiles.document.profile(id: id) else { return }
        var after = profiles.document
        let alert = NSAlert()
        if let issue = LaunchProfileEditing.remove(id, from: &after) {
            alert.messageText = "無法刪除「\(profile.name)」"
            alert.informativeText = ProfileEditorForm.message(issue)
            alert.addButton(withTitle: "知道了")
        } else {
            alert.messageText = "刪除「\(profile.name)」？"
            var info = "用這個設定檔開的 session 下次啟動時改用預設設定檔。"
            if profiles.document.defaultProfileId == id, let next = after.defaultProfile {
                info += "預設會改成「\(next.name)」。"
            }
            alert.informativeText = info
            alert.addButton(withTitle: "刪除").hasDestructiveAction = true
            alert.addButton(withTitle: "取消")
        }
        let deletable = alert.buttons.count == 2
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard deletable, response == .alertFirstButtonReturn else { return }
            if let issue = self?.profiles.delete(id) { HolderSessionStore.printLog("profiles delete \(id) refused: \(issue)") }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// The rows as drawn (tests, state checks).
    var rowViews: [ProfileRowView] { card.rowViews }
}

/// `.sx-gh`: caps title, an optional CJK note and amber-dim count, the dashed rule, then an
/// optional dimmer note at the right (`claude-default + ⌘N 對話框的選項`).
final class SettingsGroupHeadView: FlippedView {
    let title: String
    let cjk: String?
    var count: String? { didSet { needsDisplay = true } }
    var right: String? { didSet { needsDisplay = true } }

    init(title: String, cjk: String? = nil) {
        self.title = title
        self.cjk = cjk
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 16).zoomed(16).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x: CGFloat = 0
        x += Draw.text(TextStyle.caps(10.5, Palette.dim, tracking: 0.18).string(title), x: x, centerY: mid) + 8
        if let cjk { x += Draw.text(TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06).string(cjk), x: x, centerY: mid) + 8 }
        if let count { x += Draw.text(TextStyle.mono(10.5, Palette.amberDim).string(count), x: x, centerY: mid) + 8 }
        var end = bounds.width
        if let right {
            let text = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06).string(right)
            end -= Draw.width(text)
            Draw.text(text, x: end, centerY: mid)
            end -= 8
        }
        if end > x { Draw.dashedLine(from: CGPoint(x: x, y: round(mid)), to: CGPoint(x: end, y: round(mid)), color: Palette.lineBright) }
    }
}

/// `.sx-card`: bg-soft with a line-bright border; rows are stacked with dashed separators.
final class SettingsCardView: PanelView {
    private let stack = columnStack([], spacing: 0)
    private(set) var rowViews: [ProfileRowView] = []

    init() {
        super.init(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
    }

    func show(_ rows: [ProfileRowView]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            row.showsSeparator = index > 0
            stack.addFullWidth(row)
        }
        rowViews = rows
    }
}

/// One profile in the card (`.sx-row`, padding 11 / 16): glyph, name, chips, the command as
/// `code`, the meta line; `複製` `編輯` `刪除` at the right.
final class ProfileRowView: FlippedView {
    let row: ProfilesSettingsModel.Row
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var showsSeparator = false { didSet { needsDisplay = true } }
    let copyButton = CoddButton("複製", style: .bracket(.normal, small: true))
    let editButton = CoddButton("編輯", style: .bracket(.normal, small: true))
    let deleteButton = CoddButton("刪除", style: .bracket(.danger, small: true))
    private let controls = hStack([], spacing: 8)
    /// The buttons at the right, centered (`sideBySide`), or under the meta line (`stacked`): a
    /// narrow row (small window, zoom 20) would squeeze the name and the command into a sliver.
    private var sideBySide: [NSLayoutConstraint] = []
    private var stacked: [NSLayoutConstraint] = []
    private(set) var isStacked = false

    init(row: ProfilesSettingsModel.Row, readOnly: Bool) {
        self.row = row
        super.init(frame: .zero)
        let glyph = Label.make(row.glyph, style: TextStyle.mono(12.5, row.isClaude ? Palette.amber : Palette.cream))
        glyph.alignment = .center
        glyph.widthAnchor.constraint(equalToConstant: 12).zoomed(12).isActive = true
        let name = Label.make(row.name, style: TextStyle.mono(13, Palette.cream, .semibold))
        var chips: [NSView] = [glyph, name, ChipView(row.kind, style: Self.miniChip(Palette.bone, border: Palette.lineBright))]
        if row.isDefault { chips.append(ChipView("Default", style: Self.miniChip(Palette.amber, border: Palette.amberDim))) }
        let nameLine = hStack(chips, spacing: UIZoom.pt(8))
        let code = ChipView(row.command, style: ChipStyle(text: TextStyle.mono(12, Palette.amber), border: Palette.line, fill: Palette.bg,
                                                         height: 18, padding: 5))
        // A long command ends in `…` in a narrow window instead of holding Settings wide.
        code.truncates = true
        let meta = NSTextField(labelWithAttributedString: Self.metaText(row))
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, verb) in [(copyButton, "複製"), (editButton, "編輯"), (deleteButton, "刪除")] {
            button.setAccessibilityLabel("\(verb) \(row.name)")
            button.target = self
            button.isEnabled = !readOnly
        }
        copyButton.action = #selector(copyClicked)
        editButton.action = #selector(editClicked)
        deleteButton.action = #selector(deleteClicked)
        for button in [copyButton, editButton, deleteButton] { controls.addArrangedSubview(button) }
        controls.spacing = UIZoom.pt(8)
        // The name's own width gives way first (it truncates), then the row stacks.
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // `.sx-row` (padding 11 / 16, gap 24, centered controls) and `.sx-lab` (gap 5, the code and
        // meta lines 20 pt in), laid out explicitly so the lines never squeeze.
        for view in [nameLine, code, meta, controls] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameLine.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(16),
            nameLine.topAnchor.constraint(equalTo: topAnchor).zoomed(11),
            nameLine.heightAnchor.constraint(equalToConstant: 18).zoomed(18),
            code.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(36),
            code.topAnchor.constraint(equalTo: nameLine.bottomAnchor).zoomed(5),
            meta.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(36),
            meta.topAnchor.constraint(equalTo: code.bottomAnchor).zoomed(5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52).zoomed(52),
        ])
        sideBySide = [
            nameLine.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor).zoomed(-24),
            code.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor).zoomed(-24),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor).zoomed(-24),
            meta.bottomAnchor.constraint(equalTo: bottomAnchor).zoomed(-11),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-16),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        stacked = [
            nameLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).zoomed(-16),
            code.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).zoomed(-16),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).zoomed(-16),
            controls.topAnchor.constraint(equalTo: meta.bottomAnchor).zoomed(8),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(36),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).zoomed(-16),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor).zoomed(-11),
        ]
        NSLayoutConstraint.activate(sideBySide)
        setAccessibilityElement(false)
    }

    /// Whether a row of `width` puts its buttons (`controls` wide) under the meta line: beside
    /// them the name, command and meta would get less than 200 design points.
    static func stacks(width: CGFloat, controls: CGFloat) -> Bool {
        width - UIZoom.pt(36) - UIZoom.pt(24) - controls - UIZoom.pt(16) < UIZoom.pt(200)
    }

    /// Picks the arrangement for the row's width (only the width: no flicker while dragging).
    override func layout() {
        if bounds.width > 0 {
            let stack = Self.stacks(width: bounds.width, controls: controls.fittingSize.width)
            if stack != isStacked {
                isStacked = stack
                NSLayoutConstraint.deactivate(stack ? sideBySide : stacked)
                NSLayoutConstraint.activate(stack ? stacked : sideBySide)
            }
        }
        super.layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `.chip.caps.sx-mini`: 16 pt, 9.5 px caps.
    static func miniChip(_ color: NSColor, border: NSColor) -> ChipStyle {
        ChipStyle(text: TextStyle.caps(9.5, color, tracking: 0.1), border: border, fill: nil, height: 16, padding: 5)
    }

    /// `cwd 跟隨專案 · 帳號 跟隨全域 · 模型 預設（Claude Code：opus）` (dimmer labels, bone values).
    static func metaText(_ row: ProfilesSettingsModel.Row) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let label = TextStyle.mono(11, Palette.dimmer)
        let value = TextStyle.mono(11, Palette.bone)
        for (index, part) in [("cwd", row.cwd), ("帳號", row.account), ("模型", row.model)].enumerated() {
            if index > 0 { out.append(label.string(" · ")) }
            out.append(label.string(part.0 + " "))
            out.append(value.string(part.1))
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsSeparator { Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright) }
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func editClicked() { onEdit?() }
    @objc private func deleteClicked() { onDelete?() }
}

/// The Settings `.term` preview box: black, line-bright border, 12.5 mono; `$` dim, flags amber,
/// the quoted name cyan (Settings artboard 04 Preview).
final class SettingsTermView: PanelView {
    private let text = NSTextField(labelWithString: "")
    private(set) var command = ""

    init() {
        super.init(fill: Palette.termBackground, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(text)
        text.pinEdges(to: self, insets: UIZoom.insets(NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    func show(_ command: String) {
        self.command = command
        text.attributedStringValue = Self.colored(command)
        setAccessibilityValue(command)
    }

    @MainActor
    static func colored(_ command: String) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: TextStyle.mono(12.5, Palette.termDim).string("$ "))
        for (index, token) in CommandStripView.tokens(command).enumerated() {
            if index > 0 { out.append(TextStyle.mono(12.5, Palette.termForeground).string(" ")) }
            let color: NSColor
            if token.hasPrefix("-") {
                color = Palette.amber
            } else if token.hasPrefix("\"") || token.hasPrefix("'") {
                color = Palette.cyan
            } else {
                color = Palette.termForeground
            }
            out.append(TextStyle.mono(12.5, color).string(token))
        }
        return out
    }
}
