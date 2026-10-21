import AppKit
import Foundation
import Testing
@testable import CODD

/// The real sidebar controller + NSOutlineView in an offscreen window.
@MainActor
struct SidebarHarness {
    let store = MockSessionStore(shiftClock: false)
    let accounts = MockAccountStore()
    let shell = ShellState()
    let controller: SidebarViewController
    let window: NSWindow

    init() {
        controller = SidebarViewController(env: SidebarEnvironment(store: store, accounts: accounts, shell: shell))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.layoutIfNeeded()
    }

    func expanded(_ kind: NodeKind) -> Bool { controller.outline.isItemExpanded(controller.item(for: kind)) }
}

@MainActor
@Suite("Sidebar controller")
struct SidebarControllerTests {
    @Test func collapsingAGroupCollapsesItsRow() {
        let h = SidebarHarness()
        #expect(h.expanded(.group("northweb")))
        h.controller.toggleCollapsed(.group("northweb"))
        #expect(h.store.group("northweb")?.isCollapsed == true)
        #expect(!h.expanded(.group("northweb")))
        h.controller.toggleCollapsed(.group("northweb"))
        #expect(h.expanded(.group("northweb")))
    }

    @Test func collapsingAfterAGroupMoveStillCollapses() {
        let h = SidebarHarness()
        h.store.answer("s1", key: "1")
        h.controller.applyNow()
        h.store.moveGroups(["github"], toIndex: 0)
        h.controller.applyNow()
        h.controller.toggleCollapsed(.group("northweb"))
        #expect(!h.expanded(.group("northweb")))
        #expect(OutlineSelfTest.mismatch(h.controller) == nil)
    }
}

@MainActor
@Suite("Sidebar keyboard")
struct SidebarKeyboardTests {
    private func select(_ h: SidebarHarness, _ id: SessionID) {
        h.controller.reveal(id)
        #expect(h.controller.outline.selectedRowIndexes.count == 1)
    }

    @Test func optionShiftArrowsReorderWithinTheProject() {
        let h = SidebarHarness()
        select(h, "s6")
        h.controller.moveSelected(by: -1)
        #expect(h.store.project("proto")?.sessionIDs == ["s6", "s4"])
        let selected = h.controller.outline.selectedRowIndexes.first.flatMap(h.controller.kind(atRow:))
        #expect(selected == .session("s6", .tree))
        h.controller.moveSelected(by: -1) // already first: no change
        #expect(h.store.project("proto")?.sessionIDs == ["s6", "s4"])
        h.controller.moveSelected(by: 1)
        #expect(h.store.project("proto")?.sessionIDs == ["s4", "s6"])
        #expect(OutlineSelfTest.mismatch(h.controller) == nil)
    }

    @Test func keyboardReorderIsOffWhileFiltering() {
        let h = SidebarHarness()
        select(h, "s6")
        h.shell.filterText = "審查清單"
        h.controller.applyNow()
        h.controller.moveSelected(by: -1)
        #expect(h.store.project("proto")?.sessionIDs == ["s4", "s6"])
    }
}
