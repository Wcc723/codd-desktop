import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// The CONDENSE card's states as the app drives them (D32): idle → running → preview → apply or
/// discard; failed; `disabledReason`.
@Suite("Condense card", .serialized)
@MainActor
struct CondenseTests {
    func labels(_ harness: CleanupHarness) -> [String] {
        harness.body.stateViews.compactMap { ($0 as? CoddButton)?.label ?? ($0 as? CleanupTextShowing)?.displayedText }
    }

    func visible(_ harness: CleanupHarness, _ view: NSView) -> Bool { !view.isHidden && view.superview != nil }

    @Test func idleRunningPreviewApply() {
        var model = CleanupSamples.page(condense: .idle, withPreview: false)
        let harness = CleanupHarness(model)
        defer { harness.tearDown() }
        let body = harness.body
        #expect(labels(harness) == ["✻ 產生摘要", "claude -p · 掛載 codd MCP"])
        #expect(visible(harness, body.generate.button) && body.generate.button.isEnabled)
        #expect(body.apply.button.isHidden && body.cancel.button.isHidden)
        #expect(body.previewBox.displayedText == CondenseCardView.placeholder)
        body.generate.button.performClick(nil)
        #expect(harness.log.events == ["generate"])

        // Running: the elapsed time and 取消; the select cannot change mid-run.
        model.condense?.state = .running(elapsed: "12s")
        harness.update(model)
        #expect(labels(harness) == ["◌ 產生中… 12s", "取消"])
        #expect(body.generate.button.isHidden && !body.cancel.button.isHidden)
        #expect(!body.select.isEnabled)
        body.cancel.button.performClick(nil)
        #expect(harness.log.events == ["generate", "cancel"])
        model.condense?.state = .running(elapsed: "13s")
        harness.update(model)
        #expect(labels(harness).first == "◌ 產生中… 13s")

        // Preview: the summary and the three buttons.
        model.condense?.state = .preview
        model.condense?.preview = CleanupSamples.summaryPreview
        harness.update(model)
        #expect(labels(harness) == ["建立摘要並封存原稿", "重新產生", "捨棄"])
        #expect(body.select.isEnabled)
        #expect(body.previewBox.displayedText.contains("摘要 · 10/15 清理（5 則）"))
        for button in [body.apply.button, body.regenerate.button, body.discard.button] {
            #expect(!button.isHidden && button.isEnabled)
            button.performClick(nil)
        }
        #expect(harness.log.events == ["generate", "cancel", "apply", "regenerate", "discard"])
        // The primary does not overlap the others (one line or two).
        #expect(!body.apply.button.frame.intersects(body.regenerate.button.frame))
        #expect(!body.regenerate.button.frame.intersects(body.discard.button.frame))

        // Applied: the app closes the card; the table takes the full width.
        model.condense = nil
        harness.update(model)
        #expect(harness.page.condense.isHidden)
        #expect(harness.page.review.frame.width == 1296)
        #expect(!harness.allText.contains("CONDENSE"))
    }

    @Test func discardReturnsToIdle() {
        var model = CleanupSamples.page(condense: .preview)
        let harness = CleanupHarness(model)
        defer { harness.tearDown() }
        harness.body.discard.button.performClick(nil)
        #expect(harness.log.events == ["discard"])
        model.condense?.state = .idle
        model.condense?.preview = nil
        harness.update(model)
        #expect(labels(harness) == ["✻ 產生摘要", "claude -p · 掛載 codd MCP"])
        #expect(harness.body.previewBox.preview == nil)
        #expect(harness.body.previewBox.displayedText == CondenseCardView.placeholder)
    }

    @Test func failedShowsTheErrorAndRegenerate() {
        let harness = CleanupHarness(CleanupSamples.page(condense: .failed("claude -p 在 180 秒內沒有完成，已停止"), withPreview: false))
        defer { harness.tearDown() }
        #expect(labels(harness) == ["[ERROR] claude -p 在 180 秒內沒有完成，已停止", "重新產生"])
        harness.body.regenerate.button.performClick(nil)
        #expect(harness.log.events == ["regenerate"])
        #expect(harness.body.generate.button.isHidden && harness.body.apply.button.isHidden)
        #expect(harness.body.errorText.frame.maxY <= harness.body.regenerate.button.frame.minY)
    }

    @Test func disabledReasonDisablesTheRuns() {
        let reason = "測試資料根目錄只用 -codd-claude-path"
        let harness = CleanupHarness(CleanupSamples.page(condense: .idle, withPreview: false, disabledReason: reason))
        defer { harness.tearDown() }
        let body = harness.body
        #expect(!body.generate.button.isEnabled)
        #expect(body.generate.button.toolTip == reason)
        #expect(labels(harness) == ["✻ 產生摘要", reason])
        #expect(!harness.allText.contains("claude -p · 掛載 codd MCP"))
        // The long reason wraps under the button instead of being cut.
        #expect(body.idleHint.frame.minY >= body.generate.button.frame.maxY)
        #expect(body.idleHint.frame.maxY <= body.bounds.height + 0.5)
        // 重新產生 runs claude too: disabled in the failed state.
        var model = CleanupSamples.page(condense: .failed("x"), withPreview: false, disabledReason: reason)
        harness.update(model)
        #expect(!body.regenerate.button.isEnabled)
        model.condense?.disabledReason = nil
        harness.update(model)
        #expect(body.regenerate.button.isEnabled)
    }

    @Test func longPreviewScrollsInsideTheBox() {
        var model = CleanupSamples.page(condense: .preview)
        let long = NSMutableAttributedString(attributedString: CleanupSamples.summaryPreview)
        for index in 0..<40 { long.append(TextStyle.mono(11, Palette.bone).string("\n第 \(index) 行摘要")) }
        model.condense?.preview = long
        let harness = CleanupHarness(model)
        defer { harness.tearDown() }
        let box = harness.body.previewBox
        #expect(abs(box.frame.height - CondenseCardView.previewMaxNaturalHeight) < 1 || box.frame.height > CondenseCardView.previewMaxNaturalHeight)
        #expect(box.textView.frame.height > box.scroll.contentSize.height, "the summary scrolls")
        // Room below the last line for the fade.
        #expect(box.textView.frame.height >= box.contentHeight(width: box.bounds.width) - 2)
    }

    @Test func titleArrowAndSources() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let title = harness.body.bigTitle.attributed
        #expect(title.string == "濃縮 5 則 → 1 則摘要")
        let arrow = (title.string as NSString).range(of: "→")
        #expect(title.attribute(.foregroundColor, at: arrow.location, effectiveRange: nil) as? NSColor == Palette.amber)
        #expect(harness.body.sources.sources.map(\.title) == ["keynote 第 2 章大綱", "舊審查清單草稿", "每日工作日誌（舊段落 9 段）",
                                                             "Pixel Town 對話樹草稿", "Remote Control 測試紀錄"])
        #expect(harness.body.sources.sources[2].tagColor == nil)
    }
}
