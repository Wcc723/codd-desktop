import AppKit
import CoddOnboarding
import CoddUI
import Testing
@testable import CoddOnboardingUI

@MainActor
@Suite("VoiceOver labels and roles (§2.4)")
struct AccessibilityTests {
    static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .textArea, .comboBox, .slider, .incrementor,
        .link, .disclosureTriangle, .menuItem,
    ]

    /// Every accessibility element under `root` that is shown: views (hidden ones and their subtrees
    /// skipped) and the elements views hand out through `accessibilityChildren()`.
    static func elements(under root: NSView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 64, let object = object as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? NSView {
                guard !view.isHidden, view.alphaValue > 0 else { return }
                // The field editor is part of the text field it edits (VoiceOver reads that field).
                if let editor = view as? NSTextView, editor.isFieldEditor { return }
                if view.isAccessibilityElement() { out.append(view) }
                for sub in view.subviews { visit(sub, depth: depth + 1) }
                for child in view.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            } else if let element = object as? NSAccessibilityElement {
                out.append(element)
                for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return out
    }

    static func label(_ object: NSObject) -> String {
        let element = object as? NSAccessibilityProtocol
        let text = element?.accessibilityLabel() ?? element?.accessibilityTitle() ?? ""
        if !text.isEmpty { return text }
        if let field = object as? NSTextField { return field.placeholderString ?? field.placeholderAttributedString?.string ?? "" }
        return ""
    }

    static func unlabeled(_ root: NSView) -> [String] {
        elements(under: root).compactMap { object in
            guard let role = (object as? NSAccessibilityProtocol)?.accessibilityRole(), interactiveRoles.contains(role) else { return nil }
            return label(object).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(type(of: object)) \(role.rawValue)" : nil
        }
    }

    @Test("every interactive element of every step (and the open group menu) has a label")
    func labels() {
        var models = OnboardingStep.allCases.map { OnboardingSamples.step($0) }
        models.append(OnboardingSamples.step(.detect, variant: [.claudeMissing, .cswapMissing]))
        models.append(OnboardingSamples.step(.accounts, variant: .cswapMissing))
        for model in models {
            let harness = Harness(model)
            defer { harness.tearDown() }
            #expect(Self.unlabeled(harness.view) == [], "step \(model.flow.current.rawValue)")
            // CoddUI's audit also sees cell-based controls (CoddButton is exposed through its cell),
            // which the walk above does not count.
            let report = AccessibilityAudit.audit(view: harness.view, screen: "step \(model.flow.current.rawValue)")
            #expect(report.unlabeled.isEmpty, "\(report.screen): \(report.unlabeled.map(\.path))")
            #expect(report.interactive >= 4, "\(report.screen)")
        }
        let menu = Harness()
        defer { menu.tearDown() }
        menu.view.openGroupMenu(for: OnboardingSamples.home + "/Github/mysite.github.io")
        menu.settle()
        #expect(Self.unlabeled(menu.view) == [])
        menu.view.groupMenu.panel.startNaming()
        menu.settle()
        #expect(Self.unlabeled(menu.view) == [])
        #expect(AccessibilityAudit.audit(view: menu.view, screen: "group menu").unlabeled.isEmpty)
    }

    @Test("the stepper is a list of buttons and static texts named `<n>. <title>，<state>`")
    func stepper() {
        let harness = Harness()
        defer { harness.tearDown() }
        let stepper = harness.view.stepper
        #expect(stepper.accessibilityRole() == .list)
        #expect(stepper.accessibilityLabel() == "首次啟動設定步驟")
        #expect(stepper.rows.map { $0.accessibilityLabel() ?? "" } == [
            "1. 偵測環境，已完成", "2. 匯入專案，目前步驟", "3. 安裝 hooks，尚未開始", "4. 筆記本與 MCP，尚未開始",
            "5. 帳號 (cswap)，尚未開始", "6. 完成，尚未開始",
        ])
        #expect(stepper.rows.map { $0.accessibilityRole() } == [.button, .staticText, .staticText, .staticText, .staticText, .staticText])
    }

    @Test("rows are checkboxes `<name>，<path>，<最近使用>，<n> 個對話`; selects `<name> 的群組：<group>`")
    func rows() {
        let harness = Harness()
        defer { harness.tearDown() }
        let first = harness.rows.rowViews[0]
        #expect(first.checkbox.accessibilityRole() == .checkBox)
        #expect(first.checkbox.accessibilityLabel() == "原型試做，~/Project/Northstar/lab/agent-lab-2026/原型試做，今天 10:34，14 個對話")
        #expect(first.checkbox.accessibilityValue() as? Int == 1)
        #expect(first.select.accessibilityRole() == .popUpButton)
        #expect(first.select.accessibilityLabel() == "原型試做 的群組：藍鵲 · 實驗室")
        let skills = harness.rows.rowViews[2]
        #expect(skills.select.accessibilityLabel() == "Skills 的群組：藍鵲 · 實驗室（未勾選）")
        #expect(skills.checkbox.accessibilityValue() as? Int == 0)
        #expect(harness.view.importView.table.header.checkbox.accessibilityLabel() == "全選目前顯示的專案")
        #expect(harness.view.importView.filter.field.accessibilityLabel() == "篩選專案")
    }

    @Test("the boot block is a group `環境偵測結果` whose lines read `<tag> <name> <value>`")
    func boot() {
        let harness = Harness()
        defer { harness.tearDown() }
        let boot = harness.view.boot
        #expect(boot.accessibilityRole() == .group)
        #expect(boot.accessibilityLabel() == "環境偵測結果")
        #expect(boot.term.lineViews.map { $0.accessibilityLabel() ?? "" } == [
            "[ OK ] claude 2.1.302", "[ OK ] cswap 0.26.0 · 3 個帳號", "[ .. ] hooks 需要更新（4 個事件）",
            "[ OK ] ~/Library/Application Support/CODD 可寫入", "[ OK ] ~/.claude.json 187 個專案", "[ .. ] projects waiting for operator",
        ])
    }

    @Test("Tab order: stepper → body controls → footer")
    func keyLoop() {
        OnboardingKeyboard.fullKeyboardAccessOverride = true
        defer { OnboardingKeyboard.fullKeyboardAccessOverride = nil }
        let harness = Harness()
        defer { harness.tearDown() }
        let view = harness.view
        let loop = view.keyLoop
        #expect(loop.first === view.stepper.rows[0])
        #expect(loop.contains { $0 === view.importView.filter.field })
        #expect(loop.contains { $0 === harness.rows })
        #expect(loop.suffix(3).map { $0 } == [view.footer.back.button, view.footer.skip.button, view.footer.primary.button])
        for (index, item) in loop.enumerated() { #expect(item.nextKeyView === loop[(index + 1) % loop.count]) }
        #expect(view.initialFirstResponder === harness.rows)
        #expect(view.stepper.rows[0].acceptsFirstResponder)
        #expect(!view.stepper.rows[2].acceptsFirstResponder)
    }
}
