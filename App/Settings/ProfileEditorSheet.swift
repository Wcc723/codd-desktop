import AppKit
import CoddCore
import CoddUI

/// The launch profile editor: a sheet on the settings window (`+ New profile` / `編輯`). Fields
/// 名稱, 類型, 模型, 權限, 額外參數, Shell 路徑, 環境變數, `設為預設`; a live preview line and the
/// problems in 繁體中文 (`ProfileEditorForm`). `儲存 ⌘⏎` saves through `LaunchProfiles`; esc or
/// `取消` closes without saving. ⌘⏎ is claimed here (it is the main menu's 允許).
@MainActor
final class ProfileEditorSheet: NSWindowController {
    private(set) var form: ProfileEditorForm
    private let profiles: LaunchProfiles
    private let onClose: () -> Void

    let nameField = InputField(placeholder: "設定檔名稱", accessibilityLabel: "名稱")
    private let kindSwitch = SegmentedSwitch(titles: ["◆ Claude", "$ Shell"])
    let modelField = InputField(placeholder: "留空 = 預設", accessibilityLabel: "模型")
    private let permissionSwitch = SegmentedSwitch(titles: NewSessionForm.permissionModes, raw: true)
    let argumentsField = InputField(placeholder: "例如 --verbose", accessibilityLabel: "額外參數")
    let shellField = InputField(placeholder: "留空 = 使用者的 $SHELL", accessibilityLabel: "Shell 路徑")
    let environmentField = TextAreaField(accessibilityLabel: "環境變數")
    private let defaultSwitch = SwitchToggle(label: "設為預設")
    private let defaultHint = Label.make(style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
    private let preview = SettingsTermView()
    private let issuesLabel = WrappingLabel("", style: TextStyle.mono(11.5, Palette.danger))
    private var claudeRows: [NSView] = []
    private var shellRows: [NSView] = []
    private(set) var shownIssues: [ProfileEditorIssue] = []

    static let width: CGFloat = 600

    init(form: ProfileEditorForm, profiles: LaunchProfiles, onClose: @escaping () -> Void) {
        self.form = form
        self.profiles = profiles
        self.onClose = onClose
        let window = ProfileEditorWindow(contentRect: NSRect(x: 0, y: 0, width: UIZoom.pt(Self.width), height: 600),
                                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.bgSoft
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.onSave = { [weak self] in self?.save() }
        window.onCancel = { [weak self] in self?.close() }
        window.isComposing = { [weak self] in
            guard let self else { return false }
            return [self.nameField, self.modelField, self.argumentsField, self.shellField].contains { $0.isComposing }
                || self.environmentField.textView.hasMarkedText()
        }
        window.contentView = makeContent()
        window.initialFirstResponder = nameField.field
        fillFields()
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(nameField.field)
    }

    override func close() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
        onClose()
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let root = PanelView(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.amberDim)
        var display = TextStyle(font: Typeface.display(12.5), color: Palette.amber, tracking: 0.16, uppercase: true)
        display.shadow = HomeHeaderView.glow(Palette.amberGlow, radius: 10)
        let titleText = NSMutableAttributedString(attributedString: display.string("Profile · "))
        var cjk = display
        cjk.uppercase = false
        cjk.tracking = 0.04
        titleText.append(cjk.string(form.id == nil ? "新增啟動設定檔" : "編輯啟動設定檔"))
        let closeButton = CoddButton("✕", style: .glyph(size: 28), target: self, action: #selector(cancelClicked))
        closeButton.setAccessibilityLabel("關閉")
        let header = hStack([NSTextField(labelWithAttributedString: titleText), spacer(), closeButton], spacing: 10,
                            edgeInsets: NSEdgeInsets(top: 12, left: 20, bottom: 11, right: 12))
        let headerBand = PanelView(edges: [.bottom], edgeColor: Palette.lineBright, dashed: [.bottom])
        headerBand.addSubview(header)
        header.pinEdges(to: headerBand)

        nameField.onChange = { [weak self] text in self?.form.name = text; self?.sync() }
        kindSwitch.target = self
        kindSwitch.action = #selector(kindChanged)
        modelField.onChange = { [weak self] text in self?.form.model = text; self?.sync() }
        permissionSwitch.target = self
        permissionSwitch.action = #selector(permissionChanged)
        argumentsField.onChange = { [weak self] text in self?.form.arguments = text; self?.sync() }
        shellField.onChange = { [weak self] text in self?.form.shellPath = text; self?.sync() }
        environmentField.onChange = { [weak self] text in self?.form.environment = text; self?.sync() }
        environmentField.heightAnchor.constraint(equalToConstant: 84).zoomed(84).isActive = true
        defaultSwitch.target = self
        defaultSwitch.action = #selector(defaultChanged)

        let modelRow = field("模型 Model", [modelField])
        let permissionRow = field("權限 Permission", [hStack([permissionSwitch, spacer()], spacing: 0)])
        let argumentsRow = field("額外參數 Arguments", [argumentsField, hint(ProfileEditorForm.argumentsHint)])
        let shellRow = field("Shell 路徑 Shell", [shellField])
        claudeRows = [modelRow, permissionRow, argumentsRow]
        shellRows = [shellRow]
        let defaultRow = field("設為預設 Default", [hStack([defaultSwitch, defaultHint, spacer()], spacing: 10)])
        let previewRow = field("Preview 實際啟動指令", [preview])
        let body = columnStack([
            field("名稱 Name", [nameField]),
            field("類型 Kind", [hStack([kindSwitch, spacer()], spacing: 0)]),
            modelRow, permissionRow, argumentsRow, shellRow,
            field("環境變數 Environment", [environmentField, hint(ProfileEditorForm.environmentHint)]),
            defaultRow, previewRow, issuesLabel,
        ], spacing: 14, edgeInsets: NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20))

        let cancel = CoddButton("取消", style: .bracket(.normal, small: false), target: self, action: #selector(cancelClicked))
        let saveButton = CoddButton("儲存 ⌘⏎", style: .bracket(.primary, small: false), target: self, action: #selector(saveClicked))
        saveButton.isEnabled = profiles.canEdit
        let footer = hStack([spacer(), cancel, saveButton], spacing: 8, edgeInsets: NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20))
        let footerBand = PanelView(edges: [.top], edgeColor: Palette.line, dashed: [.top])
        footerBand.addSubview(footer)
        footer.pinEdges(to: footerBand)
        let stack = columnStack([headerBand, body, footerBand], spacing: 0)
        root.addSubview(stack)
        stack.pinEdges(to: root)
        root.widthAnchor.constraint(equalToConstant: Self.width).zoomed(Self.width).isActive = true
        return root
    }

    private func field(_ title: String, _ views: [NSView]) -> NSView {
        columnStack([Label.make(title, style: TextStyle.caps(10.5, Palette.dim, tracking: 0.16))] + views, spacing: 6)
    }

    private func hint(_ text: String) -> NSView {
        WrappingLabel(text, style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
    }

    private func fillFields() {
        nameField.text = form.name
        modelField.text = form.model
        argumentsField.text = form.arguments
        shellField.text = form.shellPath
        environmentField.text = form.environment
    }

    /// Kind-specific rows, the preview and the live problems.
    private func sync() {
        let claude = form.kind == .claude
        kindSwitch.selectedIndex = claude ? 0 : 1
        for row in claudeRows { row.isHidden = !claude }
        for row in shellRows { row.isHidden = claude }
        permissionSwitch.selectedIndex = NewSessionForm.permissionModes.firstIndex(of: form.permissionMode) ?? -1
        defaultSwitch.isOn = form.makeDefault
        defaultSwitch.isEnabled = !form.wasDefault
        Label.set(defaultHint, form.wasDefault ? "這是目前的預設；要換預設，請打開另一個設定檔的這個開關" : "⌘N 與 Home 預選這個設定檔",
                  style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
        let document = profiles.document
        preview.show(form.preview(in: document))
        let issues = form.build(in: document).issues
        shownIssues = issues
        var lines = issues.map { "▲ " + $0.message }
        if let refusal = profiles.editRefusal { lines.insert("▲ " + refusal, at: 0) }
        issuesLabel.isHidden = lines.isEmpty
        issuesLabel.attributedStringValue = TextStyle.mono(11.5, Palette.danger).string(lines.joined(separator: "\n"), lineBreak: .byWordWrapping)
        fitWindow()
    }

    private func fitWindow() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height)
        let frame = window.frame
        // The width at the interface zoom (the root's own width constraint is zoomed).
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: UIZoom.pt(Self.width), height: height)).size
        if frame.size != size {
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    // MARK: Actions

    @objc private func kindChanged() {
        form.kind = kindSwitch.selectedIndex == 0 ? .claude : .shell
        sync()
    }

    @objc private func permissionChanged() {
        let modes = NewSessionForm.permissionModes
        guard modes.indices.contains(permissionSwitch.selectedIndex) else { return }
        form.permissionMode = modes[permissionSwitch.selectedIndex]
        sync()
    }

    @objc private func defaultChanged() {
        form.makeDefault = defaultSwitch.isOn
        sync()
    }

    @objc private func cancelClicked() { close() }
    @objc private func saveClicked() { save() }

    /// Saves when there is nothing to fix; returns whether it saved (and closed).
    @discardableResult
    func save() -> Bool {
        guard profiles.canEdit else { NSSound.beep(); return false }
        let built = form.build(in: profiles.document)
        guard built.issues.isEmpty else {
            shownIssues = built.issues
            NSSound.beep()
            sync()
            return false
        }
        let refused = profiles.upsert(built.profile)
        guard refused.isEmpty else {
            shownIssues = refused.map(ProfileEditorIssue.profile)
            NSSound.beep()
            return false
        }
        if form.makeDefault, !form.wasDefault { profiles.setDefault(built.profile.id) }
        HolderSessionStore.printLog("profiles saved \(built.profile.id) default=\(form.makeDefault)")
        close()
        return true
    }

    // MARK: Testing

    /// Sets the form as if typed (tests and DEBUG runs).
    func setForm(_ next: ProfileEditorForm) {
        form = next
        fillFields()
        sync()
    }
}

/// ⌘⏎ saves and esc closes (left to the input method while it composes), before the main menu.
final class ProfileEditorWindow: NSWindow {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var isComposing: () -> Bool = { false }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 0x24 || event.keyCode == 0x4C, modifiers == .command {
            if !isComposing() { onSave?() }
            return true
        }
        if event.keyCode == 0x35, modifiers.isEmpty, !isComposing() {
            onCancel?()
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
