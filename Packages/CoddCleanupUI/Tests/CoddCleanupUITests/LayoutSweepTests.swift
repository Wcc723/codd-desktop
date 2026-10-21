import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// M4 layout sweep: the review table on a narrow page (a small window at UI 字級 20) folds the AI
/// hint column, then shares what is left between ITEM and WHY, and never runs past its width.
@Suite("Layout sweep")
@MainActor
struct CleanupLayoutSweepTests {
    @Test func theTableFoldsTheAIColumnAndStaysInsideItsWidth() {
        let minimum = TableColumns.minimum.reduce(0, +)
        #expect(TableColumns(width: 926).showsAI && TableColumns(width: 926).widths == TableColumns.base, "the artboard's columns")
        #expect(TableColumns(width: minimum).showsAI)
        #expect(!TableColumns(width: minimum - 1).showsAI, "the AI hint folds first")
        for width in stride(from: CGFloat(480), through: 1600, by: 17) {
            let columns = TableColumns(width: width)
            #expect(abs(columns.total - width) <= 1, "width \(width): \(columns.widths)")
            #expect(columns.widths[0] == 36 && columns.widths[5] == 196, "the checkbox and the actions stay fixed")
            #expect(columns.widths[1] >= 40 && columns.widths[2] >= 60, "width \(width)")
        }
        UIZoom.withScale(20.0 / 13.0) {
            #expect(!TableColumns(width: 800).showsAI, "the 1011 pt window at UI 20")
            #expect(abs(TableColumns(width: 800).total - 800) <= 1)
        }
    }
}
