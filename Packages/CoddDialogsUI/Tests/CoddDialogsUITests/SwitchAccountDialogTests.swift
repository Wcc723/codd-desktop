import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

@Suite("A · switch account", .serialized)
@MainActor
struct SwitchAccountDialogTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func make(_ model: SwitchAccountModel, confirmed: Recorder<Bool> = Recorder(), cancelled: Recorder<Bool> = Recorder())
        -> DialogHarness<SwitchAccountDialogView> {
        let view = SwitchAccountDialogView(model: model, onConfirm: { confirmed.append($0) }, onCancel: { cancelled.append(true) })
        let harness = DialogHarness(view)
        view.secondTick(now: now)
        return harness
    }

    @Test func copyIsTheArtboards() {
        let harness = make(DialogSamples.switchAccount(now: now))
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.dialogWidth == 640)
        #expect(view.title == "Switch account · 切換帳號")
        #expect(view.versionChipText == "cswap 0.26.0")
        #expect(view.questionText == "切換到 #2 藍鵲？")
        let (from, to) = view.cards
        #expect(from.headerLabel == "From · 剩餘" && to.headerLabel == "To · 剩餘")
        #expect(from.account.chips == [.active] && DialogChip.active.text == "Active" && DialogChip.active.caps)
        #expect(to.account.chips == [DialogChip("1 個 session 固定", kind: .cyan)])
        #expect(from.fiveHourRow.row.valueText == "91%" && from.weeklyRow.row.valueText == "15%")
        #expect(from.fiveHourRow.row.tone == .ok && from.weeklyRow.row.tone == .crit)
        #expect(to.fiveHourRow.row.valueText == "98%" && to.weeklyRow.row.valueText == "46%" && to.weeklyRow.row.tone == .warn)
        #expect(from.resetLine == "1w 重置 10/18 12:00 · 3d01h後")
        #expect(from.sourceLine == "statusline · 12s 前")
        #expect(to.resetLine == "1w 重置 10/16 22:59")
        #expect(to.sourceLine == "cswap cache · 3m 前")
        #expect(view.consequenceTexts == [
            "12 個跟隨全域登入的 session 約 30 秒內改用 #2",
            "第一則訊息可能需要重建快取",
            "固定帳號的 session（現場示範：連線 MCP）不受影響",
        ])
        #expect(view.pauseCheckbox.title == "同時暫停自動切換")
        #expect(view.autoSwitchText == "AUTO-SWITCH 目前 OFF")
        #expect(view.allLabelTexts().contains("切換後"))
        #expect(view.footerNote == "⏎ 切換 · ⎋ 取消")
        #expect(view.allButtonLabels().suffix(2) == ["取消", "切換"])
        #expect(view.progressText == nil && view.errorText == nil)
        #expect(view.confirmButton.isEnabled)
    }

    @Test func autoSwitchOnAndNoPinnedSessions() {
        var model = DialogSamples.switchAccount(now: now)
        model.autoSwitchOn = true
        model.pinnedTitles = []
        let harness = make(model)
        defer { harness.tearDown() }
        #expect(harness.view.autoSwitchText == "AUTO-SWITCH 目前 ON")
        #expect(harness.view.consequenceTexts.count == 2, "the pinned line needs pinned sessions")
    }

    @Test func switchingShowsTheD5ProgressAndDisablesConfirm() {
        let confirmed = Recorder<Bool>()
        let harness = make(DialogSamples.switchAccountSwitching(now: now), confirmed: confirmed)
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.progressText == "等待 Claude Code credential lock… 9s（1/3）")
        #expect(!view.confirmButton.isEnabled)
        #expect(view.cancelButton.isEnabled)
        #expect(harness.pressReturn(), "⏎ is claimed while switching")
        view.confirmButton.performClick(nil)
        #expect(confirmed.count == 0, "no second switch while one runs")

        // 1 Hz: the seconds count from `since`; the next attempt restarts them.
        view.secondTick(now: now.addingTimeInterval(1))
        #expect(view.progressText == "等待 Claude Code credential lock… 10s（1/3）")
        var model = view.model
        model.progress = SwitchProgress(attempt: 2, of: 3, since: now)
        view.update(model)
        view.secondTick(now: now.addingTimeInterval(3))
        #expect(view.progressText == "等待 Claude Code credential lock… 3s（2/3）")
    }

    @Test func failureShowsTheErrorLineAndAllowsARetry() {
        let confirmed = Recorder<Bool>()
        let harness = make(DialogSamples.switchAccountSwitching(now: now), confirmed: confirmed)
        defer { harness.tearDown() }
        let view = harness.view
        var model = view.model
        model.progress = nil
        model.error = "ClaudeCodeLockTimeout"
        view.update(model)
        #expect(view.progressText == nil)
        #expect(view.errorText == "[ERROR] 切換失敗：ClaudeCodeLockTimeout")
        #expect(view.confirmButton.isEnabled)
        #expect(harness.pressReturn())
        #expect(confirmed.values == [false])
    }

    @Test func returnConfirmsWithThePauseFlagAndEscapeCancels() {
        let confirmed = Recorder<Bool>()
        let cancelled = Recorder<Bool>()
        let harness = make(DialogSamples.switchAccount(now: now), confirmed: confirmed, cancelled: cancelled)
        defer { harness.tearDown() }
        let view = harness.view
        #expect(harness.pressReturn())
        #expect(confirmed.values == [false])
        view.pauseCheckbox.toggle()
        #expect(view.model.pauseAutoSwitch)
        #expect(harness.window.performKeyEquivalent(with: harness.key("\u{3}", keyCode: 0x4C)), "keypad Enter = ⏎")
        view.confirmButton.performClick(nil)
        #expect(confirmed.values == [false, true, true])
        #expect(harness.pressEscape())
        #expect(cancelled.count == 1)
        // ⌘⏎ and ⌥⎋ are not the dialog's.
        #expect(!harness.window.performKeyEquivalent(with: harness.key("\r", keyCode: 0x24, modifiers: .command)))
        #expect(confirmed.count == 3)
    }

    @Test func closeCancelAndEscapeAllCallOnCancel() {
        let cancelled = Recorder<Bool>()
        let harness = make(DialogSamples.switchAccount(now: now), cancelled: cancelled)
        defer { harness.tearDown() }
        harness.view.frameCloseButton.performClick(nil)
        harness.view.cancelButton.performClick(nil)
        harness.pressEscape()
        #expect(cancelled.count == 3, "✕, 取消 and ⎋")
    }

    @Test func aProgressUpdateKeepsTheTickedCheckboxAndTheUntouchedParts() {
        let confirmed = Recorder<Bool>()
        let harness = make(DialogSamples.switchAccount(now: now), confirmed: confirmed)
        defer { harness.tearDown() }
        let view = harness.view
        view.pauseCheckbox.toggle()
        let rows = view.consequenceRowViews
        // The app builds the next model from its own copy (pauseAutoSwitch still false).
        var next = DialogSamples.switchAccount(now: now)
        next.progress = SwitchProgress(attempt: 1, of: 3, since: now)
        view.update(next)
        #expect(view.pauseCheckbox.isOn, "the user's tick survives an unrelated update")
        #expect(view.model.pauseAutoSwitch)
        #expect(view.consequenceRowViews.map(ObjectIdentifier.init) == rows.map(ObjectIdentifier.init), "the list is not rebuilt")
        // The app may still set it on purpose.
        next.pauseAutoSwitch = true
        view.update(next)
        next.pauseAutoSwitch = false
        view.update(next)
        #expect(!view.pauseCheckbox.isOn)
    }

    @Test func sourceAgesAndCountdownsTick() {
        let harness = make(DialogSamples.switchAccount(now: now))
        defer { harness.tearDown() }
        let view = harness.view
        view.secondTick(now: now.addingTimeInterval(10))
        #expect(view.cards.from.sourceLine == "statusline · 22s 前")
        view.secondTick(now: now.addingTimeInterval(3_600))
        #expect(view.cards.from.resetLine == "1w 重置 10/18 12:00 · 3d後")
        #expect(view.cards.to.sourceLine == "cswap cache · 1h03m 前")
    }

    @Test func noFollowingSessionsSaysSo() {
        var model = DialogSamples.switchAccount(now: now)
        model.followingCount = 0
        let harness = make(model)
        defer { harness.tearDown() }
        #expect(harness.view.consequenceTexts.first == "目前沒有跟隨全域登入的 session；之後開的 session 會用 #2")
    }
}
