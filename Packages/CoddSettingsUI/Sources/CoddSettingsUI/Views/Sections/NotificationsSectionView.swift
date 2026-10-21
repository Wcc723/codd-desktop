import AppKit
import CoddPreferences
import CoddUI

/// 05 NOTIFICATIONS 通知 (D29): the 4 × (condition, notify, sound) matrix, 勿擾時段 with HH:mm
/// inputs, mute by group, Dock badge, menu bar icon (R5), and the link to REMOTE.
final class NotificationsSectionView: SettingsSectionView {
    private(set) var startInput: SxTextInput?
    private(set) var endInput: SxTextInput?
    private(set) var groupFlow: SxFlowView?
    private var quietRow: SxRow?
    private var shownGroups: [SettingsGroup] = []

    /// One matrix line: key, lamp glyph / color / size, name, suffix, hint, the condition
    /// options in the artboard's order, and the rule's path.
    private struct Event {
        let key: String
        let glyph: String
        let color: NSColor
        let glyphSize: CGFloat
        let name: String
        let suffix: String?
        let hint: String
        let conditions: [CoddPreferences.NotifyCondition]
        let rule: WritableKeyPath<CoddPreferences.Notifications, CoddPreferences.EventRule>
    }

    override func build() {
        let test = button("傳送測試通知") { [weak self] in self?.actions.sendTestNotification() }
        add(pageHead(lead: SxRich("哪些狀態要跳 macOS 通知、要不要出聲，以及徽章顯示什麼。"), actions: [test]))

        let events = [
            Event(key: "waiting", glyph: "◆", color: Palette.amber, glyphSize: 12, name: "WAITING", suffix: nil,
                  hint: "需要授權、回答問題或核准計畫", conditions: [.always, .unfocusedOnly], rule: \.waiting),
            Event(key: "error", glyph: "▲", color: Palette.danger, glyphSize: 11, name: "ERROR", suffix: nil,
                  hint: "API 過載、額度用完或驗證失敗", conditions: [.always, .unfocusedOnly], rule: \.error),
            Event(key: "done", glyph: "◇", color: Palette.cyan, glyphSize: 11, name: "DONE", suffix: nil,
                  hint: "一輪結束，結果還沒看過", conditions: [.unfocusedOnly, .always], rule: \.done),
            Event(key: "exitedNonZero", glyph: "✕", color: Palette.dimmer, glyphSize: 11, name: "EXITED", suffix: "非 0",
                  hint: "process 異常結束（exit code 不是 0）", conditions: [.always, .unfocusedOnly], rule: \.exitedNonZero),
        ]
        var matrix: [NSView] = [MatrixHeaderView()]
        for event in events { matrix.append(matrixRow(event)) }
        add(sxGroup(groupHead("Events", cjk: "事件"), [SxCard(matrix)]))

        add(sxGroup(groupHead("Quiet", cjk: "勿擾"), [SxCard([quietHoursRow(), muteRow()])]))

        let dockTitles = ["等待數", "全部", "關"]
        let dock = row("notifications.dockBadge", SxRich("Dock 徽章"), en: "Dock badge", hint: Self.dockHint(nil),
                       controls: [segmented("notifications.dockBadge", titles: dockTitles,
                                            values: [CoddPreferences.DockBadge.waiting, .all, .off], label: "Dock 徽章",
                                            get: { $0.notifications.dockBadge }, set: { $0.notifications.dockBadge = $1 })],
                       keywords: dockTitles)
        bind { [weak dock] _, info in dock?.setHint(Self.dockHint(info.waitingCount)) }
        let iconTitles = ["僅圖示", "圖示 + 數字"]
        let icon = row("notifications.menuBarIcon", "選單列圖示", en: "Menu bar icon", hint: "需要你時中間方塊亮琥珀色；數字只出現在面板、Dock 與通知。",
                       controls: [segmented("notifications.menuBarIcon", titles: iconTitles,
                                            values: [CoddPreferences.MenuBarIcon.iconOnly, .iconAndCounts], label: "選單列圖示",
                                            get: { $0.notifications.menuBarIcon }, set: { $0.notifications.menuBarIcon = $1 })],
                       keywords: iconTitles)
        let link = SxLinkButton("在「遠端」設定 →")
        link.onClick = { [weak self] in self?.context.navigate(.remote) }
        registerControl("notifications.remoteLink", link)
        let push = row("notifications.mobilePush", "Remote Control 手機推播", en: "Mobile push",
                       hint: "由 Claude Code Remote Control 推到 iPhone 的 Claude App。", controls: [link])
        add(sxGroup(groupHead("Badges", cjk: "徽章"), [SxCard([dock, icon, push])]))
    }

    static func dockHint(_ count: Int?) -> SxRich {
        SxRich("等待數 = ◆ 等待 + ▲ 錯誤" + (count.map { "，目前 \($0)。" } ?? "。"))
    }

    private func matrixRow(_ event: Event) -> MatrixRowView {
        let key = "notifications.\(event.key)"
        let condition = select("\(key).condition", titles: event.conditions.map(OptionLabels.condition), values: event.conditions,
                               width: MatrixRowView.conditionDesignWidth, label: "\(event.name) 通知條件", get: { $0.notifications[keyPath: event.rule].condition },
                               set: { $0.notifications[keyPath: event.rule].condition = $1 })
        let label = event.suffix.map { "\(event.name) \($0)" } ?? event.name
        let notify = toggle("\(key).notify", label: "\(label) 通知", get: { $0.notifications[keyPath: event.rule].notify },
                            set: { $0.notifications[keyPath: event.rule].notify = $1 })
        let sound = toggle("\(key).sound", label: "\(label) 聲音", get: { $0.notifications[keyPath: event.rule].sound },
                           set: { $0.notifications[keyPath: event.rule].sound = $1 })
        let view = MatrixRowView(glyph: event.glyph, color: event.color, glyphSize: event.glyphSize, name: event.name, suffix: event.suffix,
                                 hint: event.hint, condition: condition, notify: notify, sound: sound,
                                 keywords: event.conditions.map(OptionLabels.condition))
        register(view)
        return view
    }

    private func quietHoursRow() -> SxRow {
        func timeInput(_ value: String, label: String, path: WritableKeyPath<CoddPreferences.QuietHours, String>) -> SxTextInput {
            let input = SxTextInput(value: value, width: 68, alignment: .center, accessibilityLabel: label)
            input.onCommit = { [weak self] typed in
                guard let time = ClockTime.normalize(typed) else { return .reject }
                self?.edit { $0.notifications.quietHours[keyPath: path] = time }
                return .accept(time)
            }
            input.onValidity = { [weak self] _ in self?.refreshTimeHint() }
            bind { [weak input] prefs, _ in input?.setValue(prefs.notifications.quietHours[keyPath: path]) }
            return input
        }
        let quiet = model.preferences.notifications.quietHours
        let start = timeInput(quiet.start, label: "勿擾開始時間", path: \.start)
        let end = timeInput(quiet.end, label: "勿擾結束時間", path: \.end)
        registerControl("notifications.quietHours.start", start)
        registerControl("notifications.quietHours.end", end)
        startInput = start
        endInput = end
        let times = hStack([start, faint("–"), end], spacing: 6)
        bind { [weak times] prefs, _ in times?.alphaValue = prefs.notifications.quietHours.enabled ? 1 : 0.55 }
        let toggle = toggle("notifications.quietHours.enabled", label: "勿擾時段", get: { $0.notifications.quietHours.enabled },
                            set: { $0.notifications.quietHours.enabled = $1 })
        let made = row("notifications.quietHours", "勿擾時段", en: "Do not disturb", hint: "期間只更新徽章，不跳通知也不出聲。",
                       controls: [times, toggle])
        quietRow = made
        return made
    }

    private func refreshTimeHint() {
        let invalid = (startInput?.isInvalid ?? false) || (endInput?.isInvalid ?? false)
        quietRow?.setNote("time", invalid ? ClockTime.invalidHint : nil, color: Palette.danger)
    }

    var timeHint: String? { quietRow?.note("time") }

    private func muteRow() -> SxRow {
        let flow = SxFlowView()
        flow.trailing = true
        flow.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        groupFlow = flow
        registerControl("notifications.mutedGroupIDs", flow)
        let made = row("notifications.mutedGroupIDs", "依群組靜音", en: "Mute by group", hint: "靜音的群組仍會出現在 NEEDS YOU。", controls: [flow])
        // The chips may wrap: at least 260 pt stay for the label column.
        flow.widthAnchor.constraint(lessThanOrEqualTo: made.widthAnchor, constant: -(16 + 16 + 24 + 220)).isActive = true
        bind { [weak self, weak flow] prefs, info in
            guard let self, let flow else { return }
            if info.groups != self.shownGroups {
                self.shownGroups = info.groups
                flow.set(info.groups.map { group in
                    let chip = GroupChipView(groupID: group.id, name: group.name, color: group.color)
                    chip.onToggle = { [weak self] muted in
                        self?.edit { prefs in
                            prefs.notifications.mutedGroupIDs.removeAll { $0 == group.id }
                            if muted { prefs.notifications.mutedGroupIDs.append(group.id) }
                        }
                    }
                    return chip
                })
            }
            for case let chip as GroupChipView in flow.items {
                chip.isOn = prefs.notifications.mutedGroupIDs.contains(chip.groupID)
            }
            flow.invalidateIntrinsicContentSize()
        }
        return made
    }

    override var factSearchText: String { shownGroups.map(\.name).joined(separator: " ") }

    var groupChips: [GroupChipView] { groupFlow?.items.compactMap { $0 as? GroupChipView } ?? [] }
}

/// `.sx-mrow.h`: `EVENT 說明 條件 通知 聲音` on --bg-lift, 30 pt, 10 px caps .16em dim. A narrow
/// matrix drops the columns its rows dropped (`MatrixRowView.columns(width:)`).
final class MatrixHeaderView: FlippedView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).zoomed(30).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgLift)
        let style = TextStyle.caps(10, Palette.dim, tracking: 0.16)
        let columns = MatrixRowView.columns(width: bounds.width)
        var labels: [(String, CGFloat)] = [("Event", columns.event)]
        if columns.showsHint { labels.append(("說明", columns.hint)) }
        if !columns.stacked { labels.append(("條件", columns.condition)) }
        labels += [("通知", columns.notify), ("聲音", columns.sound)]
        for (text, x) in labels {
            Draw.text(style.string(text), x: x, centerY: bounds.midY)
        }
    }
}

/// `.sx-mrow`: grid 150 | 1fr | 150 | 44 | 44, gap 16, padding 7 / 16, min 46 pt: the event
/// (lamp + caps name), its hint, the condition select and the notify / sound switches.
///
/// A narrow row (small window, zoom 20) drops the hint column first (under 60 design points), then
/// puts the condition select under the event (the switches stay on the event's line), so nothing
/// overlaps and the Settings window is never held wide.
final class MatrixRowView: FlippedView, SxSearchable, SxSeparated, SxTitled {
    let title: String
    let searchText: String
    var isSearchHit = false { didSet { if isSearchHit != oldValue { needsDisplay = true } } }
    var showsSeparator = false { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    let condition: SelectButton
    let notify: SwitchToggle
    let sound: SwitchToggle
    let hintLabel: SxLabel
    /// The arrangement shown (tests).
    private(set) var arrangement = Columns.Arrangement.hint
    private var arrangements: [Columns.Arrangement: [NSLayoutConstraint]] = [:]

    /// The design width of the condition select (`select(…, width:)` zooms it).
    static let conditionDesignWidth: CGFloat = 150

    struct Columns: Equatable {
        enum Arrangement: Hashable { case hint, grid, stacked }
        var event: CGFloat
        var hint: CGFloat
        var condition: CGFloat
        var notify: CGFloat
        var sound: CGFloat
        var arrangement: Arrangement
        var showsHint: Bool { arrangement == .hint }
        var stacked: Bool { arrangement == .stacked }
    }

    /// The columns' x positions for a row `width` wide, at the current zoom.
    static func columns(width: CGFloat) -> Columns {
        let pad = xz(16), gap = xz(16), toggle = xz(44)
        let sound = width - pad - toggle
        let notify = sound - gap - toggle
        let condition = notify - gap - xz(conditionDesignWidth)
        let hint = pad + xz(150) + gap
        let arrangement: Columns.Arrangement
        // The grid keeps both gaps of the 0-wide hint track (`150 | 1fr | 150`, gap 16).
        if condition - gap < hint {
            arrangement = .stacked
        } else if condition - gap - hint < xz(60) {
            arrangement = .grid
        } else {
            arrangement = .hint
        }
        return Columns(event: pad, hint: hint, condition: condition, notify: notify, sound: sound, arrangement: arrangement)
    }

    init(glyph: String, color: NSColor, glyphSize: CGFloat, name: String, suffix: String?, hint: String, condition: SelectButton,
         notify: SwitchToggle, sound: SwitchToggle, keywords: [String]) {
        title = suffix.map { "\(name) \($0)" } ?? name
        searchText = ([title, hint] + keywords).joined(separator: " ")
        self.condition = condition
        self.notify = notify
        self.sound = sound
        hintLabel = SxLabel(SxRich(hint).attributed(SxStyle.hint, lineHeight: SxStyle.hintLineHeight))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let lamp = SxLabel(SxRich(glyph).attributed(TextStyle.mono(glyphSize, color), lineBreak: .byClipping), wraps: false)
        lamp.alignment = .center
        lamp.widthAnchor.constraint(equalToConstant: 12).zoomed(12).isActive = true
        var nameViews: [NSView] = [lamp, SxLabel(SxRich(name).attributed(TextStyle.mono(11, Palette.cream, tracking: 0.14), lineBreak: .byClipping),
                                                 wraps: false)]
        if let suffix {
            nameViews.append(SxLabel(SxRich(suffix).attributed(TextStyle.mono(11, Palette.dimmer, tracking: 0.04), lineBreak: .byClipping),
                                     wraps: false))
        }
        let event = hStack(nameViews, spacing: xz(8))
        for view in [event, hintLabel, condition, notify, sound] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = xz(16), gap = xz(16), toggle = xz(44)
        NSLayoutConstraint.activate([
            event.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            event.widthAnchor.constraint(lessThanOrEqualToConstant: xz(150)),
            notify.leadingAnchor.constraint(equalTo: trailingAnchor, constant: -(pad + toggle + gap + toggle)),
            sound.leadingAnchor.constraint(equalTo: trailingAnchor, constant: -(pad + toggle)),
            notify.centerYAnchor.constraint(equalTo: event.centerYAnchor),
            sound.centerYAnchor.constraint(equalTo: event.centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: xz(46)),
        ])
        let hug = heightAnchor.constraint(equalToConstant: xz(46))
        hug.priority = .defaultLow
        hug.isActive = true
        let grid = [
            event.centerYAnchor.constraint(equalTo: centerYAnchor),
            condition.trailingAnchor.constraint(equalTo: notify.leadingAnchor, constant: -gap),
            condition.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        arrangements[.hint] = grid + [
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + xz(150) + gap),
            hintLabel.trailingAnchor.constraint(equalTo: condition.leadingAnchor, constant: -gap),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: xz(7)),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -xz(7)),
        ]
        arrangements[.grid] = grid
        arrangements[.stacked] = [
            event.centerYAnchor.constraint(equalTo: topAnchor, constant: xz(23)),
            condition.topAnchor.constraint(equalTo: topAnchor, constant: xz(46) - xz(4)),
            condition.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + xz(20)),
            condition.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -xz(10)),
        ]
        NSLayoutConstraint.activate(arrangements[.hint] ?? [])
        setAccessibilityElement(false)
    }

    /// Picks the arrangement for the row's width (only the width: no flicker while dragging).
    override func layout() {
        if bounds.width > 0 {
            let next = Self.columns(width: bounds.width).arrangement
            if next != arrangement {
                NSLayoutConstraint.deactivate(arrangements[arrangement] ?? [])
                arrangement = next
                hintLabel.isHidden = next != .hint
                NSLayoutConstraint.activate(arrangements[next] ?? [])
            }
        }
        super.layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if isSearchHit {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        }
        if showsSeparator { Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright) }
    }
}
