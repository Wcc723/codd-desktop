import CoddUI
import CoreGraphics
import Testing
@testable import CoddAnnotateUI

/// M4 layout sweep: the annotation panel gives the image room on a narrow page (a small window at
/// UI 字級 20) and keeps its 380 where there is space.
@Suite("Layout sweep")
@MainActor
struct AnnotateLayoutSweepTests {
    @Test func thePanelNarrowsSoTheImageKeepsItsRoom() {
        #expect(ImageAnnotateView.panelWidth(width: 1440) == 380)
        #expect(ImageAnnotateView.panelWidth(width: 48 + 380 + 260) == 380, "380 while the image keeps 260")
        #expect(ImageAnnotateView.panelWidth(width: 600) == CGFloat(600 - 48 - 260), "typed: see ZoomTests in CoddUI")
        #expect(ImageAnnotateView.panelWidth(width: 400) == 260, "never under 260 while the page has it")
        #expect(ImageAnnotateView.panelWidth(width: 200) == CGFloat(200 - 48), "never wider than the page beside the tools")
        UIZoom.withScale(20.0 / 13.0) {
            // The 1011 pt window at UI 20: a 900 pt page.
            let panel = ImageAnnotateView.panelWidth(width: 900)
            #expect(panel < AnnotateTheme.panelWidth && 900 - AnnotateTheme.toolStripWidth - panel >= UIZoom.pt(260))
        }
    }
}
