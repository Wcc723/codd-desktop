import AppKit
import CoddUI
import Testing
@testable import CoddFileEditorUI

/// M5 D21: the FileEditor chrome (tree, tabs, toolbar, banner, status items, the dirty-close
/// sheet), built from the samples in an offscreen window, has no unlabeled interactive element
/// (CoddUI's `AccessibilityAudit`); the elements outside the key-view loop are printed for the
/// report, not failed. The custom-drawn tree rows, tabs, crumbs and status items are elements of
/// their own, and the tree is a keyboard list.
@MainActor
@Suite struct AccessibilityAuditTests {
    private func check(_ report: AccessibilityAudit.Report, sourceLocation: SourceLocation = #_sourceLocation) {
        print("A11Y \(report.screen): interactive \(report.interactive), unlabeled \(report.unlabeled.count), outsideKeyLoop \(report.outsideKeyLoop.count)")
        for finding in report.outsideKeyLoop {
            print("A11Y   \(report.screen) outside key loop: \(finding.role) \(finding.path) \(finding.label ?? "")")
        }
        #expect(report.interactive > 0, "\(report.screen): nothing interactive found", sourceLocation: sourceLocation)
        #expect(report.unlabeled.isEmpty, "\(report.screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })", sourceLocation: sourceLocation)
    }

    @Test func composition() {
        let host = Host(FileEditorComposition(), size: NSSize(width: 1440, height: 900))
        defer { host.tearDown() }
        host.layout()
        check(AccessibilityAudit.audit(window: host.window, screen: "FILE EDITOR"))
    }

    /// Each part on its own (the per-part counts of the report).
    @Test func partsOnTheirOwn() {
        let editor = FileEditorComposition()
        let host = Host(editor, size: NSSize(width: 1440, height: 900))
        defer { host.tearDown() }
        host.layout()
        let parts: [(String, NSView)] = [("tree", editor.tree), ("tabs", editor.tabs), ("toolbar", editor.toolbar), ("banner", editor.banner),
                                         ("status items", editor.statusItems)]
        for (name, view) in parts {
            check(AccessibilityAudit.audit(view: view, screen: "FILE EDITOR \(name)"))
        }
    }

    @Test func dirtyCloseSheet() {
        for sheet in [DirtyCloseSheetView(fileName: "punch.vue"),
                      DirtyCloseSheetView(title: "3 個檔案有未儲存的變更", hint: "不儲存的話，這些修改會遺失。", saveTitle: "儲存全部")] {
            let host = Host(sheet, size: NSSize(width: DirtyCloseSheetView.width, height: DirtyCloseSheetView.height))
            check(AccessibilityAudit.audit(window: host.window, screen: "FILE EDITOR dirty-close sheet \(sheet.title)"))
            host.tearDown()
        }
    }

    @Test func drawnItemsAreElements() throws {
        let editor = FileEditorComposition()
        let host = Host(editor, size: NSSize(width: 1440, height: 900))
        defer { host.tearDown() }
        host.layout()
        let rows = (editor.tree.list.accessibilityChildren() ?? []).compactMap { $0 as? TreeItemElement }
        #expect(rows.count == editor.tree.list.placed.count)
        #expect(rows.contains { $0.isAccessibilitySelected() }, "the open file is selected")
        #expect(rows.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty })
        let tabs = (editor.tabs.tabsArea.accessibilityChildren() ?? []).compactMap { $0 as? EditorTabElement }
        #expect(tabs.count == FileEditorSamples.tabs().tabs.count)
        #expect(tabs.filter { $0.isAccessibilitySelected() }.count == 1)
        #expect(tabs.allSatisfy { $0.accessibilityCustomActions()?.first?.name.hasPrefix("關閉 ") == true })
        let items = editor.statusItems.accessibilityChildren() ?? []
        #expect(!items.isEmpty)
        #expect((items.first as? DrawnItemElement)?.accessibilityLabel()?.hasPrefix("游標位置 Ln ") == true)
    }

    /// D21 keyboard: the tree takes ↑ ↓ and ⏎ / space, folders → ←; the tab strip ← →.
    @Test func treeAndTabsByKeyboard() throws {
        let editor = FileEditorComposition()
        let host = Host(editor, size: NSSize(width: 1440, height: 900))
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = nil
            host.tearDown()
        }
        host.layout()
        var opened: [(String, Bool)] = []
        var sections: [FileTreeSection] = []
        editor.tree.onOpen = { opened.append(($0, $1)) }
        editor.tree.onToggleSection = { sections.append($0) }
        KeyboardFocus.fullKeyboardAccessOverride = true
        let list = editor.tree.list
        #expect(host.window.makeFirstResponder(list))
        let start = try #require(list.keyIndex)
        list.keyDown(with: Self.key(125, "\u{F701}"))
        #expect(list.keyIndex == min(start + 1, list.placed.count - 1))
        // Walk to the first file and open it with ⏎ (a kept tab) and space (a preview).
        let file = try #require(list.placed.firstIndex {
            if case .row(let row, _) = $0.item, case .file = row.kind { return true }
            return false
        })
        for _ in list.placed.indices where (list.keyIndex ?? 0) > file { list.keyDown(with: Self.key(126, "\u{F700}")) }
        for _ in list.placed.indices where (list.keyIndex ?? 0) < file { list.keyDown(with: Self.key(125, "\u{F701}")) }
        #expect(list.keyIndex == file)
        list.keyDown(with: Self.key(36, "\r"))
        list.keyDown(with: Self.key(49, " "))
        #expect(opened.count == 2 && opened[0].1 == false && opened[1].1 == true)
        // Back to the top (a section head) and fold it with ←.
        for _ in list.placed.indices where (list.keyIndex ?? 0) > 0 { list.keyDown(with: Self.key(126, "\u{F700}")) }
        list.keyDown(with: Self.key(123, "\u{F702}"))
        #expect(sections.count == 1)

        var selected: [String] = []
        editor.tabs.onSelect = { selected.append($0) }
        #expect(host.window.makeFirstResponder(editor.tabs.tabsArea))
        let model = FileEditorSamples.tabs()
        let current = model.tabs.firstIndex { $0.id == model.selectedID } ?? -1
        editor.tabs.tabsArea.keyDown(with: Self.key(124, "\u{F703}"))
        #expect(selected == (model.tabs.indices.contains(current + 1) ? [model.tabs[current + 1].id] : []), "→ selects the next tab")
        KeyboardFocus.fullKeyboardAccessOverride = false
        #expect(!list.acceptsFirstResponder, "no key view without Full Keyboard Access")
    }

    private static func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}
