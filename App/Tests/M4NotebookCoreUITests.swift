import AppKit
import CoddUI
import Testing
@testable import CODD

// M4 I1a: the NOTES split swap (D12) and the session area's ⌘W staying with sessions (D36).
// Windows are never ordered on screen, and the split has no autosave name: a test must never
// write the app's (the user's) saved split frames.

@Suite("M4 notebook core · NOTES layout")
@MainActor
struct M4NotebookCoreUITests {
    private func split() -> (MainSplitViewController, NSWindow) {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        let shell = ShellState()
        let rail = NSViewController()
        rail.view = NSView()
        let pane = NSViewController()
        pane.view = NSView()
        let sidebar = SidebarViewController(env: SidebarEnvironment(store: store, accounts: accounts, shell: shell, realMode: false))
        let split = MainSplitViewController(rail: rail, sidebar: sidebar, pane: pane, statusSidebar: NSView(), autosaveName: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1440, height: 900))
        split.view.layoutSubtreeIfNeeded()
        return (split, window)
    }

    @Test func notesCollapsesTheSidebarAndLeavingRestoresItsWidth() {
        let (split, window) = split()
        defer { window.close() }
        split.splitView.setPosition(Metrics.railWidth + 1 + 333, ofDividerAt: 1)
        split.view.layoutSubtreeIfNeeded()
        let width = split.sidebarContainer.view.frame.width
        #expect(abs(width - 333) <= 1)
        split.setSidebarMode(.notes)
        #expect(split.isShowingNotes && split.sidebarItem.isCollapsed)
        #expect(split.splitView.autosaveName == nil, "the saved width never follows the collapsed column")
        split.toggleSessionSidebar()
        #expect(split.sidebarItem.isCollapsed, "⌘\\ has no sidebar to show on NOTES")
        split.setSidebarMode(.sessions)
        split.view.layoutSubtreeIfNeeded()
        #expect(!split.sidebarItem.isCollapsed)
        #expect(abs(split.sidebarContainer.view.frame.width - width) <= 1)
        // NOTES → STATUS → sessions keeps the session sidebar's width too.
        split.setSidebarMode(.notes)
        split.setSidebarMode(.status)
        split.view.layoutSubtreeIfNeeded()
        #expect(split.isShowingStatus && !split.sidebarItem.isCollapsed)
        split.setSidebarMode(.sessions)
        split.view.layoutSubtreeIfNeeded()
        #expect(abs(split.sidebarContainer.view.frame.width - width) <= 1)
    }

    @Test func aCollapsedSidebarStaysCollapsedAfterNotes() {
        let (split, window) = split()
        defer { window.close() }
        split.sidebarItem.isCollapsed = true
        split.setSidebarMode(.notes)
        split.setSidebarMode(.sessions)
        #expect(split.sidebarItem.isCollapsed)
    }

    @Test func commandWOnNotesNeverClosesASessionTab() {
        let store = MockSessionStore()
        let shell = ShellState()
        shell.currentSessionID = "s9"
        let pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell,
                                             surfaceFactory: FakeTerminalSurfaceFactory { _ in "mock" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        defer { window.close() }
        shell.addShellTab(in: "s9", kind: .claude)
        let tabs = shell.pane(for: "s9").tabs.count
        shell.area = .notes
        #expect(!pane.handleCloseCommand(), "⌘W on NOTES is the window's (I3 adds the Files tabs)")
        #expect(shell.pane(for: "s9").tabs.count == tabs)
        #expect(!pane.canAllowCurrent || shell.area == .notes)
        shell.area = .sessions
        #expect(pane.handleCloseCommand())
        #expect(shell.pane(for: "s9").tabs.count == tabs - 1, "the sessions area keeps ⌘W for its shell tab")
    }
}
