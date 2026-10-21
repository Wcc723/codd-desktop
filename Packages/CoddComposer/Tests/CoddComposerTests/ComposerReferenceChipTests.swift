import AppKit
import Testing
@testable import CoddComposer

/// `codd://note/<id>` chips (M4 C4): attributes only, never the text; off by default; never
/// recomputed while composing and never drawn touching the marked range.
@Suite("Composer reference chips", .serialized)
@MainActor
struct ComposerReferenceChipTests {
    static var chipStyle: ComposerStyle {
        var style = ComposerStyle.standard
        style.referenceChips = true
        return style
    }

    static let sample = "iPhone SE 寬度下的打卡按鈕改成固定在底部，參考 codd://note/rwd-punch-k7x2 再改"

    private func chipRuns(_ harness: ComposerHarness) -> [NSRange] {
        guard let storage = harness.textView.textStorage else { return [] }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.composerReferenceChip, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { runs.append(range) }
        }
        return runs
    }

    private func reference(in text: String, _ ref: String = "codd://note/rwd-punch-k7x2") -> NSRange {
        (text as NSString).range(of: ref)
    }

    @Test func chipsAreOffByDefault() {
        #expect(ComposerStyle.standard.referenceChips == false)
        let built = ComposerStyle(font: .monospacedSystemFont(ofSize: 12, weight: .regular), textColor: .white, placeholderColor: .gray,
                                  caretColor: .orange, markedTextColor: .orange, background: .black,
                                  insets: NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9))
        #expect(built.referenceChips == false)
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set(Self.sample)
        #expect(harness.textView.referenceChipRanges.isEmpty)
        #expect(chipRuns(harness).isEmpty)
        #expect(harness.textView.drawableReferenceChipRanges().isEmpty)
    }

    @Test func referenceRangesFollowTheIDCharset() {
        let text = "a codd://note/rwd-punch-k7x2, b codd://note/x9 c codd://note/-bad codd://note/end- codd://note/UPPER"
        let ranges = ComposerTextView.referenceRanges(in: text).map { (text as NSString).substring(with: $0) }
        #expect(ranges == ["codd://note/rwd-punch-k7x2", "codd://note/x9", "codd://note/end"])
        let long = "codd://note/" + String(repeating: "a", count: 60)
        #expect(ComposerTextView.referenceRanges(in: long).first?.length == 12 + 48)
    }

    @Test func chipsDecorateWithoutChangingTheText() {
        let harness = ComposerHarness(style: Self.chipStyle)
        defer { harness.tearDown() }
        harness.set(Self.sample)
        let ref = reference(in: Self.sample)
        #expect(harness.textView.string == Self.sample)
        #expect(harness.field.text == Self.sample)
        #expect(harness.textView.referenceChipRanges == [ref])
        #expect(chipRuns(harness) == [ref])
        #expect(harness.textView.drawableReferenceChipRanges() == [ref])
        let color = harness.textView.textStorage?.attribute(.foregroundColor, at: ref.location, effectiveRange: nil) as? NSColor
        #expect(color == Self.chipStyle.referenceChipText)
        // The payload is the plain text, byte for byte.
        let payload = try? ComposerEncoding.payload(for: harness.field.text)
        #expect(payload.map { String(decoding: $0.bytes, as: UTF8.self) }?.contains("codd://note/rwd-punch-k7x2") == true)
    }

    @Test func typingNextToAChipStaysOutsideIt() {
        let harness = ComposerHarness(style: Self.chipStyle)
        defer { harness.tearDown() }
        let text = "參考 codd://note/rwd-punch-k7x2"
        harness.set(text)
        harness.textView.insertText(" 打卡", replacementRange: NSRange(location: NSNotFound, length: 0))
        let ref = reference(in: text)
        #expect(harness.textView.string == text + " 打卡")
        #expect(chipRuns(harness) == [ref])
        // Deleting into the id shortens the chip; deleting the prefix removes it.
        harness.set("codd://note/abc")
        harness.textView.deleteBackward(nil)
        #expect(chipRuns(harness) == [NSRange(location: 0, length: 14)])
        harness.textView.setSelectedRange(NSRange(location: 4, length: 0))
        harness.textView.deleteBackward(nil)
        #expect(chipRuns(harness).isEmpty)
        #expect(harness.textView.referenceChipRanges.isEmpty)
    }

    @Test func nothingIsRecomputedWhileComposingAndNoChipTouchesTheMarkedRange() {
        let harness = ComposerHarness(style: Self.chipStyle)
        defer { harness.tearDown() }
        let text = "參考 codd://note/rwd-punch-k7x2"
        harness.set(text)
        let ref = reference(in: text)
        // A composition right after the chip: the chip run never includes the marked text and the
        // touching chip is not drawn until the composition ends.
        harness.compose("ㄓㄨˋ")
        let marked = harness.textView.markedRange()
        #expect(marked.length > 0)
        for run in chipRuns(harness) {
            #expect(NSIntersectionRange(run, marked).length == 0)
        }
        #expect(harness.textView.drawableReferenceChipRanges().allSatisfy { NSIntersectionRange($0, marked).length == 0 && NSMaxRange($0) != marked.location })
        #expect(harness.textView.referenceChipRanges == [ref])
        harness.textView.insertText("注", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.textView.string == text + "注")
        #expect(chipRuns(harness) == [ref])
        #expect(harness.textView.drawableReferenceChipRanges() == [ref])
    }

    @Test func aCompositionInsideAChipHidesItUntilCommitted() {
        let harness = ComposerHarness(style: Self.chipStyle)
        defer { harness.tearDown() }
        harness.set("codd://note/rwd-punch-k7x2 後面", caret: 16)
        harness.compose("ㄅ")
        let marked = harness.textView.markedRange()
        #expect(harness.textView.drawableReferenceChipRanges().allSatisfy { NSIntersectionRange($0, marked).length == 0 && !NSLocationInRange(marked.location, $0) })
        harness.textView.insertText("八", replacementRange: NSRange(location: NSNotFound, length: 0))
        // The id now ends before the CJK character (a trailing `-` is not part of an id).
        #expect(chipRuns(harness) == [NSRange(location: 0, length: 15)])
    }

    @Test func turningChipsOffRemovesThem() {
        let harness = ComposerHarness(style: Self.chipStyle)
        defer { harness.tearDown() }
        harness.set(Self.sample)
        #expect(!chipRuns(harness).isEmpty)
        harness.field.apply(.standard)
        #expect(chipRuns(harness).isEmpty)
        #expect(harness.textView.referenceChipRanges.isEmpty)
        #expect(harness.textView.string == Self.sample)
    }

    @Test func chipsAreDrawn() {
        let harness = ComposerHarness(width: 420, style: Self.chipStyle)
        defer { harness.tearDown() }
        harness.set("codd://note/rwd-punch-k7x2")
        let view = harness.textView
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("no bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The chip's fill differs from the black field somewhere left of the text start.
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let y = Int((view.textContainerOrigin.y + 9) * scale)
        let border = (0 ..< Int(view.textContainerOrigin.x * scale)).compactMap { x in rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        // The chip's amber-dim border sits a few points left of the first glyph.
        #expect(border.contains { $0.redComponent > 0.6 && $0.greenComponent > 0.4 && $0.blueComponent < 0.4 })
    }
}
