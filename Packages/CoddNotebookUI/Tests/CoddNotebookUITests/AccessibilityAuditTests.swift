import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

/// M5 D21: every main view of the package, built from the samples in an offscreen window, has no
/// unlabeled interactive element (CoddUI's `AccessibilityAudit`); the elements outside the
/// key-view loop are printed for the report, not failed.
@MainActor
@Suite struct AccessibilityAuditTests {
    @discardableResult
    private func audit<View: NSView>(_ host: Host<View>, _ screen: String, sourceLocation: SourceLocation = #_sourceLocation)
        -> AccessibilityAudit.Report {
        host.settle()
        let report = AccessibilityAudit.audit(window: host.window, screen: screen)
        print("A11Y \(screen): interactive \(report.interactive), unlabeled \(report.unlabeled.count), outsideKeyLoop \(report.outsideKeyLoop.count)")
        for finding in report.outsideKeyLoop { print("A11Y   \(screen) outside key loop: \(finding.role) \(finding.path) \(finding.label ?? "")") }
        #expect(report.interactive > 0, "\(screen): nothing interactive found", sourceLocation: sourceLocation)
        #expect(report.unlabeled.isEmpty, "\(screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })", sourceLocation: sourceLocation)
        return report
    }

    @Test func lists() {
        let host = Host(NotebookListsView(model: NotebookSamples.lists), size: CGSize(width: 220, height: 900))
        defer { host.tearDown() }
        audit(host, "Notebook lists")
    }

    @Test func noteList() {
        for (name, model) in [("note list", NotebookSamples.noteList), ("note list search", NotebookSamples.searchList)] {
            let view = NoteListView(model: model)
            view.menuPresenter = InlineMenuPresenter()
            let host = Host(view, size: CGSize(width: 300, height: 900))
            audit(host, "Notebook \(name)")
            if name == "note list" {
                view.openSortMenu()
                audit(host, "Notebook note list › sort menu")
            }
            host.tearDown()
        }
    }

    /// The top bar, info panel, doc status and footer, then every top-bar menu open in place.
    @Test func editorChromeAndMenus() {
        let chrome = NoteEditorChromeView(model: NotebookSamples.n1Chrome)
        chrome.menuPresenter = InlineMenuPresenter()
        let host = Host(chrome, size: CGSize(width: 848, height: 876))
        defer { host.tearDown() }
        audit(host, "Notebook editor chrome")
        for menu in NoteChromeMenu.allCases {
            chrome.openMenu(menu)
            audit(host, "Notebook editor › \(menu.rawValue) menu")
            chrome.closeMenu()
        }
        chrome.update(NotebookSamples.unsavedChrome)
        audit(host, "Notebook editor chrome (unsaved)")
    }

    @Test func infoPanelAndAccessories() {
        let info = Host(NoteInfoPanelView(model: NotebookSamples.n1Info), size: CGSize(width: 240, height: 824))
        audit(info, "Notebook info panel")
        info.tearDown()
        let chips = Host(NoteChipsRowView(model: NotebookSamples.n1ChipsRow), size: CGSize(width: 524, height: 20))
        audit(chips, "Notebook chips row")
        chips.tearDown()
        let annotations = Host(ImageAnnotationSummaryView(model: NotebookSamples.n1Annotations), size: CGSize(width: 420, height: 300))
        audit(annotations, "Notebook annotation summary")
        annotations.tearDown()
    }

    @Test func drawer() {
        for (name, model) in [("drawer", NotebookSamples.drawer), ("drawer without files", NotebookSamples.drawerWithoutFiles),
                              ("drawer editing", NotebookSamples.drawerEditing)] {
            let host = Host(NotesDrawerView(model: model), size: CGSize(width: 300, height: 900))
            audit(host, "Notebook \(name)")
            host.tearDown()
        }
    }

    @Test func historyCompare() {
        TestFonts.register()
        let view = HistoryCompareView(model: NotebookSamples.historyCompare)
        let host = Host(view, size: view.preferredSize)
        defer { host.tearDown() }
        audit(host, "Notebook history compare")
    }

    @Test func pickers() {
        TestFonts.register()
        let link = LinkPickerView(model: NotebookSamples.linkPicker)
        let linkHost = Host(link, size: link.preferredSize)
        audit(linkHost, "Notebook link picker")
        linkHost.tearDown()
        let tags = TagEditorView(model: NotebookSamples.tagEditor)
        let tagHost = Host(tags, size: tags.preferredSize)
        audit(tagHost, "Notebook tag editor")
        tagHost.tearDown()
    }

    /// D21 keyboard: the list rows step with ↑ ↓, a note row reads as one element, the menu keeps
    /// the focus for its rows.
    @Test func listsStepWithArrowsAndRowsReadAsOne() throws {
        let host = Host(NotebookListsView(model: NotebookSamples.lists), size: CGSize(width: 220, height: 900))
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = nil
            host.tearDown()
        }
        KeyboardFocus.fullKeyboardAccessOverride = true
        let inbox = try #require(host.view.smartRow(.inbox))
        let pinned = try #require(host.view.smartRow(.pinned))
        #expect(KeyboardFocus.focusAsKeyboardNavigation(inbox))
        inbox.keyDown(with: Keys.down)
        #expect(host.window.firstResponder === pinned)
        pinned.keyDown(with: Keys.up)
        #expect(host.window.firstResponder === inbox)
        KeyboardFocus.fullKeyboardAccessOverride = false
        #expect(!pinned.acceptsFirstResponder, "no key view without Full Keyboard Access")

        let row = NoteListRowView(row: NotebookSamples.n1Row, actions: [])
        #expect(!row.acceptsFirstResponder, "the list keeps the focus")
        let label = row.accessibilityLabel() ?? ""
        #expect(label.hasPrefix(NotebookSamples.n1Row.title) || label.contains(NotebookSamples.n1Row.title))
        #expect(label.contains(NotebookSamples.n1Row.time) && label.contains("AI"))
    }
}
