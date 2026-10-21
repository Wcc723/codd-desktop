import AppKit
import CoddUI

/// Dialog C · 加入帳號 (StatusDialogs artboard C with D24 / D33 / D34): the honest intro line, three
/// steps (1 login in a terminal, 2 capture the current login, 3 alias + slot), the add-token link
/// and `[加入 #n]`. Shown as a child panel at the main window's right edge (`presentPanel`), so it
/// is 560 pt wide (the artboard grid's minimum cell): the terminal behind it stays visible.
///
/// The alias field is the IME-safe CoddUI `InputField`; the alias is checked with cswap's rule on
/// every edit (`加入 #n` stays disabled and the rule hint shows for `工作室`) and lowercased when
/// the field ends editing; `onAdd` receives the normalized alias.
@MainActor
public final class AddAccountDialogView: DialogContentView {
    public static let width: CGFloat = 560
    /// D33 (replaces the artboard's `CODD 只呼叫 cswap，不讀取也不顯示 email…`).
    public static let introText = "CODD 透過 cswap 加入帳號；email 只在本機比對，不儲存也不顯示，帳號一律以編號與別名顯示。"
    /// D34: the artboard's `例如：工作室` would suggest an alias cswap refuses.
    public static let aliasPlaceholder = "例如：studio"

    public private(set) var model: AddAccountModel
    private let onOpenLoginTerminal: () -> Void
    private let onCapture: () -> Void
    private let onAdd: (String, Int) -> Void
    private let onAddToken: () -> Void
    private let onCancel: () -> Void
    /// Called on every alias edit (as typed) and slot pick, for an app that keeps the model.
    public var onAliasChange: ((String) -> Void)?
    public var onSlotChange: ((Int) -> Void)?

    private let versionChip = ChipView("", style: DialogChipStyle.header(.plain))
    private let step1: StepView
    private let step2: StepView
    private let step3: StepView
    let openTerminalButton = CoddButton("開啟登入終端機", style: .bracket(.normal, small: true))
    private let step1Time = Label.make(style: TextStyle.mono(10.5, Palette.dimmer))
    private let step1Hint = RichWrappingLabel()
    let captureButton = CoddButton("擷取目前登入", style: .bracket(.normal, small: true))
    private let captureArrow = Label.make("→", style: TextStyle.mono(12.5, Palette.dimmer))
    private let detectBox = DetectBoxView()
    let aliasField = InputField(placeholder: AddAccountDialogView.aliasPlaceholder, accessibilityLabel: "別名 Alias")
    let slotSelect = SelectButton(titles: [], accessibilityLabel: "編號 Slot")
    private let aliasRuleHint = RichWrappingLabel()
    let addTokenLink = DialogLinkButton("改用 setup-token / API key（cswap add-token）→")
    private let errorBox = StatusLineBox(kind: .error)
    let cancelButton = CoddButton("取消", style: .bracket(.normal, small: false))
    let addButton = CoddButton("加入 #4", style: .bracket(.primary, small: false))

    /// The last alias / slot the app passed (a new model only overrides the field when these change,
    /// so an update never clobbers what the user is typing).
    private var appliedAlias: String
    private var appliedSlot: Int

    /// - Parameters:
    ///   - onOpenLoginTerminal: step 1 `開啟登入終端機`.
    ///   - onCapture: step 2 `擷取目前登入`.
    ///   - onAdd: `加入 #n` / ⏎ with the normalized alias and the slot.
    ///   - onAddToken: `改用 setup-token / API key（cswap add-token）→`.
    ///   - onCancel: ✕, ⎋ and `取消` alike (the app decides whether to switch the login back).
    public init(model: AddAccountModel, onOpenLoginTerminal: @escaping () -> Void, onCapture: @escaping () -> Void,
                onAdd: @escaping (String, Int) -> Void, onAddToken: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onOpenLoginTerminal = onOpenLoginTerminal
        self.onCapture = onCapture
        self.onAdd = onAdd
        self.onAddToken = onAddToken
        self.onCancel = onCancel
        appliedAlias = model.alias
        appliedSlot = model.slot
        step1 = StepView(number: 1, isLast: false) { color in
            DialogText.runs([("在終端機執行 ", TextStyle.mono(12.5, color)), ("claude /login", DialogChipStyle.inlineCode),
                             (" 登入新帳號", TextStyle.mono(12.5, color))])
        }
        step2 = StepView(number: 2, isLast: false) { TextStyle.mono(12.5, $0).string("擷取目前登入", lineBreak: .byWordWrapping) }
        step3 = StepView(number: 3, isLast: true) { TextStyle.mono(12.5, $0).string("設定別名與編號", lineBreak: .byWordWrapping) }
        super.init(width: Self.width, title: "Add account · 加入帳號")
        build()
        aliasField.text = model.alias
        apply(model, previous: nil)
    }

    private func build() {
        frameView.setHeader(chips: [versionChip])

        let intro = columnStack([
            Label.make("加入帳號（cswap add）", style: DialogText.question),
            RichWrappingLabel(DialogText.hint.string(Self.introText, lineBreak: .byWordWrapping)),
        ], spacing: dz(6))

        openTerminalButton.target = self
        openTerminalButton.action = #selector(openTerminalClicked)
        step1.addBody(hStack([openTerminalButton, step1Time, spacer()], spacing: dz(10)), fullWidth: true)
        step1.addBody(step1Hint, fullWidth: true)

        captureButton.target = self
        captureButton.action = #selector(captureClicked)
        step2.addBody(hStack([captureButton, captureArrow, detectBox, spacer()], spacing: dz(10)), fullWidth: true)

        aliasField.onChange = { [weak self] text in self?.aliasEdited(text) }
        aliasField.onFocusChange = { [weak self] focused in if !focused { self?.commitAlias() } }
        slotSelect.onSelect = { [weak self] index in self?.slotPicked(index) }
        let aliasColumn = columnStack([Label.make("別名 Alias", style: DialogText.label), aliasField], spacing: dz(6))
        let slotColumn = columnStack([Label.make("編號 Slot", style: DialogText.label), slotSelect], spacing: dz(6))
        slotColumn.translatesAutoresizingMaskIntoConstraints = false
        slotColumn.widthAnchor.constraint(equalToConstant: 96).zoomed(96).isActive = true
        let fields = NSStackView(views: [aliasColumn, slotColumn])
        fields.orientation = .horizontal
        fields.alignment = .top
        fields.spacing = 10
        fields.setHuggingPriority(.defaultLow, for: .horizontal)
        step3.addBody(fields, fullWidth: true)
        aliasRuleHint.set(TextStyle.mono(11.5, Palette.danger, tracking: 0.02).string(AddAccountModel.aliasRuleHint, lineBreak: .byWordWrapping))
        step3.addBody(aliasRuleHint, fullWidth: true)
        step3.addBody(RichWrappingLabel(DialogText.hint.string("別名只用來顯示，像 #3 工作、#2 藍鵲；之後可在 設定 › 帳號 修改",
                                                               lineBreak: .byWordWrapping)), fullWidth: true)

        let steps = columnStack([step1, step2, step3], spacing: 0)
        addTokenLink.target = self
        addTokenLink.action = #selector(addTokenClicked)
        frameView.addBody([intro, steps, hStack([addTokenLink, spacer()], spacing: 0), errorBox])

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        addButton.target = self
        addButton.action = #selector(addClicked)
        frameView.setFooter(note: nil, buttons: [cancelButton, addButton])
    }

    /// Applies a new model; only the parts that changed are touched. The alias field keeps the
    /// user's text unless the app passes a different alias than before.
    public func update(_ next: AddAccountModel) {
        let previous = model
        var merged = next
        if next.alias != appliedAlias {
            appliedAlias = next.alias
            if !aliasField.isComposing { aliasField.text = next.alias }
        } else {
            merged.alias = model.alias
        }
        if next.slot != appliedSlot {
            appliedSlot = next.slot
        } else if next.slots.contains(model.slot) {
            merged.slot = model.slot
        }
        model = merged
        apply(merged, previous: previous)
    }

    private func apply(_ m: AddAccountModel, previous p: AddAccountModel?) {
        if changed(p, m, \.cswapVersion) {
            versionChip.set(m.cswapVersion ?? "")
            versionChip.isHidden = m.cswapVersion == nil
        }
        let current = m.currentStep
        step1.state = m.step1Done != nil ? .done : (current == 1 ? .current : .pending)
        step2.state = m.detected != nil ? .done : (current == 2 ? .current : .pending)
        step3.state = current == 3 ? .current : .pending

        if changed(p, m, \.step1Done) {
            step1Time.isHidden = m.step1Done == nil
            if let done = m.step1Done {
                Label.set(step1Time, "已完成 · \(ClockFormat.hourMinute(done))", style: TextStyle.mono(10.5, Palette.dimmer))
            }
        }
        if changed(p, m, \.previousActive) {
            step1Hint.set(DialogText.hint.string("登入新帳號會暫時改變全域登入，加入後自動切回 \(m.previousActive)", lineBreak: .byWordWrapping))
        }
        if changed(p, m, \.detected) {
            // The login was just captured: step 3 starts with the alias field focused (only when
            // the panel already has focus; it never takes it from the terminal behind it).
            if p != nil, p?.detected == nil, m.detected != nil, let window, window.isKeyWindow {
                window.makeFirstResponder(aliasField.field)
            }
            detectBox.isHidden = m.detected == nil
            captureArrow.isHidden = m.detected == nil
            if let detected = m.detected { detectBox.set(detected) }
        }
        if changed(p, m, \.slots) || changed(p, m, \.slot) {
            slotSelect.setItems(m.slots.map { "#\($0)" }, selected: m.slots.firstIndex(of: m.slot) ?? 0)
        }
        if changed(p, m, \.error) {
            errorBox.isHidden = m.error == nil
            if let error = m.error { errorBox.set(DialogText.error(error)) }
        }
        openTerminalButton.isEnabled = !m.busy
        captureButton.isEnabled = !m.busy
        addTokenLink.isEnabled = !m.busy
        aliasField.isEnabled = !m.busy
        slotSelect.isEnabled = !m.busy
        refreshAlias()
        if changed(p, m, \.detected) || changed(p, m, \.error) || changed(p, m, \.step1Done) {
            fitWindow()
        }
    }

    /// Button title, enablement and the rule hint from the current alias.
    private func refreshAlias() {
        addButton.label = "加入 #\(model.slot)"
        addButton.isEnabled = model.canAdd
        let showHint = model.showsAliasRuleHint
        if aliasRuleHint.isHidden == showHint {
            aliasRuleHint.isHidden = !showHint
            fitWindow()
        }
    }

    private func aliasEdited(_ text: String) {
        guard text != model.alias else { return }
        model.alias = text
        refreshAlias()
        onAliasChange?(text)
    }

    /// The field lowercases (and trims) on commit when cswap's rule accepts the alias.
    private func commitAlias() {
        guard let normalized = model.normalizedAlias, normalized != aliasField.text, !aliasField.isComposing else { return }
        aliasField.text = normalized
        aliasEdited(normalized)
    }

    private func slotPicked(_ index: Int) {
        guard model.slots.indices.contains(index) else { return }
        model.slot = model.slots[index]
        if slotSelect.selectedIndex != index { slotSelect.setItems(slotSelect.titles, selected: index) }
        refreshAlias()
        onSlotChange?(model.slot)
    }

    // MARK: Actions

    override var initialResponder: NSView? { model.detected != nil ? aliasField.field : nil }
    override var isPrimaryEnabled: Bool { addButton.isEnabled }

    override func performPrimary() {
        guard let alias = model.normalizedAlias, model.canAdd else { return }
        if aliasField.text != alias { aliasField.text = alias; model.alias = alias }
        onAdd(alias, model.slot)
    }

    override func performCancel() { onCancel() }

    @objc private func openTerminalClicked() { onOpenLoginTerminal() }
    @objc private func captureClicked() { onCapture() }
    @objc private func addTokenClicked() { onAddToken() }
    @objc private func cancelClicked() { performCancel() }
    @objc private func addClicked() { if isPrimaryEnabled { performPrimary() } }

    // MARK: Testing

    var stepStates: [StepView.State] { [step1.state, step2.state, step3.state] }
    var step1TimeText: String? { step1Time.isHidden ? nil : step1Time.stringValue }
    var step1HintText: String { step1Hint.attributedStringValue.string }
    var detectText: String? { detectBox.isHidden ? nil : detectBox.text }
    var aliasRuleHintShown: Bool { !aliasRuleHint.isHidden }
    var errorText: String? { errorBox.isHidden ? nil : errorBox.text }
    var versionChipText: String? { versionChip.isHidden ? nil : model.cswapVersion }
}

/// `.sd-detect`: `● 偵測到 新帳號 · [MAX 20x]` in a green-tinted box (padding 5 / 10, 12 px), or
/// `● 已是 #2 藍鵲（會更新它的登入資料）` in an amber-tinted one (an update, not a new account).
final class DetectBoxView: FlippedView {
    private var detected = DetectedLogin(isNew: true, text: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ next: DetectedLogin) {
        guard next != detected else { return }
        detected = next
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var text: String {
        let plan = detected.plan.map { " · \($0)" } ?? ""
        return detected.isNew ? "● 偵測到 \(detected.text)\(plan)" : "● 已是 \(detected.text)（會更新它的登入資料）\(plan)"
    }

    private var accent: NSColor { detected.isNew ? Palette.success : Palette.amber }

    private var textRun: NSAttributedString {
        let normal = TextStyle.mono(12, Palette.bone)
        let parts: [(String, TextStyle)] = detected.isNew
            ? [("偵測到 ", normal), (detected.text, DialogText.bold(12))]
            : [("已是 ", normal), (detected.text, DialogText.bold(12)), ("（會更新它的登入資料）", normal)]
        return DialogText.runs(parts, lineBreak: .byTruncatingTail)
    }

    private var planChip: (String, ChipStyle)? {
        guard let plan = detected.plan, !plan.isEmpty else { return nil }
        return (plan, DialogChipStyle.style(.plain))
    }

    override var intrinsicContentSize: NSSize {
        var width: CGFloat = dz(10) + Draw.width(TextStyle.mono(12, accent).string("●")) + dz(8) + Draw.width(textRun) + dz(10)
        if let (plan, style) = planChip { width += 8 + Draw.width(TextStyle.mono(12, Palette.bone).string("·")) + 8 + style.size(for: plan).width }
        return NSSize(width: ceil(width), height: dz(32))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, accent.withAlphaComponent(0.04))
        Draw.strokeRect(bounds, color: accent.withAlphaComponent(0.3))
        let mid = bounds.midY
        var x: CGFloat = dz(10)
        x += Draw.text(TextStyle.mono(12, accent).string("●"), x: x, centerY: mid) + dz(8)
        let right = bounds.width - dz(10)
        var chipWidth: CGFloat = 0
        if let (plan, style) = planChip { chipWidth = style.size(for: plan).width + 8 + Draw.width(TextStyle.mono(12, Palette.bone).string("·")) + 8 }
        x += Draw.text(textRun, x: x, centerY: mid, maxWidth: max(0, right - chipWidth - x))
        if let (plan, style) = planChip {
            x += dz(8)
            x += Draw.text(TextStyle.mono(12, Palette.bone).string("·"), x: x, centerY: mid) + dz(8)
            style.draw(plan, x: x, centerY: mid)
        }
    }
}

/// A 12 px amber text link (the artboard's `<a style="font-size:12px">`); cream while hovered.
final class DialogLinkButton: NSButton, KeyboardFocusTracking {
    private let text: String
    private var hovered = false

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        title = text
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.link)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(TextStyle.mono(12, Palette.amber).string(text)), height: dz(18)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    // D21: an NSButton is a key view under Full Keyboard Access already; it shows the helmet
    // focus style instead of the system ring it turned off.

    private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

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

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
        let color = hovered && isEnabled ? Palette.cream : Palette.amber
        Draw.text(TextStyle.mono(12, color).string(text), x: 0, centerY: bounds.midY)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }
}
