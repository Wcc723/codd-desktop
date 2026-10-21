import AppKit
import CoddOnboarding
import CoddUI
import Testing
@testable import CoddOnboardingUI

@MainActor
@Suite("Actions, keyboard and the group menu")
struct InteractionTests {
    static let site = OnboardingSamples.home + "/Github/mysite.github.io"
    static let skills = OnboardingSamples.home + "/Project/Northstar/lab/agent-lab-2026/整合範例/Skills"

    @Test("the footer, the boot block, the stepper and the link fire their actions")
    func chrome() {
        let harness = Harness()
        defer { harness.tearDown() }
        let view = harness.view
        view.footer.primary.button.performClick(nil)
        view.footer.back.button.performClick(nil)
        view.footer.skip.button.performClick(nil)
        view.boot.redetect.button.performClick(nil)
        view.stepper.link.performClick(nil)
        #expect(view.stepper.rows[0].accessibilityPerformPress())
        #expect(!view.stepper.rows[2].accessibilityPerformPress())   // todo: not clickable
        #expect(!view.stepper.rows[1].accessibilityPerformPress())   // the current step
        #expect(harness.recorder.events == ["next", "back", "skip", "redetect", "importWeb", "goTo:1"])
    }

    @Test("上一步 is disabled on step 1; the primary finishes on step 6")
    func firstAndLast() {
        let first = Harness(OnboardingSamples.step(.detect))
        defer { first.tearDown() }
        #expect(!first.view.footer.back.button.isEnabled)
        first.view.footer.back.button.performClick(nil)
        _ = first.view.performKeyEquivalent(with: first.commandBracket)
        #expect(first.recorder.events.isEmpty)
        let last = Harness(OnboardingSamples.step(.done))
        defer { last.tearDown() }
        last.view.footer.primary.button.performClick(nil)
        #expect(last.view.performKeyEquivalent(with: last.returnKey))
        #expect(last.recorder.events == ["finish", "finish"])
    }

    @Test("every step body's buttons")
    func stepButtons() {
        let detect = Harness(OnboardingSamples.step(.detect))
        defer { detect.tearDown() }
        (detect.view.detectView.keyViews.first as? NSButton)?.performClick(nil)
        #expect(detect.recorder.events == ["goTo:3"])

        let problems = Harness(OnboardingSamples.step(.detect, variant: [.claudeMissing]))
        defer { problems.tearDown() }
        (problems.view.detectView.keyViews.first as? NSButton)?.performClick(nil)
        #expect(problems.recorder.events == ["redetect"])

        let hooks = Harness(OnboardingSamples.step(.hooks))
        defer { hooks.tearDown() }
        hooks.view.hooksView.preview.button.performClick(nil)
        #expect(hooks.recorder.events == ["previewHooks"])

        let notebook = Harness(OnboardingSamples.step(.notebook))
        defer { notebook.tearDown() }
        notebook.view.notebookView.reveal.button.performClick(nil)
        notebook.view.notebookView.register.button.performClick(nil)
        notebook.view.notebookView.codex.button.performClick(nil)
        #expect(notebook.recorder.events == ["revealNotes", "registerClaudeCode", "copyCodexSnippet"])

        let accounts = Harness(OnboardingSamples.step(.accounts))
        defer { accounts.tearDown() }
        accounts.view.accountsView.add.button.performClick(nil)
        #expect(accounts.recorder.events == ["addAccount"])

        let done = Harness(OnboardingSamples.step(.done))
        defer { done.tearDown() }
        done.view.doneView.allow.button.performClick(nil)
        #expect(done.recorder.events == ["requestNotifications"])
    }

    @Test("⏎ is the primary button (also from the filter), ⌘[ goes back; composing text keeps ⏎")
    func keys() {
        let harness = Harness()
        defer { harness.tearDown() }
        #expect(harness.view.performKeyEquivalent(with: harness.returnKey))
        harness.window.makeFirstResponder(harness.view.importView.filter.field)
        #expect(harness.view.performKeyEquivalent(with: harness.returnKey))
        #expect(harness.view.performKeyEquivalent(with: harness.commandBracket))
        #expect(harness.recorder.events == ["next", "next", "back"])
        // The filter's own ⏎ (the field editor's insertNewline) presses the primary too.
        harness.view.importView.filter.onSubmit()
        #expect(harness.recorder.events.last == "next")
    }

    @Test("space toggles the focused row, ↑ / ↓ move the focus, ⌥↓ opens its group menu")
    func tableKeyboard() {
        let harness = Harness()
        defer { harness.tearDown() }
        let rows = harness.rows
        #expect(harness.window.makeFirstResponder(rows))
        #expect(rows.focusedIndex == 0)
        rows.keyDown(with: harness.down)
        rows.keyDown(with: harness.down)
        #expect(rows.focusedPath == Self.skills)
        #expect(rows.rowViews[2].isKeyFocused)
        rows.keyDown(with: harness.space)
        harness.settle()
        #expect(harness.recorder.selections.last?.checked.contains(Self.skills) == true)
        #expect(harness.view.model.importStep.selection.checked.contains(Self.skills))
        #expect(harness.view.model.importStep.summary == "10 個專案 → 3 個群組")
        #expect(harness.view.importView.chipText == "已選 10")
        #expect(harness.view.model.stepDetails[.importProjects] == "已選 10 / 187")
        #expect(rows.focusedPath == Self.skills)   // the focus stays on the row after the update
        rows.keyDown(with: harness.up)
        rows.keyDown(with: harness.optionDown)
        harness.settle()
        #expect(harness.view.isGroupMenuOpen)
        #expect(harness.view.groupMenu.path == OnboardingSamples.home + "/Project/Northstar/lab/agent-lab-2026/整合範例/MCP")
        harness.view.groupMenu.keyDown(with: harness.escape)
        #expect(!harness.view.isGroupMenuOpen)
        #expect(harness.window.firstResponder === rows)
    }

    @Test("the row checkbox, the name, the select-all box, the hidden toggle and 載入更多")
    func tableMouse() {
        let harness = Harness()
        defer { harness.tearDown() }
        let usageBar = harness.row("/Github/UsageBar")!
        #expect(usageBar.checkbox.accessibilityPerformPress())
        #expect(harness.recorder.selections.last?.checked.contains(usageBar.path) == true)
        let header = harness.view.importView.table.header.checkbox
        #expect(header.state == .mixed)
        #expect(header.accessibilityPerformPress())
        harness.settle()
        #expect(harness.view.model.importStep.selection.checked.count == 12)
        #expect(header.state == .on)
        #expect(header.accessibilityPerformPress())
        #expect(harness.view.model.importStep.selection.checked.isEmpty)
        #expect(!harness.view.importView.suggest.button.isEnabled)

        harness.view.importView.table.foot.hiddenToggle.performClick(nil)
        harness.settle()
        #expect(harness.view.model.importStep.selection.showHidden)
        #expect(harness.view.importView.table.foot.hiddenToggle.label == "隱藏")
        #expect(harness.rows.rowViews.contains { $0.candidate?.hidden == .worktree })
        harness.view.importView.table.foot.more.button.performClick(nil)
        harness.settle()
        #expect(harness.view.model.importStep.selection.limit == 36)
        #expect(harness.rows.rowViews.count == 36)
    }

    @Test("the filter narrows the table and reports the selection")
    func filter() {
        let harness = Harness()
        defer { harness.tearDown() }
        let filter = harness.view.importView.filter
        filter.field.stringValue = "ｇｅａｒ"
        filter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: filter.field))
        harness.settle()
        #expect(harness.recorder.selections.last?.filter == "ｇｅａｒ")
        #expect(harness.rows.rowViews.map { $0.candidate?.name } == ["Gear3D"])
        #expect(harness.view.importView.table.foot.count.displayedText == "顯示 1 / 1")
        filter.field.stringValue = "no-such-project"
        filter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: filter.field))
        harness.settle()
        #expect(harness.rows.rowViews.isEmpty)
        #expect(harness.view.importView.table.empty.displayedText == "// 沒有符合「no-such-project」的專案")
    }

    @Test("依父資料夾建議分組 asks, then reports every checked row on its suggestion")
    func suggest() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.view.importView.suggest.button.performClick(nil)
        #expect(harness.recorder.events == ["suggestGroups", "importChanged"])
        let lineBot = OnboardingSamples.home + "/Github/chat-bot-mcp"
        #expect(harness.recorder.selections.last?.group[lineBot] == GroupOption.ungroupedKey)   // unchecked: kept
        #expect(harness.recorder.selections.last?.group[Self.site] == "existing:g-github")
    }

    @Test("the group menu picks a group, names a new one, and closes on a click outside")
    func groupMenu() {
        let harness = Harness()
        defer { harness.tearDown() }
        let view = harness.view
        view.openGroupMenu(for: Self.skills)   // unchecked: its select is disabled
        #expect(!view.isGroupMenuOpen)
        view.openGroupMenu(for: Self.site)
        harness.settle()
        #expect(view.isGroupMenuOpen)
        #expect(view.groupMenu.panel.items[3].accessibilityPerformPress())   // CODD
        harness.settle()
        #expect(!view.isGroupMenuOpen)
        #expect(harness.recorder.selections.last?.group[Self.site] == "existing:g-codd")
        #expect(harness.row("/Github/mysite.github.io")?.select.displayedText == "CODD")
        #expect(harness.view.model.importStep.summary == "9 個專案 → 4 個群組")

        view.openGroupMenu(for: Self.site)
        harness.settle()
        let panel = view.groupMenu.panel
        #expect(panel.newItem.accessibilityPerformPress())
        #expect(panel.isNaming)
        panel.nameField.text = "實驗室"
        _ = panel.nameField.onCommand?(#selector(NSResponder.insertNewline(_:)))
        harness.settle()
        #expect(!view.isGroupMenuOpen)
        #expect(harness.recorder.groups.map(\.name) == ["實驗室"])
        let selection = harness.recorder.selections.last
        #expect(selection?.newGroups.map(\.name) == ["實驗室"])
        #expect(selection?.group[Self.site] == selection?.newGroups.first?.key)
        #expect(view.model.importStep.options.contains { $0.name == "實驗室" })
        #expect(harness.recorder.events.suffix(2) == ["newGroup:實驗室", "importChanged"])

        view.openGroupMenu(for: Self.site)
        harness.settle()
        #expect(view.groupMenu.panel.items.map(\.displayedText).contains("實驗室 ✓"))
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(view.groupMenu.hitTest(CGPoint(x: 5, y: 5)) === view.groupMenu)
        view.groupMenu.mouseDown(with: outside)
        #expect(!view.isGroupMenuOpen)
        #expect(!(harness.row("/Github/mysite.github.io")?.select.isOpen ?? true))
    }

    @Test("update applies only what changed and keeps the focused control focused")
    func updateKeepsFocus() {
        let harness = Harness()
        defer { harness.tearDown() }
        let field = harness.view.importView.filter.field
        #expect(harness.window.makeFirstResponder(field))
        let editor = harness.window.firstResponder
        let rowBefore = harness.row("/Github/Gear3D")
        var model = harness.view.model
        model.boot = EnvironmentReport.make(OnboardingSamples.facts(.cswapMissing), step: .importProjects, imported: nil,
                                            timeZone: OnboardingSamples.timeZone, home: OnboardingSamples.home)
        model.importStep = model.importStep.with(model.importStep.selection.toggling(Self.skills))
        harness.view.update(model)
        harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(harness.row("/Github/Gear3D") === rowBefore)
        #expect(harness.view.boot.headerTexts[1] == "3 OK · 2 待處理")
        #expect(harness.recorder.events.isEmpty)   // an update from the App reports nothing back

        var next = harness.view.model
        next.flow.next()
        harness.view.update(next)
        harness.settle()
        #expect(harness.view.importView.isHidden)
        #expect(harness.view.hooksView.superview != nil)
        #expect(harness.view.head.kicker.displayedText == "STEP 03 / 06 · HOOKS & STATUSLINE")
    }
}
