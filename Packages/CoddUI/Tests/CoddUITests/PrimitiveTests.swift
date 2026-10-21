import AppKit
import CoddUI
import Testing

@MainActor
@Suite("Primitives")
struct PrimitiveTests {
    init() { TestSupport.prepare() }

    // MARK: Tone

    @Test("tone colors follow helmet --tone", arguments: [
        (Tone.ok, [0x7C, 0xFF, 0x9A]), (.warn, [0xFF, 0xB8, 0x4A]), (.crit, [0xFF, 0x70, 0x58]), (.muted, [0x7A, 0x74, 0x68]),
    ])
    func toneColors(tone: Tone, rgb: [Int]) {
        #expect(TestSupport.rgb(tone.color) == rgb)
    }

    @Test func toneRuleMatchesTheAppQuotaWindow() {
        #expect(Tone.tone(forRemaining: nil) == .muted)
        #expect(Tone.tone(forRemaining: 91, started: false) == .muted)
        #expect(Tone.tone(forRemaining: .nan) == .muted)
        #expect(Tone.tone(forRemaining: 0) == .crit)
        #expect(Tone.tone(forRemaining: 19.9) == .crit)
        #expect(Tone.tone(forRemaining: 20) == .warn)
        #expect(Tone.tone(forRemaining: 49.9) == .warn)
        #expect(Tone.tone(forRemaining: 50) == .ok)
        #expect(Tone.tone(forRemaining: 100) == .ok)
        #expect(Tone.allCases.count == 4)
    }

    // MARK: Quota rows

    @Test func quotaRowValueText() {
        #expect(QuotaBarRow(key: "5h", remainingPercent: 91).valueText == "91%")
        #expect(QuotaBarRow(key: "5h", remainingPercent: 90.6).valueText == "91%")
        #expect(QuotaBarRow(key: "5h", remainingPercent: 140).valueText == "100%")
        #expect(QuotaBarRow(key: "5h", remainingPercent: -3).valueText == "0%")
        #expect(QuotaBarRow(key: "Fable", remainingPercent: nil).valueText == "—")
        #expect(QuotaBarRow(key: "1w", remainingPercent: 15).tone == .crit)
        #expect(QuotaBarRow(key: "1w", remainingPercent: 15, tone: .ok).tone == .ok)
    }

    @Test func quotaRowGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 16)
        let row = QuotaBarRow(key: "5h", remainingPercent: 98, threshold: 2)
        // key 22 + gap 8 at the left; value 34 + gap 8 at the right.
        let bar = QuotaBarRowRenderer.barRect(for: row, in: rect)
        #expect(bar == CGRect(x: 30, y: 5, width: 228, height: 7))
        // `.thr{width:2px;margin-left:-1px}` at 2 % of the bar.
        let tick = QuotaBarRowRenderer.thresholdTickRect(for: row, in: rect)
        #expect(tick == CGRect(x: (30 + 228 * 0.02).rounded() - 1, y: 5, width: 2, height: 7))
        #expect(QuotaBarRowRenderer.thresholdTickRect(for: QuotaBarRow(key: "5h", remainingPercent: 98), in: rect) == nil)

        let compact = QuotaBarRow(key: "1w", remainingPercent: 46, compact: true, threshold: 50)
        let compactBar = QuotaBarRowRenderer.barRect(for: compact, in: rect)
        #expect(compactBar.minX == CGFloat(16 + 5))
        #expect(compactBar.maxX == CGFloat(300 - 30 - 5))
        #expect(QuotaBarRowRenderer.thresholdTickRect(for: compact, in: rect)?.minX == (compactBar.minX + compactBar.width / 2).rounded() - 1)

        let status = QuotaBarRow(key: "Fable", remainingPercent: nil, keyWidth: 34)
        #expect(QuotaBarRowRenderer.barRect(for: status, in: rect).minX == 42)
        let trailing = QuotaBarRow(key: "5h", remainingPercent: 91, trailing: "2h57m後")
        #expect(QuotaBarRowRenderer.barRect(for: trailing, in: rect).maxX < bar.maxX)
        // Never narrower than `.bar10{min-width:40px}`.
        #expect(QuotaBarRowRenderer.barRect(for: row, in: CGRect(x: 0, y: 0, width: 60, height: 16)).width == 40)
    }

    @Test func thresholdTickIsDrawnInDanger() throws {
        let view = QuotaBarRowView(QuotaBarRow(key: "5h", remainingPercent: 98, threshold: 50))
        let rep = try #require(ViewSnapshot.render(view, size: NSSize(width: 300, height: 16)))
        let tick = try #require(QuotaBarRowRenderer.thresholdTickRect(for: view.row, in: CGRect(x: 0, y: 0, width: 300, height: 16)))
        let pixel = ViewSnapshot.color(at: CGPoint(x: tick.midX, y: tick.midY), in: rep)
        #expect(TestSupport.close(TestSupport.rgb(pixel), TestSupport.rgb(Palette.danger)))
        // The fill left of the tick is the ok tone.
        let fill = ViewSnapshot.color(at: CGPoint(x: tick.minX - 12, y: tick.midY), in: rep)
        #expect(TestSupport.close(TestSupport.rgb(fill), TestSupport.rgb(Palette.success)))
    }

    @Test func quotaRowViewSizeRedrawAndAccessibility() {
        let view = QuotaBarRowView(key: "1w", remainingPercent: 46, trailing: "1d12h後", trailingIsKey: true)
        #expect(view.intrinsicContentSize.height == 16)
        #expect(view.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        // M5 D21: static text with what the row shows.
        #expect(view.accessibilityRole() == .staticText)
        #expect(view.accessibilityLabel() == "1w 剩 46% · 1d12h後")
        // A new value shows in the next drawing and in VoiceOver.
        let bar = QuotaBarRowRenderer.barRect(for: view.row, in: CGRect(x: 0, y: 0, width: 300, height: 16))
        let probe = CGPoint(x: bar.minX + bar.width * 0.43, y: bar.midY)
        let before = ViewSnapshot.render(view, size: NSSize(width: 300, height: 16)).flatMap { ViewSnapshot.color(at: probe, in: $0) }
        view.remainingPercent = 40
        let after = ViewSnapshot.render(view, size: NSSize(width: 300, height: 16)).flatMap { ViewSnapshot.color(at: probe, in: $0) }
        #expect(TestSupport.close(TestSupport.rgb(before), TestSupport.rgb(Palette.amber)))
        #expect(TestSupport.close(TestSupport.rgb(after), TestSupport.rgb(Palette.lineBright)))
        #expect(view.accessibilityLabel() == "1w 剩 40% · 1d12h後")
        #expect(view.tone == .warn)
    }

    // MARK: Meter and sparkline

    @Test func meterShapes() {
        let track = CGRect(x: 0, y: 0, width: 200, height: 2)
        let single = MeterView(fraction: 0.23)
        #expect(single.intrinsicContentSize.height == 2)
        #expect(single.fills(in: track).map(\.rect.width) == [46])
        #expect(single.fills(in: track).first?.color == Palette.amberDim)
        #expect(MeterView(fraction: 0.86, tone: .ok).fills(in: track).first?.color == Palette.success)
        #expect(MeterView(fraction: 3).fills(in: track).first?.rect.width == 200)

        let stacked = MeterView(segments: [MeterView.Segment(fraction: 0.5, color: MeterView.stackColors[0]),
                                           MeterView.Segment(fraction: 0.25, color: MeterView.stackColors[1]),
                                           MeterView.Segment(fraction: 0.5, color: MeterView.stackColors[2])])
        #expect(stacked.intrinsicContentSize.height == 6)
        let pieces = stacked.fills(in: CGRect(x: 0, y: 0, width: 200, height: 6))
        #expect(pieces.map(\.rect.minX) == [0, 100, 150])
        #expect(pieces.map(\.rect.width) == [100, 50, 50]) // clipped at the end of the track

        let split = MeterView(main: 0.75, other: 0.25)
        #expect(split.fills(in: track).map(\.rect.width) == [150, 50])
        #expect(split.fills(in: track).last?.color == MeterView.splitOtherColor)
        #expect(split.accessibilityRole() == .levelIndicator)
        #expect(split.accessibilityValue() as? String == "100%")
        split.accessibilityText = "claude 12"
        #expect(split.accessibilityLabel() == "claude 12")
    }

    @Test func sparklinePoints() {
        let spark = SparklineView(values: [0, 0.5, 1])
        #expect(spark.intrinsicContentSize.height == 28)
        let points = spark.points(in: CGRect(x: 0, y: 0, width: 200, height: 40))
        #expect(points == [CGPoint(x: 0, y: 40), CGPoint(x: 100, y: 20), CGPoint(x: 200, y: 0)])
        spark.scale = .auto
        spark.values = [10, 20, 30]
        #expect(spark.points(in: CGRect(x: 0, y: 0, width: 100, height: 10)).map(\.y) == [10, 5, 0])
        spark.values = [7, 7]
        #expect(spark.normalized(7) == 0.5)
        spark.scale = .fixed(0...100)
        #expect(spark.normalized(150) == 1)
        spark.showsBottomRule = true
        spark.frame = NSRect(x: 0, y: 0, width: 100, height: 30)
        #expect(spark.plotRect.height == 29)
        #expect(!spark.isAccessibilityElement())
        #expect(SparklineView(values: [], accessibilityLabel: "CPU").isAccessibilityElement())
    }

    // MARK: Checkbox

    @Test func checkboxTogglesAndSendsItsAction() throws {
        let counter = ActionCounter()
        let box = CheckboxButton(title: "5 小時", target: counter, action: #selector(ActionCounter.fire(_:)))
        let window = TestSupport.host(box, size: NSSize(width: 120, height: 26))
        defer { window.close() }
        #expect(box.accessibilityRole() == .checkBox)
        #expect(box.accessibilityLabel() == "5 小時")
        #expect(box.accessibilityValue() as? Int == 0)
        TestSupport.click(box, at: CGPoint(x: 10, y: 13))
        #expect(box.isOn)
        #expect(box.state == .on)
        #expect(counter.count == 1)
        #expect(counter.lastSender === box)
        #expect(box.accessibilityValue() as? Int == 1)
        box.keyDown(with: try #require(TestSupport.key(" ", keyCode: 49)))
        #expect(!box.isOn)
        #expect(counter.count == 2)
        #expect(box.accessibilityPerformPress())
        #expect(box.isOn)
        #expect(counter.count == 3)
        // Setting the value from code sends nothing.
        box.isOn = false
        box.state = .on
        #expect(counter.count == 3)
        box.isEnabled = false
        TestSupport.click(box, at: CGPoint(x: 10, y: 13))
        #expect(!box.accessibilityPerformPress())
        #expect(counter.count == 3)
        #expect(!box.acceptsFirstResponder)
    }

    @Test func checkboxSizes() {
        let title = "每週"
        let titleWidth = Draw.width(TextStyle.mono(12, Palette.dim).string(title))
        let boxed = CheckboxButton(title: title)
        #expect(boxed.intrinsicContentSize == NSSize(width: ceil(8 + 12 + 6 + titleWidth + 10), height: 26))
        let plain = CheckboxButton(title: "同時暫停自動切換", hint: "AUTO-SWITCH 目前 OFF", style: .plain)
        #expect(plain.intrinsicContentSize.height == 20)
        #expect(plain.intrinsicContentSize.width > CheckboxButton(title: "同時暫停自動切換", style: .plain).intrinsicContentSize.width)
        #expect(plain.accessibilityHelp() == "AUTO-SWITCH 目前 OFF")
        plain.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        #expect(plain.boxRect == CGRect(x: 0, y: 3, width: 14, height: 14))
        boxed.frame = NSRect(x: 0, y: 0, width: 80, height: 26)
        #expect(boxed.boxRect == CGRect(x: 8, y: 7, width: 12, height: 12))
    }

    // MARK: Stepper

    @Test func stepperStepsWithinBoundsAndSendsActions() throws {
        let counter = ActionCounter()
        let stepper = StepperControl(value: 2, minValue: 1, maxValue: 20, format: { "\(Int($0)) %" },
                                     accessibilityLabel: "自動切換門檻", decrementLabel: "門檻減 1%", incrementLabel: "門檻加 1%")
        stepper.target = counter
        stepper.action = #selector(ActionCounter.fire(_:))
        let window = TestSupport.host(stepper, size: stepper.intrinsicContentSize)
        defer { window.close() }
        #expect(stepper.accessibilityRole() == .incrementor)
        #expect(stepper.accessibilityLabel() == "自動切換門檻")
        #expect(stepper.accessibilityValue() as? String == "2 %")
        let buttons = try #require(stepper.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(buttons.map { $0.accessibilityLabel() } == ["門檻減 1%", "門檻加 1%"])
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .button })

        let parts = stepper.partRects
        TestSupport.click(stepper, at: CGPoint(x: parts.increment.midX, y: parts.increment.midY))
        #expect(stepper.value == 3)
        #expect(counter.count == 1)
        TestSupport.click(stepper, at: CGPoint(x: parts.decrement.midX, y: parts.decrement.midY))
        TestSupport.click(stepper, at: CGPoint(x: parts.decrement.midX, y: parts.decrement.midY))
        #expect(stepper.value == 1)
        #expect(counter.count == 3)
        // At the bound: no change, no action.
        TestSupport.click(stepper, at: CGPoint(x: parts.decrement.midX, y: parts.decrement.midY))
        #expect(stepper.value == 1)
        #expect(counter.count == 3)
        #expect(!stepper.accessibilityPerformDecrement())
        #expect(stepper.accessibilityPerformIncrement())
        #expect(stepper.value == 2)
        #expect(buttons[1].accessibilityPerformPress())
        #expect(stepper.value == 3)
        stepper.keyDown(with: try #require(TestSupport.key(String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126)))
        #expect(stepper.value == 4)
        stepper.keyDown(with: try #require(TestSupport.key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123)))
        #expect(stepper.value == 3)
        #expect(counter.count == 7)
        // Values from code are clamped and send nothing.
        stepper.value = 99
        #expect(stepper.value == 20)
        #expect(stepper.valueText == "20 %")
        #expect(counter.count == 7)
        stepper.isEnabled = false
        #expect(!stepper.step(by: -1))
    }

    @Test func stepperSize() {
        let stepper = StepperControl(value: 13, minValue: 10, maxValue: 24, decrementTitle: "A−", incrementTitle: "A+",
                                     accessibilityLabel: "終端機字級")
        #expect(stepper.intrinsicContentSize.height == 26)
        stepper.frame = NSRect(origin: .zero, size: stepper.intrinsicContentSize)
        let parts = stepper.partRects
        // `.v{min-width:40px}`.
        #expect(parts.value.width == 40)
        #expect(parts.decrement.minX == 1)
        #expect(parts.increment.maxX == stepper.intrinsicContentSize.width - 1)
        #expect(StepperControl.integerFormat(13) == "13")
        #expect(StepperControl.integerFormat(12.5) == "12.5")
    }

    // MARK: Copied controls: switch / segmented actions

    @Test func switchToggleAndSegmentedSwitch() {
        let counter = ActionCounter()
        let toggle = SwitchToggle(label: "通知")
        toggle.target = counter
        toggle.action = #selector(ActionCounter.fire(_:))
        #expect(toggle.intrinsicContentSize == NSSize(width: 30, height: 16))
        #expect(toggle.accessibilityRole() == .checkBox)
        #expect(toggle.accessibilityLabel() == "通知")
        #expect(toggle.accessibilityPerformPress())
        #expect(toggle.isOn)
        #expect(toggle.accessibilityValue() as? Int == 1)
        #expect(counter.count == 1)

        let seg = SegmentedSwitch(titles: ["Off", "Subtle", "Full"])
        seg.target = counter
        seg.action = #selector(ActionCounter.fire(_:))
        let window = TestSupport.host(seg, size: seg.intrinsicContentSize)
        defer { window.close() }
        #expect(seg.accessibilityRole() == .radioGroup)
        #expect(seg.accessibilityValue() as? String == "Off")
        TestSupport.click(seg, at: CGPoint(x: seg.bounds.width - 4, y: 13))
        #expect(seg.selectedIndex == 2)
        #expect(seg.accessibilityValue() as? String == "Full")
        #expect(counter.count == 2)
    }

    // MARK: Kbd

    @Test func kbdSizes() {
        for (size, height) in [(KbdView.Size.regular, CGFloat(18)), (.large, 22), (.hotkey, 24)] {
            let view = KbdView("⌘Q", size: size)
            #expect(view.intrinsicContentSize.height == height)
            #expect(view.intrinsicContentSize == KbdView.style(size).size(for: "⌘Q"))
        }
        let kbd = KbdView("⌘Q")
        #expect(kbd.accessibilityRole() == .staticText)
        #expect(kbd.accessibilityLabel() == "⌘Q")
        let width = kbd.intrinsicContentSize.width
        kbd.text = "⌘⇧Q"
        #expect(kbd.intrinsicContentSize.width > width)
        // `padding:0 5px` + 1 px border on each side.
        #expect(width == Draw.width(TextStyle.mono(10.5, Palette.dim).string("⌘Q")) + 12)
    }

    // MARK: Diff

    @Test func diffLinesCountHeightAndColumns() {
        let lines = [
            DiffLinesView.Line(kind: .hunk, text: "@@ -38,5 +38,13 @@"),
            DiffLinesView.Line(kind: .context, oldNumber: 38, newNumber: 38, text: "\"StopFailure\": [ … ],"),
            DiffLinesView.Line(kind: .removed, oldNumber: 40, newNumber: nil, text: "a"),
            DiffLinesView.Line(kind: .added, oldNumber: nil, newNumber: 40, text: "b"),
            DiffLinesView.Line(kind: .elided, text: "⋯ 12 行未變更"),
        ]
        let view = DiffLinesView(lines: lines, accessibilityLabel: "settings.json 差異")
        #expect(view.lines.count == 5)
        #expect(view.contentHeight == 5 * DiffLinesView.defaultLineHeight)
        #expect(view.intrinsicContentSize.height == CGFloat(5 * 16 + 18))
        view.framed = false
        #expect(view.intrinsicContentSize.height == 80)
        view.lineHeight = 18
        #expect(view.intrinsicContentSize.height == 90)
        view.framed = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: view.intrinsicContentSize.height)
        #expect(view.lineRect(0) == CGRect(x: 1, y: 9, width: 598, height: 18))
        #expect(view.lineRect(4).maxY == view.bounds.height - 9)

        #expect(lines.map(\.displayedNumber) == [nil, 38, 40, 40, nil])
        #expect(lines.map(\.sign) == ["", "", "-", "+", ""])
        #expect(lines[1].spans.map(\.style) == [.plain, .ellipsis, .plain])
        #expect(lines[1].text == "\"StopFailure\": [ … ],")
        #expect(DiffLinesView.Line(kind: .context, text: "").spans == [DiffLinesView.Line.Span("")])

        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityLabel() == "settings.json 差異")
        #expect((view.accessibilityValue() as? String)?.split(separator: "\n").count == 5)
        #expect(DiffLinesView.colors(.added).background != nil)
        #expect(DiffLinesView.colors(.context).background == nil)
    }

    // MARK: Card, modal, headers

    @Test func cardUsesItsBoxForLayoutAndKeepsRoomForTheCorners() {
        let card = CardView(title: "~/.claude")
        let body = FlippedView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(equalToConstant: 40).isActive = true
        card.contentView.addSubview(body)
        body.pinEdges(to: card.contentView)
        card.setHeader(trailing: [ChipView("◆ 1 項需要更新", style: .chip(.amber))])
        let stack = vStack([card], spacing: 0)
        card.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let window = TestSupport.host(stack, size: NSSize(width: 300, height: 200))
        defer { window.close() }
        stack.layoutSubtreeIfNeeded()
        #expect(card.alignmentRectInsets.top == CardView.outset)
        // The stack aligns the box (not the frame) with its top edge.
        #expect(card.frame.minY == -CardView.outset || card.frame.maxY == stack.bounds.height + CardView.outset)
        // padding 16 + border 1, header 20 (chip), rule 6 + 1, margin 12, body 40, padding 16 + border 1.
        let expectedBox: CGFloat = 1 + 16 + 20 + 7 + 12 + 40 + 16 + 1
        #expect(card.box.height == expectedBox)
        #expect(card.frame.height == card.box.height + 2 * CardView.outset)
        let expectedContentTop: CGFloat = CardView.outset + 1 + 16 + 20 + 7 + 12
        #expect(card.contentView.frame.minY == expectedContentTop)
        #expect(card.contentView.frame.minX == 19)
        #expect(card.showsHeader)
        #expect(card.accessibilityRole() == .group)
        #expect(card.accessibilityLabel() == "~/.claude")

        let bare = CardView()
        #expect(!bare.showsHeader)
        bare.isHot = true
        bare.accessibilityText = "MCP"
        #expect(bare.accessibilityLabel() == "MCP")
    }

    @Test func modalFrameLayoutAndClose() {
        let modal = ModalFrameView(title: "Quit · 結束", headerAccessories: [KbdView("⌘Q")])
        var closed = 0
        modal.onClose = { closed += 1 }
        let body = FlippedView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(equalToConstant: 100).isActive = true
        modal.contentView.addSubview(body)
        body.pinEdges(to: modal.contentView)
        #expect(!modal.showsFooter)
        modal.setFooter(note: "⏎ 切換 · ⎋ 取消", buttons: [CoddButton("取消", style: .bracket(.normal, small: false))])
        #expect(modal.showsFooter)
        #expect(modal.footerLeading.count == 1)
        let size = ViewSnapshot.fittingSize(of: modal, width: 520)
        let window = TestSupport.host(modal, size: size)
        defer { window.close() }
        // border 1 + `.sd-modal .m-h` 12 + ✕ 28 + 11, then the dashed rule.
        let expectedBand: CGFloat = 1 + 12 + 28 + 11 + 1
        #expect(modal.headerBandHeight == expectedBand)
        #expect(modal.contentView.frame.minY == modal.headerBandHeight + 16)
        #expect(modal.contentView.frame.minX == 21)
        // body 100 + padding 16, rule 1, footer 12 + 28 + 12, border 1.
        let belowHeader: CGFloat = 16 + 100 + 16 + 1 + 12 + 28 + 12 + 1
        #expect(size.height == expectedBand + belowHeader)
        modal.closeButton.performClick(nil)
        #expect(closed == 1)
        #expect(modal.closeButton.accessibilityLabel() == "關閉")
        #expect(modal.accessibilityLabel() == "Quit · 結束")
        modal.title = "Quit"
        #expect(modal.accessibilityLabel() == "Quit")
    }

    @Test func sectionHeaderViews() {
        let host = SectionHeaderView(title: "Host", hint: "studio-mbp · 曲線為最近 10 分鐘", trailing: [ChipView("● 正常", style: .chip(.ok, caps: true))])
        #expect(ViewSnapshot.fittingSize(of: host, width: 900).height == 20)
        #expect(host.rule.minimumWidth == 24)
        #expect(host.rule.color == Palette.lineBright)
        #expect(host.accessibilityLabel() == "Host studio-mbp · 曲線為最近 10 分鐘")
        let labels = Self.labels(in: host)
        #expect(labels.contains("HOST"))
        let group = SectionHeaderView(title: "Terminal", style: .group, hint: "終端機", count: "3")
        #expect(group.rule.minimumWidth == 0)
        #expect(Self.labels(in: group) == ["TERMINAL", "終端機", "3"])
        group.title = "Auto-switch"
        #expect(Self.labels(in: group).first == "AUTO-SWITCH")
    }

    private static func labels(in view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let field = sub as? NSTextField { out.append(field.stringValue) }
                walk(sub)
            }
        }
        walk(view)
        return out
    }

    // MARK: Form rows

    @Test func formRowHeightsAndLabels() {
        let regular = FormRowView(name: "UI 字級", english: "UI font size", controls: [SwitchToggle(label: "x")])
        #expect(ViewSnapshot.fittingSize(of: regular, width: 640).height == FormRowView.minimumHeight(.regular))
        let tight = FormRowView(name: "門檻", variant: .tight)
        #expect(ViewSnapshot.fittingSize(of: tight, width: 640).height == FormRowView.minimumHeight(.tight))
        #expect(FormRowView.minimumHeight(.regular) == 51)
        #expect(FormRowView.minimumHeight(.tight) == 41)
        let wrapping = FormRowView(name: "剩餘不足時自動切換", english: "Auto-switch",
                                   hint: String(repeating: "由 cswap auto 執行，門檻換算成已用百分比。", count: 4),
                                   controls: [SwitchToggle(label: "x")])
        let narrow = ViewSnapshot.fittingSize(of: wrapping, width: 420).height
        let wide = ViewSnapshot.fittingSize(of: wrapping, width: 1200).height
        #expect(narrow > wide)
        #expect(regular.accessibilityRole() == .group)
        #expect(regular.accessibilityLabel() == "UI 字級 UI font size")
        regular.milestone = "M5"
        #expect(regular.accessibilityLabel() == "UI 字級 UI font size （M5）")
    }

    @Test func disabledFormRowIgnoresClicks() {
        let counter = ActionCounter()
        let box = CheckboxButton(title: "5 小時", target: counter, action: #selector(ActionCounter.fire(_:)))
        let row = FormRowView(name: "檢查", english: "Windows", hint: "任一個 ≤ 門檻就切換", variant: .tight, controls: [box], milestone: "M4")
        let window = TestSupport.host(row, size: NSSize(width: 640, height: 41))
        defer { window.close() }
        let point = row.convert(CGPoint(x: box.bounds.midX, y: box.bounds.midY), from: box)
        let inSuperview = row.convert(point, to: row.superview)
        #expect(row.hitTest(inSuperview) === box)
        row.isEnabled = false
        #expect(row.alphaValue == 0.55)
        #expect(row.hitTest(inSuperview) == nil)
        #expect(box.refusesFirstResponder)
        #expect(!box.acceptsFirstResponder)
        #expect(row.accessibilityChildren()?.isEmpty == true)
        #expect(row.accessibilityIsEnabledValue == false)
        // The control itself stays enabled (no double dimming), only unreachable.
        #expect(box.isEnabled)
        row.isEnabled = true
        #expect(!box.refusesFirstResponder)
        #expect(row.hitTest(inSuperview) === box)
        #expect(counter.count == 0)
    }

    // MARK: Glow, fonts

    @Test func drawGlowEqualsTheAppHelper() {
        // The body of App/Session/HomeCards.swift `HomeHeaderView.glow(_:radius:)`.
        func appGlow(_ color: NSColor, radius: CGFloat) -> NSShadow {
            let shadow = NSShadow()
            shadow.shadowColor = color
            shadow.shadowBlurRadius = radius
            shadow.shadowOffset = .zero
            return shadow
        }
        for radius in [6.0, 8, 10, 12] {
            let ours = Draw.glow(Palette.amberGlow, radius: radius)
            let theirs = appGlow(Palette.amberGlow, radius: radius)
            #expect(ours.shadowColor == theirs.shadowColor)
            #expect(ours.shadowBlurRadius == theirs.shadowBlurRadius)
            #expect(ours.shadowOffset == theirs.shadowOffset)
        }
    }

    @Test func fontRegistrationIsIdempotent() {
        #expect(TestSupport.prepare())
        #expect(TestSupport.prepare())
        #expect(Typeface.mono(13).fontName.contains("JetBrains"))
        #expect(Typeface.display(13).fontName.contains("SpaceMono"))
        // A missing directory registers nothing; the result says whether the faces resolve (they do, from above).
        #expect(Typeface.registerFonts(in: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-\(UUID())")))
    }
}

extension NSView {
    /// `isAccessibilityEnabled()` as a property for #expect.
    fileprivate var accessibilityIsEnabledValue: Bool { isAccessibilityEnabled() }
}
