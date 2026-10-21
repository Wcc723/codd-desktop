import AppKit
import CoddTerminal
import Foundation
import Testing
@testable import CODD
import CoddUI

/// M2 step I3: the sidebar on the SidebarStates artboard (STATE view heads and line 2, the filter
/// over every section, group hover actions and 清理已停止, the inline new-group editor, the hover
/// card, the countdown toast, the drop line, archive restore, ⌘P / ⌘., the `sidebar` dump). Mock
/// store data (SPEC §5) unless a test says otherwise; nothing touches disk.

@MainActor
private func mock() -> MockSessionStore { MockSessionStore(shiftClock: true) }

/// The mock's canonical "now" (SPEC §5 durations: `3m`, `1m12s`, …).
@MainActor
private var now: Date { MockData.referenceDate }

@MainActor
private func line2(_ store: MockSessionStore, _ id: SessionID, _ context: SessionContext) -> SessionLine2 {
    guard let session = store.session(id) else { return SessionLine2() }
    return SessionLine2Parts(session: session, context: context, store: store).render(now: now)
}

// MARK: - STATE view

@MainActor
@Suite("Sidebar STATE view (SidebarStates E)")
struct SidebarStateViewTests {
    @Test func headsCountTheirSectionAndIdleCountsStale() {
        let store = mock()
        let content = { (section: SidebarSection) in SectionHeaderCellView.content(section, store: store, filter: "") }
        #expect(content(.needsYou).count == 3)
        #expect(content(.working).count == 4)
        #expect(content(.ready).count == 1)
        #expect(content(.idle).count == 4)
        #expect(content(.idle).hint == "1 stale", "s11 keynote is stale")
        #expect(content(.shell).count == 1)
        #expect(content(.stopped).count == 1)
        #expect(content(.working).hint == nil)
        #expect(content(.pinned).count == nil)
        #expect(SidebarSection.working.glyphState == .busy)
        #expect(SidebarSection.stopped.glyphState == .exited)
        #expect(SidebarSection.needsYou.glyphState == nil)
    }

    @Test func sectionsTakeTheStatesThePlanNames() {
        #expect([SessionState.busy, .compacting, .starting, .unknown].allSatisfy(SidebarSection.working.contains))
        #expect(SidebarSection.ready.contains(.done))
        #expect(SidebarSection.stopped.contains(.exited) && SidebarSection.stopped.contains(.stopped))
        #expect(!SidebarSection.working.contains(.idle))
    }

    @Test func stateRowsDrawLeadThenGroupSquareThenProject() {
        let store = mock()
        let busy = line2(store, "s7", .stateList(.working))
        #expect(busy.text == "Bash · 1m12s · ■ MCP 整合範例")
        #expect(busy.square == .orange)
        #expect(line2(store, "s9", .stateList(.working)).text == "Edit · 6m · ■ orb-toolkit-frontend")
        #expect(line2(store, "s10", .stateList(.working)).text == "20s · ■ pixel-town-demo")
        #expect(line2(store, "s4", .stateList(.ready)).text == "4m · ■ 原型試做")
        let shell = line2(store, "s8", .stateList(.shell))
        #expect(shell.text == "zsh · up 42m · ■ orb-toolkit-backend")
        #expect(shell.leadDim)
        #expect(line2(store, "s12", .stateList(.stopped)).text == "code 0 · 3h 前 · ■ UsageBar")
        // NEEDS YOU in the STATE view: the pill says Perm, line 2 is the duration and the project.
        let waiting = line2(store, "s1", .stateList(.needsYou))
        #expect(waiting.text == "3m · ■ orb-toolkit-backend")
        #expect(waiting.square == .blue)
        #expect(line2(store, "s3", .stateList(.needsYou)).text == "overloaded · 1m · ■ Gear3D")
        // 未分類 has no color: no square.
        let ungrouped = line2(store, "s14", .stateList(.idle))
        #expect(ungrouped.square == nil)
        #expect(ungrouped.text == "25m · claude-line-test")
    }

    @Test func treeNeedsYouKeepsGroupSlashProject() {
        let store = mock()
        #expect(line2(store, "s1", .needs).text == "3m · 藍鵲·網站 / orb-toolkit-backend")
        #expect(line2(store, "s3", .needs).text == "1m · overloaded · 個人·Github / Gear3D")
        #expect(line2(store, "s1", .needs).square == nil)
        #expect(line2(store, "s1", .tree).text == "perm · 3m · up 42m · ◉ rc")
        #expect(line2(store, "s11", .tree).text == "1d · stale")
        #expect(line2(store, "s14", .tree).text == "25m · 外部啟動")
    }

    @Test func unreachableRowsSayTheHolderDoesNotAnswer() {
        let store = mock()
        store.session("s9")?.unreachableSince = now.addingTimeInterval(-30)
        #expect(line2(store, "s9", .tree).text == "holder 無回應 · 30s")
        #expect(line2(store, "s9", .stateList(.working)).text == "holder 無回應 · 30s · ■ orb-toolkit-frontend")
    }
}

// MARK: - Filter

@MainActor
@Suite("Sidebar filter")
struct SidebarFilterTests {
    private func sessions(_ snap: SidebarSnapshot, _ parent: NodeKind) -> [SessionID] {
        snap.childrenOf(parent).compactMap(\.sessionID)
    }

    @Test func filterByGroupNameNarrowsNeedsYouAndPinned() {
        let store = mock()
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "網站")
        #expect(sessions(snap, .section(.needsYou)) == ["s1", "s2"], "s3 is in 個人 · Github")
        #expect(!snap.childrenOf(.section(.needsYou)).contains(.doneSummary), "s4 (DONE) is in 藍鵲 · 實驗室")
        #expect(!snap.contains(.section(.pinned)), "s5 is in CODD")
        #expect(snap.childrenOf(nil).contains(.group("northweb")))
        #expect(!snap.childrenOf(nil).contains(.group("northlab")))
    }

    @Test func filterByProjectAndTitleCaseAndWidthInsensitive() {
        let store = mock()
        let byProject = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "gear3d")
        #expect(sessions(byProject, .section(.needsYou)) == ["s3"])
        #expect(byProject.childrenOf(.group("github")) == [.project("gear")])
        let byTitle = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "ＣＯＤＤ Desktop")
        #expect(sessions(byTitle, .section(.pinned)) == ["s5"])
        #expect(!byTitle.contains(.section(.needsYou)))
        let done = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "審查流程")
        #expect(done.childrenOf(.section(.needsYou)) == [.doneSummary])
        #expect(SidebarSnapshotBuilder.unseenDone(store: store, filter: "審查流程").map(\.id) == ["s4"])
    }

    @Test func stateViewFiltersByTitleProjectAndGroup() {
        let store = mock()
        let byGroup = SidebarSnapshotBuilder.build(store: store, mode: .state, filter: "實驗室")
        #expect(sessions(byGroup, .section(.working)) == ["s7"])
        #expect(sessions(byGroup, .section(.ready)) == ["s4"])
        #expect(sessions(byGroup, .section(.idle)) == ["s6"])
        #expect(!byGroup.contains(.section(.needsYou)))
        let byProject = SidebarSnapshotBuilder.build(store: store, mode: .state, filter: "backend")
        #expect(sessions(byProject, .section(.needsYou)) == ["s1"])
        #expect(sessions(byProject, .section(.shell)) == ["s8"])
        #expect(SectionHeaderCellView.content(.working, store: store, filter: "實驗室").count == 1)
        #expect(SectionHeaderCellView.content(.needsYou, store: store, filter: "backend").count == 1)
    }
}

// MARK: - Group header actions

@MainActor
@Suite("Group header actions (SidebarStates C / D)")
struct GroupHeaderActionTests {
    private func groupCell(_ h: SidebarHarness, _ id: GroupID) -> GroupHeaderCellView? {
        let row = h.controller.outline.row(forItem: h.controller.item(for: .group(id)))
        return row >= 0 ? h.controller.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? GroupHeaderCellView : nil
    }

    @Test func hoverShowsCleanupAddAndMore() throws {
        let h = SidebarHarness()
        let cell = try #require(groupCell(h, "github"))
        #expect(cell.stoppedCount == 1, "s12 exited")
        #expect(cell.cleanButton.isHidden && cell.addButton.isHidden && cell.moreButton.isHidden)
        cell.isHovered = true
        #expect(cell.showsActions)
        #expect(!cell.cleanButton.isHidden && cell.cleanButton.label == "清理已停止 (1)")
        #expect(!cell.addButton.isHidden && !cell.moreButton.isHidden)
        #expect(cell.addButton.accessibilityLabel() == "在 個人 · Github 新增 session")
        #expect(cell.moreButton.accessibilityLabel() == "個人 · Github 群組選項")
        cell.isHovered = false
        #expect(cell.moreButton.isHidden)
        let other = try #require(groupCell(h, "northlab"))
        other.isHovered = true
        #expect(other.cleanButton.isHidden, "no stopped session in 藍鵲 · 實驗室")
        #expect(!other.addButton.isHidden)
    }

    @Test func cleanupArchivesStoppedCODDSessionsWithACountdownToast() throws {
        let h = SidebarHarness()
        #expect(h.controller.stoppedSessions(inGroup: "github") == ["s12"])
        #expect(h.controller.stoppedSessions(inGroup: "ungrouped").isEmpty, "s14 is external")
        h.controller.cleanupStopped(inGroup: "github")
        #expect(h.store.session("s12") == nil)
        #expect(h.store.archivedSessions(inProject: "usagebar").map(\.id) == ["s12"])
        let toast = try #require(h.controller.currentToast)
        #expect(toast.remainingSeconds == 5)
        #expect(toast.countdownLabelText == "5s")
        #expect(toast.accessibilityLabel() == "✕ 1 個 session 已封存")
    }

    @Test func groupMenuHasTheArtboardItems() throws {
        let h = SidebarHarness()
        let row = h.controller.outline.row(forItem: h.controller.item(for: .group("github")))
        let menu = try #require(h.controller.groupMenu("github", row: row))
        let titles = menu.items.map(\.title)
        #expect(titles.contains("✎  重新命名"))
        #expect(titles.contains("▾  全部收合"))
        #expect(titles.contains("清理已停止 (1)"))
        #expect(titles.contains("✕  刪除群組（專案移到未分類）"))
        #expect(menu.items.first { $0.title == "清理已停止 (1)" }?.isEnabled == true)
        let northlab = try #require(h.controller.groupMenu("northlab", row: 0))
        #expect(northlab.items.first { $0.title == "清理已停止" }?.isEnabled == false)
    }
}

// MARK: - New group editor

@MainActor
@Suite("Inline new group (SidebarStates D)")
struct NewGroupEditorTests {
    @Test func defaultColorIsTheFirstUnusedOne() {
        let store = mock()
        #expect(NewGroupEditor.defaultColor(in: store) == .red, "orange, blue, green and purple are taken")
        for color in TagColor.allCases { _ = store.addGroup(name: color.rawValue, color: color) }
        #expect(NewGroupEditor.defaultColor(in: store) == .cyan)
    }

    @Test func digitsPickOnlyWhileThePopoverIsOpen() {
        let editor = NewGroupEditor(color: .red)
        #expect(!editor.pickDigit("3"), "closed: the digit is typed")
        editor.isColorPopoverOpen = true
        #expect(!editor.pickDigit("a"))
        #expect(!editor.pickDigit("9"))
        #expect(editor.pickDigit("3"))
        #expect(editor.color == .green)
        #expect(!editor.isColorPopoverOpen, "a pick closes the popover")
        editor.isColorPopoverOpen = true
        #expect(editor.pickDigit("0"))
        #expect(editor.color == nil)
        #expect(editor.colorButtonLabel == "群組顏色：無顏色")
        editor.color = .cyan
        #expect(editor.colorButtonLabel == "群組顏色：cyan")
    }

    @Test func blankNameBecomesTheDefault() {
        let editor = NewGroupEditor(color: nil)
        editor.name = "   "
        #expect(editor.committedName == "新群組")
        editor.name = " 內部工具 "
        #expect(editor.committedName == "內部工具")
    }

    @Test func enterCreatesWithNameAndColor() throws {
        let h = SidebarHarness()
        h.controller.beginNewGroup()
        #expect(h.shell.isAddingGroup)
        #expect(h.controller.snapshot.contains(.newGroup))
        #expect(!h.controller.snapshot.contains(.addGroup))
        let cell = try #require(h.controller.newGroupCell)
        cell.field.stringValue = "內部工具"
        cell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        h.controller.toggleNewGroupColorPopover()
        #expect(h.controller.newGroupEditor?.isColorPopoverOpen == true)
        #expect(h.controller.newGroupDigit("8"))
        let before = h.store.groups.count
        let handled = cell.control(cell.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(handled)
        #expect(h.store.groups.count == before + 1)
        let made = try #require(h.store.groups.first { $0.name == "內部工具" })
        #expect(made.color == .cyan)
        #expect(!h.shell.isAddingGroup)
        #expect(h.controller.snapshot.contains(.addGroup))
        #expect(OutlineSelfTest.mismatch(h.controller) == nil)
    }

    @Test func escCancelsAndBlankEnterMakesNewGroup() throws {
        let h = SidebarHarness()
        let before = h.store.groups.count
        h.controller.beginNewGroup()
        let cell = try #require(h.controller.newGroupCell)
        cell.field.stringValue = "不要了"
        cell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(cell.control(cell.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(h.store.groups.count == before)
        #expect(h.controller.newGroupEditor == nil)
        h.controller.beginNewGroup()
        let id = try #require(h.controller.commitNewGroup())
        #expect(h.store.group(id)?.name == "新群組")
        #expect(h.store.group(id)?.color == .red)
    }

    @Test func focusLossKeepsATypedNameAndDropsABlankOne() {
        let h = SidebarHarness()
        let before = h.store.groups.count
        h.controller.beginNewGroup()
        h.controller.newGroupFocusLost()
        #expect(h.store.groups.count == before)
        h.controller.beginNewGroup()
        h.controller.newGroupEditor?.name = "保留"
        h.controller.newGroupFocusLost()
        #expect(h.store.groups.contains { $0.name == "保留" })
    }

    @Test func openingClearsTheFilterAndLeavesTheStateView() {
        let h = SidebarHarness()
        h.controller.setFilter("網站")
        h.controller.setMode(.state)
        h.controller.beginNewGroup()
        #expect(h.shell.filterText.isEmpty)
        #expect(h.shell.sidebarMode == .tree)
        #expect(h.controller.snapshot.contains(.newGroup))
        h.controller.setMode(.state)
        #expect(h.controller.newGroupEditor == nil, "the STATE view closes the editor")
        #expect(!h.shell.isAddingGroup)
    }

    @Test func theRealFieldEditorRoutesDigitsAndEnter() throws {
        let h = SidebarHarness()
        h.controller.beginNewGroup()
        let cell = try #require(h.controller.newGroupCell)
        cell.focus()
        let editor = try #require(cell.field.currentEditor() as? NSTextView, "the window's field editor edits the name")
        editor.insertText("組", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("2", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(cell.field.stringValue == "組2", "popover closed: digits are typed")
        h.controller.toggleNewGroupColorPopover()
        editor.insertText("6", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(cell.field.stringValue == "組2")
        #expect(h.controller.newGroupEditor?.color == .orange)
        #expect(h.controller.newGroupEditor?.isColorPopoverOpen == false)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(h.store.groups.contains { $0.name == "組2" && $0.color == .orange })
        #expect(h.controller.newGroupEditor == nil)
    }

    @Test func digitsWhileAnInputMethodComposesAreTyped() {
        let field = NewGroupNameField()
        var asked = 0
        field.onDigit = { _ in asked += 1; return true }
        let composing = NSTextView()
        composing.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(composing.hasMarkedText())
        #expect(field.textView(composing, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "1"))
        #expect(asked == 0, "注音 owns the number keys while it composes")
        #expect(!field.textView(NSTextView(), shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "1"))
        #expect(asked == 1)
    }
}

// MARK: - Hover card

@MainActor
@Suite("Hover card (SidebarStates F, D20)")
struct HoverCardTests {
    private func card(_ store: MockSessionStore, _ id: SessionID, number: Int? = 1, prompt: String? = nil,
                      reorderable: Bool = true) -> HoverCardModel? {
        store.session(id).map { HoverCardModel.make(session: $0, store: store, now: now, number: number, prompt: prompt,
                                                    reorderable: reorderable) }
    }

    @Test func waitingCardHasEveryPart() throws {
        let store = mock()
        let m = try #require(card(store, "s1", prompt: store.session("s1")?.lastPrompt))
        #expect(m.stateLine == "◆ 權限確認 · 3m")
        #expect(m.title == "修正登入 API 401")
        #expect(m.prompt == "登入 API 在 token 過期後會回 401，幫我修好並補測試")
        #expect(m.path == "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend")
        #expect(m.meta == ["opus-5.5", "tool Bash", "ctx 58%", "up 42m"])
        #expect(m.shortcut == "⌘1")
        #expect(m.hint == "拖曳或 ⌥⇧↑↓ 調整順序")
    }

    @Test func stateLinesFollowThePlanCopy() {
        let store = mock()
        func line(_ id: SessionID, _ configure: (SessionVM) -> Void = { _ in }) -> String? {
            if let session = store.session(id) { configure(session) }
            return card(store, id)?.stateLine
        }
        #expect(line("s2") == "◆ 等你回答 · 12m")
        #expect(line("s6") { $0.state = .waiting; $0.waitingReason = .plan; $0.stateSince = now.addingTimeInterval(-120) } == "◆ 計畫待核准 · 2m")
        #expect(line("s3") == "▲ 失敗 · OVERLOADED · 1m")
        #expect(line("s4") == "◇ 完成待看 · 4m")
        #expect(line("s9") == "● 工作中 · Edit · 6m")
        #expect(line("s10") == "◌ 壓縮中 · 20s")
        #expect(line("s13") { $0.stateSince = now.addingTimeInterval(-7200) } == "○ 閒置 · 2h")
        #expect(line("s7") { $0.state = .starting; $0.stateSince = now.addingTimeInterval(-4) } == "◌ 啟動中 · 4s")
        #expect(line("s5") { $0.state = .unknown } == "● 執行中 · 沒有 hook")
        #expect(line("s8") == "$ shell · zsh")
        #expect(line("s12") == "✕ 已結束 · code 0")
        #expect(line("s6") { $0.state = .stopped } == "⟲ 已停止 · 可接續")
        #expect(line("s9") { $0.unreachableSince = now.addingTimeInterval(-30) } == "◌ holder 無回應 · 30s")
    }

    @Test func externalCardSaysWhereItRunsAndHasNoDragHint() throws {
        let store = mock()
        let m = try #require(card(store, "s14", number: 9))
        #expect(m.meta == ["外部啟動 · pid 48211"])
        #expect(m.hint == nil)
        #expect(m.shortcut == "⌘9")
        #expect(m.stateLine == "○ 閒置 · 25m")
        store.session("s14")?.externalInfo?.hostSessionID = "s8"
        #expect(card(store, "s14")?.meta == ["在 CODD shell 中 · pid 48211"])
    }

    @Test func unknownPartsAreLeftOut() throws {
        let store = mock()
        let m = try #require(card(store, "s12", number: 10, reorderable: false))
        #expect(m.meta.isEmpty, "exited: no model, no tool, no ctx, no uptime")
        #expect(m.shortcut == nil, "only ⌘1–⌘9")
        #expect(m.hint == nil)
        #expect(m.prompt == nil)
        #expect(card(store, "s8", prompt: "ls")?.prompt == nil, "a shell has no prompt box")
        #expect(card(store, "s9", prompt: "  ")?.prompt == nil)
    }

    @Test func cardSitsRightOfTheRowAndStaysInsideTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let row = CGRect(x: 72, y: 600, width: 280, height: 38)
        let placed = HoverCardController.place(size: CGSize(width: 340, height: 200), rowOnScreen: row, windowFrame: window)
        #expect(placed.minX == 362)
        #expect(placed.maxY == row.maxY, "top aligned with the row")
        let low = HoverCardController.place(size: CGSize(width: 340, height: 200), rowOnScreen: CGRect(x: 72, y: 20, width: 280, height: 38),
                                            windowFrame: window)
        #expect(low.minY == 8, "moved up to the window's bottom edge")
    }

    @Test func showsHidesAndMeasuresTheShow() throws {
        let h = SidebarHarness()
        h.window.orderFront(nil)
        defer { h.window.orderOut(nil) }
        let row = h.controller.outline.row(forItem: h.controller.item(for: .session("s1", .tree)))
        #expect(row >= 0)
        h.controller.hoverCard.show(.session("s1", .tree), row: row, force: true)
        #expect(h.controller.hoverCard.isShown)
        #expect(h.controller.hoverCard.shownSessionID == "s1")
        let latency = try #require(h.controller.hoverCard.lastShowDuration)
        print(String(format: "MEASURE hover card show %.2f ms", TerminalHub.milliseconds(latency)))
        #expect(latency < .milliseconds(100))
        // A click on the list puts it away.
        h.controller.outlineInteracted(scroll: false)
        #expect(!h.controller.hoverCard.isShown)
        // A non-session row hides it.
        h.controller.hoverCard.show(.session("s1", .tree), row: row, force: true)
        h.controller.hoverDidChange(row: 0)
        #expect(!h.controller.hoverCard.isShown, "row 0 is the NEEDS YOU head")
        // A drag never shows one.
        h.controller.draggedNodes = [.session("s8", .tree)]
        #expect(!h.controller.hoverCard.canShow)
        h.controller.draggedNodes = []
    }

    @Test func cardFollowsItsSessionWhileShown() async throws {
        let h = SidebarHarness()
        h.window.orderFront(nil)
        defer { h.window.orderOut(nil) }
        let row = h.controller.outline.row(forItem: h.controller.item(for: .session("s9", .tree)))
        h.controller.hoverCard.show(.session("s9", .tree), row: row, force: true)
        h.store.session("s9")?.lastPrompt = "RWD 斷點改成 768"
        try await Task.sleep(for: .milliseconds(50))
        let model = try #require(h.controller.hoverCard.panel?.card.model)
        #expect(model.prompt == "RWD 斷點改成 768")
        h.controller.hoverCard.hide()
    }

    /// Review concurrency-perf-2: a transcript prompt is read again after the session's state
    /// changed (an external's next turn), not once per run; an unchanged state reads nothing.
    @Test func transcriptPromptIsReadAgainAfterAStateChange() async throws {
        final class Source {
            var prompt = "舊的 prompt"
            var reads = 0
        }
        let h = SidebarHarness()
        h.window.orderFront(nil)
        defer { h.window.orderOut(nil) }
        let source = Source()
        h.controller.hoverCard.promptProvider = { _ in
            source.reads += 1
            return source.prompt
        }
        let session = try #require(h.store.session("s6"))
        #expect(session.lastPrompt == nil)
        let row = h.controller.outline.row(forItem: h.controller.item(for: .session("s6", .tree)))
        h.controller.hoverCard.show(.session("s6", .tree), row: row, force: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.controller.hoverCard.cachedTranscriptPrompt("s6") == "舊的 prompt")
        h.controller.hoverCard.hide()
        h.controller.hoverCard.show(.session("s6", .tree), row: row, force: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.reads == 1, "same state: not read again")
        h.controller.hoverCard.hide()
        source.prompt = "新的 prompt"
        session.stateSince = Date()
        h.controller.hoverCard.show(.session("s6", .tree), row: row, force: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.reads == 2)
        #expect(h.controller.hoverCard.panel?.card.model?.prompt == "新的 prompt")
        h.controller.hoverCard.hide()
    }
}

// MARK: - Toast, restore, drop line

@MainActor
@Suite("Sidebar toasts, archive restore and drop line")
struct SidebarToastRestoreDropTests {
    @Test func countdownToastCountsDownAndLeavesAtZero() async {
        let toast = ToastView(text: "✕ 3 個 session 已封存", undo: {}, countdown: 5)
        #expect(toast.countdownLabelText == "5s")
        toast.advanceCountdown()
        toast.advanceCountdown()
        #expect(toast.countdownLabelText == "3s")
        #expect(toast.remainingSeconds == 3)
        for _ in 0..<5 { toast.advanceCountdown() }
        #expect(toast.remainingSeconds == 0)
        #expect(ToastView.countdownText(0) == "0s")
        #expect(ToastView.countdownText(-1) == "0s")
        let message = ToastView.countdownMessage("✕ 3 個 session 已封存")
        #expect(message.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.amber)
        #expect(message.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == Palette.bone)
        // The default look keeps no countdown.
        #expect(ToastView(text: "x", undo: nil).countdownLabelText == nil)
    }

    @Test func liveCountdownRemovesTheToast() async {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let toast = ToastView(text: "✕ 1 個 session 已封存", undo: nil, countdown: 2)
        host.addSubview(toast)
        toast.startCountdown(tick: .milliseconds(20))
        let deadline = ContinuousClock.now + .seconds(2)
        while toast.superview != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(toast.remainingSeconds == 0)
        #expect(toast.superview == nil)
    }

    @Test func archiveRestoreMenuListsArchivedSessions() throws {
        let h = SidebarHarness()
        #expect(ArchiveRestoreMenuModel.make(project: "proto", store: h.store) == nil)
        _ = h.store.archive(["s4", "s6"])
        let model = try #require(ArchiveRestoreMenuModel.make(project: "proto", store: h.store))
        #expect(model.title == "封存 2")
        #expect(Set(model.entries.map(\.title)) == ["還原「第二版原型 · 審查流程」", "還原「產生程式碼審查清單」"])
        #expect(ArchiveRestoreMenuModel.restoreAllTitle == "全部還原")
        let row = h.controller.outline.row(forItem: h.controller.item(for: .project("proto")))
        let menu = try #require(h.controller.contextMenu(forRow: row))
        let parent = try #require(menu.items.first { $0.title == "封存 2" })
        #expect(parent.submenu?.items.map(\.title).last == "全部還原")
        h.controller.restore([model.entries[0].id])
        #expect(h.store.archivedSessions(inProject: "proto").count == 1)
        h.controller.restore(h.store.archivedSessions(inProject: "proto").map(\.id))
        #expect(h.store.project("proto")?.sessionIDs.count == 2)
        #expect(OutlineSelfTest.mismatch(h.controller) == nil)
    }

    @Test func dropLineGoesAboveTheChildOrBelowTheSubtree() {
        let store = mock()
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let rows = snap.visibleRows { node in
            switch node {
            case .group(let id): !(store.group(id)?.isCollapsed ?? false)
            case .project(let id): !(store.project(id)?.isCollapsed ?? false)
            default: true
            }
        }
        let above = DropIndicator.position(parent: .group("northweb"), childIndex: 1, snapshot: snap, rows: rows)
        #expect(above?.anchor == .project("frontend") && above?.below == false)
        let end = DropIndicator.position(parent: .group("northweb"), childIndex: 3, snapshot: snap, rows: rows)
        #expect(end?.anchor == .session("s2", .tree) && end?.below == true, "below the last project's last session")
        let collapsedEnd = DropIndicator.position(parent: .group("northlab"), childIndex: 3, snapshot: snap, rows: rows)
        #expect(collapsedEnd?.anchor == .project("skills") && collapsedEnd?.below == true, "a collapsed project is one row")
        let sessionEnd = DropIndicator.position(parent: .project("backend"), childIndex: 2, snapshot: snap, rows: rows)
        #expect(sessionEnd?.anchor == .session("s8", .tree) && sessionEnd?.below == true)
    }

    @Test func dragDecorationsComeAndGo() {
        let h = SidebarHarness()
        let edges = h.controller.ghostEdges(for: [.project("backend")])
        #expect(edges[.project("backend")] == .top)
        #expect(edges[.session("s1", .tree)] == .middle)
        #expect(edges[.session("s8", .tree)] == .bottom)
        #expect(h.controller.ghostEdges(for: [.session("s9", .tree)]) == [.session("s9", .tree): .single])
        let plan = DropPlan(target: .projects(group: "northlab", index: 1), parent: .group("northlab"), childIndex: 1)
        h.controller.showDropLine(for: plan)
        #expect(!h.controller.dropLine.isHidden)
        let row = h.controller.outline.row(forItem: h.controller.item(for: .project("mcp")))
        #expect(abs(h.controller.dropLine.frame.midY - h.controller.outline.rect(ofRow: row).minY) <= 1)
        h.controller.endDrag()
        #expect(h.controller.dropLine.isHidden)
        #expect(h.controller.dragGhostEdges.isEmpty)
        #expect(h.controller.liftedImage(for: .project("backend")) != nil)
    }
}

// MARK: - Menus and shortcuts (D21)

@MainActor
@Suite("Session menu and ⌘P / ⌘. (D21)")
struct SidebarShortcutTests {
    @Test func terminalsDeclinePinAndStopAlsoUnder注音() {
        let policy = CoddTerminalSetup.keyEquivalents
        #expect(policy.isReserved(characters: "p", keyCode: 0x23, modifiers: .command))
        #expect(policy.isReserved(characters: ".", keyCode: 0x2F, modifiers: .command))
        #expect(policy.isReserved(characters: "ㄣ", keyCode: 0x23, modifiers: .command), "注音 reports ⌘P as ㄣ")
        #expect(policy.isReserved(characters: "ㄡ", keyCode: 0x2F, modifiers: .command), "注音 reports ⌘. as ㄡ")
        #expect(policy.isReserved(characters: "l", keyCode: 0x25, modifiers: .command), "⌘L stays reserved")
        #expect(!policy.isReserved(characters: "p", keyCode: 0x23, modifiers: []))
        let rendered = CoddTerminalSetup.configuration.renderedGhosttyConfig
        #expect(rendered.contains("keybind = super+p=unbind"))
        #expect(rendered.contains("keybind = super+period=unbind"))
    }

    @Test func mainMenuHasPinAndStop() throws {
        final class Commands: NSObject, CoddCommands {
            func showSettings(_ sender: Any?) {}
            func showQuickSwitch(_ sender: Any?) {}
            func toggleSessionSidebar(_ sender: Any?) {}
            func selectSessionByNumber(_ sender: NSMenuItem) {}
            func selectNextSession(_ sender: Any?) {}
            func selectPreviousSession(_ sender: Any?) {}
            func allowCurrentSession(_ sender: Any?) {}
            func newShellTab(_ sender: Any?) {}
            func toggleBottomTerminal(_ sender: Any?) {}
            func showMainWindow(_ sender: Any?) {}
            func focusSidebarFilter(_ sender: Any?) {}
            func newSession(_ sender: Any?) {}
            func quitApp(_ sender: Any?) {}
            func togglePinCurrentSession(_ sender: Any?) {}
            func stopCurrentSession(_ sender: Any?) {}
            func toggleComposer(_ sender: Any?) {}
        }
        let commands = Commands()
        let menu = MainMenuBuilder.build(commands: commands)
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let pin = try #require(items.first { $0.action == #selector(CoddCommands.togglePinCurrentSession(_:)) })
        #expect(pin.keyEquivalent == "p" && pin.keyEquivalentModifierMask == [.command])
        let stop = try #require(items.first { $0.action == #selector(CoddCommands.stopCurrentSession(_:)) })
        #expect(stop.keyEquivalent == "." && stop.keyEquivalentModifierMask == [.command])
        #expect(stop.title == "停止 session")
    }

    @Test func stopAsksWithTheSessionTitle() throws {
        let store = mock()
        let s9 = try #require(store.session("s9"))
        let s8 = try #require(store.session("s8"))
        #expect(SidebarViewController.stopConfirmation([s9]).message == "要停止「打卡頁 RWD 調整」嗎？")
        #expect(SidebarViewController.stopConfirmation([s9]).info.contains("RESUME"))
        #expect(SidebarViewController.stopConfirmation([s8]).info.contains("RESTART"))
        #expect(SidebarViewController.stopConfirmation([s9, s8]).message == "要停止 2 個 session 嗎？")
    }

    @Test func sessionMenuFollowsArtboardB() throws {
        let h = SidebarHarness()
        let row = h.controller.outline.row(forItem: h.controller.item(for: .session("s9", .tree)))
        let menu = try #require(h.controller.contextMenu(forRow: row))
        let resume = try #require(menu.items.first { $0.title == "⟲  接續對話 resume" })
        #expect(!resume.isEnabled)
        #expect(resume.badge?.stringValue == "執行中", "a running session cannot be resumed")
        let delete = try #require(menu.items.first { $0.title == "✕  刪除對話紀錄…" })
        #expect(delete.badge?.stringValue == "需輸入名稱確認")
        let pin = try #require(menu.items.first { $0.title == "釘選到 PINNED" })
        #expect(pin.keyEquivalent == "p")
        let stop = try #require(menu.items.first { $0.title == "■  停止" })
        #expect(stop.keyEquivalent == "." && stop.isEnabled)
        let stoppedRow = h.controller.outline.row(forItem: h.controller.item(for: .session("s12", .tree)))
        if stoppedRow >= 0, let exited = h.controller.contextMenu(forRow: stoppedRow) {
            #expect(exited.items.first { $0.title == "⟲  接續對話 resume" }?.badge == nil)
        }
        // Review spec-fidelity-3: a shell has no conversation to delete (`✕ 移除 session…` instead).
        h.store.session("s8")?.state = .exited
        let shellRow = h.controller.outline.row(forItem: h.controller.item(for: .session("s8", .tree)))
        let shellMenu = try #require(h.controller.contextMenu(forRow: shellRow))
        #expect(shellMenu.items.first { $0.title == "✕  刪除對話紀錄…" }?.isEnabled == false)
        #expect(shellMenu.items.first { $0.title == "✕  移除 session…" } != nil)
        // Externals keep their own small menu.
        let ext = h.controller.outline.row(forItem: h.controller.item(for: .session("s14", .tree)))
        let extMenu = try #require(h.controller.contextMenu(forRow: ext))
        #expect(extMenu.items.map(\.title) == ["Session · LINE bot 測試", "複製 session ID", "$  複製 resume 指令", "↗  在 Terminal.app 開啟"])
    }

    @Test func stopOfNothingRunningBeepsInsteadOfAsking() {
        let h = SidebarHarness()
        h.controller.confirmStop(["s12", "s14"])
        #expect(h.window.attachedSheet == nil, "exited and external: nothing to stop")
    }
}

// MARK: - Sidebar dump

@MainActor
@Suite("Sidebar state dump")
struct SidebarDumpTests {
    private func rows(_ h: SidebarHarness) -> [SidebarDumpRow] {
        SidebarDump.rows(snapshot: h.controller.snapshot, store: h.store, shell: h.shell, expanded: h.controller.wantsExpanded, now: now)
    }

    @Test func treeRowsInDisplayOrderWithCollapseRespected() throws {
        let h = SidebarHarness()
        let dump = rows(h)
        #expect(dump.first == SidebarDumpRow(kind: "section", id: "needsYou", section: "needsYou", title: "◆ Needs you", line2: nil,
                                             stale: false, depth: 0, count: 3, hint: nil, state: nil))
        #expect(dump[1].kind == "session" && dump[1].id == "s1" && dump[1].section == "needsYou" && dump[1].depth == 1)
        #expect(dump[1].line2 == "3m · 藍鵲·網站 / orb-toolkit-backend")
        #expect(dump.contains { $0.kind == "doneSummary" && $0.title == "1 個待看 · 第二版原型 · 審查流程" })
        // CODD is collapsed: its projects are not rows; Skills 整合範例 is collapsed too.
        let codd = try #require(dump.firstIndex { $0.kind == "group" && $0.id == "codd" })
        #expect(dump[codd + 1].kind == "group" && dump[codd + 1].id == "ungrouped")
        #expect(!dump.contains { $0.kind == "emptyProject" && $0.id == "skills" })
        #expect(dump.contains { $0.kind == "project" && $0.id == "skills" && $0.line2 == "封存 3" })
        let stale = try #require(dump.first { $0.id == "s11" && $0.section == "tree" })
        #expect(stale.stale && stale.depth == 2 && stale.line2 == "1d · stale")
        #expect(dump.last?.kind == "addGroup")
        #expect(dump.count == h.controller.outline.numberOfRows, "the same rows the outline shows")
    }

    @Test func stateRowsCarryHeadsCountsAndTheStaleHint() throws {
        let h = SidebarHarness()
        h.controller.setMode(.state)
        h.controller.applyNow()
        let dump = rows(h)
        let idle = try #require(dump.first { $0.kind == "section" && $0.id == "idle" })
        #expect(idle.count == 4 && idle.hint == "1 stale")
        let busy = try #require(dump.first { $0.id == "s7" })
        #expect(busy.section == "working" && busy.line2 == "Bash · 1m12s · ■ MCP 整合範例" && busy.state == "busy")
        let object = h.controller.dumpObject()
        #expect(object["mode"] as? String == "state")
        #expect((object["rows"] as? [[String: Any]])?.count == dump.count)
    }
}

@Suite("I3 options")
struct SidebarOptionsTests {
    @Test func sidebarFlagsParse() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-sidebar-mode", "STATE", "-codd-sidebar-filter", "藍鵲 網站",
                                                        "-codd-hover-card", "Current", "-codd-new-group", "內部工具",
                                                        "-codd-group-hover", "northlab", "-codd-drag-preview", "invoice,northlab",
                                                        "-codd-shortcut-matrix"],
                                            environment: [:], home: "/Users/x")
        #expect(options.sidebarMode == .state)
        #expect(options.sidebarFilter == "藍鵲 網站")
        #expect(options.hoverCard == "current")
        #expect(options.newGroupName == "內部工具")
        #expect(options.groupHover == "northlab")
        #expect(options.dragPreview == "invoice,northlab")
        #expect(options.shortcutMatrix)
        #expect(RealModeOptions.parse(arguments: ["CODD", "-codd-sidebar-mode", "list"], environment: [:], home: "/").sidebarMode == nil)
        // A Release build keeps none of them.
        #expect(options.releaseSubset.sidebarMode == nil && options.releaseSubset.sidebarFilter == nil && !options.releaseSubset.shortcutMatrix)
    }
}
