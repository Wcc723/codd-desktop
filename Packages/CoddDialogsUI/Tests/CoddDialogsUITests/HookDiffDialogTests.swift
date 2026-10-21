import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

@Suite("B · Hook 差異", .serialized)
@MainActor
struct HookDiffDialogTests {
    private func make(_ model: HookDiffModel, applied: Recorder<Bool> = Recorder(), cancelled: Recorder<Bool> = Recorder())
        -> DialogHarness<HookDiffDialogView> {
        DialogHarness(HookDiffDialogView(model: model, onApply: { applied.append(true) }, onCancel: { cancelled.append(true) }))
    }

    @Test func copyIsTheArtboards() {
        let harness = make(DialogSamples.hookDiff())
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.dialogWidth == 640)
        #expect(view.title == "Hook diff · 預覽變更")
        #expect(view.headerChipTexts == ["+9", "−1"])
        #expect(view.questionText == "預覽 ~/.claude/settings.json 變更")
        #expect(view.chipsRowTexts == ["補上 4 個 event", "+ PreCompact", "+ PostCompact", "+ SubagentStart", "+ SubagentStop"])
        #expect(view.summaryTexts.isEmpty)
        #expect(view.foreignText == "✓ foreign hooks 保持不動：hook-tap ×11 · osascript ×2")
        #expect(view.backupText == "~/.claude/settings.json.codd-bak-20261015-104210")
        #expect(view.allLabelTexts().contains("FOREIGN") && view.allLabelTexts().contains("BACKUP"))
        #expect(view.footerNote == "只動 hooks 與 statusLine，其他 key 不碰")
        #expect(view.allButtonLabels().suffix(2) == ["取消", "套用並備份"])
        #expect(view.applyButton.isEnabled)
        #expect(view.errorText == nil)
    }

    /// M3 review: a restore that deletes other tools' hooks said `保持不動`.
    @Test func aRestoreThatRemovesForeignHooksSaysSo() {
        var model = DialogSamples.hookDiff()
        model.foreignChanged = "移除 hook-tap ×2"
        let harness = make(model)
        defer { harness.tearDown() }
        #expect(harness.view.foreignText == "◆ foreign hooks 會變動：移除 hook-tap ×2")
        model.foreignKept = ""
        harness.view.update(model)
        #expect(harness.view.foreignText == "◆ foreign hooks 會變動：移除 hook-tap ×2", "shown even with nothing kept")
        model.foreignChanged = ""
        harness.view.update(model)
        #expect(harness.view.foreignText == nil)
    }

    @Test func diffLinesMapToCoddUILinesWithNumbersEllipsesAndEventEmphasis() {
        let harness = make(DialogSamples.hookDiff())
        defer { harness.tearDown() }
        let lines = harness.view.diffBox.linesView.lines
        #expect(lines.count == 15)
        #expect(lines.first?.kind == .hunk && lines.first?.displayedNumber == nil)
        #expect(lines.map(\.displayedNumber) == [nil, 38, 39, 40, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50])
        #expect(lines.filter { $0.kind == .added }.count == 9)
        #expect(lines.filter { $0.kind == .removed }.count == 1)
        let removed = lines[3]
        #expect(removed.sign == "-" && removed.spans.contains { $0.style == .ellipsis && $0.text == "…" })
        let preCompact = lines[5]
        #expect(preCompact.spans.first { $0.style == .emphasis }?.text == "\"PreCompact\"")
        #expect(preCompact.text == "    \"PreCompact\": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5,")
        // The artboard's 15 lines fit without scrolling.
        harness.settle()
        #expect(harness.view.diffBox.frame.height == CGFloat(15 * 16 + 18))
    }

    @Test func longDiffsScrollInsideAFixedBox() {
        var model = DialogSamples.hookDiff()
        model.lines = (1 ... 80).map { (index: Int) in DiffLineModel(.added, newNumber: index, text: "line \(index)") }
        let harness = make(model)
        defer { harness.tearDown() }
        #expect(harness.view.diffBox.frame.height == HookDiffDialogView.maxDiffHeight + 18)
        #expect(harness.view.diffBox.linesView.frame.height == CGFloat(80 * 16))
    }

    @Test func applyNeedsChangesAndCanApply() {
        let applied = Recorder<Bool>()
        let harness = make(DialogSamples.hookDiffNoChanges(), applied: applied)
        defer { harness.tearDown() }
        let view = harness.view
        #expect(!view.applyButton.isEnabled, "nothing to apply")
        #expect(view.headerChipTexts.isEmpty)
        #expect(view.chipsRowTexts.isEmpty)
        #expect(view.summaryTexts == ["hooks 與 statusLine 已是 CODD Desktop 的設定"])
        #expect(view.backupText == nil, "no backup row without a backup path")
        #expect(view.diffBox.linesView.lines.map(\.text) == ["// 沒有需要變更的地方：hooks 與 statusLine 已是最新"])
        #expect(harness.pressReturn())
        view.applyButton.performClick(nil)
        #expect(applied.count == 0)

        view.update(DialogSamples.hookDiff())
        #expect(view.applyButton.isEnabled)
        #expect(harness.pressReturn())
        #expect(applied.count == 1)

        view.update(DialogSamples.hookDiffError())
        #expect(!view.applyButton.isEnabled, "canApply false")
        #expect(view.errorText == "[ERROR] settings.json 在預覽後被修改，請關閉後重新預覽")
        #expect(harness.pressReturn())
        #expect(applied.count == 1)
    }

    @Test func restoreTitleAndMixedChipsLabel() {
        var model = DialogSamples.hookDiff()
        model.applyTitle = "還原"
        model.chips = [DiffChip("+ PreCompact", kind: .added), DiffChip("− Notification", kind: .removed)]
        let harness = make(model)
        defer { harness.tearDown() }
        #expect(harness.view.applyButton.label == "還原")
        #expect(harness.view.chipsRowTexts.first == "變更 2 個 event")
        var removedOnly = model
        removedOnly.chips = [DiffChip("− Stop", kind: .removed)]
        #expect(removedOnly.resolvedChipsLabel == "移除 1 個 event")
        removedOnly.chipsLabel = "移除舊版 CODD web hook"
        #expect(removedOnly.resolvedChipsLabel == "移除舊版 CODD web hook")
    }

    @Test func cancelPathsAndKeys() {
        let applied = Recorder<Bool>()
        let cancelled = Recorder<Bool>()
        let harness = make(DialogSamples.hookDiff(), applied: applied, cancelled: cancelled)
        defer { harness.tearDown() }
        harness.view.frameCloseButton.performClick(nil)
        harness.view.cancelButton.performClick(nil)
        #expect(harness.pressEscape())
        #expect(cancelled.count == 3)
        #expect(applied.count == 0)
        harness.view.applyButton.performClick(nil)
        #expect(applied.count == 1)
    }

    @Test func diffSpansSplitEmphasisAndEllipses() {
        let spans = DiffBoxView.spans("  \"PreCompact\": … end …", emphasis: ["\"PreCompact\"", "missing"])
        #expect(spans.map(\.text) == ["  ", "\"PreCompact\"", ": ", "…", " end ", "…"])
        #expect(spans.map(\.style) == [.plain, .emphasis, .plain, .ellipsis, .plain, .ellipsis])
        #expect(DiffBoxView.spans("", emphasis: []).map(\.text) == [""])
    }
}
