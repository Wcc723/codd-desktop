import AppKit
import CoddUI

/// The specimen boards: every copied control and every M3 primitive, in its states, with the
/// artboards' own sample copy (SPEC §5) so the PNGs can be compared with helmet.html and the
/// Status / Settings / StatusDialogs artboards.
@MainActor
enum GalleryBoards {
    struct Board {
        var name: String
        var width: CGFloat
        var view: NSView
    }

    static func all() -> [Board] {
        [
            Board(name: "01-tokens", width: 1040, view: tokens()),
            Board(name: "02-buttons", width: 1040, view: buttons()),
            Board(name: "03-forms", width: 1040, view: forms()),
            Board(name: "04-quota-meters", width: 1040, view: quotaAndMeters()),
            Board(name: "05-cards-headers", width: 1040, view: cardsAndHeaders()),
            Board(name: "06-form-rows", width: 1040, view: formRows()),
            Board(name: "07-modals-diff", width: 1400, view: modalsAndDiff()),
            Board(name: "08-toast-misc", width: 1040, view: toastAndMisc()),
            Board(name: "09-focus", width: 1400, view: focus()),
        ]
    }

    // MARK: 01 tokens

    static func tokens() -> NSView {
        let colors: [(String, NSColor)] = [
            ("bg", Palette.bg), ("bg-soft", Palette.bgSoft), ("bg-lift", Palette.bgLift), ("bg-raise", Palette.bgRaise),
            ("line", Palette.line), ("line-bright", Palette.lineBright), ("amber", Palette.amber), ("amber-dim", Palette.amberDim),
            ("amber-glow", Palette.amberGlow), ("cream", Palette.cream), ("bone", Palette.bone), ("dim", Palette.dim),
            ("dimmer", Palette.dimmer), ("cyan", Palette.cyan), ("danger", Palette.danger), ("success", Palette.success),
            ("success-dim", Palette.successDim),
        ]
        let swatches = Specimen.column([
            Specimen.row(colors.prefix(9).map { SwatchView($0.0, $0.1) }, spacing: 10),
            Specimen.row(colors.dropFirst(9).map { SwatchView($0.0, $0.1) }, spacing: 10),
        ], spacing: 10)
        let tones = Specimen.row(Tone.allCases.map { SwatchView("tone-\($0.rawValue)", $0.color) }, spacing: 10)

        let type = Specimen.column([
            Specimen.label("STATUS 狀態", TextStyle.pageTitle),
            Specimen.row([Specimen.label("Host", TextStyle.subTitle), Specimen.caption(".h-sub · Space Mono 13 · .16em")]),
            Specimen.row([Specimen.label("~/.claude", TextStyle.cardTitle), Specimen.caption(".card-h · Space Mono 12")]),
            Specimen.row([Specimen.label("Switch account · 切換帳號", TextStyle.modalTitle), Specimen.caption(".m-h · Space Mono 12.5")]),
            Specimen.row([Specimen.label("切換後 After switch", TextStyle.sectionLabel), Specimen.caption(".sec · 10.5 caps .18em")]),
            Specimen.row([Specimen.label("別名 Alias", TextStyle.fieldLabel), Specimen.caption(".lbl · 10.5 caps .16em")]),
            Specimen.row([Specimen.label("studio-mbp · 曲線為最近 10 分鐘", TextStyle.hint), Specimen.caption(".hint · 11.5 dimmer")]),
            Specimen.row([Specimen.label("// 自動切換未開啟", TextStyle.comment), Specimen.caption(".comment · 12 dimmer")]),
            Specimen.row([Specimen.label("CODD 管理多個 Claude Code session 0123456789", TextStyle.mono(13, Palette.cream)),
                          Specimen.caption("body · JetBrains Mono 13 + PingFang TC")]),
            Specimen.row([Specimen.label("medium 500", TextStyle.mono(13, Palette.bone, .medium)),
                          Specimen.label("semibold 600", TextStyle.mono(13, Palette.bone, .semibold)),
                          Specimen.label("bold 700", TextStyle.mono(13, Palette.bone, .bold))], spacing: 18),
        ], spacing: 9)

        let chips = Specimen.column([
            Specimen.row(ChipKind.allCases.map { Specimen.chip(chipText($0), .chip($0)) }, spacing: 8),
            Specimen.row([Specimen.chip("● 正常", .chip(.ok, caps: true)), Specimen.chip("Active", .chip(.amber, caps: true)),
                          Specimen.chip("MAX 20x", .chip(caps: true, mini: true)), Specimen.chip("實驗", .chip(.amber, mini: true)),
                          Specimen.chip("✓ Active", .chip(.fill, caps: true, mini: true)), Specimen.chip("下一個", .chip(.cyan, mini: true)),
                          Specimen.chip("5h", .chip(dashed: true)), Specimen.chip("MAX 20x", .chip(weight: .medium)),
                          Specimen.chip("cswap 0.26.0", .chip(display: true)), Specimen.chip("+ PreCompact", .chip(.ok, height: 22))], spacing: 8),
            Specimen.row([Specimen.chip("~/.claude/settings.json", .code), Specimen.chip("~/.claude-swap-backup", .path),
                          Specimen.chip("M4", .milestone), Specimen.chip("EXT", .ext), Specimen.chip("3", .badge),
                          Specimen.chip("#2", .smallChip(Palette.cyan, border: Palette.cyan.withAlphaComponent(0.4)))], spacing: 8),
            Specimen.caption(".chip · .amber · .ok · .cy · .bad · .fill · .caps · .sx-mini · .sx-dc · .code · .path · .ext · .badge"),
        ], spacing: 10)

        let kbd = Specimen.row([
            Specimen.captioned(ChipView.kbd("⌘K"), "ChipView.kbd"),
            Specimen.captioned(KbdView("⌘Q"), ".kbd"),
            Specimen.captioned(KbdView("⌘⇧P", size: .large), ".sx-kbd"),
            Specimen.captioned(KbdView("⌥ Space", size: .hotkey), ".sx-hk"),
        ], spacing: 18)

        let icons: [(Icon, String)] = [(.sessions, "sessions"), (.notes, "notes"), (.status, "status"), (.settings, "settings"),
                                       (.search, "search"), (.files, "files"), (.bottomTerminal, "terminal"), (.plus, "plus"),
                                       (.window, "window"), (.brand, "brand"), (.folder, "folder"), (.maximize, "maximize"),
                                       (.restore, "restore"), (.copy, "copy")]
        let iconRow = Specimen.row(icons.map { IconSpecimenView($0.0, name: $0.1) }, spacing: 2)

        return Specimen.board("TOKENS", caption: "Palette · Tone · Type · Chips · Kbd · Icons", sections: [
            Specimen.section("Palette", swatches), Specimen.section("Tone", tones), Specimen.section("Type", type),
            Specimen.section("Chips", chips), Specimen.section("Kbd", kbd), Specimen.section("Icons", iconRow),
        ])
    }

    private static func chipText(_ kind: ChipKind) -> String {
        switch kind {
        case .plain: "MAX 20x"
        case .amber: "◆ 1 項需要更新"
        case .ok: "+9"
        case .cyan: "1 個 session 固定"
        case .bad: "−1"
        case .fill: "FILL"
        }
    }

    // MARK: 02 buttons

    static func buttons() -> NSView {
        func bracket(_ title: String, _ variant: CoddButton.Variant, small: Bool = false) -> CoddButton {
            CoddButton(title, style: .bracket(variant, small: small))
        }
        let disabled = bracket("Active", .normal, small: true)
        disabled.isEnabled = false
        let pressed = bracket("Pressed", .normal)
        pressed.isHighlighted = true
        let withKey = bracket("前往", .normal)
        withKey.trailing = "⌘1"
        let primaryKey = bracket("切換", .primary)
        primaryKey.trailing = "⏎"

        let brackets = Specimen.column([
            Specimen.row([bracket("取消", .normal), bracket("切換", .primary), bracket("全部停止並結束", .danger), bracket("Switch", .accent),
                          withKey, primaryKey, pressed]),
            Specimen.row([bracket("還原本頁預設", .normal, small: true), bracket("套用並備份", .primary, small: true),
                          bracket("解除安裝", .danger, small: true), bracket("Switch", .accent, small: true), disabled]),
        ], spacing: 10)

        let iconOn = CoddButton("", style: .icon(.search))
        iconOn.isOn = true
        let icons = Specimen.row([CoddButton("", style: .icon(.settings)), iconOn, CoddButton("", style: .icon(.plus, size: 24)),
                                  CoddButton("⋯", style: .glyph()), CoddButton("✕", style: .glyph()), CoddButton("A−", style: .glyph()),
                                  CoddButton("✕", style: .glyph(size: 22))])

        let pillOn = CoddButton("Needs", style: .pill(count: "3"))
        pillOn.isOn = true
        let tabOn = CoddButton("claude", style: .tab(lamp: "●", lampColor: Palette.success))
        tabOn.isOn = true
        tabOn.tabMarks = [.running, .bell]
        let tabOff = CoddButton("zsh", style: .tab(lamp: "○", lampColor: Palette.dim))
        let misc = Specimen.column([
            Specimen.row([CoddButton("Yes", style: .key(cap: "1", danger: false)), CoddButton("No", style: .key(cap: "esc", danger: true)),
                          CoddButton("Running", style: .pill(count: nil)), pillOn, CoddButton("✕ ⌘J", style: .smallPill)]),
            Specimen.row([tabOn, tabOff, CoddButton("開啟 →", style: .link), CoddButton("清理已停止 (5)", style: .plain)]),
            Specimen.sized(CoddButton("+ 新增群組", style: .addRow), width: 280),
        ], spacing: 10)

        return Specimen.board("BUTTONS", caption: "CoddButton · .btn · .icon-btn · .keybtn · .pillbtn · .tab", sections: [
            Specimen.section(".btn  [ LABEL ]  normal · primary · danger · accent · .sm · disabled · pressed", brackets),
            Specimen.section(".icon-btn  icon · on · glyph", icons),
            Specimen.section(".keybtn · .pillbtn · .tab · link · .btn.plain · addrow", misc),
        ])
    }

    // MARK: 03 forms

    static func forms() -> NSView {
        let empty = Specimen.sized(InputField(placeholder: "例如：studio"), width: 220)
        let filled = Specimen.sized(InputField(placeholder: "別名"), width: 220)
        filled.text = "studio"
        let focused = Specimen.sized(InputField(placeholder: "別名"), width: 220)
        focused.text = "工作室"
        focused.isFocused = true
        let off = Specimen.sized(InputField(placeholder: "停用"), width: 160)
        off.isEnabled = false
        let inputs = Specimen.row([Specimen.captioned(empty, "placeholder"), Specimen.captioned(filled, "value"),
                                   Specimen.captioned(focused, "focused"), Specimen.captioned(off, "disabled")], spacing: 16)

        let select = Specimen.sized(SelectButton(titles: ["13 px（預設）", "12 px", "14 px"], accessibilityLabel: "UI 字級"), width: 160)
        let selectOff = Specimen.sized(SelectButton(titles: ["#4", "#5"], accessibilityLabel: "編號"), width: 96)
        selectOff.isEnabled = false
        let selects = Specimen.row([Specimen.captioned(select, ".select"), Specimen.captioned(selectOff, "disabled")], spacing: 16)

        let radioOn = Specimen.sized(RadioRowView(title: "跟隨全域登入", hint: "切換帳號時一起換"), width: 360)
        radioOn.isOn = true
        let radioOff = Specimen.sized(RadioRowView(title: "固定 #2 藍鵲（cswap run）", hint: "不受切換影響"), width: 360)
        let radios = Specimen.column([radioOn, radioOff], spacing: 2)

        let swOn = SwitchToggle(label: "on")
        swOn.isOn = true
        let swOff = SwitchToggle(label: "off")
        let swDisabled = SwitchToggle(label: "disabled")
        swDisabled.isOn = true
        swDisabled.isEnabled = false
        let segCaps = SegmentedSwitch(titles: ["Off", "Subtle", "Full"])
        segCaps.selectedIndex = 1
        let segRaw = SegmentedSwitch(titles: ["default", "acceptEdits", "plan"], raw: true)
        segRaw.selectedIndex = 1
        let segNone = SegmentedSwitch(titles: ["5h", "1w"])
        segNone.selectedIndex = -1
        let switches = Specimen.row([Specimen.captioned(swOn, ".sw.on"), Specimen.captioned(swOff, ".sw"),
                                     Specimen.captioned(swDisabled, "disabled"), Specimen.captioned(segCaps, ".seg"),
                                     Specimen.captioned(segRaw, ".seg raw"), Specimen.captioned(segNone, "none")], spacing: 18)

        let area = Specimen.sized(TextAreaField(accessibilityLabel: "環境變數"), width: 360, height: 64)
        area.text = "ANTHROPIC_LOG=debug\nCLAUDE_CODE_MAX_OUTPUT_TOKENS=32000"
        let squares = Specimen.row([ColorSquareView(color: NSColor(hex: 0xEF5B5B)), ColorSquareView(color: NSColor(hex: 0x5B8DEF)),
                                    ColorSquareView(color: NSColor(hex: 0x4EC9B0)), ColorSquareView(color: nil)], spacing: 8)
        let fields = Specimen.row([Specimen.captioned(area, "TextAreaField"), Specimen.captioned(squares, "ColorSquareView")], spacing: 24)

        let cbOn = CheckboxButton(title: "5 小時", isOn: true)
        let cbOff = CheckboxButton(title: "每週")
        let cbDisabled = CheckboxButton(title: "停用", isOn: true)
        cbDisabled.isEnabled = false
        let plainOff = CheckboxButton(title: "同時暫停自動切換", hint: "AUTO-SWITCH 目前 OFF", style: .plain)
        let plainOn = CheckboxButton(title: "下次直接保留在選單列", style: .plain, isOn: true)
        let checks = Specimen.column([
            Specimen.row([Specimen.captioned(cbOn, ".sx-cb.on"), Specimen.captioned(cbOff, ".sx-cb"), Specimen.captioned(cbDisabled, "disabled")], spacing: 16),
            Specimen.row([Specimen.captioned(plainOff, ".sd-check + hint"), Specimen.captioned(plainOn, ".sd-check checked")], spacing: 24),
        ], spacing: 12)

        let threshold = StepperControl(value: 2, minValue: 1, maxValue: 20, format: { "\(Int($0)) %" },
                                       accessibilityLabel: "自動切換門檻", decrementLabel: "門檻減 1%", incrementLabel: "門檻加 1%")
        let font = StepperControl(value: 13, minValue: 10, maxValue: 24, decrementTitle: "A−", incrementTitle: "A+",
                                  accessibilityLabel: "終端機字級", decrementLabel: "縮小終端機字級", incrementLabel: "放大終端機字級")
        let wide = StepperControl(value: 20, minValue: 1, maxValue: 20, format: { "\(Int($0)) %" }, accessibilityLabel: "上限")
        let steppers = Specimen.row([Specimen.captioned(threshold, ".sx-step  2 %"), Specimen.captioned(font, "A− 13 A+"),
                                     Specimen.captioned(wide, "at max  20 %")], spacing: 24)

        return Specimen.board("FORMS", caption: "Input · Select · Radio · Switch · Seg · Checkbox · Stepper", sections: [
            Specimen.section(".input", inputs), Specimen.section(".select", selects), Specimen.section(".ns-radio", radios),
            Specimen.section(".sw · .seg", switches), Specimen.section("textarea · tag squares", fields),
            Specimen.section("CheckboxButton  .sx-cb · .sd-check", checks), Specimen.section("StepperControl  .sx-step", steppers),
        ])
    }

    // MARK: 04 quota, meters, sparklines

    static func quotaAndMeters() -> NSView {
        func rowView(_ row: QuotaBarRow, width: CGFloat = 300) -> QuotaBarRowView {
            Specimen.sized(QuotaBarRowView(row), width: width)
        }
        let rows = Specimen.row([
            Specimen.column([
                rowView(QuotaBarRow(key: "5h", remainingPercent: 98)),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 46)),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 15)),
                rowView(QuotaBarRow(key: "5h", remainingPercent: 100, tone: .muted)),
                Specimen.caption("ok · warn · crit · muted (not started)"),
            ], spacing: 6),
            Specimen.column([
                rowView(QuotaBarRow(key: "5h", remainingPercent: 91, keyWidth: 34)),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 15, keyWidth: 34)),
                rowView(QuotaBarRow(key: "Fable", remainingPercent: nil, keyWidth: 34)),
                rowView(QuotaBarRow(key: "Fable", remainingPercent: 100, keyWidth: 34)),
                Specimen.caption("STATUS card: key 34 · Fable nil = empty + —"),
            ], spacing: 6),
            Specimen.column([
                rowView(QuotaBarRow(key: "5h", remainingPercent: 98, threshold: 2)),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 15, threshold: 20)),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 3, threshold: 2, fontSize: 10.5)),
                rowView(QuotaBarRow(key: "5h", remainingPercent: 50, threshold: 50)),
                Specimen.caption(".thr tick at 2 · 20 · 2 · 50 %"),
            ], spacing: 6),
        ], spacing: 28)
        rows.alignment = .top
        let compact = Specimen.row([
            Specimen.column([
                rowView(QuotaBarRow(key: "5h", remainingPercent: 98, trailing: "2h37m後", compact: true), width: 240),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 46, trailing: "1d12h後", trailingIsKey: true, compact: true), width: 240),
                Specimen.caption(".acrow compact · trailing · sort key (bone)"),
            ], spacing: 4),
            Specimen.column([
                rowView(QuotaBarRow(key: "5h", remainingPercent: 91, trailing: "13:39 · 2h57m後"), width: 380),
                rowView(QuotaBarRow(key: "1w", remainingPercent: 15, trailing: "10/18 週日 12:00"), width: 380),
                Specimen.caption("Home USAGE: trailing reset"),
            ], spacing: 4),
        ], spacing: 28)
        compact.alignment = .top

        let meters = Specimen.row([
            Specimen.captioned(Specimen.sized(MeterView(fraction: 0.23), width: 180), ".meter 23 %"),
            Specimen.captioned(Specimen.sized(MeterView(fraction: 0.86, tone: .ok), width: 180), ".meter.tone-ok 86 %"),
            Specimen.captioned(Specimen.sized(MeterView(fraction: 1, tone: .muted), width: 180), ".tone-muted 100 %"),
            Specimen.captioned(Specimen.sized(MeterView(segments: zip([0.383, 0.119, 0.092], MeterView.stackColors).map {
                MeterView.Segment(fraction: $0.0, color: $0.1)
            }), width: 180), ".sx-stack app · wired · compressed"),
            Specimen.captioned(Specimen.sized(MeterView(main: 0.917, other: 0.083), width: 180), ".sx-split 11 + 1"),
        ], spacing: 20)
        meters.alignment = .top

        let cpu: [Double] = [28, 26, 27.3, 22.7, 19.3, 21.3, 24, 25.3, 22, 16.7, 14.7, 20, 23.3, 26, 27.3, 24, 20.7, 22.7, 25.3, 26.7, 24.7]
            .map { 1 - $0 / 40 }
        let memory: [Double] = [17.1, 16.7, 16.3, 15.9, 16, 15.5, 14.8, 14.3, 14.5, 14.7, 13.9, 13.6, 14, 14.4, 14.1, 13.7, 13.5, 13.9, 14.1, 14.3, 14.1]
            .map { 1 - $0 / 40 }
        let cpuSpark = SparklineView(values: cpu, baseline: 1 - 24.7 / 40)
        cpuSpark.showsBottomRule = true
        let memSpark = SparklineView(values: memory)
        memSpark.showsBottomRule = true
        let autoSpark = SparklineView(values: [3, 5, 4, 9, 12, 8, 6, 7, 11, 15, 10], scale: .auto, accessibilityLabel: "auto")
        let flat = SparklineView(values: [0.4])
        let sparks = Specimen.row([
            Specimen.captioned(Specimen.sized(cpuSpark, width: 220, height: 40), "CPU · baseline · bottom rule"),
            Specimen.captioned(Specimen.sized(memSpark, width: 220, height: 40), "MEM"),
            Specimen.captioned(Specimen.sized(autoSpark, width: 220, height: 28), ".spark auto-scaled"),
            Specimen.captioned(Specimen.sized(flat, width: 160, height: 28), "one value"),
        ], spacing: 20)
        sparks.alignment = .top

        return Specimen.board("QUOTA · METERS", caption: ".qrow · .bar10 · .thr · .meter · .spark", sections: [
            Specimen.section("QuotaBarRowView  .qrow", rows), Specimen.section("compact · trailing", compact),
            Specimen.section("MeterView  .meter", meters), Specimen.section("SparklineView  .spark", sparks),
        ])
    }

    // MARK: 05 cards and headers

    static func cardsAndHeaders() -> NSView {
        let host = SectionHeaderView(title: "Host", hint: "studio-mbp · 曲線為最近 10 分鐘",
                                     trailing: [ChipView("● 正常", style: .chip(.ok, caps: true))])
        let accounts = SectionHeaderView(title: "Accounts", leading: [ChipView("cswap 0.26.0", style: .chip()),
                                                                      ChipView("~/.claude-swap-backup", style: .path)],
                                         trailing: [SectionHeaderView.hintLabel("依每週重置排序 · 越快重置越上面"),
                                                    Label.make("·", style: TextStyle.mono(12, Palette.dimmer)),
                                                    SectionHeaderView.hintLabel("3 個帳號 · 不顯示 email")])
        let hooks = SectionHeaderView(title: "Hooks & Statusline")
        let group = SectionHeaderView(title: "Terminal", style: .group, hint: "終端機")
        let groupRight = SectionHeaderView(title: "Auto-switch", style: .group, hint: "自動切換",
                                           trailing: [SectionHeaderView.trailingText("OFF")])
        let groupPrefix = SectionHeaderView(title: "Remote Control", style: .group, hint: "Claude 官方 · 不需 Apple 開發者帳號",
                                            prefix: [ChipView("Phase 0", style: .chip(caps: true, mini: true))])
        let groupCount = SectionHeaderView(title: "Foreign hooks", style: .group, hint: "其他工具", count: "13")
        let headers = columnStack([host, accounts, hooks, group, groupRight, groupPrefix, groupCount], spacing: 14)

        let cards = Specimen.row([
            accountCard(slot: "#2", alias: "藍鵲", hot: false, button: "Switch", state: "cswap cache · 3m 前",
                        rows: [("5h", 98, "重置 13:19", "2h37m後", false), ("1w", 46, "重置 10/16 週五 22:59", "1d12h後", true),
                               ("Fable", nil, "快取未提供", "等待回報", false)], who: "1 個 session 固定（cswap run）"),
            accountCard(slot: "#3", alias: "工作", hot: true, button: "Active", state: "statusline · 12s 前",
                        rows: [("5h", 91, "重置 13:39", "2h57m後", false), ("1w", 15, "重置 10/18 週日 12:00", "3d01h後", true),
                               ("Fable", 100, "週額度 · 同 1w 重置", "未使用", false)], who: "12 個 session 跟隨全域登入"),
        ], spacing: 12)
        cards.alignment = .top

        let hooksCard = CardView(title: "~/.claude")
        hooksCard.setHeader(leading: [Label.make("settings.json", style: TextStyle.mono(11.5, Palette.dimmer, tracking: 0.04))],
                            trailing: [ChipView("◆ 1 項需要更新", style: .chip(.amber, weight: .medium))])
        fill(hooksCard, with: columnStack([
            Label.make("Hooks  ● 14 個 event 已安裝 · 1 個需要更新", style: TextStyle.mono(12, Palette.bone)),
            Label.make("Statusline  codd-statusline → 你的 statusline", style: TextStyle.mono(12, Palette.bone)),
        ], spacing: 8))
        Specimen.sized(hooksCard, width: 400)
        let bare = CardView()
        fill(bare, with: Label.make("// M4：筆記本與 MCP server 尚未提供", style: TextStyle.comment))
        Specimen.sized(bare, width: 260)
        let danger = CardView(title: "Danger zone")
        danger.borderColor = Palette.danger.withAlphaComponent(0.45)
        danger.showsCorners = false
        fill(danger, with: Label.make("borderColor · showsCorners = false", style: TextStyle.mono(12, Palette.dim)))
        Specimen.sized(danger, width: 260)
        let more = Specimen.row([hooksCard, bare, danger], spacing: 12)
        more.alignment = .top

        return Specimen.board("CARDS · HEADERS", caption: ".card · .card.hot · .card-h · .sx-sh · .sx-gh", sections: [
            Specimen.section("SectionHeaderView  .sx-sh · .sx-gh", headers, fullWidth: true),
            Specimen.section("CardView  .card · .card.hot (STATUS accounts)", cards),
            Specimen.section("CardView  header chips · no header · border override", more),
        ])
    }

    /// A STATUS account card (`.card.sx-acct`).
    private static func accountCard(slot: String, alias: String, hot: Bool, button: String, state: String,
                                    rows: [(String, Double?, String, String, Bool)], who: String) -> CardView {
        let card = CardView(hot: hot, padding: NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14))
        let title = NSMutableAttributedString(attributedString: TextStyle(font: Typeface.display(15), color: Palette.amber, tracking: 0.02).string(slot))
        title.append(NSAttributedString(string: "  "))
        title.append(TextStyle(font: Typeface.display(12), color: Palette.cream, tracking: 0.06).string(alias))
        card.attributedTitle = title
        let action = CoddButton(button, style: .bracket(hot ? .normal : .accent, small: true))
        action.isEnabled = !hot
        card.setHeader(leading: [ChipView("MAX 20x", style: .chip(hot ? .amber : .plain, weight: .medium))], trailing: [action])
        card.headerSpacing = 4 + 7
        var views: [NSView] = [hStack([Label.make("● ok", style: TextStyle.mono(11, Palette.success)),
                                       Label.make("·", style: TextStyle.mono(11, Palette.dimmer)),
                                       Label.make(state, style: TextStyle.mono(11, Palette.dim)), spacer()], spacing: 6)]
        for (key, remaining, reset, countdown, isKey) in rows {
            let quota = QuotaBarRowView(QuotaBarRow(key: key, remainingPercent: remaining, keyWidth: 34))
            let resetLine = hStack([Label.make(reset, style: TextStyle.mono(10.5, isKey ? Palette.bone : Palette.dim)), spacer(),
                                    Label.make(countdown, style: TextStyle.mono(10.5, isKey ? Palette.cream : Palette.dimmer, isKey ? .semibold : .regular))],
                                   spacing: 8, edgeInsets: NSEdgeInsets(top: 0, left: 42, bottom: 0, right: 0))
            views.append(columnStack([quota, resetLine], spacing: 2))
        }
        let whoLine = hStack([Label.make("●", style: TextStyle.mono(11, Palette.cyan)), Label.make(who, style: TextStyle.mono(11, Palette.bone)), spacer()],
                             spacing: 6, edgeInsets: NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0))
        views.append(whoLine)
        fill(card, with: columnStack(views, spacing: 7))
        card.accessibilityText = "帳號 \(slot) \(alias)"
        return Specimen.sized(card, width: 300)
    }

    private static func fill(_ card: CardView, with view: NSView) {
        card.contentView.addSubview(view)
        view.pinEdges(to: card.contentView)
    }

    // MARK: 06 form rows

    static func formRows() -> NSView {
        let uiSize = Specimen.sized(SelectButton(titles: ["13 px（預設）", "12 px", "14 px"], accessibilityLabel: "UI 字級"), width: 160)
        let vibrancy = SwitchToggle(label: "原生玻璃側欄")
        let threshold = StepperControl(value: 2, minValue: 1, maxValue: 20, format: { "\(Int($0)) %" }, accessibilityLabel: "自動切換門檻",
                                       decrementLabel: "門檻減 1%", incrementLabel: "門檻加 1%")
        let terminal = StepperControl(value: 13, minValue: 10, maxValue: 24, decrementTitle: "A−", incrementTitle: "A+",
                                      accessibilityLabel: "終端機字級")
        let mode = SegmentedSwitch(titles: ["Subtle", "Full", "Off"])
        let autoSwitch = SwitchToggle(label: "剩餘不足時自動切換")
        autoSwitch.isOn = true
        let rows: [FormRowView] = [
            FormRowView(name: "剩餘不足時自動切換", english: "Auto-switch",
                        hint: "由 cswap auto 執行（門檻換算成已用 98%、策略 consume-first）· 已有 cswap menubar 在跑時會提醒", controls: [autoSwitch]),
            FormRowView(name: "門檻", english: "Threshold", hint: "1–20%，預設 2%", variant: .tight,
                        controls: [Label.make("剩餘 ≤", style: TextStyle.mono(13, Palette.dimmer)), threshold]),
            FormRowView(name: "檢查", english: "Windows", hint: "任一個 ≤ 門檻就切換", variant: .tight,
                        controls: [CheckboxButton(title: "5 小時", isOn: true), CheckboxButton(title: "每週", isOn: true)]),
            FormRowView(name: "原生玻璃側欄", english: "Native vibrancy", hint: "側欄改用 macOS 毛玻璃材質；與 CRT 同時開啟較耗 GPU。",
                        controls: [vibrancy], nameAccessories: [ChipView("實驗", style: .chip(.amber, mini: true))]),
            FormRowView(name: "UI 字級", english: "UI font size", hint: "介面文字大小；終端機另外設定。", controls: [uiSize], milestone: "M5"),
            FormRowView(name: "終端機字級", english: "Terminal font size", hint: "也可在 session 標題列用 A− / A+ 調整，範圍 10–24。", controls: [terminal]),
            FormRowView(name: "CRT 掃描線", english: "CRT", hint: "仿 CRT 掃描線與暈影；Subtle 幾乎不影響閱讀。", controls: [mode]),
        ]
        rows[4].isEnabled = false
        rows[rows.count - 1].showsSeparator = false
        let card = PanelView(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        let stack = columnStack(rows, spacing: 0, edgeInsets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        card.addSubview(stack)
        stack.pinEdges(to: card)
        Specimen.sized(card, width: 700)

        let narrowRow = FormRowView(name: "狀態目錄", english: "Status dir", hint: "hooks 寫入、CODD 讀取 session 狀態的資料夾。",
                                    controls: [CoddButton("重新安裝", style: .bracket(.normal, small: true))],
                                    nameAccessories: [ChipView("! 與預設不同", style: .chip(.amber, mini: true))],
                                    detailViews: [hStack([ChipView("~/Github/codd-web/agent-sandbox/.claude/codd-status", style: .path)], spacing: 0)])
        narrowRow.showsSeparator = false
        let narrow = PanelView(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        let narrowStack = columnStack([narrowRow], spacing: 0, edgeInsets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        narrow.addSubview(narrowStack)
        narrowStack.pinEdges(to: narrow)
        Specimen.sized(narrow, width: 520)

        return Specimen.board("FORM ROWS", caption: ".sx-card · .sx-row · .sx-row.tight · .sx-dim + M5", sections: [
            Specimen.section("FormRowView  regular · tight · accessories · disabled (M5) · last row without separator", card),
            Specimen.section("FormRowView  detail view (path) · narrow width", narrow),
        ])
    }

    // MARK: 07 modals and diff

    static func modalsAndDiff() -> NSView {
        // A · switch account
        let switchModal = ModalFrameView(title: "Switch account · 切換帳號",
                                         headerAccessories: [ChipView("cswap 0.26.0", style: .chip(display: true))])
        let question = NSMutableAttributedString(attributedString: TextStyle(font: Typeface.display(17), color: Palette.cream, tracking: 0.01).string("切換到 "))
        question.append(TextStyle(font: Typeface.display(17), color: Palette.cyan, tracking: 0.01).string("#2 藍鵲"))
        question.append(TextStyle(font: Typeface.display(17), color: Palette.cream, tracking: 0.01).string("？"))
        let questionLabel = NSTextField(labelWithAttributedString: question)
        let swap = hStack([miniAccount(label: "From · 剩餘", slot: "#3", alias: "工作", rows: [("5h", 91), ("1w", 15)], to: false),
                           Label.make("→", style: TextStyle.mono(16, Palette.amber)),
                           miniAccount(label: "To · 剩餘", slot: "#2", alias: "藍鵲", rows: [("5h", 98), ("1w", 46)], to: true)], spacing: 10)
        swap.distribution = .fill
        let pause = CheckboxButton(title: "同時暫停自動切換", hint: "AUTO-SWITCH 目前 OFF", style: .plain)
        let body = columnStack([questionLabel, swap, Label.make("切換後", style: TextStyle.sectionLabel),
                                Label.make("▸ 12 個跟隨全域登入的 session 約 30 秒內改用 #2", style: TextStyle.mono(12.5, Palette.bone)),
                                hStack([pause], spacing: 0)], spacing: 14)
        switchModal.contentView.addSubview(body)
        body.pinEdges(to: switchModal.contentView)
        switchModal.setFooter(note: "⏎ 切換 · ⎋ 取消", buttons: [CoddButton("取消", style: .bracket(.normal, small: false)),
                                                               CoddButton("切換", style: .bracket(.primary, small: false))])
        Specimen.sized(switchModal, width: 640)

        // B · hook diff
        let diffModal = ModalFrameView(title: "Hook diff · 預覽變更",
                                       headerAccessories: [ChipView("+9", style: .chip(.ok, display: true)), ChipView("−1", style: .chip(.bad, display: true))])
        let diff = DiffLinesView(lines: sampleDiff, accessibilityLabel: "settings.json 差異")
        let diffQuestion = hStack([Label.make("預覽", style: TextStyle(font: Typeface.display(17), color: Palette.cream, tracking: 0.01)),
                                   ChipView("~/.claude/settings.json", style: .code),
                                   Label.make("變更", style: TextStyle(font: Typeface.display(17), color: Palette.cream, tracking: 0.01)), spacer()],
                                  spacing: 6)
        let events = hStack([Label.make("補上 4 個 event", style: TextStyle.fieldLabel)] +
                            ["+ PreCompact", "+ PostCompact", "+ SubagentStart", "+ SubagentStop"].map { ChipView($0, style: .chip(.ok)) } + [spacer()], spacing: 6)
        let diffBody = columnStack([diffQuestion, events, diff], spacing: 14)
        diffModal.contentView.addSubview(diffBody)
        diffBody.pinEdges(to: diffModal.contentView)
        diffModal.setFooter(note: "只動 hooks 與 statusLine，其他 key 不碰",
                            buttons: [CoddButton("取消", style: .bracket(.normal, small: false)), CoddButton("套用並備份", style: .bracket(.primary, small: false))])
        Specimen.sized(diffModal, width: 640)

        // D · quit (footer: checkbox left, note right)
        let quit = ModalFrameView(title: "Quit · 結束", headerAccessories: [KbdView("⌘Q")])
        let quitBody = columnStack([
            Label.make("結束 CODD？", style: TextStyle(font: Typeface.display(17), color: Palette.cream, tracking: 0.01)),
            Label.make("13 個 session 執行中 · ◆ 3 需要你", style: TextStyle.mono(12.5, Palette.bone)),
            CoddButton("全部停止並結束", style: .bracket(.danger, small: false)),
            CoddButton("保留在選單列（關閉視窗）", style: .bracket(.primary, small: false)),
        ], spacing: 12)
        quit.contentView.addSubview(quitBody)
        quitBody.pinEdges(to: quit.contentView)
        quit.setFooter(leading: [CheckboxButton(title: "下次直接保留在選單列", style: .plain)],
                       trailing: [ModalFrameView.noteLabel("設定 › 一般 › 結束時")])
        Specimen.sized(quit, width: 520)

        let noClose = ModalFrameView(title: "No close · helmet .m-h", showsClose: false)
        let noCloseBody = Label.make("showsClose = false · no footer", style: TextStyle.mono(12, Palette.dim))
        noClose.contentView.addSubview(noCloseBody)
        noCloseBody.pinEdges(to: noClose.contentView)
        Specimen.sized(noClose, width: 520)

        let elided = DiffLinesView(lines: [
            DiffLinesView.Line(kind: .hunk, text: "@@ -1,3 +1,3 @@"),
            DiffLinesView.Line(kind: .context, oldNumber: 1, newNumber: 1, text: "{"),
            DiffLinesView.Line(kind: .elided, text: "⋯ 36 行未變更"),
            DiffLinesView.Line(kind: .removed, oldNumber: 38, text: "  \"model\": \"opus\""),
            DiffLinesView.Line(kind: .added, newNumber: 38, spans: [.init("  "), .init("\"model\"", style: .emphasis), .init(": \"sonnet\"")]),
        ])
        let bare = DiffLinesView(lines: Array(sampleDiff.prefix(3)))
        bare.framed = false

        let left = columnStack([Specimen.section("ModalFrameView  A · Switch account", switchModal),
                                Specimen.section("ModalFrameView  D · Quit (checkbox left, note right)", quit),
                                Specimen.section("ModalFrameView  without ✕", noClose)], spacing: 26)
        let right = columnStack([Specimen.section("ModalFrameView + DiffLinesView  B · Hook diff", diffModal),
                                 Specimen.section("DiffLinesView  elided · emphasis", Specimen.sized(elided, width: 640)),
                                 Specimen.section("DiffLinesView  framed = false", Specimen.sized(bare, width: 640))], spacing: 26)
        let columns = hStack([left, right], spacing: 40)
        columns.alignment = .top
        return Specimen.board("MODALS · DIFF", caption: ".modal · .m-h · .m-b · .m-f · .sd-diff", sections: [columns])
    }

    /// `.sd-acct` (dialog A's mini account card) built from the primitives.
    private static func miniAccount(label: String, slot: String, alias: String, rows: [(String, Double)], to: Bool) -> NSView {
        let box = PanelView(fill: Palette.bg, edges: [.top, .bottom, .left, .right], edgeColor: to ? Palette.amberDim : Palette.lineBright)
        let head = hStack([Label.make(label, style: TextStyle.fieldLabel), spacer(),
                           ChipView(to ? "1 個 session 固定" : "Active", style: to ? .chip(.cyan) : .chip(.amber, caps: true))], spacing: 8)
        let name = hStack([Label.make(slot, style: TextStyle(font: Typeface.display(14), color: to ? Palette.cyan : Palette.amber)),
                           Label.make(alias, style: TextStyle.mono(14, Palette.cream)), spacer(), ChipView("MAX 20x", style: .chip())], spacing: 8)
        var views: [NSView] = [head, name]
        views += rows.map { QuotaBarRowView(QuotaBarRow(key: $0.0, remainingPercent: $0.1)) }
        let stack = columnStack(views, spacing: 6, edgeInsets: NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13))
        box.addSubview(stack)
        stack.pinEdges(to: box)
        return Specimen.sized(box, width: 270)
    }

    /// The Hook diff artboard's lines.
    static let sampleDiff: [DiffLinesView.Line] = {
        let command = "      \"command\": \"[ -z \\\"$CODD_TERMINAL_ID\\\" ] || … status-writer.js'\" }] }],"
        func event(_ number: Int, _ name: String) -> DiffLinesView.Line {
            DiffLinesView.Line(kind: .added, newNumber: number, spans: [.init("    "), .init("\"\(name)\"", style: .emphasis),
                                                                       .init(": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5,")])
        }
        return [
            DiffLinesView.Line(kind: .hunk, text: "@@ -38,5 +38,13 @@  \"hooks\""),
            DiffLinesView.Line(kind: .context, oldNumber: 38, newNumber: 38,
                               text: "    \"StopFailure\": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5, … }] }],"),
            DiffLinesView.Line(kind: .context, oldNumber: 39, newNumber: 39, text: "    \"SessionEnd\": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5,"),
            DiffLinesView.Line(kind: .removed, oldNumber: 40, text: String(command.dropLast())),
            DiffLinesView.Line(kind: .added, newNumber: 40, text: command),
            event(41, "PreCompact"),
            DiffLinesView.Line(kind: .added, newNumber: 42, text: command),
            event(43, "PostCompact"),
            DiffLinesView.Line(kind: .added, newNumber: 44, text: command),
            event(45, "SubagentStart"),
            DiffLinesView.Line(kind: .added, newNumber: 46, text: command),
            event(47, "SubagentStop"),
            DiffLinesView.Line(kind: .added, newNumber: 48, text: String(command.dropLast())),
            DiffLinesView.Line(kind: .context, oldNumber: 41, newNumber: 49, text: "  },"),
            DiffLinesView.Line(kind: .context, oldNumber: 42, newNumber: 50,
                               text: "  \"statusLine\": { \"type\": \"command\", \"command\": \"… codd-statusline.js …\" }"),
        ]
    }()

    // MARK: 08 toast and misc

    static func toastAndMisc() -> NSView {
        let toast = ToastView(text: "已切換到 #2 藍鵲 · 12 個 session 約 30 秒內套用", undo: {})
        Specimen.sized(toast, width: 460)
        let countdown = ToastView(text: "✕ 3 個 session 已封存", undo: {}, countdown: 5)
        let rules = columnStack([
            Specimen.captioned(Specimen.sized(DashedRuleView(), width: 400), "DashedRuleView() · --line (the app's rule)"),
            Specimen.captioned(Specimen.sized(DashedRuleView(color: Palette.lineBright, minimumWidth: 24), width: 400), "color: --line-bright (.sx-rule)"),
        ], spacing: 14)
        let panel = PanelView(fill: Palette.bgSoft, edges: [.top, .bottom], edgeColor: Palette.lineBright, dashed: [.bottom])
        let panelLabel = Label.make("PanelView · fill bg-soft · top solid · bottom dashed", style: TextStyle.mono(11.5, Palette.dim))
        panel.addSubview(panelLabel)
        panelLabel.pinEdges(to: panel, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        Specimen.sized(panel, width: 400)
        let wrapping = WrappingLabel("WrappingLabel：多行文字依版面寬度換行，中文與 English mixed 都正常斷行，不會被截斷。", style: TextStyle.mono(12, Palette.bone))
        Specimen.sized(wrapping, width: 300)
        return Specimen.board("TOAST · MISC", caption: "ToastView · DashedRuleView · PanelView · WrappingLabel", sections: [
            Specimen.section("ToastView  .mn-toast · countdown .toast", Specimen.column([toast, countdown], spacing: 14)),
            Specimen.section("DashedRuleView", rules),
            Specimen.section("PanelView · WrappingLabel", Specimen.row([panel, wrapping], spacing: 24)),
        ])
    }
}
