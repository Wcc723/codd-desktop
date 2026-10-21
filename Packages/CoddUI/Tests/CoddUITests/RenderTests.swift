import AppKit
import CoddUI
import Testing

/// Rendering smoke tests: every primitive draws something (offscreen, with App/Fonts registered).
@MainActor
@Suite("Rendering")
struct RenderTests {
    init() {
        #expect(TestSupport.prepare(), "App/Fonts must register")
    }

    private static func filled(_ card: CardView, _ view: NSView) -> CardView {
        card.contentView.addSubview(view)
        view.pinEdges(to: card.contentView)
        return card
    }

    @Test func everyPrimitiveDraws() {
        let modal = ModalFrameView(title: "Switch account · 切換帳號", headerAccessories: [ChipView("cswap 0.26.0", style: .chip(display: true))])
        let modalBody = Label.make("切換到 #2 藍鵲？", style: TextStyle.mono(13, Palette.cream))
        modal.contentView.addSubview(modalBody)
        modalBody.pinEdges(to: modal.contentView)
        modal.setFooter(note: "⏎ 切換 · ⎋ 取消", buttons: [CoddButton("切換", style: .bracket(.primary, small: false))])

        let cases: [(String, NSView, NSSize?, CGFloat?)] = [
            ("quota row", QuotaBarRowView(QuotaBarRow(key: "5h", remainingPercent: 91, threshold: 2)), NSSize(width: 300, height: 16), nil),
            ("quota row nil", QuotaBarRowView(QuotaBarRow(key: "Fable", remainingPercent: nil, keyWidth: 34)), NSSize(width: 300, height: 16), nil),
            ("meter", MeterView(fraction: 0.6), NSSize(width: 200, height: 2), nil),
            ("meter stacked", MeterView(segments: [MeterView.Segment(fraction: 0.4, color: MeterView.stackColors[0])]), NSSize(width: 200, height: 6), nil),
            ("meter split", MeterView(main: 0.9, other: 0.1), NSSize(width: 200, height: 2), nil),
            ("sparkline", SparklineView(values: [0.2, 0.6, 0.4, 0.9], baseline: 0.5), NSSize(width: 200, height: 28), nil),
            ("card", Self.filled(CardView(title: "#2 藍鵲", hot: true), Label.make("body", style: TextStyle.mono(12, Palette.bone))), nil, 300),
            ("checkbox boxed", CheckboxButton(title: "5 小時", isOn: true), nil, nil),
            ("checkbox plain", CheckboxButton(title: "同時暫停自動切換", hint: "AUTO-SWITCH 目前 OFF", style: .plain), nil, nil),
            ("stepper", StepperControl(value: 2, minValue: 1, maxValue: 20, accessibilityLabel: "門檻"), nil, nil),
            ("kbd", KbdView("⌘Q"), nil, nil),
            ("kbd hotkey", KbdView("⌥ Space", size: .hotkey), nil, nil),
            ("modal", modal, nil, 520),
            ("diff", DiffLinesView(lines: [DiffLinesView.Line(kind: .hunk, text: "@@ -1 +1 @@"),
                                          DiffLinesView.Line(kind: .added, newNumber: 1, text: "\"PreCompact\": … ,")]), nil, 500),
            ("section header", SectionHeaderView(title: "Host", hint: "studio-mbp"), nil, 600),
            ("group header", SectionHeaderView(title: "Terminal", style: .group, hint: "終端機"), nil, 600),
            ("dashed rule", DashedRuleView(color: Palette.lineBright), NSSize(width: 200, height: 1), nil),
            ("form row", FormRowView(name: "UI 字級", english: "UI font size", hint: "介面文字大小。", controls: [SwitchToggle(label: "x")]), nil, 640),
        ]
        for (name, view, size, width) in cases {
            let inked = TestSupport.inkedPixels(view, size: size, width: width)
            #expect(inked > 20, "\(name) rendered \(inked) inked pixels")
        }
    }

    @Test func copiedControlsDraw() {
        let cases: [(String, NSView, NSSize?, CGFloat?)] = [
            ("bracket", CoddButton("取消", style: .bracket(.normal, small: false)), nil, nil),
            ("primary", CoddButton("切換", style: .bracket(.primary, small: true)), nil, nil),
            ("chip", ChipView("MAX 20x", style: .chip()), nil, nil),
            ("switch", SwitchToggle(label: "x"), NSSize(width: 30, height: 16), nil),
            ("segmented", SegmentedSwitch(titles: ["Off", "Subtle"]), nil, nil),
            ("select", SelectButton(titles: ["13 px（預設）"], accessibilityLabel: "UI 字級"), NSSize(width: 160, height: 30), nil),
            ("toast", ToastView(text: "已切換到 #2 藍鵲", undo: {}), nil, 400),
            ("panel", PanelView(fill: Palette.bgLift, edges: [.top], edgeColor: Palette.lineBright), NSSize(width: 100, height: 20), nil),
        ]
        for (name, view, size, width) in cases {
            let inked = TestSupport.inkedPixels(view, size: size, width: width)
            #expect(inked > 20, "\(name) rendered \(inked) inked pixels")
        }
    }

    /// The card's corner glyphs are drawn in amber-dim on the page color, half outside the box.
    @Test func cardCornersAreDrawnOutsideTheBox() throws {
        let card = CardView(title: "~/.claude")
        let size = ViewSnapshot.fittingSize(of: card, width: 300)
        let rep = try #require(ViewSnapshot.render(card, size: size))
        // Somewhere in the 7 pt above the box, left part: amber-dim ink.
        var found = false
        for y in stride(from: 1.0, to: CardView.outset + 1, by: 0.5) {
            for x in stride(from: 1.0, to: 20, by: 0.5) {
                let color = TestSupport.rgb(ViewSnapshot.color(at: CGPoint(x: x, y: y), in: rep))
                if TestSupport.close(color, TestSupport.rgb(Palette.amberDim), tolerance: 40) { found = true }
            }
        }
        #expect(found)
        // Inside the box: --bg-soft.
        let inside = ViewSnapshot.color(at: CGPoint(x: 150, y: size.height / 2), in: rep)
        #expect(TestSupport.close(TestSupport.rgb(inside), TestSupport.rgb(Palette.bgSoft), tolerance: 2))
    }

    @Test func snapshotsWritePNG() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coddui-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rep = try #require(ViewSnapshot.render(KbdView("⌘Q")))
        #expect(rep.pixelsWide == Int(KbdView("⌘Q").intrinsicContentSize.width * 2))
        let url = directory.appendingPathComponent("kbd.png")
        try ViewSnapshot.writePNG(rep, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
