import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

@Suite("D · quit", .serialized)
@MainActor
struct QuitDialogTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func make(_ model: QuitModel, choices: Recorder<(QuitChoice, Bool)> = Recorder()) -> DialogHarness<QuitDialogView> {
        let view = QuitDialogView(model: model) { choices.append(($0, $1)) }
        let harness = DialogHarness(view)
        view.secondTick(now: now)
        return harness
    }

    @Test func copyIsTheArtboardPlusD18() {
        let harness = make(DialogSamples.quit(now: now))
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.dialogWidth == 560)
        #expect(view.title == "Quit · 結束")
        #expect(view.allLabelTexts().contains("結束 CODD？"))
        #expect(view.summaryString == "13 個 session 執行中 · ◆ 3 需要你")
        #expect(view.needsPanelShown)
        #expect(view.rowViews.map(\.row.title) == ["修正登入 API 401", "發票匯出 CSV", "場景載入優化"])
        #expect(view.rowViews.map(\.row.pill) == ["Perm", "Ask", "Error"])
        #expect(view.rowViews.map(\.line2Text) == ["3m · 藍鵲·網站 / orb-toolkit-backend", "12m · 藍鵲·網站 / Northstar invoice system",
                                                   "1m · overloaded · 個人·Github / Gear3D"])
        // Four stacked choices: danger, D18's normal one, primary, cancel.
        #expect(view.allButtonLabels() == ["✕", "全部停止並結束", "結束 · session 繼續執行", "保留在選單列（關閉視窗）", "取消"])
        let order = [view.stopAllButton, view.keepSessionsButton, view.menuBarButton, view.cancelButton].map {
            $0.convert($0.bounds, to: view).minY
        }
        #expect(order == order.sorted(), "stacked top to bottom")
        guard case .bracket(.danger, small: false) = view.stopAllButton.style,
              case .bracket(.normal, small: false) = view.keepSessionsButton.style,
              case .bracket(.primary, small: false) = view.menuBarButton.style,
              case .bracket(.normal, small: false) = view.cancelButton.style
        else { Issue.record("button variants"); return }
        #expect(view.stopAllButton.frame.height == 34 && view.stopAllButton.frame.width == view.cancelButton.frame.width)
        #expect(view.stopHintText == "停止 CODD 啟動的 12 個 session（外部 session 不受影響），下次開啟可 ⟲ 接續")
        let texts = view.allLabelTexts()
        #expect(texts.contains("holder 會繼續執行；CODD 關閉期間不更新狀態、不通知，下次開啟自動接回"))
        #expect(texts.contains("session 繼續在背景執行，選單列圖示亮琥珀色提醒你"))
        #expect(view.keepCheckbox.title == "下次直接保留在選單列" && !view.keepCheckbox.isOn)
        #expect(view.footerNote == "設定 › 一般 › 結束時")
    }

    @Test func zeroNeedsHidesThePanelAndTheNeedsPart() {
        let harness = make(DialogSamples.quitNoNeeds())
        defer { harness.tearDown() }
        #expect(harness.view.summaryString == "13 個 session 執行中")
        #expect(!harness.view.needsPanelShown)
        #expect(harness.view.rowViews.isEmpty)
    }

    @Test func eachChoiceCarriesTheKeepNextTimeFlag() {
        let choices = Recorder<(QuitChoice, Bool)>()
        let harness = make(DialogSamples.quit(now: now), choices: choices)
        defer { harness.tearDown() }
        let view = harness.view
        view.stopAllButton.performClick(nil)
        view.keepCheckbox.toggle()
        view.keepSessionsButton.performClick(nil)
        view.menuBarButton.performClick(nil)
        view.keepCheckbox.toggle()
        view.cancelButton.performClick(nil)
        view.frameCloseButton.performClick(nil)
        #expect(choices.values.map(\.0) == [.stopAllAndQuit, .quitKeepingSessions, .keepInMenuBar, .cancel, .cancel])
        #expect(choices.values.map(\.1) == [false, true, true, false, false])
    }

    @Test func returnKeepsInTheMenuBarAndEscapeCancels() {
        let choices = Recorder<(QuitChoice, Bool)>()
        let harness = make(DialogSamples.quit(now: now), choices: choices)
        defer { harness.tearDown() }
        harness.view.keepCheckbox.toggle()
        #expect(harness.pressReturn())
        #expect(harness.pressEscape())
        #expect(choices.values.map(\.0) == [.keepInMenuBar, .cancel])
        #expect(choices.values.map(\.1) == [true, true])
    }

    @Test func rowsTickAndUpdateInPlace() {
        let harness = make(DialogSamples.quit(now: now))
        defer { harness.tearDown() }
        let view = harness.view
        let before = view.rowViews.map(ObjectIdentifier.init)
        view.secondTick(now: now.addingTimeInterval(60))
        #expect(view.rowViews.first?.line2Text == "4m · 藍鵲·網站 / orb-toolkit-backend")
        var model = DialogSamples.quit(now: now)
        model.running = 12
        model.rows[0].title = "修正登入 API 401（重跑）"
        view.update(model)
        #expect(view.rowViews.map(ObjectIdentifier.init) == before, "same sessions: the row views are reused")
        #expect(view.rowViews.first?.row.title == "修正登入 API 401（重跑）")
        #expect(view.summaryString == "12 個 session 執行中 · ◆ 3 需要你")
        model.rows.removeLast()
        model.needs = 2
        view.update(model)
        #expect(view.rowViews.count == 2)
    }

    @Test func manyRowsScrollInsideThePanel() {
        var model = DialogSamples.quit(now: now)
        model.rows = (0 ..< 9).map { index in
            DialogSessionRow(id: "s\(index)", glyph: "◆", color: Palette.amber, title: "session \(index)", pill: "Ask", pillFilled: true,
                             since: now, location: "group / project")
        }
        model.needs = 9
        let harness = make(model)
        defer { harness.tearDown() }
        #expect(harness.view.rowViews.count == 9)
        let panel = harness.view.rowViews[0].enclosingScrollView?.superview
        #expect(panel?.frame.height == CGFloat(QuitDialogView.maxVisibleRows) * DialogSessionRowView.height + 8)
    }

    @Test func anUpdateKeepsTheTickedCheckbox() {
        let choices = Recorder<(QuitChoice, Bool)>()
        let harness = make(DialogSamples.quit(now: now), choices: choices)
        defer { harness.tearDown() }
        harness.view.keepCheckbox.toggle()
        harness.view.update(DialogSamples.quitNoNeeds())
        #expect(harness.view.keepCheckbox.isOn)
        harness.view.menuBarButton.performClick(nil)
        #expect(choices.values.first?.1 == true)
    }
}
