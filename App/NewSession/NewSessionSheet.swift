import AppKit
import CoddCore
import CoddUI

/// Where the ⌘N sheet gets its data and what it can start. Real mode: the store and AppServices;
/// mock mode: the SPEC §5 data (the sheet can be drawn and compared, nothing starts).
@MainActor
struct NewSessionSources {
    var knownProjects: @MainActor () -> [ProjectChoice]
    /// `.claude.json` folders (observable in real mode: the sheet refreshes when they arrive).
    var claudeProjects: @MainActor () -> [RecentProject]
    var groups: @MainActor () -> [GroupID: (name: String, color: TagColor?)]
    /// Claude's `cleanupPeriodDays` and `model` (D18, D30), read only.
    var claudeSettings: @MainActor () -> ClaudeUserSettingsSummary
    /// D18: the folder's conversations (off the main actor, cached briefly).
    var transcripts: @MainActor (String) async -> [TranscriptSummary]
    var isTranscriptListCached: @MainActor (String) -> Bool
    /// Conversations a live claude uses (picker rows shown `執行中`).
    var inUseClaudeSessionIDs: @MainActor () -> Set<String>
    /// `+ 加入`: the folder becomes an ungrouped project. False when refused.
    var addProject: @MainActor (String) -> Bool
    /// Starts the session; nil when started, else the reason to show.
    var create: @MainActor (NewSessionRequest) -> String?
    /// `編輯設定檔…`: Settings › 啟動設定檔.
    var openProfileSettings: @MainActor () -> Void
    var now: @MainActor () -> Date
    /// D12: the account select (observable: the sheet follows an account read).
    var accountOptions: @MainActor () -> [NewSessionAccountOption] = { [] }
    /// The `.ns-quota` line for an account option id (follow = the active account), nil to hide it.
    var accountQuota: @MainActor (String?) -> NewSessionQuota? = { _ in nil }
    /// Settings › 一般 › 預設專案根目錄 (`~` expanded): where `選擇資料夾…` starts without a folder.
    var projectRoot: @MainActor () -> String? = { nil }
    /// Settings › 清理 › 接續前提醒: the resume picker's expiry warning.
    var resumeWarning: @MainActor () -> Bool = { true }
}

extension NewSessionSources {
    /// Real mode: the store's saved projects, `.claude.json`, Claude's settings and transcripts
    /// through AppServices (cached, off the main actor), `+ 加入` as an ungrouped project.
    static func real(holders: HolderSessionStore, services: AppServices, accounts: (any AccountStore)? = nil,
                     create: @escaping @MainActor (NewSessionRequest) -> String?,
                     openProfileSettings: @escaping @MainActor () -> Void) -> NewSessionSources {
        NewSessionSources(
            knownProjects: { ProjectChoice.known(in: holders) },
            claudeProjects: { services.recentProjects },
            groups: { groupTable(holders) },
            claudeSettings: { services.claudeSettings },
            transcripts: { await services.transcripts(for: $0) },
            isTranscriptListCached: { services.isTranscriptListCached($0) },
            inUseClaudeSessionIDs: { services.inUseClaudeSessionIds },
            addProject: { holders.addProject(path: $0, groupID: nil) != nil },
            create: create,
            openProfileSettings: openProfileSettings,
            now: { holders.clock.now() },
            accountOptions: { accounts?.newSessionAccountOptions ?? [] },
            accountQuota: { id in accounts.flatMap { NewSessionQuota.make(option: id, accounts: $0) } })
    }

    /// Mock mode: the SPEC §5 store, transcripts and `.claude.json` folders; nothing starts.
    static func mock(store: any SessionStore, accounts: any AccountStore = MockAccountStore(),
                     openProfileSettings: @escaping @MainActor () -> Void) -> NewSessionSources {
        let transcripts = MockData.resumeTranscripts()
        return NewSessionSources(
            knownProjects: { ProjectChoice.known(in: store) },
            claudeProjects: { MockData.claudeJsonProjects },
            groups: { groupTable(store) },
            claudeSettings: { MockData.claudeSettings },
            transcripts: { transcripts[HolderSessionStore.standardize($0)] ?? [] },
            isTranscriptListCached: { _ in true },
            inUseClaudeSessionIDs: { [] },
            addProject: { _ in false },
            create: { _ in "mock 模式不能開 session" },
            openProfileSettings: openProfileSettings,
            now: { store.clock.now() },
            accountOptions: { accounts.newSessionAccountOptions },
            accountQuota: { NewSessionQuota.make(option: $0, accounts: accounts) })
    }

    /// User groups by id (the footer's `■ <group>` for a new folder's group).
    static func groupTable(_ store: any SessionStore) -> [GroupID: (name: String, color: TagColor?)] {
        Dictionary(store.groups.filter { !$0.isUngrouped }.map { ($0.id, (name: $0.name, color: $0.color)) }, uniquingKeysWith: { a, _ in a })
    }
}

/// ⌘N `New session · 新增 session` (NewSession artboard, SPEC §7.5, D16 / D18 / D22 / D30): a
/// 720 pt sheet on the main window, a 348 | 1fr grid of the project combobox and kind, the start
/// radios with the resume picker and the (fixed) account, model | permission, name | color, the
/// advanced row with the launch profile, the black command strip with its copy button and the
/// footer with where the session will show up.
///
/// Keys: ⌘⏎ creates (the sheet and its project list claim it before the main menu's 允許), esc
/// closes the project list first and the sheet second, ⌘O picks a folder, 1–8 pick a color while
/// no text field has focus, ↑↓ ⏎ walk the open project list. The combobox's list is a borderless
/// child window of the sheet (it closes with it).
@MainActor
final class NewSessionSheet: NSWindowController {
    private(set) var form: NewSessionForm
    let sources: NewSessionSources
    private let profiles: LaunchProfiles
    private let onClose: () -> Void
    /// The form, the list or the picker changed (state dump).
    var onChange: (() -> Void)?

    private var known: [ProjectChoice] = []
    private var claudeProjects: [RecentProject] = []
    /// What the user typed into the combobox; nil while it shows the chosen project.
    private var query: String?
    private(set) var dropdownModel = ProjectDropdownModel()
    let dropdown = ProjectDropdownPanel()
    private(set) var isDropdownOpen = false
    private(set) var pickerContent: ResumePickerView.Content = .loading
    private var pickerSummaries: [String: TranscriptSummary] = [:]
    /// The folder the picker lists (or is loading).
    private var pickerFolder: String?
    private var pickerGeneration = 0
    private var loop: ObservationLoop?
    private let dim = DimOverlayView()
    private let createdAt = ContinuousClock.now
    /// The sheet's open time and the latest picker load (log lines, report).
    private(set) var openDuration: Duration?
    /// Building the controls (init) and attaching the sheet (present), for the log.
    private var buildDuration: Duration = .zero
    private(set) var lastPickerLoad: (count: Int, duration: Duration, cached: Bool)?
    private var isClosing = false

    // MARK: Views

    let combobox = ProjectComboBox()
    private let kindSwitch = SegmentedSwitch(titles: ["◆ Claude", "$ Shell"])
    private let radioNew = RadioRowView(title: "新對話", hint: "自動帶 --session-id")
    private let radioResume = RadioRowView(title: "接續先前對話", hint: "claude --resume")
    private let radioRC = RadioRowView(title: "從 Remote Control 啟動", hint: "--remote-control")
    let picker = ResumePickerView()
    private let pickerBox = NSView()
    private let accountSelect = SelectButton(titles: ["跟隨全域登入"], accessibilityLabel: "帳號")
    private let accountQuota = NewSessionQuotaLineView()
    private let modelSelect = SelectButton(titles: [], accessibilityLabel: "模型")
    private let customModel = InputField(placeholder: "輸入模型名稱", accessibilityLabel: "其他模型")
    private let permissionSwitch = SegmentedSwitch(titles: NewSessionForm.permissionModes, raw: true)
    private let permissionHint = WrappingLabel("", style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
    let nameField = InputField(placeholder: "留空 = 由 Claude 命名", accessibilityLabel: "名稱")
    private lazy var swatches = SwatchMenuItemView(current: form.tag, showsLabel: false) { [weak self] tag in
        self?.setTag(tag)
    }
    private let advancedToggle = DisclosureButton(title: "進階 Advanced")
    private let advancedHint = Label.make(style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
    private let profileSelect = SelectButton(titles: [], accessibilityLabel: "Launch profile")
    private let profileDetail = Label.make(style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
    private let editProfiles = CoddButton("編輯設定檔…", style: .link)
    private let advancedPanel = NSView()
    private let errorLabel = Label.make(style: TextStyle.mono(11.5, Palette.danger))
    let commandStrip = CommandStripView()
    private let destinationLabel = Label.make(style: TextStyle.mono(11, Palette.bone))
    private let destinationSquare = ColorSquareView(color: nil)
    private var shellHidden: [NSView] = []
    private var nameHint: NSTextField?
    private var nameKind: SessionKind?

    static let width: CGFloat = 720
    static let leftColumn: CGFloat = 348

    init(form initial: NewSessionForm, sources: NewSessionSources, profiles: LaunchProfiles, onClose: @escaping () -> Void) {
        form = initial
        self.sources = sources
        self.profiles = profiles
        self.onClose = onClose
        let window = NewSessionWindow(contentRect: NSRect(x: 0, y: 0, width: UIZoom.pt(Self.width), height: 600),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.bgSoft
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("新增 session")
        super.init(window: window)
        window.onCreate = { [weak self] in self?.create() }
        window.onCancel = { [weak self] in self?.close() }
        window.onEscape = { [weak self] in self?.escape() ?? false }
        window.onChooseFolder = { [weak self] in self?.chooseFolder() }
        window.onDigit = { [weak self] characters in self?.digit(characters) ?? false }
        window.onMouseDown = { [weak self] view in self?.mouseDownInSheet(view) }
        window.isComposing = { [weak self] in
            guard let self else { return false }
            return self.combobox.isComposing || self.nameField.isComposing || self.customModel.isComposing
        }
        dropdown.onCommandReturn = { [weak self] in self?.create() }
        dropdown.onCancel = { [weak self] in self?.closeDropdown(restore: true) }
        known = sources.knownProjects()
        claudeProjects = sources.claudeProjects()
        form.setAccountOptions(sources.accountOptions())
        window.contentView = makeContent()
        window.initialFirstResponder = combobox.field
        wireActions()
        showChoiceInCombobox()
        sync()
        buildDuration = ContinuousClock.now - createdAt
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Presenting

    /// Attaches the sheet to `parent` (dimmed like the artboard's `.backdrop`); `openDropdown`
    /// opens the project list right away (DEBUG snapshots).
    func present(on parent: NSWindow, openDropdown: Bool = false) {
        guard let window else { return }
        if let content = parent.contentView {
            dim.frame = content.bounds
            dim.autoresizingMask = [.width, .height]
            content.addSubview(dim)
        }
        // AppKit runs the sheet's slide-in inside beginSheet (about 0.28 s here): logged apart.
        let attachStart = ContinuousClock.now
        parent.beginSheet(window)
        let attach = ContinuousClock.now - attachStart
        window.makeFirstResponder(combobox.field)
        loop = ObservationLoop(track: { [weak self] () -> (LaunchProfileDocument, ClaudeUserSettingsSummary, [RecentProject],
                                                         [NewSessionAccountOption], NewSessionQuota?)? in
            guard let self else { return nil }
            return (self.profiles.document, self.sources.claudeSettings(), self.sources.claudeProjects(), self.sources.accountOptions(),
                    self.sources.accountQuota(self.form.accountOption?.id))
        }, apply: { [weak self] value in
            guard let self, let value else { return }
            if value.3 != self.form.accountOptions {
                self.form.setAccountOptions(value.3)
                self.sync()
            }
            // The numbers of the account shown move with reports and reads (the pick goes through sync).
            self.accountQuota.quota = self.sources.accountQuota(self.form.accountOption?.id)
            self.externalDataChanged(profiles: value.0, settings: value.1, claudeProjects: value.2)
        })
        if form.start.isResume { reloadPicker() }
        if openDropdown { openDropdownList() }
        openDuration = ContinuousClock.now - createdAt
        let suggested = ProjectDropdownModel.build(query: nil, known: known, recent: claudeProjects, chosenPath: nil).suggested.count
        HolderSessionStore.printLog(String(format: "NEWSESSION shown ms=%.2f buildMs=%.2f sheetMs=%.2f path=%@ start=%@ known=%d suggested=%d",
                                           TerminalHub.milliseconds(openDuration ?? .zero), TerminalHub.milliseconds(buildDuration),
                                           TerminalHub.milliseconds(attach), form.resolvedPath, form.start.mode, known.count, suggested))
        onChange?()
    }

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        loop?.cancel()
        loop = nil
        closeDropdown(restore: false)
        dim.removeFromSuperview()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
        onClose()
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let root = SheetRootView()
        root.onBackgroundClick = { [weak self] in self?.window?.makeFirstResponder(nil) }

        // m-h
        let titleText = NSMutableAttributedString()
        var display = TextStyle(font: Typeface.display(12.5), color: Palette.amber, tracking: 0.16, uppercase: true)
        display.shadow = HomeHeaderView.glow(Palette.amberGlow, radius: 10)
        titleText.append(display.string("New session · "))
        var cjk = TextStyle(font: Typeface.display(12.5), color: Palette.amber, tracking: 0.04)
        cjk.shadow = display.shadow
        titleText.append(cjk.string("新增 session"))
        let title = NSTextField(labelWithAttributedString: titleText)
        title.setAccessibilityRole(.staticText)
        let closeButton = CoddButton("✕", style: .glyph(size: 28), target: self, action: #selector(cancelClicked))
        closeButton.setAccessibilityLabel("關閉")
        let header = hStack([title, spacer(), ChipView.kbd("⌘N"), closeButton], spacing: 10,
                            edgeInsets: NSEdgeInsets(top: 12, left: 20, bottom: 11, right: 12))
        let headerBand = PanelView(edges: [.bottom], edgeColor: Palette.lineBright, dashed: [.bottom])
        headerBand.addSubview(header)
        header.pinEdges(to: headerBand)

        // Left column: project + kind.
        let projectField = field([labelRow("專案 Project", hint: "輸入名稱或路徑篩選"), combobox])
        let kindHint = Label.make("SHELL 只在專案目錄開 zsh", style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
        kindSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let kindRow = hStack([kindSwitch, kindHint], spacing: 10)
        let kindField = field([label("類型 Kind"), kindRow])
        let left = columnStack([projectField, kindField], spacing: 14)

        // Right column: start + account.
        pickerBox.addSubview(picker)
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: pickerBox.leadingAnchor, constant: 22),
            picker.trailingAnchor.constraint(equalTo: pickerBox.trailingAnchor),
            picker.topAnchor.constraint(equalTo: pickerBox.topAnchor),
            picker.bottomAnchor.constraint(equalTo: pickerBox.bottomAnchor),
        ])
        let radios = columnStack([radioNew, radioResume, pickerBox, radioRC], spacing: 4)
        radios.setAccessibilityRole(.radioGroup)
        radios.setAccessibilityLabel("開始方式")
        let startField = field([label("開始方式 Start"), radios])
        let accountHint = WrappingLabel("改選固定帳號會以 cswap run 建立獨立設定目錄，對話紀錄分開存放",
                                        style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
        let accountField = field([label("帳號 Account"), accountSelect, accountQuota, accountHint])
        let right = columnStack([startField, accountField], spacing: 14)

        // Model | permission, name | color.
        customModel.isHidden = true
        let modelField = field([label("模型 Model"), modelSelect, customModel])
        let permissionField = field([label("權限 Permission"), leading(permissionSwitch), permissionHint])
        let nameBlock = field([labelRow("名稱 Name", hint: "側欄顯示，並以 -n 傳給 claude", keep: \.nameHint), nameField])
        let colorBlock = field([labelRow("顏色 Color", hint: "1–8 快速選色"), leading(swatches)])
        swatches.setContentHuggingPriority(.required, for: .horizontal)

        let row1 = gridRow(left, right)
        let row2 = gridRow(modelField, permissionField)
        let row3 = gridRow(nameBlock, colorBlock)

        // Advanced.
        advancedHint.lineBreakMode = .byTruncatingTail
        let advancedRow = hStack([advancedToggle, advancedHint], spacing: 12, edgeInsets: NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0))
        advancedToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        let advancedBand = PanelView(edges: [.top], edgeColor: Palette.line, dashed: [.top])
        advancedBand.addSubview(advancedRow)
        advancedRow.pinEdges(to: advancedBand)
        let profileLabel = Label.make("Launch profile", style: TextStyle.caps(10.5, Palette.dim, tracking: 0.16))
        profileSelect.widthAnchor.constraint(equalToConstant: 220).zoomed(220).isActive = true
        profileDetail.lineBreakMode = .byTruncatingTail
        let advancedLine = hStack([profileLabel, profileSelect, profileDetail, spacer(), editProfiles], spacing: 10)
        advancedPanel.addSubview(advancedLine)
        advancedLine.pinEdges(to: advancedPanel)

        let body = columnStack([row1, row2, row3, advancedBand, advancedPanel, errorLabel], spacing: 14,
                               edgeInsets: NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20))
        body.setCustomSpacing(10, after: advancedBand)
        errorLabel.isHidden = true
        advancedPanel.isHidden = true

        // m-f
        let cancel = CoddButton("取消", style: .bracket(.normal, small: false), target: self, action: #selector(cancelClicked))
        let createButton = CoddButton("建立 ⌘⏎", style: .bracket(.primary, small: false), target: self, action: #selector(createClicked))
        let lead = Label.make("建立後放在", style: TextStyle.mono(11, Palette.dimmer))
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        let destination = hStack([lead, destinationSquare, destinationLabel], spacing: 6)
        let footer = hStack([destination, spacer(), cancel, createButton], spacing: 8,
                            edgeInsets: NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20))
        let footerBand = PanelView(edges: [.top], edgeColor: Palette.line, dashed: [.top])
        footerBand.addSubview(footer)
        footer.pinEdges(to: footerBand)

        commandStrip.onCopy = { [weak self] in self?.copyCommand() }

        shellHidden = [startField, accountField, row2, advancedBand, advancedPanel]
        let stack = columnStack([headerBand, body, commandStrip, footerBand], spacing: 0)
        root.addSubview(stack)
        stack.pinEdges(to: root)
        root.widthAnchor.constraint(equalToConstant: Self.width).zoomed(Self.width).isActive = true
        return root
    }

    private func label(_ text: String) -> NSView {
        Label.make(text, style: TextStyle.caps(10.5, Palette.dim, tracking: 0.16))
    }

    /// `.ns-lrow`: the caps label and its hint on one line, apart (`keep` stores the hint label).
    private func labelRow(_ title: String, hint: String, keep: ReferenceWritableKeyPath<NewSessionSheet, NSTextField?>? = nil) -> NSView {
        let hintLabel = Label.make(hint, style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
        hintLabel.alignment = .right
        if let keep { self[keyPath: keep] = hintLabel }
        return hStack([label(title), spacer(), hintLabel], spacing: 8)
    }

    /// `.field`: label row, then the controls, 6 pt apart, full width.
    private func field(_ views: [NSView]) -> NSStackView {
        columnStack(views, spacing: 6)
    }

    /// A control that keeps its own width at the start of a full-width row.
    private func leading(_ view: NSView) -> NSView {
        hStack([view, spacer()], spacing: 0)
    }

    /// One `.ns-grid` row: 348 | the rest, 24 apart, top-aligned.
    private func gridRow(_ left: NSView, _ right: NSView) -> NSView {
        let row = NSView()
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.widthAnchor.constraint(equalToConstant: Self.leftColumn).zoomed(Self.leftColumn),
            left.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 24),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.topAnchor.constraint(equalTo: row.topAnchor),
            right.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
        ])
        // `align-items: start`: the row is as tall as its taller column; neither stretches.
        let hug = row.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
        return row
    }

    private func wireActions() {
        combobox.onTextChange = { [weak self] text in self?.comboboxTyped(text) }
        combobox.onCommand = { [weak self] selector in self?.comboboxCommand(selector) ?? false }
        combobox.onToggle = { [weak self] in
            guard let self else { return }
            if self.isDropdownOpen { self.closeDropdown(restore: true) } else { self.openDropdownList(); self.combobox.focus() }
        }
        dropdown.list.onHover = { [weak self] index in self?.dropdown.list.setHighlighted(index) }
        dropdown.list.onPick = { [weak self] index in self?.pickDropdownRow(index) }
        dropdown.list.onAdd = { [weak self] index in self?.addSuggestion(index) }
        kindSwitch.target = self
        kindSwitch.action = #selector(kindChanged)
        permissionSwitch.target = self
        permissionSwitch.action = #selector(permissionChanged)
        radioNew.onClick = { [weak self] in self?.setStart(.new) }
        radioResume.onClick = { [weak self] in self?.setStart(.resume(nil)) }
        radioRC.onClick = { [weak self] in self?.setStart(.remoteControl) }
        picker.onSelect = { [weak self] row in self?.pickTranscript(row.id) }
        modelSelect.onSelect = { [weak self] index in self?.modelPicked(index) }
        accountSelect.onSelect = { [weak self] index in self?.accountPicked(index) }
        customModel.onChange = { [weak self] text in self?.form.customModel = text; self?.sync() }
        nameField.onChange = { [weak self] text in self?.form.setName(text); self?.sync(name: false) }
        profileSelect.onSelect = { [weak self] index in self?.profilePicked(index) }
        advancedToggle.target = self
        advancedToggle.action = #selector(advancedClicked)
        editProfiles.target = self
        editProfiles.action = #selector(editProfilesClicked)
    }

    // MARK: Syncing

    /// Pushes the form into the controls (`name: false` while the user types the name).
    private func sync(name: Bool = true) {
        let claude = form.kind == .claude
        kindSwitch.selectedIndex = claude ? 0 : 1
        for view in shellHidden { view.isHidden = !claude }
        advancedPanel.isHidden = !claude || !form.advancedOpen
        radioNew.isOn = form.start == .new
        radioResume.isOn = form.start.isResume
        radioRC.isOn = form.start == .remoteControl
        pickerBox.isHidden = !(claude && form.start.isResume)
        modelSelect.setItems(NewSessionForm.ModelChoice.allCases.map(form.modelTitle),
                             selected: NewSessionForm.ModelChoice.allCases.firstIndex(of: form.modelChoice) ?? 0,
                             enabled: [], toolTips: [form.defaultModelHint])
        let accountOptions = form.accountOptions.isEmpty
            ? [NewSessionAccountOption(id: NewSessionAccountOption.followID, title: "跟隨全域登入", enabled: true, hint: nil)]
            : form.accountOptions
        accountSelect.setItems(accountOptions.map(\.title),
                               selected: accountOptions.firstIndex { $0.id == form.accountOption?.id } ?? 0,
                               enabled: accountOptions.map(\.enabled), toolTips: accountOptions.map(\.hint))
        // D12: one entry means nothing to choose (no cswap accounts).
        accountSelect.isEnabled = accountOptions.count > 1
        accountQuota.quota = sources.accountQuota(form.accountOption?.id)
        customModel.isHidden = form.modelChoice != .other
        if customModel.text != form.customModel { customModel.text = form.customModel }
        permissionSwitch.selectedIndex = NewSessionForm.permissionModes.firstIndex(of: form.permissionMode) ?? -1
        Label.set(permissionHint, form.permissionHint, style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02))
        if name, nameField.text != form.name { nameField.text = form.name }
        // A shell has no -n: its name is only CODD's.
        if nameKind != form.kind {
            nameKind = form.kind
            if let nameHint {
                Label.set(nameHint, claude ? "側欄顯示，並以 -n 傳給 claude" : "側欄顯示的名稱",
                          style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
            }
            nameField.field.placeholderAttributedString = TextStyle.mono(12.5, Palette.dimmer)
                .string(claude ? "留空 = 由 Claude 命名" : "留空 = 使用 shell 的標題")
        }
        swatches.setCurrent(form.tag)
        advancedToggle.isOpen = form.advancedOpen
        let summary = form.advancedSummary
        let hint = NSMutableAttributedString(attributedString: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02).string("launch profile "))
        hint.append(TextStyle.mono(10.5, Palette.cream, tracking: 0.02).string(summary.profile))
        hint.append(TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02).string(" · " + summary.rest))
        if advancedHint.attributedStringValue != hint { advancedHint.attributedStringValue = hint }
        let claudeProfiles = form.profiles.profiles.filter { $0.kind == .claude }
        profileSelect.setItems(claudeProfiles.map(\.name), selected: claudeProfiles.firstIndex { $0.id == form.profile.id } ?? 0)
        let flags = form.profile.extraArguments.isEmpty ? "—" : LaunchProfileEditing.formatArguments(form.profile.extraArguments)
        Label.set(profileDetail, "env \(form.profile.environment.count) 個 · 額外參數 \(flags)",
                  style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
        commandStrip.show(form.commandPreview())
        if let destination = form.destination(known: known, groups: sources.groups()) {
            destinationSquare.isHidden = destination.tag == nil
            destinationSquare.color = destination.tag?.color
            Label.set(destinationLabel, destination.text, style: TextStyle.mono(11, Palette.bone))
        } else {
            destinationSquare.isHidden = true
            Label.set(destinationLabel, "—", style: TextStyle.mono(11, Palette.dimmer))
        }
        if !errorLabel.isHidden, form.isValid { showError(nil) }
        fitWindow()
        onChange?()
    }

    /// The sheet is as tall as its content (the picker and the shell kind change it); the top
    /// edge stays attached, the project list follows the box.
    private func fitWindow() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height)
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        // The width at the interface zoom (the root's own width constraint is zoomed).
        let width = UIZoom.pt(Self.width)
        if content.height != height || content.width != width {
            let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        if isDropdownOpen { placeDropdown() }
    }

    private func showError(_ message: String?) {
        errorLabel.isHidden = message == nil
        Label.set(errorLabel, message.map { "▲ " + $0 } ?? "", style: TextStyle.mono(11.5, Palette.danger))
        fitWindow()
    }

    /// The profiles, Claude's settings or `.claude.json` changed while the sheet is up.
    private func externalDataChanged(profiles document: LaunchProfileDocument, settings: ClaudeUserSettingsSummary,
                                     claudeProjects projects: [RecentProject]) {
        var changed = false
        if document != form.profiles {
            form.profiles = document
            if document.profile(id: form.profileID ?? "")?.kind != .claude { form.setProfile(nil) }
            changed = true
        }
        if settings.model != form.settingsModel {
            form.settingsModel = settings.model
            changed = true
        }
        if projects != claudeProjects {
            claudeProjects = projects
            if isDropdownOpen { rebuildDropdown(keepHighlight: true) }
        }
        if case .rows(let rows) = pickerContent, settings.cleanupPeriodDays != nil {
            // Expiry depends on cleanupPeriodDays, which may arrive after the list.
            let fresh = ResumePicker.rows(rows.compactMap { pickerSummaries[$0.id] }, inUse: sources.inUseClaudeSessionIDs(),
                                          cleanupPeriodDays: settings.cleanupPeriodDays, now: sources.now(),
                                          warnExpiry: sources.resumeWarning())
            if fresh != rows { pickerContent = .rows(fresh); showPicker() }
        }
        if changed { sync() }
    }

    // MARK: Combobox

    private func showChoiceInCombobox() {
        let folder = form.resolvedPath
        let choice = known.first { HolderSessionStore.standardize($0.path) == folder }
        combobox.text = choice?.name ?? (form.hasFolder ? HolderSessionStore.projectName(cwd: folder) : form.path)
        combobox.showChoice(tag: choice?.tag, known: choice != nil, path: form.hasFolder ? folder : "")
    }

    private func comboboxTyped(_ text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            // A typed path is the folder (as in M1); the list filters by it too.
            form.path = trimmed
            combobox.showChoice(tag: nil, known: false, path: form.hasFolder ? form.resolvedPath : "")
            folderChanged()
        }
        if isDropdownOpen { rebuildDropdown(keepHighlight: false) } else { openDropdownList() }
    }

    private func comboboxCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if isDropdownOpen { moveHighlight(1) } else { openDropdownList() }
        case #selector(NSResponder.moveUp(_:)):
            if isDropdownOpen { moveHighlight(-1) } else { openDropdownList() }
        case #selector(NSResponder.insertNewline(_:)):
            guard isDropdownOpen else { return false }
            pickDropdownRow(dropdown.list.highlighted)
        case #selector(NSResponder.cancelOperation(_:)):
            if !escape() { close() }
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            closeDropdown(restore: true)
            return false
        default:
            return false
        }
        return true
    }

    private func moveHighlight(_ step: Int) {
        dropdown.list.setHighlighted(dropdown.list.highlighted + step)
        dropdown.scrollToHighlighted()
        onChange?()
    }

    /// Opens (or refreshes) the project list under the box.
    func openDropdownList() {
        guard let window else { return }
        known = sources.knownProjects()
        rebuildDropdown(keepHighlight: false)
        if !isDropdownOpen {
            isDropdownOpen = true
            combobox.isOpen = true
            placeDropdown()
            window.addChildWindow(dropdown, ordered: .above)
            dropdown.orderFront(nil)
        }
        onChange?()
    }

    func closeDropdown(restore: Bool) {
        guard isDropdownOpen else { return }
        isDropdownOpen = false
        combobox.isOpen = false
        window?.removeChildWindow(dropdown)
        dropdown.orderOut(nil)
        if restore, query != nil {
            query = nil
            showChoiceInCombobox()
        }
        onChange?()
    }

    /// esc: the open list closes first (returns true); otherwise the sheet closes.
    private func escape() -> Bool {
        guard isDropdownOpen else { return false }
        closeDropdown(restore: true)
        return true
    }

    private func rebuildDropdown(keepHighlight: Bool) {
        let previous = dropdown.list.highlighted
        dropdownModel = ProjectDropdownModel.build(query: query, known: known, recent: claudeProjects,
                                                   chosenPath: form.hasFolder ? form.resolvedPath : nil)
        let chosen = dropdownModel.rows.firstIndex { $0.isChosen }
        let highlight = keepHighlight ? previous : (query == nil ? (chosen ?? 0) : 0)
        dropdown.list.show(dropdownModel, highlighted: highlight)
        if isDropdownOpen { placeDropdown() }
        onChange?()
    }

    private func placeDropdown() {
        guard let window else { return }
        let box = window.convertToScreen(combobox.convert(combobox.bounds, to: nil))
        dropdown.place(under: box, screen: window.screen?.visibleFrame)
        dropdown.scrollToHighlighted()
    }

    private func pickDropdownRow(_ index: Int) {
        let rows = dropdownModel.rows
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        switch row.kind {
        case .chooseFolder:
            closeDropdown(restore: true)
            chooseFolder()
        case .recent, .suggestion:
            guard let choice = row.choice else { return }
            choose(choice)
        }
    }

    /// `+ 加入`: the folder becomes a project (ungrouped), then it is the choice.
    private func addSuggestion(_ index: Int) {
        let rows = dropdownModel.rows
        guard rows.indices.contains(index), let choice = rows[index].choice else { return }
        guard sources.addProject(choice.path) else { NSSound.beep(); return }
        known = sources.knownProjects()
        let added = known.first { HolderSessionStore.standardize($0.path) == HolderSessionStore.standardize(choice.path) } ?? choice
        choose(added)
    }

    private func choose(_ choice: ProjectChoice) {
        form.path = choice.path
        query = nil
        closeDropdown(restore: false)
        showChoiceInCombobox()
        folderChanged()
        sync()
    }

    private func folderChanged() {
        if form.start.isResume { reloadPicker() }
    }

    // MARK: Actions

    @objc private func kindChanged() {
        form.kind = kindSwitch.selectedIndex == 0 ? .claude : .shell
        if form.kind == .claude, form.start.isResume { reloadPicker() }
        sync()
    }

    @objc private func permissionChanged() {
        let modes = NewSessionForm.permissionModes
        guard modes.indices.contains(permissionSwitch.selectedIndex) else { return }
        form.permissionMode = modes[permissionSwitch.selectedIndex]
        sync()
    }

    private func setStart(_ start: NewSessionForm.Start) {
        form.setStart(start)
        if start.isResume {
            reloadPicker()
        }
        sync()
    }

    private func modelPicked(_ index: Int) {
        let choices = NewSessionForm.ModelChoice.allCases
        guard choices.indices.contains(index) else { return }
        form.modelChoice = choices[index]
        sync()
        if form.modelChoice == .other { customModel.focus() }
    }

    private func profilePicked(_ index: Int) {
        let claudeProfiles = form.profiles.profiles.filter { $0.kind == .claude }
        guard claudeProfiles.indices.contains(index) else { return }
        form.setProfile(claudeProfiles[index].id)
        sync()
    }

    private func setTag(_ tag: TagColor?) {
        form.tag = tag
        sync()
    }

    @objc private func advancedClicked() {
        form.advancedOpen.toggle()
        sync()
    }

    @objc private func editProfilesClicked() {
        sources.openProfileSettings()
    }

    /// 1–8 / 0 while no text field has focus.
    private func digit(_ characters: String) -> Bool {
        guard let color = NewSessionForm.color(forDigit: characters) else { return false }
        setTag(color)
        return true
    }

    /// A click outside the project box closes its list (the list window has its own clicks).
    private func mouseDownInSheet(_ view: NSView?) {
        guard isDropdownOpen else { return }
        if let view, view.isDescendant(of: combobox) { return }
        closeDropdown(restore: true)
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(form.commandPreview(abbreviated: false), forType: .string)
        commandStrip.flashCopied()
    }

    func chooseFolder() {
        guard let window else { return }
        closeDropdown(restore: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        panel.message = "選一個專案資料夾"
        if form.hasFolder {
            panel.directoryURL = URL(fileURLWithPath: form.resolvedPath, isDirectory: true)
        } else if let root = sources.projectRoot() {
            panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let path = HolderSessionStore.standardize(url.path)
            self.choose(self.known.first { HolderSessionStore.standardize($0.path) == path }
                ?? ProjectChoice(path: path, name: HolderSessionStore.projectName(cwd: path), tag: nil, isKnown: false, lastUsed: nil))
        }
    }

    @objc private func cancelClicked() { close() }
    @objc private func createClicked() { create() }

    /// D12: a disabled entry (the active account, an account without a usable profile) is never
    /// picked; its menu item shows why as a tooltip.
    private func accountPicked(_ index: Int) {
        guard form.accountOptions.indices.contains(index) else { return }
        if !form.pickAccount(form.accountOptions[index].id) { NSSound.beep() }
        sync()
    }

    /// DEBUG / tests: picks the entry with `id` the way the menu does.
    @discardableResult
    func selectAccount(_ id: String) -> Bool {
        let picked = form.pickAccount(id)
        sync()
        return picked
    }

    /// `建立 ⌘⏎`: refused with the reason in the sheet, else the sheet closes.
    func create() {
        if let problem = form.problem {
            showError(problem)
            return
        }
        if let problem = sources.create(form.request) {
            showError(problem)
            return
        }
        close()
    }

    // MARK: Resume picker

    /// D18: lists the folder's conversations (`// 讀取中…` meanwhile), the first one that is not
    /// running selected; a later folder change drops an older answer.
    func reloadPicker() {
        guard form.kind == .claude, form.start.isResume else { return }
        guard form.hasFolder else {
            pickerContent = .noFolder
            form.pick(nil)
            showPicker()
            return
        }
        let folder = form.resolvedPath
        // Another folder: the old pick (and its name) must not run while the list loads.
        if folder != pickerFolder, form.resumeID != nil { form.pick(nil) }
        pickerFolder = folder
        pickerGeneration += 1
        let generation = pickerGeneration
        let cached = sources.isTranscriptListCached(folder)
        pickerContent = .loading
        showPicker()
        let start = ContinuousClock.now
        let sources = self.sources
        Task { @MainActor [weak self] in
            let items = await sources.transcripts(folder)
            guard let self, generation == self.pickerGeneration else { return }
            let rows = ResumePicker.rows(items, inUse: sources.inUseClaudeSessionIDs(),
                                         cleanupPeriodDays: sources.claudeSettings().cleanupPeriodDays, now: sources.now(),
                                         warnExpiry: sources.resumeWarning())
            let duration = ContinuousClock.now - start
            self.lastPickerLoad = (rows.count, duration, cached)
            HolderSessionStore.printLog(String(format: "NEWSESSION picker cwd=%@ count=%d ms=%.2f cache=%@", folder, rows.count,
                                               TerminalHub.milliseconds(duration), cached ? "hit" : "miss"))
            self.pickerSummaries = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.pickerContent = rows.isEmpty ? .empty : .rows(rows)
            let keep = self.form.resumeID.flatMap { id in rows.first { $0.id == id && !$0.disabled } }
            let selected = keep ?? ResumePicker.firstEnabled(rows)
            if self.form.start.isResume { self.form.pick(selected.flatMap { self.pickerSummaries[$0.id] }) }
            self.showPicker()
            self.sync()
            self.picker.scrollToSelected()
        }
    }

    private func pickTranscript(_ id: String) {
        guard let summary = pickerSummaries[id] else { return }
        form.pick(summary)
        picker.select(id)
        sync()
    }

    private func showPicker() {
        let folder = form.resolvedPath
        let name = known.first { HolderSessionStore.standardize($0.path) == folder }?.name ?? HolderSessionStore.projectName(cwd: folder)
        picker.show(pickerContent, project: name, selected: form.resumeID)
        fitWindow()
    }

    // MARK: State dump

    /// The `newSession` entry: `{path, kind, start, profile, command, …}`.
    var dumpObject: [String: Any] {
        let request = form.request
        var object: [String: Any] = [
            "path": form.resolvedPath, "kind": form.kind == .claude ? "claude" : "shell", "start": form.start.mode,
            "profile": form.profile.id, "command": form.commandPreview(), "copyCommand": form.commandPreview(abbreviated: false),
            "sessionId": form.sessionID.uuidString.lowercased(), "permission": form.permissionMode,
            "remoteControl": form.passesRemoteControl, "advancedOpen": form.advancedOpen, "dropdownOpen": isDropdownOpen,
            "valid": form.isValid,
        ]
        object["name"] = form.effectiveName.map { $0 as Any } ?? NSNull()
        object["account"] = form.accountOption?.id ?? NewSessionAccountOption.followID
        object["accountQuota"] = accountQuota.quota.map { $0.text as Any } ?? NSNull()
        object["accountOptions"] = form.accountOptions.map { ["id": $0.id, "title": $0.title, "enabled": $0.enabled] }
        object["model"] = request.claude.model.map { $0 as Any } ?? NSNull()
        object["modelTitle"] = form.modelTitle(form.modelChoice)
        object["tag"] = form.tag?.rawValue as Any? ?? NSNull()
        object["group"] = form.groupID.map { $0 as Any } ?? NSNull()
        object["transcript"] = form.resumeID.map { $0 as Any } ?? NSNull()
        object["destination"] = form.destination(known: known, groups: sources.groups())?.line as Any? ?? NSNull()
        object["dropdown"] = isDropdownOpen ? dropdownModel.rows.map { ["kind": "\($0.kind)", "title": $0.title, "detail": $0.detail,
                                                                         "chosen": $0.isChosen] } : []
        object["dropdownHighlighted"] = dropdown.list.highlighted
        switch pickerContent {
        case .loading: object["picker"] = "loading"
        case .empty: object["picker"] = "empty"
        case .noFolder: object["picker"] = "noFolder"
        case .rows: object["picker"] = "rows"
        }
        if let error = errorLabel.isHidden ? nil : errorLabel.stringValue { object["error"] = error }
        return object
    }

    /// The `resumePicker` entry (empty unless the picker has rows).
    var pickerDump: [[String: Any]] {
        guard form.start.isResume, case .rows(let rows) = pickerContent else { return [] }
        return ResumePicker.dump(rows, selected: form.resumeID)
    }
}

/// The sheet's window. ⌘⏎ creates, esc closes the project list or the sheet (both left to the
/// input method while it composes), ⌘O picks a folder, ⌘W closes the sheet; all answered here
/// before the main menu sees them (⌘⏎ is its 允許). Digits reach `keyDown` only when no text
/// field took them.
final class NewSessionWindow: NSWindow {
    var onCreate: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Returns true when it handled esc (the project list closed).
    var onEscape: (() -> Bool)?
    var onChooseFolder: (() -> Void)?
    var onDigit: ((String) -> Bool)?
    /// A mouse-down in the sheet, with the view it hit.
    var onMouseDown: ((NSView?) -> Void)?
    var isComposing: () -> Bool = { false }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { onCancel?() }
    }

    override func performClose(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let isReturn = event.keyCode == 0x24 || event.keyCode == 0x4C
        if isReturn, modifiers == .command {
            if !isComposing() { onCreate?() }
            return true
        }
        if event.keyCode == 0x35, modifiers.isEmpty, !isComposing() {
            if onEscape?() != true { onCancel?() }
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "o" {
            onChooseFolder?()
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers, onDigit?(characters) == true { return }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView {
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            onMouseDown?(hit)
        }
        super.sendEvent(event)
    }
}

/// The sheet's background (`.modal`: bg-soft, amber-dim border). A click on it (not on a
/// control) takes the focus out of the text fields, so 1–8 pick colors.
final class SheetRootView: PanelView {
    var onBackgroundClick: (() -> Void)?

    init() {
        super.init(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.amberDim)
    }

    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

/// `▸ 進階 Advanced` (`.ns-advbtn`): caret + caps label, bone, amber on hover.
final class DisclosureButton: NSButton {
    var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true; setAccessibilityExpanded(isOpen) } } }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let text: String

    init(title: String) {
        text = title
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setAccessibilityLabel(title)
        setAccessibilityExpanded(false)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var style: TextStyle { TextStyle.caps(10.5, isHovered ? Palette.amber : Palette.bone, tracking: 0.16) }

    override var intrinsicContentSize: NSSize { NSSize(width: 10 + 6 + Draw.width(style.string(text)), height: 18) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.caret(open: isOpen, at: CGPoint(x: 0, y: bounds.midY), color: isHovered ? Palette.amber : Palette.dimmer)
        Draw.text(style.string(text), x: 16, centerY: bounds.midY)
    }
}

/// `.ns-cmd`: the black 38 pt command strip. `$` amber, `claude` white bold, flags `#8a8578`,
/// quoted values cyan, the rest `#e8e6d8`; the copy button (`複製指令`) at the right.
final class CommandStripView: PanelView {
    private let text = Label.make(style: TextStyle.mono(10.5, Palette.termForeground))
    private let copyButton = CoddButton("複製指令", style: .icon(.copy, size: 24))
    var onCopy: (() -> Void)?
    private var flashTask: Task<Void, Never>?
    private(set) var command = ""

    init() {
        super.init(fill: Palette.termBackground, edges: [.top], edgeColor: Palette.lineBright)
        text.lineBreakMode = .byTruncatingTail
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.setAccessibilityLabel("複製指令")
        copyButton.toolTip = "複製指令（完整 session id）"
        let row = hStack([text, copyButton], spacing: 8, edgeInsets: NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 8))
        addSubview(row)
        row.pinEdges(to: self)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).zoomed(38).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("指令預覽")
    }

    func show(_ command: String) {
        guard command != self.command else { return }
        self.command = command
        let value = Self.colored(command)
        if text.attributedStringValue != value { text.attributedStringValue = value }
        text.setAccessibilityValue(command)
    }

    @objc private func copyClicked() { onCopy?() }

    /// The copy button shows amber for a moment after a copy.
    func flashCopied() {
        copyButton.isOn = true
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.copyButton.isOn = false
        }
    }

    /// `$ claude --resume 3f2a91c0-… -n "…"` with the artboard's colors.
    @MainActor
    static func colored(_ command: String) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: TextStyle.mono(10.5, Palette.amber).string("$ "))
        for (index, token) in tokens(command).enumerated() {
            if index > 0 { out.append(TextStyle.mono(10.5, Palette.termForeground).string(" ")) }
            if index == 0 {
                out.append(TextStyle.mono(10.5, Palette.termWhite, .bold).string(token))
            } else if token.hasPrefix("-"), let eq = token.firstIndex(of: "="), token[token.index(after: eq)...].hasPrefix("\"") {
                out.append(TextStyle.mono(10.5, Palette.termDim).string(String(token[...eq])))
                out.append(TextStyle.mono(10.5, Palette.cyan).string(String(token[token.index(after: eq)...])))
            } else if token.hasPrefix("-") {
                out.append(TextStyle.mono(10.5, Palette.termDim).string(token))
            } else if token.hasPrefix("\"") || token.hasPrefix("'") {
                out.append(TextStyle.mono(10.5, Palette.cyan).string(token))
            } else {
                out.append(TextStyle.mono(10.5, Palette.termForeground).string(token))
            }
        }
        return out
    }

    /// Words split on spaces outside quotes (a `-n "a b"` value stays one word).
    nonisolated static func tokens(_ command: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for c in command {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\", quote == "\"" { current.append(c); escaped = true; continue }
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                current.append(c)
                quote = c
            } else if c == " " {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
