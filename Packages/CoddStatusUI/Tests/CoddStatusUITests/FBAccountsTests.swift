import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// FB 「Status 的 Account 小一點」/「縮放尺寸時，版型會跑掉」/「引導安裝 cswap」/「自動切換帳號加上警語」.
@Suite("FB accounts", .serialized)
@MainActor
struct FBAccountsTests {
    /// The window widths of the FB sweep (sidebar 220 + page).
    static let windowWidths: [CGFloat] = [760, 900, 1000, 1200, 1440, 1900]

    /// Visible descendants of `view` whose frame leaves `view`'s bounds (the hanging ASCII corners
    /// excepted: they straddle the border by design).
    static func outside(_ view: NSView, tolerance: CGFloat = 0.5) -> [String] {
        var out: [String] = []
        func walk(_ node: NSView) {
            for sub in node.subviews where !sub.isHidden && !(sub is CornerGlyphView) {
                let frame = view.convert(sub.bounds, from: sub)
                if frame.width > 0, frame.height > 0,
                   frame.minX < -tolerance || frame.minY < -tolerance || frame.maxX > view.bounds.width + tolerance
                    || frame.maxY > view.bounds.height + tolerance {
                    out.append("\(type(of: sub)) \(frame) in \(view.bounds.size)")
                }
                walk(sub)
            }
        }
        walk(view)
        return out
    }

    static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    // MARK: Layout

    @Test func cardContentStaysInsideItsFrameAtEveryWidth() throws {
        var columnsByWidth: [Int] = []
        for width in Self.windowWidths {
            let harness = StatusHarness(size: CGSize(width: width, height: 1300))
            defer { harness.tearDown() }
            let accounts = harness.page.accounts
            let cards = accounts.orderedCards
            #expect(cards.count == 3)
            let minimum = accounts.minimumCardContentWidth
            for card in cards {
                #expect(card.frame.width + 0.5 >= minimum, "\(width): card \(card.frame.width) < content \(minimum)")
                #expect(Self.outside(card).isEmpty, "\(width): \(Self.outside(card))")
                for block in card.quotaBlocks {
                    #expect(block.showsWholeReset, "\(width): \(block.resetText) cut")
                    #expect(Self.outside(block).isEmpty, "\(width): \(Self.outside(block))")
                }
                // The corners sit on the border: top left at x 0, bottom right ending at the width.
                let corners = card.subviews.compactMap { $0 as? CornerGlyphView }
                #expect(corners.count == 2)
                #expect(corners.first?.frame.minX == 0)
                #expect(abs((corners.last?.frame.maxX ?? 0) - card.bounds.width) < 0.5)
            }
            // The grid stays inside the section and no two cards overlap.
            let frames = cards.map(\.frame) + [accounts.addCard.frame]
            for (index, frame) in frames.enumerated() {
                #expect(frame.minX >= 0 && frame.maxX <= accounts.bounds.width + 0.5, "\(width): \(frame)")
                for other in frames[(index + 1)...] { #expect(!frame.intersects(other)) }
            }
            // Columns: the cards on the first grid row.
            columnsByWidth.append(frames.filter { abs($0.minY - frames[0].minY) < 0.5 }.count)
            #expect(Self.outside(accounts).isEmpty, "\(width): \(Self.outside(accounts))")
        }
        // Columns reflow with the width (never fewer on a wider window) instead of overflowing.
        #expect(columnsByWidth == columnsByWidth.sorted(), "\(columnsByWidth)")
        #expect((columnsByWidth.first ?? 0) < (columnsByWidth.last ?? 0))
    }

    @Test func compactCardsAreShorterThanTheArtboardCards() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        // #2 has no pace line: 247 tall before the FB compaction.
        let card = harness.card("2")
        #expect(card.preferredHeight(width: 280) <= 205)
        #expect(QuotaBlockView.height == 31)
    }

    @Test func aNarrowWindowAtZoom20KeepsTheContentInside() {
        UIZoom.withScale(20.0 / 13.0) {
            let harness = StatusHarness(size: CGSize(width: 760, height: 1600))
            defer { harness.tearDown() }
            let accounts = harness.page.accounts
            for card in accounts.orderedCards {
                #expect(Self.outside(card).isEmpty, "\(Self.outside(card))")
                #expect(card.frame.maxX <= accounts.bounds.width + 0.5)
            }
            #expect(Set(accounts.orderedCards.map(\.frame.minX)).count == 1, "one column")
        }
    }

    @Test func theHeaderHintsNeverRunOverTheRule() throws {
        for width in Self.windowWidths {
            let harness = StatusHarness(size: CGSize(width: width, height: 1300))
            defer { harness.tearDown() }
            let accounts = harness.page.accounts
            let header = accounts.headerRow
            let hints = accounts.hintViews
            if accounts.hintsWrapped {
                // Their own line under the title, inside the section.
                for hint in hints {
                    let frame = accounts.convert(hint.bounds, from: hint)
                    #expect(frame.minY >= header.frame.maxY && frame.maxX <= accounts.bounds.width + 0.5, "\(width): \(frame)")
                }
            } else {
                let first = try #require(hints.first)
                #expect(header.ruleFrame.maxX <= first.frame.minX, "\(width): rule \(header.ruleFrame) hint \(first.frame)")
                for hint in hints { #expect(hint.frame.maxX <= header.bounds.width + 0.5, "\(width): \(hint.frame)") }
            }
            #expect(harness.pageTexts.contains("3 個帳號 · 不顯示 email"), "\(width): the count stays whole")
        }
        // The artboard's 1440 keeps the one-line header; 1000 (the FB screenshot) wraps it.
        let wide = StatusHarness(size: CGSize(width: 1440, height: 1300))
        defer { wide.tearDown() }
        #expect(!wide.page.accounts.hintsWrapped)
        let narrow = StatusHarness(size: CGSize(width: 1000, height: 1300))
        defer { narrow.tearDown() }
        #expect(narrow.page.accounts.hintsWrapped)
    }

    /// The FB screenshot: borders, rules and bars kept the old width after a window resize. Every
    /// drawn view of the page and the sidebar now redraws when its size changes (AppKit's
    /// scrollers and clip views keep their own policy).
    @Test func everyDrawnViewRedrawsWhenItsSizeChanges() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let views = Self.allViews(harness.page) + Self.allViews(harness.sidebar)
        let stale = views.filter { view in
            !(view is NSScroller || view is NSClipView || view is NSScrollView) && view.layerContentsRedrawPolicy == .onSetNeedsDisplay
        }
        #expect(stale.isEmpty, "\(Set(stale.map { String(describing: type(of: $0)) }))")
        #expect(harness.card("2").quotaBlocks.allSatisfy { $0.bar.layerContentsRedrawPolicy == .duringViewResize })
    }

    // MARK: Install guide

    @Test func cswapMissingShowsTheInstallGuide() throws {
        let harness = StatusHarness(StatusSamples.model(.accountsMissing))
        defer { harness.tearDown() }
        let guide = harness.page.accounts.guide
        #expect(!guide.isHidden)
        #expect(guide.commandTexts == ["uv tool install claude-swap", "brew install uv", "curl -LsSf https://astral.sh/uv/install.sh | sh"])
        #expect(guide.texts.first?.hasPrefix("INSTALL") == true, "\(guide.texts)")
        #expect(guide.texts.containsInOrder(["uv tool install claude-swap", "複製", "在終端機執行", CswapInstallGuide.uvHint,
                                             "brew install uv", "複製", CswapInstallGuide.note, CswapInstallGuide.redetectTitle]))
        #expect(Self.outside(guide).isEmpty, "\(Self.outside(guide))")
        // `[在終端機執行]` hands the command over (typed, not run, by the app); `[複製]` each line.
        try #require(guide.runButton).performClick(nil)
        for button in guide.copyButtons { button.performClick(nil) }
        #expect(harness.log.guideEvents == ["run:uv tool install claude-swap", "copy:uv tool install claude-swap", "copy:brew install uv",
                                            "copy:curl -LsSf https://astral.sh/uv/install.sh | sh"])
        #expect(guide.copyButtons.first?.label == CswapInstallGuide.copiedTitle)
        // `[↻ 重新偵測]` is the page's refresh (it looks for cswap again).
        guide.redetect.performClick(nil)
        #expect(harness.log.events.last == "refresh")
    }

    @Test func theGuideFollowsTheAvailability() {
        let harness = StatusHarness(StatusSamples.model(.accountsTooOld))
        defer { harness.tearDown() }
        let guide = harness.page.accounts.guide
        #expect(!guide.isHidden && guide.guide?.kind == .upgrade)
        #expect(guide.commandTexts == ["uv tool upgrade claude-swap"])
        harness.apply(StatusSamples.model(.accountsUnreadable))
        #expect(guide.isHidden, "cswap is there: no guide")
        harness.apply(StatusSamples.spec())
        #expect(guide.isHidden)
    }

    @Test func theGuideFitsANarrowPage() {
        let harness = StatusHarness(StatusSamples.model(.accountsMissing), size: CGSize(width: 220 + 560, height: 1300))
        defer { harness.tearDown() }
        let guide = harness.page.accounts.guide
        #expect(guide.frame.maxX <= harness.page.accounts.bounds.width + 0.5)
        #expect(Self.outside(guide).isEmpty, "\(Self.outside(guide))")
    }

    // MARK: Policy warning

    @Test func theAutoSwitchRowWarnsInAmber() {
        for state in [StatusSamples.State.spec, .autoSwitchOn] {
            let harness = StatusHarness(StatusSamples.model(state))
            defer { harness.tearDown() }
            let row = harness.page.accounts.autoSwitch
            #expect(row.policyText == "! Claude 官方不建議用多個帳號自動輪替來延長用量，可能違反 Anthropic 的使用條款；開啟前請自行評估風險。")
            #expect(row.policyFrame.height > 0 && row.policyFrame.maxX <= row.bounds.width)
            #expect(Self.outside(row).isEmpty, "\(Self.outside(row))")
        }
    }

    @Test func turningAutoSwitchOnAsksFirst() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let row = harness.page.accounts.autoSwitch
        // Declined: nothing changes.
        harness.log.confirmAnswer = false
        _ = row.toggle.accessibilityPerformPress()
        #expect(harness.log.events == ["confirmAutoSwitch"])
        // Confirmed: the app toggles.
        harness.log.confirmAnswer = true
        _ = row.toggle.accessibilityPerformPress()
        #expect(harness.log.events == ["confirmAutoSwitch", "confirmAutoSwitch", "toggleAutoSwitch"])
        // Turning it OFF does not ask.
        harness.apply(StatusSamples.model(.autoSwitchOn))
        _ = row.toggle.accessibilityPerformPress()
        #expect(harness.log.events.suffix(1) == ["toggleAutoSwitch"])
        #expect(harness.log.events.filter { $0 == "confirmAutoSwitch" }.count == 2)
    }
}
