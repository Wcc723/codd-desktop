import AppKit
import Darwin
import Foundation
import Testing
@testable import CODD

// The user's note of 2026-10-19 「額外開啟的終端機，也要可以關閉（另外終端機應該開在下方就好了）」:
// every extra terminal of a session opens as a tab of its ⌘J panel, and every panel tab closes
// (its `✕`, its context menu, ⌘W in it), asking first while a program runs in it.

private let uuidA = "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f"
private let uuidB = "4d5e6f7a-8b9c-4d1e-9f2a-3b4c5d6e7f8a"
private let uuidC = "5e6f7a8b-9c1d-4e2f-8a3b-4c5d6e7f8a9b"

@MainActor
private func pause(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// Mock terminals that record which shell tabs were closed and say which run a job.
@MainActor
private final class RecordingFactory: TerminalSurfaceFactory, ShellTabJobProbe {
    private let fake = FakeTerminalSurfaceFactory { _ in "<d>></d> mock" }
    private(set) var closed: [String] = []
    var running: Set<String> = []

    func makeSurface(slot: TerminalSlot) -> TerminalSurface { fake.makeSurface(slot: slot) }
    func closeShellTab(sessionID: SessionID, tabID: String) { closed.append(tabID) }
    func send(_ input: TerminalInput, to target: TerminalTarget) -> Bool { fake.send(input, to: target) }
    func runsForegroundJob(tabID: String) -> Bool { running.contains(tabID) }
}

/// A mock-mode pane in a window that is never ordered in; the close sheet is answered by the test.
@MainActor
private final class Harness {
    let store = MockSessionStore(shiftClock: false)
    let shell = ShellState()
    let factory = RecordingFactory()
    let pane: SessionPaneViewController
    let window: NSWindow
    /// What the close sheet was asked, in order, with the way to answer it.
    var asked: [(label: String, answer: @MainActor (Bool) -> Void)] = []

    init(current: SessionID = "s9") {
        shell.currentSessionID = current
        pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell, surfaceFactory: factory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.layoutIfNeeded()
        pane.confirmCloseTerminal = { [weak self] label, answer in self?.asked.append((label, answer)) }
    }

    deinit { MainActor.assumeIsolated { window.close() } }

    var layout: PaneLayout { shell.pane(for: shell.currentSessionID ?? "") }
}

// MARK: - Open in the panel

@MainActor
@Suite("FB terminals: extra terminals open in the panel", .serialized)
struct FBTerminalsOpenTests {
    @Test func commandTAndPlusOpenPanelTabs() async throws {
        let h = Harness()
        await pause()
        // The strip is the session's own tab and `+`: no `$ ZSH` above the panel any more.
        #expect(h.pane.sessionTabStrip.tabButtons.map(\.label) == ["Claude"])
        #expect(h.pane.sessionTabStrip.addTab.accessibilityLabel() == TabStripView.addTitle)
        // ⌘T: a new shell in the panel, shown and focused; the top keeps showing claude.
        h.pane.newShellTab()
        #expect(h.layout.tabs.isEmpty && h.layout.panelTabs.count == 1)
        #expect(h.layout.panelOpen && h.layout.panel == h.layout.panelTabs.first)
        #expect(h.layout.effectiveSelection == .claude)
        #expect(h.pane.panelSurface.hasFocus)
        // The strip's `+` does the same.
        h.pane.sessionTabStrip.addTab.performClick(nil)
        await pause()
        #expect(h.layout.panelTabs.map(\.number) == [1, 2] && h.layout.panel?.number == 2)
        #expect(h.pane.panelStrip.tabButtons.map(\.label) == ["zsh 1", "zsh 2"])
        #expect(h.pane.sessionTabStrip.tabButtons.map(\.label) == ["Claude"])
        // `-codd-open-zsh-tab` (the old `$ ZSH`) opens one there too.
        h.pane.openShellTab()
        #expect(h.layout.panelTabs.count == 3 && h.layout.tabs.isEmpty)
        // ⌘J hides the panel and keeps its shells; ⌘T opens it again on a new one.
        h.pane.toggleBottomTerminal()
        #expect(!h.layout.panelOpen && h.layout.panelTabs.count == 3)
        h.pane.newShellTab()
        #expect(h.layout.panelOpen && h.layout.panelTabs.count == 4 && h.layout.panel?.number == 4)
        #expect(h.factory.closed.isEmpty)
    }

    @Test func aShellSessionsExtraTerminalsOpenInItsPanel() async throws {
        let h = Harness(current: "s8")
        await pause()
        #expect(h.pane.sessionTabStrip.tabButtons.map(\.label) == ["zsh"])
        h.pane.newShellTab()
        #expect(h.layout.tabs.isEmpty && h.layout.panelTabs.count == 1 && h.layout.panelOpen)
        #expect(h.pane.panelStrip.tabButtons.map(\.label) == ["zsh 1"])
    }
}

// MARK: - Close

@MainActor
@Suite("FB terminals: closing panel tabs", .serialized)
struct FBTerminalsCloseTests {
    /// Three panel tabs, the last one shown.
    private func threeTabs() async -> Harness {
        let h = Harness()
        await pause()
        for _ in 0..<3 { h.pane.newShellTab() }
        await pause()
        return h
    }

    @Test func theCloseButtonShowsOnTheShownAndTheHoveredTab() async throws {
        let h = await threeTabs()
        let items = h.pane.panelStrip.tabItems
        #expect(items.map(\.close.isHidden) == [true, true, false], "only the shown tab's `✕` without the pointer")
        items[0].setHovered(true)
        #expect(!items[0].close.isHidden)
        items[0].setHovered(false)
        #expect(items[0].close.isHidden)
        #expect(h.pane.panelStrip.closeButtons[2].accessibilityLabel() == "關閉終端機「zsh 3」")
        // The `✕` has room of its own inside the tab: the item is wider than the bare tab button.
        #expect(items[0].intrinsicContentSize.width > items[0].tab.intrinsicContentSize.width)
        h.window.layoutIfNeeded()
        #expect(items[2].close.frame.maxX <= items[2].bounds.maxX && items[2].close.frame.minX > 0)
    }

    @Test func closeButtonEndsTheShellAndTheNeighbourShows() async throws {
        let h = await threeTabs()
        let ids = h.layout.panelTabs.map(\.id)
        // A tab not shown (its `✕` appears under the pointer): it goes, the shown one stays.
        h.pane.panelStrip.tabItems[0].setHovered(true)
        h.pane.panelStrip.closeButtons[0].performClick(nil)
        #expect(h.factory.closed == [ids[0]])
        #expect(h.layout.panelTabs.map(\.id) == [ids[1], ids[2]] && h.layout.panel?.id == ids[2])
        await pause()
        #expect(h.pane.panelStrip.tabButtons.map(\.label) == ["zsh 2", "zsh 3"])
        // The shown tab: the one before it shows.
        h.pane.panelStrip.closeButtons[1].performClick(nil)
        #expect(h.factory.closed == [ids[0], ids[2]])
        #expect(h.layout.panel?.id == ids[1] && h.layout.panelOpen)
        #expect(h.pane.panelSurface.hasFocus)
        // The last one hides the panel; nothing asked (no program ran in them).
        h.pane.closePanelTab(ids[1])
        #expect(h.factory.closed == [ids[0], ids[2], ids[1]])
        #expect(!h.layout.panelOpen && h.layout.panelTabs.isEmpty && !h.layout.panelMaximized)
        #expect(h.asked.isEmpty)
        await pause()
        #expect(h.pane.panelStrip.isHiddenOrHasHiddenAncestor)
    }

    @Test func theFirstTabClosedShowsTheNextOne() async throws {
        let h = await threeTabs()
        let ids = h.layout.panelTabs.map(\.id)
        h.pane.selectPanelTab(ids[0])
        h.pane.closePanelTab(ids[0])
        #expect(h.layout.panel?.id == ids[1])
    }

    @Test func contextMenuAddsAndCloses() async throws {
        let h = await threeTabs()
        let ids = h.layout.panelTabs.map(\.id)
        let menu = try #require(h.pane.panelStrip.tabButtons[1].menu)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [PanelStripView.addTabTitle, PanelStripView.closeTabTitle])
        let close = try #require(menu.items.firstIndex { $0.title == PanelStripView.closeTabTitle })
        menu.performActionForItem(at: close)
        #expect(h.factory.closed == [ids[1]])
        #expect(h.layout.panelTabs.map(\.id) == [ids[0], ids[2]])
        let add = try #require(h.pane.panelStrip.tabButtons[0].menu?.items.firstIndex { $0.title == PanelStripView.addTabTitle })
        h.pane.panelStrip.tabButtons[0].menu?.performActionForItem(at: add)
        #expect(h.layout.panelTabs.count == 3 && h.layout.panel?.number == 4)
    }

    @Test func commandWClosesTheFocusedPanelTabOnly() async throws {
        let h = await threeTabs()
        let ids = h.layout.panelTabs.map(\.id)
        h.pane.panelSurface.focus()
        #expect(h.pane.handleCloseCommand())
        #expect(h.factory.closed == [ids[2]] && h.layout.panel?.id == ids[1] && h.pane.panelSurface.hasFocus)
        #expect(h.layout.panelTabs.map(\.id) == [ids[0], ids[1]])
    }
}

// MARK: - Close while a program runs

@MainActor
@Suite("FB terminals: closing a terminal that runs a program", .serialized)
struct FBTerminalsRunningTests {
    @Test func asksFirstAndCancelKeepsTheTab() async throws {
        let h = Harness()
        await pause()
        h.pane.newShellTab()
        h.pane.newShellTab()
        let ids = h.layout.panelTabs.map(\.id)
        h.shell.setTabTitle("npm run dev", for: ids[1])
        h.factory.running = [ids[1]]
        await pause()
        h.pane.panelStrip.closeButtons[1].performClick(nil)
        #expect(h.asked.map(\.label) == ["npm run dev"])
        #expect(h.factory.closed.isEmpty && h.layout.panelTabs.count == 2, "nothing closes before the answer")
        h.asked[0].answer(false)
        #expect(h.factory.closed.isEmpty && h.layout.panelTabs.count == 2)
        // ⌘W in it asks too; this time the answer is to close.
        h.pane.panelSurface.focus()
        #expect(h.pane.handleCloseCommand())
        #expect(h.asked.count == 2 && h.factory.closed.isEmpty)
        h.asked[1].answer(true)
        #expect(h.factory.closed == [ids[1]] && h.layout.panelTabs.map(\.id) == [ids[0]])
        // A tab at its prompt closes at once.
        h.pane.closePanelTab(ids[0])
        #expect(h.asked.count == 2 && h.factory.closed == [ids[1], ids[0]] && !h.layout.panelOpen)
    }

    @Test func aTabThatEndedWhileTheSheetWasUpIsNotClosedTwice() async throws {
        let h = Harness()
        await pause()
        h.pane.newShellTab()
        let id = try #require(h.layout.panel?.id)
        h.factory.running = [id]
        h.pane.closePanelTab(id)
        #expect(h.asked.count == 1)
        // Its shell exited meanwhile (the hub drops the tab).
        h.shell.removePanelTab(id, in: "s9")
        h.asked[0].answer(true)
        #expect(h.factory.closed.isEmpty)
    }

    @Test func withoutAProbeTheRunningLampDecides() async throws {
        // Mock mode's own factory has no probe: the lamp the strip shows is what counts.
        let store = MockSessionStore(shiftClock: false)
        let shell = ShellState()
        shell.currentSessionID = "s9"
        let pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell,
                                             surfaceFactory: FakeTerminalSurfaceFactory { _ in "" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane.view
        var asked: [String] = []
        pane.confirmCloseTerminal = { label, _ in asked.append(label) }
        pane.newShellTab()
        let id = try #require(shell.pane(for: "s9").panel?.id)
        shell.setRunning([id])
        pane.closePanelTab(id)
        #expect(asked == ["zsh 1"] && shell.pane(for: "s9").panelTabs.count == 1)
        shell.setRunning([])
        pane.closePanelTab(id)
        #expect(asked.count == 1 && shell.pane(for: "s9").panelTabs.isEmpty)
    }

    @Test func sheetText() {
        let text = SessionPaneViewController.closeRunningConfirmation("npm run dev")
        #expect(text.message == "要關閉「npm run dev」嗎？")
        #expect(text.info.contains("還有程式在執行"))
    }
}

// MARK: - Persistence

@MainActor
@Suite("FB terminals: panes.json")
struct FBTerminalsPersistenceTests {
    /// What an older CODD wrote: two strip shell tabs (the second shown) and a hidden panel.
    private static let olderFile = """
    {"version":1,"sessions":{"s":{"tabs":[{"id":"\(uuidA)","number":1},{"id":"\(uuidB)","number":2}],"selected":"\(uuidB)",
    "panelTabs":[{"id":"\(uuidC)","number":1}],"panelSelected":"\(uuidC)","panel":{"id":"\(uuidC)","number":1},
    "panelOpen":false,"panelHeight":300,"composerOpen":true}}}
    """

    @Test func olderStripTabsMoveIntoThePanel() throws {
        var layout = try #require(PaneLayoutStore.decode(Data(Self.olderFile.utf8))?["s"])
        #expect(layout.tabs.map(\.id) == [uuidA, uuidB], "the file still loads as written")
        let changed = layout.moveStripTabsToPanel()
        #expect(changed)
        #expect(layout.tabs.isEmpty && layout.effectiveSelection == .claude)
        #expect(layout.panelTabs == [ShellTab(id: uuidC, number: 1), ShellTab(id: uuidA, number: 2), ShellTab(id: uuidB, number: 3)],
                "the same holders, numbered after the panel's own")
        #expect(layout.panel?.id == uuidB && layout.panelOpen, "the strip tab that was shown opens the panel on it")
        #expect(layout.panelHeight == 300 && layout.composerOpen)
        // Done once: a second pass changes nothing.
        let moved = layout
        let again = layout.moveStripTabsToPanel()
        #expect(!again && layout == moved)
    }

    @Test func aHiddenStripTabKeepsThePanelAsItWas() throws {
        var layout = PaneLayout()
        layout.tabs = [ShellTab(id: uuidA, number: 1)]
        layout.selected = .claude
        layout.moveStripTabsToPanel()
        #expect(layout.panelTabs.map(\.id) == [uuidA] && layout.panelTabs[0].number == 1)
        #expect(!layout.panelOpen && layout.panel?.id == uuidA)
    }

    @Test func movedLayoutsRoundTripAndAnM1FileStillLoads() throws {
        let shell = ShellState()
        shell.panes = try #require(PaneLayoutStore.decode(Data(Self.olderFile.utf8)))
        shell.moveStripTabsToPanel()
        let data = try #require(PaneLayoutStore.encode(shell.panes))
        let decoded = try #require(PaneLayoutStore.decode(data))
        #expect(decoded == shell.panes)
        #expect(decoded["s"]?.tabs.isEmpty == true && decoded["s"]?.panelTabs.count == 3 && decoded["s"]?.panel?.id == uuidB)
        // An M1 file: a strip tab and the single `panel`.
        let m1 = """
        {"version":1,"sessions":{"s":{"tabs":[{"id":"\(uuidA)","number":1}],"selected":"claude",
        "panel":{"id":"\(uuidB)","number":1},"panelOpen":true}}}
        """
        var layout = try #require(PaneLayoutStore.decode(Data(m1.utf8))?["s"])
        layout.moveStripTabsToPanel()
        #expect(layout.panelTabs.map(\.id) == [uuidB, uuidA] && layout.panel?.id == uuidB && layout.panelOpen)
    }

    /// The terminal hub moves them at discovery, right after panes.json was loaded (a temp data
    /// root without sessions or holders).
    @Test func discoveryMovesStripTabsIntoThePanel() async throws {
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/codd-fb.XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        let path = String(cString: created)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let root = CoddDataRoot(path: path)
        let store = HolderSessionStore(root: root, launcher: nil, claudeDirectory: ClaudeDirectory(path: path + "/claude")) { _ in }
        let shell = ShellState()
        shell.panes = try #require(PaneLayoutStore.decode(Data(Self.olderFile.utf8)))
        let hub = TerminalHub(store: store, shell: shell) { _ in }
        await hub.discoverTabs()
        let layout = shell.pane(for: "s")
        #expect(layout.tabs.isEmpty && layout.panelTabs.map(\.id) == [uuidC, uuidA, uuidB] && layout.panel?.id == uuidB)
        #expect(!hub.runsForegroundJob(tabID: uuidA), "a tab without a running shell runs nothing")
        hub.shutdown()
    }
}
