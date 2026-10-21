import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

@Suite("C · add account", .serialized)
@MainActor
struct AddAccountDialogTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    final class Calls {
        var opened = 0
        var captured = 0
        var added: [(String, Int)] = []
        var addToken = 0
        var cancelled = 0
    }

    private func make(_ model: AddAccountModel, calls: Calls = Calls()) -> DialogHarness<AddAccountDialogView> {
        DialogHarness(AddAccountDialogView(model: model, onOpenLoginTerminal: { calls.opened += 1 }, onCapture: { calls.captured += 1 },
                                           onAdd: { calls.added.append(($0, $1)) }, onAddToken: { calls.addToken += 1 },
                                           onCancel: { calls.cancelled += 1 }))
    }

    /// Focuses the alias field and types through its field editor, as the keyboard would.
    private func type(_ text: String, in harness: DialogHarness<AddAccountDialogView>, replacing: Bool = true) throws {
        harness.window.makeFirstResponder(harness.view.aliasField.field)
        harness.window.update()   // AppKit sends this every event loop pass; InputField tracks focus with it
        let editor = try #require(harness.window.firstResponder as? NSTextView)
        if replacing { editor.selectAll(nil) }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func copyIsTheArtboardsWithD24D33D34() {
        let harness = make(DialogSamples.addAccountStep3(now: now, alias: "studio"))
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.dialogWidth == 560)
        #expect(view.title == "Add account · 加入帳號")
        let texts = view.allLabelTexts()
        #expect(texts.contains("加入帳號（cswap add）"))
        #expect(texts.contains("CODD 透過 cswap 加入帳號；email 只在本機比對，不儲存也不顯示，帳號一律以編號與別名顯示。"), "D33")
        #expect(!texts.contains { $0.contains("不讀取也不顯示") }, "the artboard's untrue line is gone")
        #expect(texts.contains("在終端機執行 claude /login 登入新帳號"))
        #expect(texts.contains("擷取目前登入"))
        #expect(texts.contains("設定別名與編號"))
        #expect(view.step1HintText == "登入新帳號會暫時改變全域登入，加入後自動切回 #3 工作", "D24")
        #expect(view.step1TimeText == "已完成 · \(ClockFormat.hourMinute(now.addingTimeInterval(-60)))")
        #expect(view.detectText == "● 偵測到 新帳號 · MAX 20x")
        #expect(texts.contains("別名 ALIAS") && texts.contains("編號 SLOT"))
        #expect(texts.contains("別名只用來顯示，像 #3 工作、#2 藍鵲；之後可在 設定 › 帳號 修改"))
        #expect(view.aliasField.field.placeholderAttributedString?.string == "例如：studio")
        #expect(view.slotSelect.titles == ["#4", "#5"] && view.slotSelect.currentTitle == "#4")
        #expect(view.addTokenLink.title == "改用 setup-token / API key（cswap add-token）→")
        #expect(view.allButtonLabels() == ["✕", "開啟登入終端機", "擷取目前登入", "取消", "加入 #4"])
        #expect(view.stepStates == [.done, .done, .current])
        #expect(!view.aliasRuleHintShown)
        #expect(view.addButton.isEnabled)
        #expect(view.versionChipText == "cswap 0.26.0")
    }

    @Test func stepStatesFollowTheFlow() {
        let harness = make(DialogSamples.addAccountStep1())
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.stepStates == [.current, .pending, .pending])
        #expect(view.step1TimeText == nil && view.detectText == nil)
        view.update(DialogSamples.addAccountStep2(now: now))
        #expect(view.stepStates == [.done, .current, .pending])
        view.update(DialogSamples.addAccountExisting(now: now))
        #expect(view.stepStates == [.done, .done, .current])
        #expect(view.detectText == "● 已是 #2 藍鵲（會更新它的登入資料） · MAX 20x")
        // Logged in elsewhere: a capture without step 1 still makes step 3 current.
        var skipped = DialogSamples.addAccountStep1()
        skipped.detected = .newAccount(plan: nil)
        view.update(skipped)
        #expect(view.stepStates == [.pending, .done, .current])
        #expect(view.detectText == "● 偵測到 新帳號")
    }

    @Test func addStaysDisabledUntilTheAliasPassesCswapsRule() throws {
        let calls = Calls()
        let harness = make(DialogSamples.addAccountStep3(now: now), calls: calls)
        defer { harness.tearDown() }
        let view = harness.view
        #expect(!view.addButton.isEnabled, "empty alias")
        #expect(!view.aliasRuleHintShown, "no hint before typing")
        try type("工作室", in: harness)
        #expect(view.model.alias == "工作室")
        #expect(!view.addButton.isEnabled)
        #expect(view.aliasRuleHintShown)
        #expect(harness.pressReturn())
        #expect(calls.added.isEmpty, "⏎ does nothing while 加入 is disabled")
        try type("Studio", in: harness)
        #expect(view.addButton.isEnabled)
        #expect(!view.aliasRuleHintShown)
        #expect(harness.pressReturn())
        #expect(calls.added.count == 1)
        #expect(calls.added.first?.0 == "studio", "the callback gets the normalized alias")
        #expect(calls.added.first?.1 == 4)
        #expect(view.aliasField.text == "studio", "the field shows what cswap stores")
    }

    @Test func addNeedsACaptureAndNothingRunning() throws {
        var model = DialogSamples.addAccountStep2(now: now)
        model.alias = "studio"
        let harness = make(model)
        defer { harness.tearDown() }
        let view = harness.view
        #expect(!view.addButton.isEnabled, "no login captured yet")
        var captured = DialogSamples.addAccountStep3(now: now, alias: "studio")
        view.update(captured)
        #expect(view.addButton.isEnabled)
        captured.busy = true
        view.update(captured)
        #expect(!view.addButton.isEnabled)
        #expect(!view.captureButton.isEnabled && !view.openTerminalButton.isEnabled && !view.addTokenLink.isEnabled)
        #expect(view.cancelButton.isEnabled, "取消 always works")
        captured.busy = false
        captured.error = "cswap add 失敗：slot 4 已被使用"
        view.update(captured)
        #expect(view.addButton.isEnabled)
        #expect(view.errorText == "[ERROR] cswap add 失敗：slot 4 已被使用")
    }

    @Test func slotPickReachesTheCallbackAndTheButtonTitle() {
        let calls = Calls()
        let harness = make(DialogSamples.addAccountStep3(now: now, alias: "studio"), calls: calls)
        defer { harness.tearDown() }
        let view = harness.view
        var slots: [Int] = []
        view.onSlotChange = { slots.append($0) }
        view.slotSelect.onSelect?(1)
        #expect(slots == [5])
        #expect(view.addButton.label == "加入 #5")
        #expect(view.slotSelect.currentTitle == "#5")
        view.addButton.performClick(nil)
        #expect(calls.added.map(\.1) == [5])
    }

    @Test func returnIsLeftToTheInputMethodWhileComposing() throws {
        let calls = Calls()
        let harness = make(DialogSamples.addAccountStep3(now: now, alias: "studio"), calls: calls)
        defer { harness.tearDown() }
        harness.window.makeFirstResponder(harness.view.aliasField.field)
        let editor = try #require(harness.window.firstResponder as? NSTextView)
        editor.moveToEndOfDocument(nil)
        editor.setMarkedText("ㄍ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(harness.view.isComposing)
        #expect(!harness.pressReturn(), "⏎ commits the composition, it is not the dialog's")
        #expect(!harness.pressEscape(), "⎋ cancels the composition, it is not the dialog's")
        #expect(calls.added.isEmpty && calls.cancelled == 0)
        // The user deletes the syllable: the composition ends with the alias as before.
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        #expect(!harness.view.isComposing)
        #expect(harness.view.model.alias == "studio")
        #expect(harness.pressReturn())
        #expect(calls.added.map(\.0) == ["studio"])
    }

    @Test func anUpdateNeverClobbersTheTypedAlias() throws {
        let harness = make(DialogSamples.addAccountStep3(now: now))
        defer { harness.tearDown() }
        let view = harness.view
        var typed: [String] = []
        view.onAliasChange = { typed.append($0) }
        try type("studio", in: harness)
        #expect(typed == ["studio"])
        var next = DialogSamples.addAccountStep3(now: now)
        next.busy = true
        view.update(next)
        #expect(view.aliasField.text == "studio")
        #expect(view.model.alias == "studio")
        next.alias = "lab"
        view.update(next)
        #expect(view.aliasField.text == "lab", "a different alias from the app replaces it")
    }

    @Test func lowercasesOnCommit() throws {
        let harness = make(DialogSamples.addAccountStep3(now: now))
        defer { harness.tearDown() }
        try type(" Lab ", in: harness)
        harness.window.makeFirstResponder(nil)
        harness.window.update()
        #expect(harness.view.aliasField.text == "lab")
        try type("工作室", in: harness)
        harness.window.makeFirstResponder(nil)
        harness.window.update()
        #expect(harness.view.aliasField.text == "工作室", "a refused alias is left as typed (the hint explains)")
    }

    @Test func buttonsAndCancelPaths() {
        let calls = Calls()
        let harness = make(DialogSamples.addAccountStep1(), calls: calls)
        defer { harness.tearDown() }
        let view = harness.view
        view.openTerminalButton.performClick(nil)
        view.captureButton.performClick(nil)
        view.addTokenLink.performClick(nil)
        #expect(calls.opened == 1 && calls.captured == 1 && calls.addToken == 1)
        view.frameCloseButton.performClick(nil)
        view.cancelButton.performClick(nil)
        #expect(harness.pressEscape())
        #expect(calls.cancelled == 3, "✕, 取消 and ⎋ alike")
        #expect(calls.added.isEmpty)
    }
}
