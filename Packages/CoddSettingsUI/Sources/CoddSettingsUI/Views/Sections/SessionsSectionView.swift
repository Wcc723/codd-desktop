import AppKit
import CoddPreferences
import CoddUI

/// 03 SESSIONS 工作階段: default profile (profiles.json, through `setDefaultProfile`), the locked
/// `--session-id` and restore rows (D17), NO HOOK / STALE, external display (`Detected 區`
/// disabled), hide SDK, and the static state-source flow.
final class SessionsSectionView: SettingsSectionView {
    private(set) var profileSelect: SelectButton?
    private var externalRow: SxRow?

    override func build() {
        let reset = button("還原本頁預設") { [weak self] in
            self?.model.resetSection(.sessions)
            self?.actions.resetSection(.sessions)
        }
        add(pageHead(lead: SxRich("新 session 的預設值、狀態怎麼判定，以及外部 session 的顯示方式。"), actions: [reset]))

        let profiles = SelectButton(titles: [], accessibilityLabel: "預設啟動設定檔")
        profiles.widthAnchor.constraint(equalToConstant: 240).zoomed(240).isActive = true
        profiles.onSelect = { [weak self] index in
            guard let self, self.model.info.profileNames.indices.contains(index) else { return }
            self.actions.setDefaultProfile(self.model.info.profileNames[index].id)
        }
        bind { [weak profiles] _, info in
            guard let profiles else { return }
            let titles = info.profileNames.map(\.title)
            let index = info.profileNames.firstIndex { $0.id == info.defaultProfileID } ?? 0
            if profiles.titles != titles || profiles.selectedIndex != index { profiles.setItems(titles, selected: index) }
            profiles.displayTitle = titles.isEmpty ? "—" : nil
            profiles.isEnabled = !titles.isEmpty
        }
        registerControl("sessions.defaultProfile", profiles)
        profileSelect = profiles
        let profile = row("sessions.defaultProfile", "預設啟動設定檔", en: "Default profile", hint: "⌘N 與 [+ NEW ▾] 預選的設定檔。",
                          controls: [profiles])
        let sessionID = row("sessions.autoSessionId", SxRich([.text("自動加上 "), .code("--session-id")]), en: "Auto session id",
                            hint: SxRich("讓 hook 事件對到正確的分頁；關閉後只能用 cwd 推測。"),
                            controls: [faint("CODD 需要它對應 hook"), lockedToggle("sessions.autoSessionId", label: "自動加上 --session-id")])
        add(sxGroup(groupHead("Launch", cjk: "啟動"), [SxCard([profile, sessionID])]))

        let grace = CoddPreferences.Sessions.noHookWarningOptions
        let noHook = row("sessions.noHookWarningSeconds", SxRich("NO HOOK 警示"), en: "No-hook warning",
                         hint: SxRich([.text("啟動後超過這個時間仍沒有 hook 資料，列上標示 "), .color("! NO HOOK", Palette.amber), .text("。")]),
                         controls: [select("sessions.noHookWarningSeconds", titles: grace.map(OptionLabels.seconds), values: grace,
                                           width: 120, label: "NO HOOK 警示時間", get: { $0.sessions.noHookWarningSeconds },
                                           set: { $0.sessions.noHookWarningSeconds = $1 }, unknownTitle: OptionLabels.seconds)])
        let staleValues = CoddPreferences.Sessions.staleAfterOptions
        let stale = row("sessions.staleAfterSeconds", "STALE 判定", en: "Stale after", hint: "IDLE 超過這個時間，側欄列變暗為 75%。",
                        controls: [select("sessions.staleAfterSeconds", titles: staleValues.map(OptionLabels.stale), values: staleValues,
                                          width: 120, label: "STALE 判定時間", get: { $0.sessions.staleAfterSeconds },
                                          set: { $0.sessions.staleAfterSeconds = $1 }, unknownTitle: OptionLabels.stale)],
                        keywords: staleValues.map(OptionLabels.stale))
        let restore = row("sessions.restoreAsStopped", SxRich("App 重開後恢復"), en: "Restore on relaunch",
                          hint: SxRich([.text("上次執行中的 session 顯示為 "), .color("⟲", Palette.dimmer), .text(" STOPPED · 可接續，不會自動重啟。")]),
                          controls: [faint("CODD 一律這樣做"), lockedToggle("sessions.restoreAsStopped", label: "App 重開後恢復為 STOPPED 可接續")])
        add(sxGroup(groupHead("State", cjk: "狀態判定"), [SxCard([noHook, stale, restore])]))

        let externalTitles = ["顯示在專案下", "Detected 區", "不顯示"]
        let external = row("sessions.externalDisplay", SxRich("外部 session"), en: "External", hint: Self.externalHint(nil),
                           controls: [segmented("sessions.externalDisplay", titles: externalTitles,
                                                values: [CoddPreferences.ExternalDisplay.project, .detected, .hidden],
                                                label: "外部 session 顯示方式", disabled: [1], get: { $0.sessions.externalDisplay },
                                                set: { $0.sessions.externalDisplay = $1 })],
                           keywords: externalTitles)
        externalRow = external
        bind { [weak external] _, info in external?.setHint(Self.externalHint(info.externalSessionCount)) }
        let hideSDK = row("sessions.hideSDKAndDesktop", "隱藏 SDK / Desktop 來源", en: "Hide SDK & Desktop",
                          hint: "Agent SDK 與 Claude Desktop 建立的 session 不列入側欄。",
                          controls: [toggle("sessions.hideSDKAndDesktop", label: "隱藏 SDK 與 Desktop 來源",
                                            get: { $0.sessions.hideSDKAndDesktop }, set: { $0.sessions.hideSDKAndDesktop = $1 })])
        add(sxGroup(groupHead("External", cjk: "外部 session"), [SxCard([external, hideSDK])]))

        let flow = StateSourceFlowView()
        sectionSearchText += " " + flow.plainText
        add(sxGroup(groupHead("State source", cjk: "狀態來源", right: "依序採用 · 前一層沒資料才往下找"), [flow]))
    }

    static func externalHint(_ count: Int?) -> SxRich {
        SxRich([.text("不是 CODD 啟動、由 "), .code("claude agents --json"),
                .text(" 偵測到的 session" + (count.map { "（目前 \($0) 個）" } ?? "") + "。")])
    }
}

/// `.sx-flow`: `1 hook → 2 registry → 3 claude agents --json`, three equal nodes with hints.
final class StateSourceFlowView: FlippedView {
    static let nodes: [(String, String)] = [
        ("hook", "事件即時寫入 status dir，最準"),
        ("registry", "Claude Code 的 session 註冊檔，補 busy / idle"),
        ("claude agents --json", "補抓外部啟動的 session"),
    ]

    var plainText: String { Self.nodes.map { "\($0.0) \($0.1)" }.joined(separator: " ") }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var views: [NSView] = []
        var boxes: [NSView] = []
        for (index, node) in Self.nodes.enumerated() {
            if index > 0 {
                let arrow = SxLabel(SxRich("→").attributed(TextStyle.mono(13, Palette.amberDim), lineBreak: .byClipping), wraps: false)
                arrow.setContentHuggingPriority(.required, for: .horizontal)
                arrow.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(arrow)
            }
            let box = FlowNodeView(number: index + 1, title: node.0, hint: node.1)
            boxes.append(box)
            views.append(box)
        }
        let row = hStack(views, spacing: 10)
        row.alignment = .centerY
        row.distribution = .fill
        addSubview(row)
        row.pinEdges(to: self)
        for box in boxes.dropFirst() { box.widthAnchor.constraint(equalTo: boxes[0].widthAnchor).isActive = true }
        for box in boxes { box.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// `.sx-node`: line-bright border on bg-soft, padding 8 / 10; the amber number square, the title
/// (12 cream) and the hint.
final class FlowNodeView: FlippedView {
    init(number: Int, title: String, hint: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let badge = NumberBadgeView(number)
        let titleLabel = SxLabel(SxRich(title).attributed(TextStyle.mono(12, Palette.cream), lineBreak: .byTruncatingTail), wraps: false)
        let top = hStack([badge, titleLabel], spacing: 7)
        let hintLabel = SxLabel(SxRich(hint).attributed(SxStyle.hint, lineHeight: SxStyle.hintLineHeight))
        let column = columnStack([top, hintLabel], spacing: 3)
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }
}

/// `.sx-node .i`: 16 × 16 amber square with a black 10 px bold number.
final class NumberBadgeView: NSView {
    let number: Int

    init(_ number: Int) {
        self.number = number
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: xz(16), height: xz(16)) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.amber)
        let text = TextStyle.mono(10, .black, .bold).string("\(number)")
        Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
    }
}
