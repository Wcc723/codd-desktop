import AppKit
import CoddPreferences
import CoddUI

/// 07 HOOKS & STATUS (D10): status dir + `在 Finder 顯示` (`變更…` M5), the installer's parts
/// with their buttons, the 14 event chips with the foreign summary, and the settings backups
/// (`差異` / `還原`). Every fact comes from `SettingsInfo.hooks`; every button is an action.
final class HooksSectionView: SettingsSectionView {
    private var reinstallButton: CoddButton?
    private var uninstallButton: CoddButton?
    private let differsChip = ChipView("! 與預設不同", style: .chip(.amber, mini: true))
    private let pathLabel = SxPathLabel()
    private let componentsCard = SxCard()
    private let eventsFlow = SxFlowView()
    private let foreignLine = SxLabel("", style: SxStyle.hint, lineHeight: SxStyle.hintLineHeight)
    private let backupsCard = SxCard()
    private var eventsHead: SxGroupHead?
    private var backupsHead: SxGroupHead?
    private var shown = SettingsHooksInfo(canReinstall: false, canUninstall: false)
    private(set) var componentRows: [SxRow] = []
    private(set) var backupRows: [SxRow] = []

    override func build() {
        let reinstall = button("重新安裝") { [weak self] in self?.actions.reinstallHooks() }
        let uninstall = button("解除安裝", variant: .danger) { [weak self] in self?.actions.uninstallHooks() }
        reinstallButton = reinstall
        uninstallButton = uninstall
        registerControl("hooks.reinstall", reinstall)
        registerControl("hooks.uninstall", uninstall)
        add(pageHead(lead: SxRich([.text("CODD 寫在 "), .code("~/.claude/settings.json"), .text(" 的 hooks 與 statusline。其他工具的 hooks 不會被動到。")]),
                     actions: [reinstall, uninstall]))

        let reveal = button("在 Finder 顯示", accessibilityLabel: "在 Finder 顯示狀態目錄") { [weak self] in
            guard let self else { return }
            self.actions.revealPath(self.model.info.hooks.statusDir)
        }
        registerControl("hooks.revealStatusDir", reveal)
        let change = SxStaticButton("變更…", accessibilityLabel: "變更狀態目錄（M5）")
        let statusDir = row("hooks.statusDir", "狀態目錄", en: "Status dir", hint: "hooks 寫入、CODD 讀取 session 狀態的資料夾。",
                            chips: [differsChip], extra: [pathLabel],
                            controls: [reveal, ChipView("M5", style: .milestone), change], labelGap: 5)
        change.alphaValue = 0.55
        add(sxGroup(groupHead("Status dir", cjk: "狀態目錄"), [SxCard([statusDir])]))

        add(sxGroup(groupHead("Components", cjk: "安裝部件"), [componentsCard]))

        let eventsHead = groupHead("Events", cjk: "事件")
        self.eventsHead = eventsHead
        eventsFlow.insets = NSEdgeInsets(top: xz(12), left: xz(16), bottom: xz(12), right: xz(16))
        let foreign = FlippedView()
        foreign.addSubview(foreignLine)
        foreignLine.pinEdges(to: foreign, insets: NSEdgeInsets(top: 0, left: xz(16), bottom: xz(12), right: xz(16)))
        let eventsCard = SxCard([eventsFlow, foreign])
        add(sxGroup(eventsHead, [eventsCard]))

        let backupsHead = groupHead("Backups", cjk: "備份")
        self.backupsHead = backupsHead
        add(sxGroup(backupsHead, [backupsCard]))

        bind { [weak self] _, info in self?.update(info.hooks) }
    }

    override var dynamicSearchables: [SxSearchable] { componentRows + backupRows }

    override var factSearchText: String {
        ([shown.statusDir, shown.foreignSummary ?? ""] + shown.events.map(\.name)).joined(separator: " ")
    }

    private func update(_ hooks: SettingsHooksInfo) {
        reinstallButton?.isEnabled = hooks.canReinstall
        uninstallButton?.isEnabled = hooks.canUninstall
        differsChip.isHidden = !hooks.statusDirDiffersFromDefault
        pathLabel.text = hooks.statusDir.isEmpty ? "—" : hooks.statusDir
        if hooks.components != shown.components {
            releaseTargets("components")
            componentRows = hooks.components.map(componentRow)
            componentsCard.set(componentRows.isEmpty ? [commentRow("// 尚未檢查 hooks 與 statusline")] : componentRows)
        }
        if hooks.events != shown.events {
            eventsFlow.set(hooks.events.map { EventChipView(name: $0.name, installed: $0.installed) })
            let installed = hooks.events.filter(\.installed).count
            let missing = hooks.events.count - installed
            eventsHead?.count = "\(hooks.events.count)"
            let right = NSMutableAttributedString()
            let style = SxGroupHead.rightStyle
            right.append(style.with(color: Palette.success).string("●"))
            right.append(style.string(" \(installed) 已安裝 · "))
            right.append(style.with(color: Palette.amber).string("◆"))
            right.append(style.string(" \(missing) 缺少"))
            eventsHead?.right = right
        }
        foreignLine.set(SxRich(hooks.foreignSummary ?? "外部 hooks 保持不動").attributed(SxStyle.hint, lineHeight: SxStyle.hintLineHeight))
        if hooks.backups != shown.backups {
            releaseTargets("backups")
            backupRows = hooks.backups.map(backupRow)
            backupsCard.set(backupRows.isEmpty ? [commentRow("// 尚無備份")] : backupRows)
            backupsHead?.count = "\(hooks.backups.count)"
        }
        shown = hooks
    }

    private func componentRow(_ component: SettingsHooksComponent) -> SxRow {
        let part = SxLabel(SxRich(component.part).attributed(TextStyle.caps(11, Palette.cream, tracking: 0.14), lineBreak: .byClipping), wraps: false)
        part.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        var controls: [NSView] = []
        if let chip = component.chip {
            let view = ChipView(chip, style: .chip(.plain))
            view.truncates = chip.count > 6
            controls.append(view)
        }
        for spec in component.buttons {
            let variant: CoddButton.Variant = switch spec.style {
            case .normal: .normal
            case .primary: .primary
            case .danger: .danger
            }
            let made = button(spec.title, variant: variant, group: "components") { [weak self] in self?.perform(spec.action) }
            made.isEnabled = spec.isEnabled
            controls.append(made)
        }
        let statusColor: NSColor = switch component.statusTone {
        case .ok: Palette.success
        case .warn: Palette.amber
        case .crit: Palette.danger
        case .muted: Palette.dimmer
        }
        return SxRow(key: "hooks.component.\(component.id)", name: SxRich([.color(component.status, statusColor)]),
                     hint: SxRich(component.hint), leading: [part], controls: controls)
    }

    func perform(_ action: SettingsHooksAction) {
        switch action {
        case .previewChanges: actions.openHookDiff()
        case .update: actions.reinstallHooks()
        case .removeLegacy: actions.removeLegacy()
        case .uninstall: actions.uninstallHooks()
        }
    }

    private func backupRow(_ backup: SettingsBackupRow) -> SxRow {
        let compare = button("差異", accessibilityLabel: "比較 \(backup.label) 備份差異", group: "backups") { [weak self] in
            self?.actions.compareBackup(backup.id)
        }
        let restore = button("還原", accessibilityLabel: "還原 \(backup.label) 備份", group: "backups") { [weak self] in
            self?.actions.restoreBackup(backup.id)
        }
        return SxRow(key: "hooks.backup.\(backup.id)", name: SxRich([.code(backup.name)]), hint: SxRich(backup.hint),
                     controls: [compare, restore], tight: true)
    }

    private func commentRow(_ text: String) -> NSView {
        let view = FlippedView()
        let label = SxLabel(text, style: TextStyle.comment, wraps: false)
        view.addSubview(label)
        label.pinEdges(to: view, insets: NSEdgeInsets(top: xz(12), left: xz(16), bottom: xz(12), right: xz(16)))
        return view
    }

    var eventChipNames: [String] { eventsFlow.items.compactMap { ($0 as? EventChipView)?.name } }
    var foreignText: String { foreignLine.text }
    var statusDirText: String { pathLabel.text }
    var differsChipShown: Bool { !differsChip.isHidden }
}

/// `.path.ell`: 11.5 dim on bg-soft with a 1 px --line border, `padding: 1px 8px`, truncated to
/// the width it gets. `display:block`: `SxRow` makes it as wide as the label column, so it must
/// neither hug nor resist (either one above the section's 490 fill would pull the whole page
/// down to the path's text width).
final class SxPathLabel: FlippedView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true; invalidateIntrinsicContentSize(); setAccessibilityValue(text) } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var style: TextStyle { TextStyle.mono(11.5, Palette.dim) }

    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(style.string(text)) + xz(18), height: xz(20)) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.line)
        Draw.text(style.string(text), x: xz(9), centerY: bounds.midY, maxWidth: max(0, bounds.width - xz(18)))
    }
}

/// `.sx-chips .chip`: 22 pt, the state glyph (`●` ok or amber `◆`) then the event name.
final class EventChipView: NSView {
    let name: String
    let installed: Bool

    init(name: String, installed: Bool) {
        self.name = name
        self.installed = installed
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(name) \(installed ? "已安裝" : "缺少")")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var glyph: NSAttributedString { TextStyle.mono(11, installed ? Palette.success : Palette.amber).string(installed ? "●" : "◆") }
    private var label: NSAttributedString { TextStyle.mono(11, installed ? Palette.bone : Palette.amber, tracking: 0.03).string(name) }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(8 + Draw.width(glyph) + xz(5) + Draw.width(label) + xz(8)), height: xz(22)) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.strokeRect(bounds, color: installed ? Palette.lineBright : Palette.amberDim)
        let x = xz(8) + Draw.text(glyph, x: xz(8), centerY: bounds.midY) + xz(5)
        Draw.text(label, x: x, centerY: bounds.midY)
    }
}
