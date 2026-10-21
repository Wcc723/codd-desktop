import AppKit
import CoddUI
import Testing
@testable import CoddCodeEditor

/// M4 layout sweep: the find widget stays inside a narrow editor (a small window at UI 字級 20):
/// the query field gives way, down to 80, instead of the widget running over the file tree.
@Suite("Find widget layout")
@MainActor
struct FindWidgetLayoutTests {
    @Test func theQueryFieldNarrowsToTheEditorsWidth() {
        let widget = FindWidgetView(style: CodeEditorStyle())
        let full = widget.boxSize.width
        #expect(widget.fieldWidth == CodeEditorStyle().findFieldWidth, "the style's width with room")
        widget.maximumBoxWidth = full - 50
        #expect(widget.boxSize.width == full - 50 && widget.fieldWidth == CodeEditorStyle().findFieldWidth - 50)
        widget.maximumBoxWidth = 10
        #expect(widget.fieldWidth == 80, "never under 80")
        widget.maximumBoxWidth = .greatestFiniteMagnitude
        #expect(widget.boxSize.width == full)
    }
}
