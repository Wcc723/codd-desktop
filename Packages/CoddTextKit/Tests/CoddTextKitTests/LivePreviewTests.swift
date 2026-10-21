import AppKit
import CoddUI
import Testing
@testable import CoddTextKit

/// A fixed-height accessory for line-height checks.
@MainActor
final class FixedAccessory: NSView, MarkdownAccessorySizing {
    let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    func markdownAccessoryHeight(forWidth width: CGFloat) -> CGFloat { height }
}

@Suite("Live preview", .serialized)
@MainActor
struct LivePreviewTests {
    let style = MarkdownEditorStyle.notebook

    private func n1Harness(caret: Int? = nil, resolver: Bool = true) -> EditorHarness {
        let harness = EditorHarness()
        if resolver {
            harness.editor.imageResolver = { path in
                path == MarkdownSamples.n1ImagePath ? MarkdownSamples.n1ImageInfo(image: nil) : nil
            }
        }
        harness.load(MarkdownSamples.n1, caret: caret)
        return harness
    }

    @Test func theEditorIsTextKit1() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        let textView = harness.editor.textViewForTesting
        #expect(textView.textLayoutManager == nil)
        #expect(textView.layoutManager === harness.editor.layoutManagerRef)
        #expect(textView.layoutManager is MarkdownLayoutManager)
        #expect(textView.textContainer === harness.editor.container)
        // Smart substitutions are off.
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isRichText)
    }

    @Test func marksAreHiddenOffTheCaretAndShownOnIt() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let text = harness.text
        let h2 = harness.location(of: "## 問題")
        let safari = harness.location(of: "- **Safari")
        let code = harness.location(of: "`/punch`")
        // Caret at the very end (the empty last line): nothing revealed.
        #expect(harness.isHidden(h2) && harness.isHidden(h2 + 1) && harness.isHidden(h2 + 2))
        #expect(!harness.isHidden(h2 + 3))
        #expect(harness.glyphWidth(h2) == 0)
        #expect(harness.isHidden(safari) && harness.isHidden(safari + 1))
        #expect(harness.isHidden(safari + 2) && harness.isHidden(safari + 3))
        #expect(harness.isHidden(code))
        #expect(!harness.isHidden(code + 1))
        // The caret on the Safari line shows its `**` (dimmed), the list marker stays a bullet.
        harness.select(MarkdownSamples.n1CaretLocation)
        #expect(!harness.isHidden(safari + 2) && !harness.isHidden(safari + 3))
        #expect(harness.glyphWidth(safari + 2) > 0)
        #expect(harness.isHidden(safari) && harness.isHidden(safari + 1))
        let markColor = harness.editor.storage.attribute(.foregroundColor, at: safari + 2, effectiveRange: nil) as? NSColor
        #expect(markColor == style.mark)
        // Other lines stay hidden.
        #expect(harness.isHidden(h2))
        // Moving to the heading shows its `## `.
        harness.select(h2 + 4)
        #expect(!harness.isHidden(h2))
        #expect(harness.isHidden(safari + 2))
        _ = text
    }

    @Test func withoutFocusNothingIsRevealed() {
        let harness = n1Harness(caret: MarkdownSamples.n1CaretLocation)
        defer { harness.tearDown() }
        let safari = harness.location(of: "- **Safari")
        #expect(!harness.isHidden(safari + 2))
        harness.window.makeFirstResponder(nil)
        harness.settle()
        #expect(harness.isHidden(safari + 2))
        harness.editor.revealsCaretLineWhenInactive = true
        harness.settle()
        #expect(!harness.isHidden(safari + 2))
    }

    @Test func sourceModeHidesNothing() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.editor.mode = .source
        harness.settle()
        let all = harness.editor.storage.length
        for index in 0 ..< all where harness.isHidden(index) {
            Issue.record("hidden in source mode at \(index)")
            break
        }
        let json = harness.location(of: "{\"v\":1")
        #expect(harness.fragment(at: json).height > 0)
        let font = harness.editor.storage.attribute(.font, at: harness.location(of: "問題"), effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == style.sourceFont.pointSize)
    }

    @Test func theAnnotationFenceHasZeroHeight() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let open = harness.location(of: "```codd-annotations")
        let json = harness.location(of: "{\"v\":1")
        let close = harness.location(of: "```\n\n## 想請")
        for index in [open, json, json + 40, close] {
            #expect(harness.fragment(at: index).height == 0, "at \(index)")
        }
        // A plain code block's fences are hidden too, its code is not.
        let css = harness.location(of: "```css")
        #expect(harness.fragment(at: css).height == 0)
        #expect(harness.fragment(at: harness.location(of: "@media")).height > 0)
    }

    @Test func theCaretNeverRestsInsideAHiddenFence() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let image = harness.location(of: "![截圖")
        let json = harness.location(of: "{\"v\":1")
        let after = harness.location(of: "\n## 想請") // the blank line after the fence
        harness.select(image)
        harness.select(json)
        #expect(harness.caret == after, "moving forward lands on the line after the fence")
        harness.select(after + 1)
        harness.select(json + 3)
        // Moving backward lands at the end of the image line.
        let imageLineEnd = harness.location(of: "\n```codd-annotations")
        #expect(harness.caret == imageLineEnd)
    }

    @Test func decorationHeights() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let titleHeight = style.titleFont.pointSize * style.titleLineHeight
        #expect(abs(harness.fragment(at: 2).height - titleHeight) < 0.01)
        harness.editor.titleAccessory = FixedAccessory(height: 20)
        harness.settle()
        #expect(abs(harness.fragment(at: 2).height - (titleHeight + style.titleAccessoryGap + 20)) < 0.01)
        // The accessory sits under the title line.
        let accessory = harness.editor.titleAccessory!
        #expect(accessory.superview === harness.textView)
        #expect(abs(accessory.frame.minY - (style.padding.top + titleHeight + style.titleAccessoryGap)) < 0.5)
        #expect(abs(accessory.frame.minX - style.padding.left) < 0.5)
        // A blank line is a full body line, on the caret or not (it never resizes when the caret
        // crosses it); the H2 after it has its margin, rule and padding.
        let blank = harness.location(of: "\n## 問題") + 1 - 1
        #expect(abs(harness.fragment(at: blank).height - style.bodyFont.pointSize * style.bodyLineHeight) < 0.01)
        let h2 = harness.location(of: "## 問題")
        let h2Height = style.heading2Font.pointSize * style.heading2LineHeight + style.heading2Margin + 1 + style.heading2RulePadding
        #expect(abs(harness.fragment(at: h2 + 3).height - h2Height) < 0.01)
        // The image line becomes the figure row: 2 + plate (220 + 2 × 8) + 6 + caption 17 + 2.
        let image = harness.location(of: "![截圖")
        let caption = ceil(style.captionFont.pointSize * style.captionLineHeight)
        let row = style.figureRowPadding * 2 + 220 + 2 * (style.figurePadding + 1) + style.figureCaptionGap + caption
        #expect(abs(harness.fragment(at: image).height - row) < 0.01)
        // With an accessory taller than the figure, the row follows the accessory.
        harness.editor.imageAccessoryProvider = { _ in FixedAccessory(height: 300) }
        harness.settle()
        #expect(abs(harness.fragment(at: image).height - (300 + 2 * style.figureRowPadding)) < 0.01)
        // On the caret, the raw line shows above the figure.
        harness.select(image + 3)
        let body = style.bodyFont.pointSize * style.bodyLineHeight
        #expect(abs(harness.fragment(at: image).height - (body + style.figureRevealGap + 300 + 2 * style.figureRowPadding)) < 0.01)
        #expect(!harness.isHidden(image + 3))
    }

    @Test func anUnresolvedImageIsShownAsText() {
        let harness = n1Harness(resolver: false)
        defer { harness.tearDown() }
        let image = harness.location(of: "![截圖")
        #expect(!harness.isHidden(image + 3))
        #expect(abs(harness.fragment(at: image).height - style.bodyFont.pointSize * style.bodyLineHeight) < 0.01)
    }

    @Test func figureAccessoriesArePlacedRightOfTheFigure() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let accessory = FixedAccessory(height: 120)
        harness.editor.imageAccessoryProvider = { _ in accessory }
        harness.settle()
        let figure = harness.editor.figureFrames(forBlock: harness.editor.blocks.firstIndex { if case .image = $0.kind { true } else { false } }!)!
        #expect(accessory.superview === harness.textView)
        #expect(abs(accessory.frame.minX - (style.padding.left + figure.accessory!.minX)) < 0.5)
        #expect(accessory.frame.minX >= style.padding.left + figure.plate.maxX + style.accessoryGap - 0.5)
        #expect(abs(accessory.frame.width - (harness.editor.container.size.width - figure.accessory!.minX)) < 0.5)
        // Source mode: no decorations, so no accessory.
        harness.editor.mode = .source
        harness.settle()
        #expect(accessory.superview == nil)
    }

    @Test func overlayGeometryMapsOriginalPixels() {
        // SPEC §5 / R6: a 750 × 1334 screenshot shown 220 pt tall (the artboard's 124 × 220).
        let info = MarkdownSamples.n1ImageInfo(image: nil)
        let figure = FigureGeometry.make(info: info, contentWidth: 676, style: style, accessoryHeight: 0, hasAccessory: false)
        #expect(figure.image.height == 220)
        #expect(figure.image.width == 124)
        let image = figure.image
        let rect = ImageOverlayGeometry.rect(CGRect(x: 20, y: 1150, width: 710, height: 120), pixelSize: info.pixelSize, in: image)
        // The artboard's percentages: left 2.667 %, top 86.207 %, width 94.667 %, height 8.996 %.
        #expect(abs((rect.minX - image.minX) / image.width - 0.02667) < 0.0005)
        #expect(abs((rect.minY - image.minY) / image.height - 0.86207) < 0.0005)
        #expect(abs(rect.width / image.width - 0.94667) < 0.0005)
        #expect(abs(rect.height / image.height - 0.08996) < 0.0005)
        let point = ImageOverlayGeometry.pinCenter(.point(n: 2, CGPoint(x: 375, y: 330), color: nil), pixelSize: info.pixelSize, in: image)
        #expect(abs((point.x - image.minX) / image.width - 0.5) < 0.0005)
        #expect(abs((point.y - image.minY) / image.height - 0.24738) < 0.0005)
        let arrowPin = ImageOverlayGeometry.pinCenter(MarkdownSamples.n1Annotations[2], pixelSize: info.pixelSize, in: image)
        #expect(abs((arrowPin.x - image.minX) / image.width - 0.8) < 0.0005)
        #expect(abs((arrowPin.y - image.minY) / image.height - 0.56972) < 0.0005)
        let tip = ImageOverlayGeometry.point(CGPoint(x: 700, y: 1080), pixelSize: info.pixelSize, in: image)
        let arrow = ImageOverlayGeometry.arrow(from: arrowPin, to: tip, headLength: 8, headHalfWidth: 4.5)
        #expect(arrow.head[0] == tip)
        #expect(abs(hypot(tip.x - arrow.shaftEnd.x, tip.y - arrow.shaftEnd.y) - 8) < 0.001)
        // The plate: 7 pt padding + 1 pt border around the image.
        #expect(figure.plate.width == CGFloat(140))
        #expect(figure.plate.height == CGFloat(236))
    }

    @Test func wideImagesLeaveRoomForTheAccessory() {
        let wide = MarkdownImageInfo(path: "w.png", image: nil, pixelSize: CGSize(width: 3000, height: 600), caption: "")
        let with = FigureGeometry.make(info: wide, contentWidth: 676, style: style, accessoryHeight: 80, hasAccessory: true)
        #expect(with.plate.width <= 676 - style.accessoryMinWidth - style.accessoryGap + 0.5)
        #expect(with.accessory!.width >= style.accessoryMinWidth - 0.5)
        let without = FigureGeometry.make(info: wide, contentWidth: 676, style: style, accessoryHeight: 0, hasAccessory: false)
        #expect(without.plate.width <= 676 + 0.5)
        #expect(without.image.height <= style.figureMaxHeight)
        // A small @2x image is never shown larger than its point size.
        let small = MarkdownImageInfo(path: "s.png", image: nil, pixelSize: CGSize(width: 100, height: 60), caption: "")
        #expect(FigureGeometry.make(info: small, contentWidth: 676, style: style, accessoryHeight: 0, hasAccessory: false).image.width == 50)
    }

    @Test func foldingHidesTheSectionUntilTheNextH2() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let h2 = harness.location(of: "## 問題")
        let paragraph = harness.location(of: "iPhone SE")
        let nextH2 = harness.location(of: "## 想請")
        harness.editor.setFolded(true, headingAt: h2)
        harness.settle()
        #expect(harness.editor.foldedHeadingLocations == [h2])
        #expect(harness.fragment(at: paragraph).height == 0)
        #expect(harness.fragment(at: harness.location(of: "![截圖")).height == 0)
        #expect(harness.fragment(at: nextH2 + 3).height > 0)
        #expect(harness.isHidden(paragraph))
        // The caret skips the folded lines.
        harness.select(h2 + 4)
        harness.select(paragraph + 2)
        #expect(harness.caret >= nextH2 - 1)
        // The text never changed; unfolding restores the lines.
        #expect(harness.text == MarkdownSamples.n1)
        harness.editor.setFolded(false, headingAt: h2)
        harness.settle()
        #expect(harness.fragment(at: paragraph).height > 0)
        #expect(harness.textChanges.isEmpty)
    }

    @Test func clickingTheFoldGlyphFolds() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let h2 = harness.location(of: "## 問題")
        let line = harness.editor.textLineRect(forCharacterAt: h2 + 3)!
        let point = NSPoint(x: style.padding.left - style.foldGlyphOffset + 3, y: line.midY)
        #expect(harness.editor.handleClick(at: point, clickCount: 1, modifiers: []))
        harness.settle()
        #expect(harness.editor.foldedHeadingLocations == [h2])
    }

    @Test func listsTasksAndCodeAreStyled() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let storage = harness.editor.storage
        let task = harness.location(of: "- [x] 先重現")
        let box = task + 2
        #expect(storage.attribute(.foregroundColor, at: box, effectiveRange: nil) as? NSColor == style.taskBox)
        #expect(storage.attribute(.foregroundColor, at: box + 1, effectiveRange: nil) as? NSColor == style.taskCheck)
        let done = harness.location(of: "先重現")
        #expect(storage.attribute(.strikethroughStyle, at: done, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(storage.attribute(.foregroundColor, at: done, effectiveRange: nil) as? NSColor == style.doneText)
        let media = harness.location(of: "@media")
        #expect(storage.attribute(.foregroundColor, at: media, effectiveRange: nil) as? NSColor == style.codeKeyword)
        #expect((storage.attribute(.font, at: media, effectiveRange: nil) as? NSFont)?.pointSize == style.codeFont.pointSize)
        let px = harness.location(of: "640px)")
        #expect(storage.attribute(.foregroundColor, at: px, effectiveRange: nil) as? NSColor == style.codeString)
        let inline = harness.location(of: "/punch`")
        #expect(storage.attribute(.coddInlineCode, at: inline, effectiveRange: nil) != nil)
        #expect(storage.attribute(.foregroundColor, at: inline, effectiveRange: nil) as? NSColor == style.inlineCodeText)
        let bold = harness.location(of: "Safari")
        #expect((storage.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
            || (storage.attribute(.font, at: bold, effectiveRange: nil) as? NSFont) == style.boldFont)
        // (CJK characters get the fallback font NSTextStorage substitutes; check a Latin one.)
        let title = storage.attribute(.font, at: harness.location(of: "RWD"), effectiveRange: nil) as? NSFont
        #expect(title == style.titleFont)
        // The task text starts at the artboard's 36 pt (box 30 + gap 6).
        let first = harness.location(of: "先重現")
        let glyph = harness.layoutManager.glyphIndexForCharacter(at: first)
        let x = harness.layoutManager.location(forGlyphAt: glyph).x
        #expect(abs(x - style.taskBoxWidth) < 1.5)
        // The bullet text starts at 18 pt.
        let bulletText = harness.location(of: "影響頁面")
        #expect(abs(harness.layoutManager.location(forGlyphAt: harness.layoutManager.glyphIndexForCharacter(at: bulletText)).x - style.listIndent) < 0.5)
    }

    @Test func noteRefsAreChipsAndLinksOpen() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("# T\n\n參考 codd://note/rwd-punch-k7x2 與 [說明](https://example.com) 結束\n\n尾", caret: 1)
        let storage = harness.editor.storage
        let chip = harness.location(of: "codd://note")
        #expect(storage.attribute(.coddChip, at: chip, effectiveRange: nil) != nil)
        #expect(storage.attribute(.foregroundColor, at: chip, effectiveRange: nil) as? NSColor == style.chipText)
        let link = harness.location(of: "說明")
        #expect(storage.attribute(.foregroundColor, at: link, effectiveRange: nil) as? NSColor == style.link)
        // A click on the link (its line is not the caret's) opens it.
        guard let box = harness.editor.textLineRect(forCharacterAt: link) else {
            Issue.record("no line")
            return
        }
        let glyph = harness.layoutManager.glyphIndexForCharacter(at: link)
        let x = harness.layoutManager.location(forGlyphAt: glyph).x + style.padding.left + 3
        #expect(harness.editor.handleClick(at: NSPoint(x: x, y: box.midY), clickCount: 1, modifiers: []))
        #expect(harness.openedLinks == ["https://example.com"])
        let chipGlyph = harness.layoutManager.glyphIndexForCharacter(at: chip + 2)
        let chipX = harness.layoutManager.location(forGlyphAt: chipGlyph).x + style.padding.left + 2
        #expect(harness.editor.handleClick(at: NSPoint(x: chipX, y: box.midY), clickCount: 1, modifiers: []))
        #expect(harness.openedLinks.last == "codd://note/rwd-punch-k7x2")
        // Source mode: only ⌘-click.
        harness.editor.mode = .source
        harness.settle()
        let sourceBox = harness.editor.textLineRect(forCharacterAt: link)!
        let sourceX = harness.layoutManager.location(forGlyphAt: harness.layoutManager.glyphIndexForCharacter(at: link)).x + style.padding.left + 3
        #expect(!harness.editor.handleClick(at: NSPoint(x: sourceX, y: sourceBox.midY), clickCount: 1, modifiers: []))
        #expect(harness.editor.handleClick(at: NSPoint(x: sourceX, y: sourceBox.midY), clickCount: 1, modifiers: [.command]))
        #expect(harness.openedLinks.count == 3)
    }

    @Test func aDoubleClickOnAFigureEditsItsAnnotations() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let index = harness.editor.blocks.firstIndex { if case .image = $0.kind { true } else { false } }!
        let figure = harness.editor.figureFrames(forBlock: index)!
        let point = NSPoint(x: figure.plate.midX + style.padding.left, y: figure.plate.midY + style.padding.top)
        #expect(!harness.editor.handleClick(at: point, clickCount: 1, modifiers: []))
        #expect(harness.editor.handleClick(at: point, clickCount: 2, modifiers: []))
        #expect(harness.annotated == [MarkdownSamples.n1ImagePath])
        // ⌘⇧A on the image line (and on its hidden block) does the same.
        harness.select(harness.location(of: "![截圖") + 2)
        #expect(harness.editor.imagePathAtCaret == MarkdownSamples.n1ImagePath)
        #expect(harness.keyEquivalent("a", keyCode: 0, modifiers: [.command, .shift]))
        #expect(harness.annotated.count == 2)
        harness.select(0)
        #expect(!harness.keyEquivalent("a", keyCode: 0, modifiers: [.command, .shift]))
    }

    @Test func theEditorRendersTheNotebookDocument() {
        let harness = n1Harness(caret: MarkdownSamples.n1CaretLocation)
        defer { harness.tearDown() }
        let screenshot = MarkdownSamples.placeholderScreenshot()
        harness.editor.imageResolver = { _ in MarkdownSamples.n1ImageInfo(image: screenshot) }
        harness.settle()
        let editor = harness.editor
        guard let rep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else {
            Issue.record("no bitmap")
            return
        }
        editor.cacheDisplay(in: editor.bounds, to: rep)
        #expect(ViewSnapshot.pixelsDiffering(from: style.background, in: rep) > 20_000)
        // The caret band reaches the view's left edge on the raw line (the inset amber-dim bar).
        let line = editor.textLineRect(forCharacterAt: MarkdownSamples.n1CaretLocation - 1)!
        let bar = ViewSnapshot.color(at: CGPoint(x: 1, y: line.midY), in: rep)
        #expect((bar?.redComponent ?? 0) > 0.7)
        // The figure plate is black inside its amber-dim border.
        let index = editor.blocks.firstIndex { if case .image = $0.kind { true } else { false } }!
        let figure = editor.figureFrames(forBlock: index)!
        let border = ViewSnapshot.color(at: CGPoint(x: figure.plate.minX + style.padding.left + 0.5, y: figure.plate.midY + style.padding.top), in: rep)
        #expect((border?.redComponent ?? 0) > 0.7 && (border?.blueComponent ?? 1) < 0.4)
    }
}
