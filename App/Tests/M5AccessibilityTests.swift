import AppKit
import CoddUI
import Foundation
import Testing
@testable import CODD

// M5 I3 (D21): VoiceOver labels and roles of the App's own views, the menu items for actions that
// were only a click, and the `-codd-a11y-audit` screen list. Every window here is built offscreen
// and never ordered in.

@MainActor
@Suite("M5 spoken state (D21)")
struct M5SpokenStateTests {
    private func session(_ state: SessionState, since seconds: TimeInterval, now: Date) -> SessionVM {
        SessionVM(id: "a11y", projectID: "p", title: "修正登入 API 401", state: state, stateSince: now.addingTimeInterval(-seconds))
    }

    @Test func everyStateIsSpokenAsTextNotColor() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let expected: [SessionState: String] = [
            .waiting: "等待中 · 權限 · 3 分鐘", .error: "錯誤 · OVERLOADED · 3 分鐘", .done: "完成 · 3 分鐘",
            .busy: "工作中 · Edit · 3 分鐘", .compacting: "壓縮中 · 3 分鐘", .idle: "閒置 · 3 分鐘", .starting: "啟動中 · 3 分鐘",
            .unknown: "執行中 · 沒有 hook 資料 · 3 分鐘", .shell: "Shell · zsh", .exited: "已結束 · 結束碼 0 · 3 分鐘前",
            .stopped: "已停止 · 可接續",
        ]
        for state in SessionState.allCases {
            let s = session(state, since: 180, now: now)
            s.waitingReason = .permission
            s.errorReason = "OVERLOADED"
            s.tool = "Edit"
            s.exitCode = 0
            #expect(SessionSpeech.state(s, now: now) == expected[state], "\(state)")
            #expect(!StateStyle.spokenName(state).isEmpty)
        }
        let unreachable = session(.busy, since: 600, now: now)
        unreachable.unreachableSince = now.addingTimeInterval(-30)
        #expect(SessionSpeech.state(unreachable, now: now) == "無法連線 · holder 無回應 · 30 秒")
    }

    @Test func durationsAreWords() {
        #expect(SpokenDuration.text(12) == "12 秒")
        #expect(SpokenDuration.text(3 * 60 + 59) == "3 分鐘")
        #expect(SpokenDuration.text(65 * 60) == "1 小時 5 分鐘")
        #expect(SpokenDuration.text(2 * 3600) == "2 小時")
        #expect(SpokenDuration.text(27 * 3600) == "1 天 3 小時")
        #expect(SpokenDuration.text(.nan) == "0 秒")
    }

    @Test func aLampIsAnImageWithItsStateWhenItHasADescription() {
        let lamp = LampView()
        lamp.configure(StateStyle.of(.waiting))
        #expect(!lamp.isAccessibilityElement(), "inside a row the lamp is decoration")
        lamp.spokenDescription = { "等待中 · 權限 · 3 分鐘" }
        #expect(lamp.isAccessibilityElement())
        #expect(lamp.accessibilityRole() == .image)
        #expect(lamp.accessibilityLabel() == "等待中 · 權限 · 3 分鐘")
    }

    @Test func tallyAndBadgesAreWords() {
        #expect(SessionSpeech.tally([(.waiting, 2), (.busy, 1), (.shell, 1)]) == "等待中 2、工作中 1、Shell 1")
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let s = session(.idle, since: 7200, now: now)
        s.tag = .red
        s.isStale = true
        s.externalInfo = ExternalInfo(pid: 1, kind: "interactive", entrypoint: "cli", claudeSessionID: nil, version: nil)
        let row = SessionSpeech.row(s, accountChip: "#2", now: now)
        #expect(row == "修正登入 API 401，閒置 · 2 小時，標籤：紅，EXT 外部 session，帳號 #2，stale，閒置超過 1 小時")
    }
}

@MainActor
@Suite("M5 sidebar and rail accessibility (D21)", .serialized)
struct M5SidebarAccessibilityTests {
    private func rowView(_ h: SidebarHarness, _ kind: NodeKind) throws -> SidebarRowView {
        h.controller.applyNow()
        let row = h.controller.outline.row(forItem: h.controller.item(for: kind))
        #expect(row >= 0, "\(kind) has a row")
        return try #require(h.controller.outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarRowView)
    }

    @Test func aWaitingSessionRowIsOneElementThatSaysItsState() throws {
        let h = SidebarHarness()
        defer { h.window.close() }
        let row = try rowView(h, .session("s1", .tree))
        let label = try #require(row.accessibilityLabel())
        #expect(label.hasPrefix("修正登入 API 401，等待中 · 權限 · "), "\(label)")
        // The harness runs on the wall clock against the mock's 2026-10-15 dates, so the duration
        // depends on the day the test runs: check its shape, not its value.
        let badges = "，標籤：紅，Remote Control 已連線"
        #expect(label.hasSuffix(badges), "\(label)")
        let duration = label.dropFirst("修正登入 API 401，等待中 · 權限 · ".count).dropLast(badges.count)
        #expect(["秒", "分鐘", "小時", "天"].contains { duration.hasSuffix($0) } && duration.first?.isNumber == true, "\(label)")
        #expect(row.subviews.allSatisfy { !$0.isAccessibilityElement() || $0 is NSControl },
                "the cell, its lamp and line 2 are not elements of their own")
    }

    @Test func headersSayTheirCounts() throws {
        let h = SidebarHarness()
        defer { h.window.close() }
        let group = try #require(h.store.groups.first { !$0.isUngrouped })
        let label = try #require(try rowView(h, .group(group.id)).accessibilityLabel())
        #expect(label.hasPrefix("\(group.name) 群組，展開，"), "\(label)")
        #expect(label.contains("個 session"))
        let needs = try #require(try rowView(h, .section(.needsYou)).accessibilityLabel())
        #expect(needs.hasPrefix("NEEDS YOU，展開，3 個 session"), "\(needs)")
    }

    @Test func theSidebarHasNoUnlabeledElement() {
        let h = SidebarHarness()
        defer { h.window.close() }
        h.controller.applyNow()
        let report = AccessibilityAudit.audit(window: h.window, screen: "sidebar")
        #expect(report.interactive > 0)
        #expect(report.unlabeled.isEmpty, "\(report.unlabeled.map(\.path))")
    }

    @Test func railItemsAreRadioButtonsWithTheirAttentionCount() async throws {
        let store = MockSessionStore(shiftClock: false)
        let shell = ShellState()
        let rail = RailViewController(store: store, accounts: MockAccountStore(), shell: shell)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 72, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = rail
        window.layoutIfNeeded()
        func items() -> [RailItemButton] { m5AllViews(rail.view).compactMap { $0 as? RailItemButton } }
        await m3Eventually("the rail rendered") { items().first?.accessibilityLabel()?.contains("需要你") == true }
        let all = items()
        #expect(all.map(\.area) == [.sessions, .notes, .status, .settings])
        #expect(all.map { $0.accessibilityRole() } == Array(repeating: .radioButton, count: 4))
        let attention = store.allSessions.filter { $0.state.needsAttention }.count
        #expect(all.first?.accessibilityLabel() == "SESSIONS，\(attention) 個需要你")
        #expect(all.dropFirst().map { $0.accessibilityLabel() } == ["NOTES", "STATUS", "SETTINGS"])
        #expect(all.map { ($0.accessibilityValue() as? NSNumber)?.intValue } == [1, 0, 0, 0])
        shell.area = .notes
        await m3Eventually("NOTES is selected") { (items()[1].accessibilityValue() as? NSNumber)?.intValue == 1 }
        #expect((items()[0].accessibilityValue() as? NSNumber)?.intValue == 0)
    }

    @Test func railItemsTakeKeyboardFocusOnlyWithFullKeyboardAccess() {
        let saved = KeyboardFocus.fullKeyboardAccessOverride
        defer { KeyboardFocus.fullKeyboardAccessOverride = saved }
        let item = RailItemButton(area: .notes, icon: .notes, title: "Notes")
        KeyboardFocus.fullKeyboardAccessOverride = false
        #expect(!item.acceptsFirstResponder)
        KeyboardFocus.fullKeyboardAccessOverride = true
        #expect(item.acceptsFirstResponder)
    }
}

@MainActor
@Suite("M5 main window audit (D21)", .serialized)
struct M5MainWindowAuditTests {
    @Test func theMockMainWindowHasNoUnlabeledElement() async {
        let store = MockSessionStore(shiftClock: false)
        let shell = ShellState()
        shell.currentSessionID = "s1"
        let main = MainWindowController(store: store, accounts: MockAccountStore(), shell: shell,
                                        surfaceFactory: FakeTerminalSurfaceFactory { _ in "<d>></d> mock" }, savesFrame: false)
        defer { main.window?.close() }
        guard let window = main.window else { Issue.record("no window"); return }
        main.show("s1")
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        let reports = AccessibilityAudit.auditIncludingAttachedWindows(window, screen: "sessions-waiting")
        #expect(reports.first?.interactive ?? 0 > 10)
        for report in reports {
            #expect(report.unlabeled.isEmpty, "\(report.screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })")
        }
    }
}

/// `view` and every view below it, depth first (tests).
@MainActor
func m5AllViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(m5AllViews) }

// MARK: - Menu items (D21)

@MainActor
private final class A11yCommands: NSObject, CoddCommands {
    var calls: [String] = []
    func showSettings(_ sender: Any?) { calls.append("settings") }
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
    func showSessionsArea(_ sender: Any?) { calls.append("sessions") }
    func showNotesArea(_ sender: Any?) { calls.append("notes") }
    func showStatusArea(_ sender: Any?) { calls.append("status") }
    func showNotebookMode(_ sender: Any?) { calls.append("notebook") }
    func showFilesMode(_ sender: Any?) { calls.append("files") }
    func showCleanupMode(_ sender: Any?) { calls.append("cleanup") }
    func toggleNotesDrawer(_ sender: Any?) { calls.append("drawer") }
    func newGroup(_ sender: Any?) { calls.append("newGroup") }
    func togglePauseNotifications(_ sender: Any?) { calls.append("pause") }
    func fillAccountsMenu(_ menu: NSMenu) {
        menu.addItem(NSMenuItem(title: "#3 工作 · 5h 剩 91% · 1w 剩 15%", action: nil, keyEquivalent: ""))
    }
}

@MainActor
@Suite("M5 menu items for click-only actions (D21)", .serialized)
struct M5MenuItemTests {
    @Test func everyNewItemExistsWithoutAKeyEquivalentAndFires() throws {
        let windows = NSApp.windowsMenu
        let help = NSApp.helpMenu
        defer {
            NSApp.windowsMenu = windows
            NSApp.helpMenu = help
        }
        let commands = A11yCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        func submenu(_ title: String) throws -> NSMenu { try #require(menu.items.first { $0.title == title }?.submenu) }
        func fire(_ menu: NSMenu, _ title: String) throws {
            let item = try #require(menu.items.first { $0.title == title }, "\(title)")
            #expect(item.keyEquivalent.isEmpty, "\(title) adds no key equivalent")
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        let view = try submenu("顯示方式")
        for title in MainMenuBuilder.areaItemTitles { try fire(view, title) }
        let notes = try submenu("筆記")
        for title in MainMenuBuilder.notesModeTitles { try fire(notes, title) }
        let session = try submenu("Session")
        try fire(session, MainMenuBuilder.notesDrawerTitle)
        try fire(session, "新增群組…")
        try fire(try submenu("CODD"), MainMenuBuilder.pauseNotificationsTitle)
        #expect(commands.calls == ["sessions", "notes", "status", "settings", "notebook", "files", "cleanup", "drawer", "newGroup", "pause"])

        let accounts = try #require(session.items.first { $0.title == MainMenuBuilder.accountsMenuTitle }?.submenu)
        accounts.delegate?.menuNeedsUpdate?(accounts)
        #expect(accounts.items.map(\.title) == ["#3 工作 · 5h 剩 91% · 1w 剩 15%"])
        #expect(!accounts.items.contains { $0.title.contains("@") }, "aliases only, never an e-mail")
    }

    @Test func theAccountTitleIsTheAliasAndTheRemainingQuota() throws {
        let accounts = MockAccountStore()
        let account = try #require(accounts.account("3"))
        #expect(AppDelegate.accountMenuTitle(account) == "#3 工作 · 5h 剩 91% · 1w 剩 15%")
    }
}

#if DEBUG
@MainActor
@Suite("M5 a11y audit flag (D21)")
struct M5AuditFlagTests {
    @Test func theScreenListCoversEveryMainScreenAndOnboarding() {
        let names = AccessibilityAuditPass.screenNames
        for step in 1...6 { #expect(names.contains("onboarding-\(step)")) }
        for name in ["sessions-waiting", "sessions-shell", "sessions-ext", "home", "notes-notebook", "notes-files", "notes-cleanup",
                     "notes-annotate", "status", "menubar", "palette", "new-session", "new-session-dropdown", "dialog-a", "dialog-b",
                     "dialog-c", "dialog-d", "problem-banner"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(names.filter { $0.hasPrefix("settings-") }.count == 13)
        #expect(Set(names).count == names.count)
        #expect(AccessibilityAuditPass.selected(["onboarding"]) == (1...6).map { "onboarding-\($0)" })
        #expect(AccessibilityAuditPass.selected(["new-session"]) == ["new-session", "new-session-dropdown"])
        #expect(AccessibilityAuditPass.selected([]) == names)
    }

    @Test func theFlagsParseAndTheAuditIsAMockTool() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-a11y-audit", "~/x/a11y.json", "-codd-a11y-screens", "Settings,onboarding",
                                                        "-codd-full-keyboard-access", "YES"],
                                            environment: [:], home: "/Users/test")
        #expect(options.a11yAuditPath == "/Users/test/x/a11y.json")
        #expect(options.a11yScreens == ["settings", "onboarding"])
        #expect(options.fullKeyboardAccess == true)
        #expect(!options.enabled, "the audit draws the SPEC §5 mock data")
        #expect(options.releaseSubset.a11yAuditPath == nil)
    }
}
#endif
