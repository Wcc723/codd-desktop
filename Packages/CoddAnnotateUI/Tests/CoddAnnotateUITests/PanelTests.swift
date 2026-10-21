import AppKit
import CoddUI
import Testing
@testable import CoddAnnotateUI

/// The artboard texts, the list, the coordinate fields, the IME-safe comment, send options and the
/// AI preview.
@Suite("Panel", .serialized)
@MainActor
struct PanelTests {
    @Test func artboardTextsAppear() {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let top = h.view.topBar.annotateTexts
        #expect(top.contains("INBOX / 打卡頁 RWD 跑版紀錄 / 9f3a1c.png 標註模式 ⌘⇧A"))
        #expect(top.contains("assets/rwd-punch-k7x2/9f3a1c.png · 750×1334 px · iPhone SE @2x · 截圖 2026-10-15 09:32"))
        #expect(top.contains("取消") && top.contains("完成"))
        let stage = h.view.stage.annotateTexts
        #expect(stage.contains("拖曳控制點調整大小 · ⇧ 鎖定比例 · Del 刪除 · ⎋ 結束標註"))
        let strip = h.view.toolStrip
        #expect(strip.toolButtons.map { $0.1.keyLetter } == ["V", "R", "P", "A", "T"])
        #expect(strip.button(.select)?.isOn == true && strip.button(.rect)?.isOn == false)
        #expect(strip.annotateTexts.contains("ZOOM"))
        #expect(strip.zoomSwitch.displayedText == "FIT 100% 200%")
        let panel = h.view.panel.annotateTexts
        for text in ["ANNOTATIONS 3", "依建立順序編號", "RECT 框選", "已選取", "X", "Y", "W", "H", "20", "1150", "710", "120",
                     "說明 · COMMENT", ImageAnnotateSamples.document.items[0].note, "單位 px（原圖）· Del", "刪除",
                     "2 POINT 時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px x 375 · y 330",
                     "3 ARROW 打卡紀錄卡片離按鈕太近，間距加到 16px x 600 · y 760 → x 700 · y 1080",
                     "送給 AI 時", "附上原圖 9f3a1c.png", "附上標註後的圖（燒進框線與編號）", "附上座標清單", "AI 會收到",
                     "notes_read · 送到 session", "Markdown 原始碼（codd-annotations 區塊）"] {
            #expect(panel.contains(text), "\(text)")
        }
        #expect(h.panel.term.displayedText == ImageAnnotateSamples.previewText(h.view.document))
        #expect(h.view.statusText == "標註模式 · 3 個標註")
    }

    @Test func artboardGeometry() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        #expect(h.view.topBar.frame.height == 52)
        #expect(h.view.toolStrip.frame == CGRect(x: 0, y: 52, width: 48, height: 824))
        #expect(h.view.panel.frame == CGRect(x: 988, y: 52, width: 380, height: 824))
        let tools = h.view.toolStrip.toolButtons.map(\.1.frame)
        #expect(tools.map(\.minY) == [10, 50, 90, 130, 170])
        #expect(tools.allSatisfy { $0.size == CGSize(width: 36, height: 36) })
        #expect(h.view.toolStrip.colorButton.frame.minY == 227)
        let expanded = try #require(h.expanded)
        #expect(expanded.frame.minX == 16 && expanded.frame.width == 347)
        #expect(h.panel.rows.map { $0.frame.height } == [52, 52])
        #expect(expanded.fields.map { $0.1.frame.height } == [26, 26, 26, 26])
    }

    @Test func rowsSelectAndCollapse() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        #expect(h.panel.rows.map(\.item.n) == [2, 3])
        _ = h.panel.rows[0].accessibilityPerformPress()
        #expect(h.view.selection == 2)
        #expect(h.expanded?.item.n == 2)
        #expect(h.expanded?.fields.map { $0.1.label } == ["X", "Y"])
        #expect(h.panel.rows.map(\.item.n) == [1, 3])
        h.view.selection = 3
        #expect(h.expanded?.fields.map { $0.1.label } == ["X1", "Y1", "X2", "Y2"])
        #expect(h.expanded?.fields.map { $0.1.displayedText } == ["600", "760", "700", "1080"])
        h.expanded?.collapseButton.press()
        #expect(h.view.selection == nil && h.expanded == nil)
        #expect(h.panel.rows.count == 3)
        #expect(h.changes.isEmpty)
    }

    @Test func fieldEditsCommitOnEnterAndBlur() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        h.type("40", in: .x)
        #expect(h.view.document.item(1)?.x == 40)
        #expect(h.changes.count == 1)
        // Clamped to the image: W ends at its right edge.
        h.type("9999", in: .w)
        #expect(h.view.document.item(1)?.w == 710, "x 40 + 710 = 750 already")
        h.type("1100", in: .y, enter: false)
        #expect(h.view.document.item(1)?.y == 1100, "blur commits")
        #expect(h.window.firstResponder === h.canvas)
        h.view.selection = 3
        h.type("720", in: .x2)
        #expect(h.view.document.item(3)?.x2 == 720)
        h.type("１０００", in: .y2)
        #expect(h.view.document.item(3)?.y2 == 1000, "full-width digits")
        #expect(h.changes.count == 4)
    }

    @Test func invalidFieldInputIsRestored() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        h.type("abc", in: .x)
        #expect(h.view.document.item(1)?.x == 20)
        #expect(h.expanded?.field(.x)?.displayedText == "20")
        h.type("", in: .h, enter: false)
        #expect(h.view.document.item(1)?.h == 120)
        #expect(h.expanded?.field(.h)?.displayedText == "120")
        #expect(h.changes.isEmpty)
        #expect(h.view.undoManager?.canUndo == false, "no undo step for a rejected value")
        // ⎋ in a field puts the stored value back.
        let editor = h.focus(.w)
        editor.selectAll(nil)
        editor.insertText("5", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(h.expanded?.field(.w)?.displayedText == "710")
    }

    @Test func aPendingFieldEditStaysWithItsItem() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let editor = h.focus(.x)
        editor.selectAll(nil)
        editor.insertText("33", replacementRange: editor.selectedRange())
        // Clicking another row while X still edits: the edit lands on item 1, never on item 2.
        _ = h.panel.rows[0].accessibilityPerformPress()
        #expect(h.view.selection == 2)
        #expect(h.view.document.item(1)?.x == 33)
        #expect(h.view.document.item(2)?.x == 375)
        #expect(h.window.firstResponder === h.canvas, "focus goes back to the canvas")
    }

    @Test func commentIsIMESafe() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let original = ImageAnnotateSamples.document.items[0].note
        let text = h.commentView
        h.window.makeFirstResponder(text)
        text.selectAll(nil)
        text.insertText("改用 sticky", replacementRange: text.selectedRange())
        text.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        #expect(h.view.document.item(1)?.note == original, "nothing is stored while composing")
        #expect(h.changes.isEmpty)
        // 完成 stores the committed text, never the composing range.
        h.view.done()
        #expect(h.done.last?.item(1)?.note == "改用 sticky")
        #expect(h.changes.count == 1)
    }

    @Test func commentCommitsOnBlurAsOneStep() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let original = ImageAnnotateSamples.document.items[0].note
        let text = h.commentView
        h.window.makeFirstResponder(text)
        text.selectAll(nil)
        text.insertText("按鈕被蓋住", replacementRange: text.selectedRange())
        text.insertText("了", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.view.document.item(1)?.note == original, "typing alone stores nothing")
        h.view.focusCanvas()
        #expect(h.view.document.item(1)?.note == "按鈕被蓋住了")
        #expect(h.changes.count == 1)
        #expect(h.panel.rows.isEmpty == false)
        h.view.undo()
        #expect(h.view.document.item(1)?.note == original)
        #expect(h.commentView.string == original)
    }

    @Test func toolKeysWorkOnlyOnTheCanvas() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        h.view.focusCanvas()
        for (character, code, tool) in [("r", AnnotateHarness.keyR, AnnotateTool.rect), ("p", AnnotateHarness.keyP, .point),
                                        ("a", AnnotateHarness.keyA, .arrow), ("t", AnnotateHarness.keyT, .text),
                                        ("v", AnnotateHarness.keyV, .select)] {
            h.press(character, keyCode: code)
            #expect(h.view.tool == tool)
            #expect(h.view.toolStrip.button(tool)?.isOn == true)
        }
        // A coordinate field edits: R is a character, not a tool.
        h.focus(.x)
        h.press("r", keyCode: AnnotateHarness.keyR)
        #expect(h.view.tool == .select)
        // The comment area: P neither.
        h.window.makeFirstResponder(h.commentView)
        h.press("p", keyCode: AnnotateHarness.keyP)
        #expect(h.view.tool == .select)
        // The canvas ignores a key that reaches it while it is not focused.
        h.canvas.keyDown(with: h.key("a", keyCode: AnnotateHarness.keyA))
        #expect(h.view.tool == .select)
        // The strip buttons switch tools and zoom.
        h.view.toolStrip.button(.arrow)?.press()
        #expect(h.view.tool == .arrow)
        h.view.toolStrip.zoomSwitch.select(2)
        #expect(h.view.zoom == .double && h.view.canvasScale == 2)
    }

    @Test func sendOptionsAreUndoableEdits() {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        #expect(h.view.document.send == AnnotationSendOptions(original: false, annotated: true, list: true))
        h.panel.sendOriginal.toggle()
        #expect(h.view.document.send.original)
        #expect(h.panel.term.displayedText.contains("/9f3a1c.png (750×1334)"))
        h.panel.sendList.toggle()
        #expect(!h.view.document.send.list)
        #expect(!h.panel.term.displayedText.contains("annotations"))
        #expect(h.changes.count == 2)
        h.view.undo()
        h.view.undo()
        #expect(h.view.document.send == AnnotationSendOptions())
        #expect(!h.panel.sendOriginal.isOn && h.panel.sendList.isOn)
    }

    @Test func markdownDisclosureShowsTheBlock() {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        #expect(h.panel.markdownBox.isHidden)
        h.panel.disclosure.toggle()
        h.settle()
        #expect(!h.panel.markdownBox.isHidden)
        #expect(h.panel.markdownBox.displayedText.hasPrefix("```codd-annotations"))
        #expect(h.panel.markdownBox.frame.height > 100)
        h.panel.disclosure.toggle()
        #expect(h.panel.markdownBox.isHidden)
    }

    @Test func emptyDocumentShowsTheEmptyLine() {
        let h = AnnotateHarness(document: AnnotationDocument(pixelSize: ImageAnnotateSamples.pixelSize))
        defer { h.tearDown() }
        let texts = h.view.panel.annotateTexts
        #expect(texts.contains("ANNOTATIONS 0"))
        #expect(texts.contains("// 還沒有標註 · 選工具後在圖上點按或拖曳"))
        #expect(h.view.statusText == "標註模式 · 0 個標註")
    }

    @Test func previewStylingFollowsTheAIText() throws {
        let home = "/Users/someone"
        let text = """
        [image] /Users/someone/notes/assets/a/9f3a1c.annotated.png (750×1334)
        annotations（原圖像素，左上為原點）:
          1 rect  x=20 y=1150 w=710 h=120  上班打卡按鈕被底部導覽列蓋住
          3 arrow 600,760 → 700,1080  間距
        """
        let styled = PreviewStyler.attributed(text, width: 326, home: home)
        let string = styled.string as NSString
        func color(of needle: String, offset: Int = 0) -> NSColor? {
            let range = string.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return styled.attribute(.foregroundColor, at: range.location + offset, effectiveRange: nil) as? NSColor
        }
        #expect(color(of: "[image]") == Palette.termDim)
        #expect(color(of: "~/") == Palette.cyan, "the home folder shows as ~")
        #expect(color(of: "(750×1334)") == Palette.termDim)
        #expect(color(of: "（原圖像素") == Palette.termDim)
        #expect(color(of: "  1 rect", offset: 2) == Palette.amber)
        #expect(color(of: "rect") == Palette.cyan)
        #expect(color(of: "x=20") == Palette.termForeground)
        #expect(color(of: "上班") == Palette.cream)
        #expect(color(of: "arrow") == Palette.cyan)
        #expect(color(of: "間距") == Palette.cream)
        // The long comment drops to its own line; the short one stays after its coordinates.
        #expect(string.range(of: "\u{2028}上班").location != NSNotFound)
        #expect(string.range(of: "1080  間距").location != NSNotFound)
    }
}
