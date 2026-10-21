import AppKit
import CoddNotebookUI
import CoddUI
import Testing
@testable import CODD

/// M4 layout sweep: the layout rules that keep every screen usable from the minimum window to a
/// wide one and from UI 字級 10 to 20, checked without rendering (the renders are
/// `scripts/m4-layout-sweep.sh`). Pure computations at a given zoom use `UIZoom.withScale`, so
/// no test leaves the app zoomed.
@MainActor
@Suite("M4 layout sweep · window, columns and bars")
struct M4LayoutSweepTests {
    private static let sizes = Array(UIZoom.fontSizeRange)

    @Test func theMinimumWindowIsTheSplitsMinimumsAtEveryZoom() {
        for size in Self.sizes {
            UIZoom.withScale(UIZoom.scale(forFontSize: size)) {
                let minimum = MainWindowController.minimumSize
                // rail | 1 px | narrowest sidebar | 1 px | narrowest pane: no column below its minimum.
                #expect(minimum.width == Metrics.railWidth + Metrics.sidebarMinWidth + Metrics.mainMinWidth + 2, "UI \(size)")
                #expect(Metrics.sidebarMinWidth <= Metrics.sidebarWidth && Metrics.sidebarWidth <= Metrics.sidebarMaxWidth, "UI \(size)")
                #expect(minimum.height == 560, "UI \(size)")
            }
        }
        // The largest zoom still fits a 1280 pt laptop screen.
        let largest = UIZoom.withScale(UIZoom.scale(forFontSize: UIZoom.fontSizeRange.upperBound)) { MainWindowController.minimumSize }
        #expect(largest.width <= 1280)
        #expect(MainWindowController.minimumSize == NSSize(width: 854, height: 560), "the design minimum at 13")
    }

    @Test func theSweepSizesParseAndStayOutOfRelease() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-window-size", "MIN", "-codd-sidebar-width", "Max",
                                                        "-codd-settings-size", "900x600", "-codd-settings-all", "YES"],
                                            environment: [:], home: "/Users/test")
        #expect(options.windowSize == "min" && options.sidebarWidth == "max" && options.settingsSize == "900x600" && options.settingsAll)
        let release = options.releaseSubset
        #expect(release.windowSize == nil && release.sidebarWidth == nil && release.settingsSize == nil && !release.settingsAll)
        let minimum = CGSize(width: 854, height: 560)
        #expect(RealModeOptions.layoutSize("min", minimum: minimum) == minimum)
        #expect(RealModeOptions.layoutSize("1280x800", minimum: minimum) == CGSize(width: 1280, height: 800))
        #expect(RealModeOptions.layoutSize(" 2560 x 1080 ", minimum: minimum) == CGSize(width: 2560, height: 1080))
        for bad in ["", "wide", "0x560", "854x0", "9000x560", "854x560x2", "-854x560"] {
            #expect(RealModeOptions.layoutSize(bad, minimum: minimum) == nil, "\(bad)")
        }
        #expect(RealModeOptions.layoutSize(nil, minimum: minimum) == nil)
    }

    @Test func notebookColumnsFoldInOrderAndNeverSqueezeTheDocument() {
        for size in Self.sizes {
            UIZoom.withScale(UIZoom.scale(forFontSize: size)) {
                let lists = NotebookListsView.preferredWidth
                let list = NoteListView.preferredWidth
                let info = NoteInfoPanelView.preferredWidth
                let document = UIZoom.pt(NotebookModeView.documentMinimum)
                let narrowList = min(list, UIZoom.pt(NotebookModeView.listMinimum))
                let wide = NotebookModeView.columns(width: lists + list + info + document + 200)
                #expect(wide == .init(lists: lists, list: list, info: true), "UI \(size)")
                let noInfo = NotebookModeView.columns(width: lists + list + document + 10)
                #expect(noInfo == .init(lists: lists, list: list, info: false), "UI \(size): the info panel folds first")
                let narrowed = NotebookModeView.columns(width: lists + narrowList + document + 1)
                #expect(narrowed.lists == lists && narrowed.list < list && narrowed.list >= narrowList && !narrowed.info, "UI \(size)")
                let folded = NotebookModeView.columns(width: lists + narrowList + document - 1)
                #expect(folded.lists == 0 && folded.list >= narrowList, "UI \(size): then the lists column")
                let revealed = NotebookModeView.columns(width: lists + narrowList + document - 1, revealLists: true)
                #expect(revealed.lists == lists, "UI \(size): ⌘F keeps the lists column")
                // Wherever the columns fit, the document keeps at least its minimum.
                for width in stride(from: lists + narrowList + document, through: lists + list + info + document + 100, by: 37) {
                    let columns = NotebookModeView.columns(width: width)
                    let rest = width - columns.lists - columns.list - (columns.info ? info : 0)
                    #expect(rest >= document - 0.5, "UI \(size) width \(width)")
                }
            }
        }
    }

    @Test func theNotesDrawerLeavesTheTerminalHalfTheBody() {
        for size in Self.sizes {
            UIZoom.withScale(UIZoom.scale(forFontSize: size)) {
                let full = PaneBodyRowView.drawerWidth
                #expect(PaneBodyRowView.drawerWidth(in: 2000) == full, "UI \(size): its own width on a wide pane")
                for width in stride(from: CGFloat(0), through: 1200, by: 23) {
                    let drawer = PaneBodyRowView.drawerWidth(in: width)
                    #expect(drawer >= 0 && drawer <= full && drawer <= floor(width / 2) && width - drawer >= min(width, UIZoom.pt(200)),
                            "UI \(size) width \(width)")
                }
            }
        }
    }

    @Test func theComposerUsesTheCompactSendOnlyWhenTheFieldWouldBeNarrow() {
        UIZoom.withScale(1) {
            let button: CGFloat = 80
            let chrome = ComposerBarView.padding.left + ComposerBarView.padding.right + ComposerBarView.buttonGap + button
            #expect(!ComposerBarView.usesCompactSend(width: chrome + 200, fullButton: button))
            #expect(ComposerBarView.usesCompactSend(width: chrome + 199, fullButton: button))
            #expect(!ComposerBarView.usesCompactSend(width: 1200, fullButton: button))
        }
    }

    @Test func aHiddenSelectionBarTakesNoHeight() {
        let bar = SelectionBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        bar.update(count: 3)
        let shown = bar.fittingSize.height
        #expect(!bar.isHidden && shown > 20)
        bar.update(count: 1)
        #expect(bar.isHidden && bar.fittingSize.height == 0, "the list reaches the footer while nothing is multi-selected")
        bar.update(count: 2)
        #expect(!bar.isHidden && bar.fittingSize.height == shown)
    }
}
