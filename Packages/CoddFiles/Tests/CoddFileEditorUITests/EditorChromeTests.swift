import AppKit
import CoddFiles
import CoddUI
import Testing
@testable import CoddFileEditorUI

@Suite("Tab strip, toolbar, banner, status items, dirty-close sheet", .serialized)
@MainActor
struct EditorChromeTests {
    // MARK: Tabs

    @Test func tabStripRendersAndReportsClicks() throws {
        let host = Host(EditorTabStripView(model: FileEditorSamples.tabs()), size: NSSize(width: 1104, height: EditorTabStripView.height))
        defer { host.tearDown() }
        let strip = host.view
        let rep = try #require(host.render())
        #expect(rep.contains(Palette.amber), "the active tab's top line and name")
        #expect(rep.contains(FileEditorColors.tagPink), "the session tag")
        #expect(rep.contains(Palette.bgSoft))
        let selected = Calls<String>(), closed = Calls<String>(), pinned = Calls<String>()
        strip.onSelect = { selected.append($0) }
        strip.onClose = { closed.append($0) }
        strip.onPin = { pinned.append($0) }
        var sessions = 0, more = 0
        strip.onOpenSession = { sessions += 1 }
        strip.onMore = { more += 1 }
        let tabs = strip.tabsArea.placed
        #expect(tabs.map(\.tab.id) == ["src/pages/punch.vue", "tailwind.config.js", "note:rwd-punch-k7x2"])
        strip.tabsArea.click(at: CGPoint(x: tabs[1].frame.minX + 20, y: 15), count: 1)
        strip.tabsArea.click(at: CGPoint(x: tabs[1].frame.minX + 20, y: 15), count: 2)
        strip.tabsArea.click(at: CGPoint(x: tabs[2].close.midX, y: tabs[2].close.midY), count: 1)
        #expect(selected.values == ["tailwind.config.js"])
        #expect(pinned.values == ["tailwind.config.js"], "double click pins the preview tab")
        #expect(closed.values == ["note:rwd-punch-k7x2"])
        _ = strip.sessionPill.accessibilityPerformPress()
        strip.moreButton.performClickAction()
        #expect(sessions == 1 && more == 1)
        #expect(!strip.splitButton.isEnabled && strip.splitButton.toolTip == "分割編輯器（之後提供）")
        #expect(tabs[0].frame.maxX <= strip.sessionPill.frame.minX)
    }

    @Test func tabStripWithoutASession() {
        var model = FileEditorSamples.tabs()
        model.session = nil
        model.tabs.append(EditorTab(id: "x", title: "x.swift", ai: AIChip(color: nil)))
        let host = Host(EditorTabStripView(model: model), size: NSSize(width: 900, height: EditorTabStripView.height))
        defer { host.tearDown() }
        #expect(host.view.sessionPill.isHidden)
        #expect(host.view.tabsArea.placed.count == 4)
        #expect(host.render() != nil)
    }

    // MARK: Toolbar

    @Test func toolbarControlsReportTheirActions() throws {
        let host = Host(EditorToolbarView(model: FileEditorSamples.toolbar()), size: NSSize(width: 1104, height: EditorToolbarView.height))
        defer { host.tearDown() }
        let bar = host.view
        let rep = try #require(host.render())
        #expect(rep.contains(Palette.amber), "the switch knob and the select chevron")
        let crumbs = Calls<Int>(), baselines = Calls<Int>(), switches = Calls<Bool>()
        var previous = 0, next = 0, finds = 0
        bar.onCrumb = { crumbs.append($0) }
        bar.onBaseline = { baselines.append($0) }
        bar.onShowAIChanges = { switches.append($0) }
        bar.onPreviousChange = { previous += 1 }
        bar.onNextChange = { next += 1 }
        bar.onFind = { finds += 1 }
        let frames = bar.crumbs.computeFrames()
        bar.crumbs.click(at: CGPoint(x: frames[0].midX, y: 10))
        bar.crumbs.click(at: CGPoint(x: frames[2].midX, y: 10)) // the file: not a link
        bar.crumbs.click(at: CGPoint(x: frames[3].midX, y: 10)) // a symbol: not a link
        #expect(crumbs.values == [0])
        bar.previousButton.performClickAction()
        bar.nextButton.performClickAction()
        #expect(previous == 1 && next == 1)
        #expect(bar.aiSwitch.isOn)
        _ = bar.aiSwitch.accessibilityPerformPress()
        #expect(switches.values == [false])
        bar.baselineSelect.choose(2)
        #expect(baselines.values == [2])
        #expect(bar.baselineSelect.currentTitle == "基準：AI 開始前 10:30")
        bar.findButton.performClick(nil)
        #expect(finds == 1)
        #expect(bar.changesLabel.text == "AI 變更 2 段")
        #expect(bar.changesLabel.frame.width >= bar.changesLabel.intrinsicContentSize.width - 0.5, "never cut short")
    }

    @Test func toolbarWithoutAIChangesAndADisabledBaseline() {
        var model = FileEditorSamples.toolbar()
        model.aiChangeCount = nil
        model.baselines = EditorToolbarModel.baselineTitles(lastSave: "10:39", aiStart: nil)
        model.baselineEnabled = [true, false]
        let host = Host(EditorToolbarView(model: model), size: NSSize(width: 1104, height: EditorToolbarView.height))
        defer { host.tearDown() }
        #expect(host.view.changesLabel.isHidden && host.view.previousButton.isHidden && host.view.nextButton.isHidden)
        var picked: [Int] = []
        host.view.onBaseline = { picked.append($0) }
        host.view.baselineSelect.choose(1)
        #expect(picked.isEmpty, "a disabled baseline cannot be picked")
        #expect(model.baselines == ["基準：git HEAD", "基準：上次儲存 10:39"])
    }

    // MARK: Banner

    @Test func bannerTextsAndButtons() throws {
        let model = DiskChangeBannerModel.fileChanged(aiSession: "打卡頁 RWD 調整", time: "10:41")
        #expect(model.title == "磁碟上的檔案已被 AI 變更（打卡頁 RWD 調整 · 10:41）")
        #expect(DiskChangeBannerModel.fileChanged(aiSession: nil, time: nil).title == "磁碟上的檔案已變更")
        #expect(DiskChangeBannerModel.noteChanged().title == "磁碟上的筆記已變更")
        let host = Host(DiskChangeBannerView(model: model), size: NSSize(width: 1104, height: DiskChangeBannerView.height))
        defer { host.tearDown() }
        let banner = host.view
        let rep = try #require(host.render())
        #expect(rep.contains(Palette.amberDim), "the rule and the accent button")
        var reloads = 0, keeps = 0, compares = 0
        banner.onReload = { reloads += 1 }
        banner.onKeepMine = { keeps += 1 }
        banner.onCompare = { compares += 1 }
        banner.reloadButton.performClick(nil)
        banner.keepButton.performClick(nil)
        banner.compareButton.performClick(nil)
        #expect(reloads == 1 && keeps == 1 && compares == 1)
        #expect(banner.unsavedLabel.frame.width >= banner.unsavedLabel.intrinsicContentSize.width - 0.5, "· 你有未儲存的修改 fits")
        banner.update(.noteChanged(showsUnsaved: false))
        #expect(banner.titleLabel.text == "磁碟上的筆記已變更" && banner.unsavedLabel.isHidden)
        banner.update(.fileChanged(aiSession: nil, time: nil, canReload: false))
        #expect(!banner.reloadButton.isEnabled)
    }

    // MARK: Status items

    @Test func statusItemsAreClickable() throws {
        let host = Host(EditorStatusItemsView(model: FileEditorSamples.status()), size: NSSize(width: 900, height: 24))
        defer { host.tearDown() }
        let items = host.view
        let rep = try #require(host.render())
        #expect(rep.contains(FileEditorColors.tagPink) && rep.contains(Palette.amberDim))
        var clicked: [EditorStatusItem] = []
        items.onItem = { clicked.append($0) }
        for (_, frame) in items.computeButtonFrames() { items.click(at: CGPoint(x: frame.midX, y: 12)) }
        items.click(at: CGPoint(x: 2, y: 12)) // the branch is not a button
        #expect(clicked == EditorStatusItem.allCases)
    }

    @Test func statusModelFromADecodedFile() throws {
        let decoded = try TextFileCodec.decode(Data("a\r\nb\nc\r\n".utf8)).get()
        let model = EditorStatusModel(decoded: decoded, branch: "main", session: nil, line: 3, column: 1, language: "Plain Text",
                                      saved: .dirty)
        #expect(model.lineEnding == "CRLF*" && model.encoding == "UTF-8" && model.indentation == "—")
        #expect(TextEncodingKind.big5.label == "Big5" && Indentation.spaces(2).label == "2 spaces" && Indentation.tabs.label == "Tab")
    }

    // MARK: Dirty close

    @Test func dirtyCloseSheetChoicesAndKeys() throws {
        let host = Host(DirtyCloseSheetView(fileName: "punch.vue"), size: NSSize(width: DirtyCloseSheetView.width, height: DirtyCloseSheetView.height))
        defer { host.tearDown() }
        let sheet = host.view
        #expect(sheet.titleLabel.text == "儲存「punch.vue」的變更？")
        #expect(sheet.hintLabel.text == "不儲存的話，這次的修改會遺失。")
        let rep = try #require(host.render())
        #expect(rep.contains(Palette.amber) && rep.contains(Palette.danger))
        let choices = Calls<DirtyCloseChoice>()
        sheet.onChoice = { choices.append($0) }
        sheet.saveButton.performClick(nil)
        sheet.discardButton.performClick(nil)
        sheet.cancelButton.performClick(nil)
        #expect(choices.values == [.save, .discard, .cancel])
        #expect(DirtyCloseSheetView.choice(for: "\r", keyCode: 0x24, flags: []) == .save)
        #expect(DirtyCloseSheetView.choice(for: "\u{1B}", keyCode: 0x35, flags: []) == .cancel)
        #expect(DirtyCloseSheetView.choice(for: "d", keyCode: 0x02, flags: .command) == .discard)
        #expect(DirtyCloseSheetView.choice(for: "\u{8}", keyCode: 0x33, flags: .command) == .discard)
        #expect(DirtyCloseSheetView.choice(for: "s", keyCode: 0x01, flags: .command) == nil)
        #expect(sheet.saveButton.frame.maxX > sheet.cancelButton.frame.maxX && sheet.discardButton.frame.minX < sheet.cancelButton.frame.minX,
                "不儲存 left, 取消 then 儲存 right")
    }

    /// M4 fix (D24): quitting with dirty tabs uses the same sheet with its own texts.
    @Test func dirtySheetTakesTheQuitTexts() throws {
        let sheet = DirtyCloseSheetView(title: "3 個檔案有未儲存的變更", hint: "不儲存的話，這些修改會遺失。", saveTitle: "儲存全部")
        let host = Host(sheet, size: NSSize(width: DirtyCloseSheetView.width, height: DirtyCloseSheetView.height))
        defer { host.tearDown() }
        #expect(sheet.title == "3 個檔案有未儲存的變更" && sheet.titleLabel.text == sheet.title)
        #expect(sheet.hintLabel.text == "不儲存的話，這些修改會遺失。")
        #expect(sheet.saveButton.label == "儲存全部")
        let choices = Calls<DirtyCloseChoice>()
        sheet.onChoice = { choices.append($0) }
        sheet.saveButton.performClick(nil)
        #expect(choices.values == [.save])
    }

    // MARK: Composition

    @Test func theArtboardCompositionRendersAt1440x900() throws {
        TestFonts.register()
        let rep = try #require(FileEditorSnapshot.render(FileEditorComposition(), size: NSSize(width: 1440, height: 900), scale: 1))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 900)
        #expect(rep.inkRatio() > 0.05)
        #expect(rep.contains(FileEditorColors.tagPink) && rep.contains(Palette.success) && rep.contains(.black))
    }
}
