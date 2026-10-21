import AppKit
@testable import CoddUI
import Testing

/// VoiceOver defaults of every control and primitive (M5 D21): roles, labels from what is shown,
/// values, press actions, and explicit labels that always win.
@MainActor
@Suite("Accessibility defaults")
struct AccessibilityDefaultsTests {
    init() {
        #expect(TestSupport.prepare(), "App/Fonts must register")
    }

    @Test func buttonIsLabelledByItsTitle() {
        let counter = ActionCounter()
        let button = CoddButton("取消", style: .bracket(.normal, small: false), target: counter, action: #selector(ActionCounter.fire(_:)))
        let window = TestSupport.host(button, size: NSSize(width: 90, height: 28))
        defer { window.close() }
        #expect(button.cell?.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "取消" || button.cell?.accessibilityTitle() == "取消")
        button.setAccessibilityLabel("取消切換")
        button.label = "Cancel"
        #expect(button.accessibilityLabel() == "取消切換")
        #expect(button.accessibilityPerformPress())
        #expect(counter.count == 1)
    }

    @Test func checkboxLabelFollowsTheTitleUntilACallerSetsOne() {
        let box = CheckboxButton(title: "5 小時")
        #expect(box.accessibilityRole() == .checkBox)
        #expect(box.accessibilityLabel() == "5 小時")
        box.title = "每週"
        #expect(box.accessibilityLabel() == "每週")
        box.setAccessibilityLabel("選取「每週」")
        box.title = "每日"
        #expect(box.accessibilityLabel() == "選取「每週」")
        box.setAccessibilityLabel(nil)
        #expect(box.accessibilityLabel() == "每日")
    }

    @Test func switchIsACheckboxThatReadsOnOff() {
        let toggle = SwitchToggle(label: "通知")
        #expect(toggle.accessibilityRole() == .checkBox)
        #expect(toggle.accessibilitySubrole() == .switch)
        #expect(toggle.accessibilityLabel() == "通知")
        #expect(toggle.accessibilityValue() as? Int == 0)
        #expect(toggle.accessibilityValueDescription() == "關")
        toggle.isOn = true
        #expect(toggle.accessibilityValue() as? Int == 1)
        #expect(toggle.accessibilityValueDescription() == "開")
    }

    @Test func segmentedSwitchIsARadioGroupOfRadioButtons() throws {
        let counter = ActionCounter()
        let seg = SegmentedSwitch(titles: ["Off", "Subtle", "Full"])
        seg.target = counter
        seg.action = #selector(ActionCounter.fire(_:))
        let window = TestSupport.host(seg, size: seg.intrinsicContentSize)
        defer { window.close() }
        #expect(seg.accessibilityRole() == .radioGroup)
        let segments = try #require(seg.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(segments.map { $0.accessibilityLabel() } == ["Off", "Subtle", "Full"])
        #expect(segments.allSatisfy { $0.accessibilityRole() == .radioButton && $0.isAccessibilityEnabled() })
        #expect(segments.map { $0.accessibilityValue() as? Int } == [1, 0, 0])
        #expect(segments.allSatisfy { $0.accessibilityFrame().width > 0 })
        #expect(segments[2].accessibilityPerformPress())
        #expect(seg.selectedIndex == 2)
        #expect(counter.count == 1)
        #expect(segments.map { $0.accessibilityValue() as? Int } == [0, 0, 1])
        #expect(seg.accessibilityValue() as? String == "Full")
    }

    @Test func stepperIsAnIncrementor() {
        let stepper = StepperControl(value: 2, minValue: 1, maxValue: 20, accessibilityLabel: "門檻")
        #expect(stepper.accessibilityRole() == .incrementor)
        #expect(stepper.accessibilityLabel() == "門檻")
        #expect(stepper.accessibilityValue() as? String == "2")
    }

    @Test func selectIsAPopUpButtonWithItsValue() {
        let select = SelectButton(titles: ["13 px（預設）", "12 px"], accessibilityLabel: "UI 字級")
        var presented = 0
        select.menuPresenter = { _ in presented += 1 }
        #expect(select.accessibilityRole() == .popUpButton)
        #expect(select.isAccessibilityEnabled())
        #expect(select.accessibilityLabel() == "UI 字級")
        #expect(select.accessibilityValue() as? String == "13 px（預設）")
        select.displayTitle = "15 px"
        #expect(select.accessibilityValue() as? String == "15 px")
        #expect(select.accessibilityPerformPress())
        #expect(presented == 1)
        select.isEnabled = false
        #expect(!select.isAccessibilityEnabled())
        #expect(!select.accessibilityPerformPress())
    }

    @Test func radioRowIsARadioButton() {
        var clicks = 0
        let radio = RadioRowView(title: "新對話", hint: "自動帶 --session-id")
        radio.onClick = { clicks += 1 }
        #expect(radio.accessibilityRole() == .radioButton)
        #expect(radio.isAccessibilityEnabled())
        #expect(radio.accessibilityLabel() == "新對話（自動帶 --session-id）")
        #expect(RadioRowView(title: "新對話", hint: "").accessibilityLabel() == "新對話")
        #expect(radio.accessibilityValue() as? Int == 0)
        radio.isOn = true
        #expect(radio.accessibilityValue() as? Int == 1)
        #expect(radio.accessibilityPerformPress())
        #expect(clicks == 1)
        radio.setAccessibilityLabel("開新對話")
        #expect(radio.accessibilityLabel() == "開新對話")
        radio.isEnabled = false
        #expect(!radio.isAccessibilityEnabled())
        #expect(!radio.accessibilityPerformPress())
        #expect(clicks == 1)
    }

    @Test func staticPrimitivesReadWhatTheyShow() {
        let chip = ChipView("MAX 20x", style: .chip())
        #expect(chip.isAccessibilityElement())
        #expect(chip.accessibilityRole() == .staticText)
        #expect(chip.accessibilityLabel() == "MAX 20x")
        chip.set("MAX 5x")
        #expect(chip.accessibilityLabel() == "MAX 5x")
        // A caller's label survives later text changes (Settings' cswap version chip).
        chip.setAccessibilityLabel("cswap 0.26.0")
        chip.set("0.27.0")
        #expect(chip.accessibilityLabel() == "cswap 0.26.0")

        let kbd = KbdView("⌘Q")
        #expect(kbd.accessibilityRole() == .staticText)
        #expect(kbd.accessibilityLabel() == "⌘Q")
        kbd.text = "⌘⇧Q"
        #expect(kbd.accessibilityLabel() == "⌘⇧Q")

        let quota = QuotaBarRowView(QuotaBarRow(key: "5h", remainingPercent: 91))
        #expect(quota.accessibilityRole() == .staticText)
        #expect(quota.accessibilityLabel() == "5h 剩 91%")
        quota.trailing = "2h57m後"
        #expect(quota.accessibilityLabel() == "5h 剩 91% · 2h57m後")
        quota.remainingPercent = nil
        #expect(quota.accessibilityLabel() == "5h 剩 — · 2h57m後")

        let header = SectionHeaderView(title: "Host", hint: "studio-mbp")
        #expect(header.accessibilityRole()?.rawValue == "AXHeading")
        #expect(header.accessibilityLabel() == "Host studio-mbp")
        header.title = "Accounts"
        #expect(header.accessibilityLabel() == "Accounts studio-mbp")

        let meter = MeterView(fraction: 0.5)
        #expect(meter.accessibilityLabel() == "使用量")
        meter.accessibilityText = "CPU 23%"
        #expect(meter.accessibilityLabel() == "CPU 23%")
    }

    @Test func groupsAreLabelledByTheirTitles() {
        let card = CardView(title: "~/.claude")
        #expect(card.accessibilityRole() == .group)
        #expect(card.accessibilityLabel() == "~/.claude")
        card.title = "MCP"
        #expect(card.accessibilityLabel() == "MCP")
        card.accessibilityText = "MCP 伺服器"
        #expect(card.accessibilityLabel() == "MCP 伺服器")
        card.setAccessibilityLabel("帳號 #2")
        card.title = "#3"
        #expect(card.accessibilityLabel() == "帳號 #2")

        let modal = ModalFrameView(title: "Quit · 結束")
        #expect(modal.accessibilityRole() == .group)
        #expect(modal.accessibilityLabel() == "Quit · 結束")
        modal.setAccessibilityLabel("結束 CODD")
        modal.title = "Quit"
        #expect(modal.accessibilityLabel() == "結束 CODD")

        let row = FormRowView(name: "UI 字級", english: "UI font size")
        #expect(row.accessibilityLabel() == "UI 字級 UI font size")
        row.setAccessibilityLabel("介面字級")
        row.name = "字級"
        #expect(row.accessibilityLabel() == "介面字級")
    }

    /// A disabled form row keeps every focusable control out of the key loop, not only NSControls.
    @Test func disabledFormRowRefusesFocusForSelectsAndRadios() {
        FocusSupport.with(fullKeyboardAccess: true) {
            let select = SelectButton(titles: ["a"], accessibilityLabel: "選擇")
            select.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let radio = RadioRowView(title: "跟隨", hint: "")
            radio.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = FormRowView(name: "帳號", controls: [select, radio])
            let window = TestSupport.host(row, size: NSSize(width: 640, height: 51))
            defer { window.close() }
            #expect(select.acceptsFirstResponder && radio.acceptsFirstResponder)
            row.isEnabled = false
            #expect(!select.acceptsFirstResponder && !radio.acceptsFirstResponder)
            row.isEnabled = true
            #expect(select.acceptsFirstResponder && radio.acceptsFirstResponder)
        }
    }
}
