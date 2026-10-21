import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// M4 layout sweep: the STATUS grids step down to fewer columns at the same zoomed widths, so a
/// small window at UI 字級 20 shows two or one columns instead of squeezed cards.
@Suite("Layout sweep")
@MainActor
struct StatusLayoutSweepTests {
    @Test func theHostAndAccountGridsUseFewerColumnsWhenNarrow() {
        #expect(HostSectionView.columns(forWidth: 1200) == HostSectionView.columns)
        #expect(HostSectionView.columns(forWidth: 600) == HostSectionView.narrowColumns)
        #expect(HostSectionView.columns(forWidth: 400) == [1, 1])
        #expect(HostSectionView.columns(forWidth: 200) == [1])
        UIZoom.withScale(20.0 / 13.0) {
            #expect(HostSectionView.columns(forWidth: 600) == [1, 1], "600 is narrow at UI 20")
            #expect(HostSectionView.columns(forWidth: 450) == [1])
            #expect(AccountsSectionView.columns(forWidth: 1148) == 3, "four compact cards need 1406 at UI 20")
            #expect(AccountsSectionView.columns(forWidth: 700, minimumCard: UIZoom.pt(228)) == 1)
        }
        #expect(StatusSidebarView.preferredWidth == 220)
        UIZoom.withScale(20.0 / 13.0) { #expect(StatusSidebarView.preferredWidth == UIZoom.pt(220)) }
    }
}
