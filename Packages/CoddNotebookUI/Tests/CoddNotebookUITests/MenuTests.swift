import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

@MainActor
@Suite struct MenuTests {
    private func sample() -> NotebookMenuModel {
        NotebookMenuModel(entries: [
            .header("Test", trailing: "x"),
            .item(NotebookMenuItem(id: "a", title: "Alpha")),
            .item(NotebookMenuItem(id: "b", title: "Beta", isEnabled: false, disabledReason: "不能用")),
            .separator,
            .item(NotebookMenuItem(id: "c", title: "Gamma", hint: "第二行提示", shortcut: "⌘G")),
            .item(NotebookMenuItem(id: "d", title: "Delta", submenu: NotebookMenuModel(entries: [
                .item(NotebookMenuItem(id: "d1", title: "D one")),
                .item(NotebookMenuItem(id: "d2", title: "D two")),
            ]))),
        ])
    }

    @Test func keyboardNavigationSkipsDisabledItemsAndWraps() {
        TestFonts.register()
        let menu = NotebookMenuView(model: sample())
        var chosen: [String] = []
        var dismissed = 0
        menu.onActivate = { chosen.append($0.id) }
        menu.onDismiss = { dismissed += 1 }
        #expect(menu.highlightedID == "a", "the first enabled item")
        menu.handleKey(Keys.down)
        #expect(menu.highlightedID == "c", "Beta is disabled")
        menu.handleKey(Keys.down)
        #expect(menu.highlightedID == "d")
        menu.handleKey(Keys.down)
        #expect(menu.highlightedID == "a", "wraps")
        menu.handleKey(Keys.up)
        #expect(menu.highlightedID == "d")
        menu.handleKey(Keys.right)
        #expect(menu.stack.map(\.id) == ["d"])
        #expect(menu.visibleItems.map(\.id) == [NotebookMenuView.backRowID, "d1", "d2"])
        #expect(menu.highlightedID == "d1")
        menu.handleKey(Keys.escape)
        #expect(menu.stack.isEmpty, "⎋ in a submenu goes back")
        #expect(dismissed == 0)
        #expect(menu.highlightedID == "d")
        menu.handleKey(Keys.enter)
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(chosen == ["d2"])
        menu.handleKey(Keys.left)
        menu.handleKey(Keys.escape)
        #expect(dismissed == 1)
        #expect(!menu.handleKey(Keys.event(0, "a")), "other keys are not the menu's")
        // The back row works with the mouse too.
        menu.activate(id: "d")
        menu.row(NotebookMenuView.backRowID)?.performClick(nil)
        #expect(menu.stack.isEmpty)
    }

    @Test func mouseHighlightsAndActivates() {
        TestFonts.register()
        let menu = NotebookMenuView(model: sample())
        var chosen: [String] = []
        menu.onActivate = { chosen.append($0.id) }
        menu.layoutSubtreeIfNeeded()
        menu.row("c")?.setHovered(true)
        #expect(menu.highlightedID == "c")
        menu.row("b")?.setHovered(true)
        #expect(menu.highlightedID == "c", "a disabled item never highlights")
        #expect(menu.row("b")?.toolTip == "不能用")
        menu.row("b")?.performClick(nil)
        menu.row("c")?.performClick(nil)
        #expect(chosen == ["c"])
        #expect(!menu.activate(id: "b"))
        #expect(!menu.activate(id: "nope"))
    }

    @Test func rowMetrics() {
        TestFonts.register()
        let menu = NotebookMenuView(model: sample())
        menu.layoutSubtreeIfNeeded()
        #expect(menu.row("a")?.frame.height == 28, "`.menu .mi{height:28px}`")
        let two = menu.row("c")?.frame.height ?? 0
        #expect(two == 48, "`.nb-mi2`: padding 7, value 17, gap 2, one hint line (15), padding 7")
        #expect(menu.row("a")?.frame.minX == 5, "1 px border + `padding:4px`")
        #expect(menu.menuWidth >= 220, "`.menu{min-width:220px}`")
        #expect(menu.preferredSize.height == menu.frame.height)
        // A submenu changes the size and reports it.
        var sizes: [NSSize] = []
        menu.onSizeChange = { sizes.append($0) }
        menu.activate(id: "d")
        #expect(sizes.count == 1)
        #expect(sizes.first?.height == menu.preferredSize.height)
    }

    @Test func updateKeepsTheHighlight() {
        TestFonts.register()
        let menu = NotebookMenuView(model: sample())
        menu.handleKey(Keys.down)
        var model = sample()
        model.entries.append(.item(NotebookMenuItem(id: "e", title: "Epsilon")))
        menu.update(model)
        #expect(menu.highlightedID == "c")
        #expect(menu.visibleItems.last?.id == "e")
    }

    @Test func copyRefMenuRowHeightsFitTheArtboard() throws {
        TestFonts.register()
        let chrome = NoteEditorChromeView(model: NotebookSamples.n1Chrome)
        let menu = NotebookMenuView(model: chrome.menuModel(for: .copyRef))
        menu.layoutSubtreeIfNeeded()
        #expect(menu.frame.width == 404)
        for id in ["ref.2", "ref.3", "ref.4", "ref.5"] {
            #expect(menu.row(id)?.frame.height == 48, "\(id) has a one-line hint")
        }
        let first = try #require(menu.row("ref.1"))
        #expect(first.frame.height >= 48 && first.frame.height <= 63, "the first hint takes one or two lines")
        let texts = menu.notebookVisibleTexts()
        #expect(texts.containsInOrder(["COPY REFERENCE · 複製引用", "rwd-punch-k7x2", "codd://note/rwd-punch-k7x2", "推薦", "⌘⇧C"]))
    }

    /// The default presenter never orders a window in when its host is not on screen.
    @Test func popoverPresenterNeverOrdersAWindowFront() {
        TestFonts.register()
        let chrome = NoteEditorChromeView(model: NotebookSamples.n1Chrome)
        let host = Host(chrome, size: CGSize(width: 848, height: 876))
        defer { host.tearDown() }
        let presenter = PopoverMenuPresenter()
        chrome.menuPresenter = presenter
        let before = NSApp.windows.filter(\.isVisible).count
        for menu in NoteChromeMenu.allCases {
            chrome.openMenu(menu)
            #expect(presenter.panel == nil, "nothing shown from an offscreen window")
            #expect(chrome.presentedMenu == nil, "the menu closed at once")
        }
        chrome.promptFooter.targetPill.performClick(nil)
        #expect(chrome.promptFooter.targetMenu == nil)
        #expect(NSApp.windows.filter(\.isVisible).count == before)
        #expect(!host.window.isVisible)
        let panel = PopoverPanel(content: NotebookMenuView(model: chrome.menuModel(for: .copyRef)))
        #expect(!panel.show(at: .zero, in: chrome), "refused: the host window is not visible")
        #expect(!panel.isVisible)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.canBecomeMain)
    }

    @Test func inlinePresenterPlacesTheMenuInTheHost() throws {
        TestFonts.register()
        let chrome = NoteEditorChromeView(model: NotebookSamples.n1Chrome)
        let host = Host(chrome, size: CGSize(width: 848, height: 876))
        defer { host.tearDown() }
        let presenter = InlineMenuPresenter()
        chrome.menuPresenter = presenter
        chrome.openMenu(.copyRef)
        let menu = try #require(presenter.menu)
        #expect(menu.superview === chrome)
        #expect(menu.frame.origin == CGPoint(x: 848 - 10 - 404, y: 46))
        chrome.closeMenu()
        #expect(menu.superview == nil)
        #expect(presenter.menu == nil)
    }
}

@MainActor
@Suite struct SVGTests {
    @Test func tokenizerReadsCompactNumbersAndArcFlags() {
        #expect(NotebookSVG.tokenize("l2.2 4.6 5.05.55-3.75") == [.command("l"), .number(2.2), .number(4.6), .number(5.05), .number(0.55),
                                                                   .number(-3.75)])
        #expect(NotebookSVG.tokenize("a3 3 0 0 1 6 0") == [.command("a"), .number(3), .number(3), .number(0), .number(0), .number(1),
                                                            .number(6), .number(0)])
        #expect(NotebookSVG.tokenize("a3 3 0 016 0") == [.command("a"), .number(3), .number(3), .number(0), .number(0), .number(1),
                                                          .number(6), .number(0)], "compact flags")
    }

    @Test func arcsAndSmoothCurvesHaveTheRightBounds() {
        // The lock's shackle: a half circle of radius 3 from (7,6.5) to (13,6.5) over the top.
        let shackle = NotebookSVG.parse("M7 9V6.5a3 3 0 0 1 6 0V9")
        let bounds = shackle.bounds
        #expect(abs(bounds.minX - 7) < 0.01 && abs(bounds.maxX - 13) < 0.01)
        #expect(abs(bounds.minY - 3.5) < 0.05, "the arc peaks at y = 6.5 − 3")
        // The eye: smooth cubic curves reaching x 2…18.
        let eye = NotebookSVG.parse("M2 10s3-5.25 8-5.25S18 10 18 10s-3 5.25-8 5.25S2 10 2 10z")
        #expect(abs(eye.bounds.minX - 2) < 0.01 && abs(eye.bounds.maxX - 18) < 0.01)
        #expect(eye.bounds.minY > 4 && eye.bounds.minY < 7)
        // Every artboard icon parses to something.
        for icon in NotebookIcon.allCases { #expect(!NotebookIconRenderer.path(icon).isEmpty, "\(icon)") }
    }
}
