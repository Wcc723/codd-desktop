import AppKit
import CoddUI
import Observation
import Testing

// Compile-level proof that every declaration copied from App/ is reachable from another module
// with plain `import CoddUI` (no @testable), and that the classes the app subclasses are `open`
// with overridable members. If an access modifier were missing, this file would not compile.

final class ProbeFlippedView: FlippedView {
    var drawn = 0
    var laidOut = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawn += 1 }
    override func layout() { super.layout(); laidOut += 1 }
}

final class ProbePanelView: PanelView {
    var drawn = 0
    var laidOut = 0
    var fillChanges = 0
    override var fill: NSColor? { didSet { fillChanges += 1 } }
    override var edges: PanelView.Edges { didSet { needsDisplay = true } }
    override var edgeColor: NSColor { didSet { needsDisplay = true } }
    override var dashedEdges: PanelView.Edges { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); drawn += 1 }
    override func layout() { super.layout(); laidOut += 1 }
}

final class ProbeDragView: WindowDragView {
    var downs = 0
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
    override func layout() { super.layout() }
}

final class ProbeFieldBox: FieldBoxView {
    var drawn = 0
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFocused: Bool { didSet { needsDisplay = true } }
    override var isDimmed: Bool { didSet { needsDisplay = true } }
    override var fill: NSColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); drawn += 1 }
    override func layout() { super.layout() }
}

/// A 1 Hz subscriber and a pulse subscriber from outside the module.
final class ProbeTicking: NSView, SecondTicking, PulseSubscriber {
    var ticks = 0
    var motionChanges = 0
    func secondTick(now: Date) { ticks += 1 }
    func motionPreferenceChanged() { motionChanges += 1 }
}

@MainActor @Observable
final class ProbeModel {
    var value = 0
}

@MainActor
@Suite("Public API")
struct PublicAPITests {
    init() { TestSupport.prepare() }

    @Test func themeTokensAndTypeface() {
        let colors: [NSColor] = [Palette.bg, Palette.bgSoft, Palette.bgLift, Palette.bgRaise, Palette.line, Palette.lineBright,
                                 Palette.amber, Palette.amberDim, Palette.amberGlow, Palette.cream, Palette.bone, Palette.dim,
                                 Palette.dimmer, Palette.cyan, Palette.danger, Palette.success, Palette.successDim,
                                 Palette.termBackground, Palette.termForeground, Palette.termDim, Palette.termWhite, Palette.termClaude,
                                 Palette.termAddBackground, Palette.termAddText, Palette.termDelBackground, Palette.termDelText]
        #expect(colors.count == 26)
        let metrics: [CGFloat] = [Metrics.railWidth, Metrics.sidebarWidth, Metrics.sidebarMinWidth, Metrics.sidebarMaxWidth,
                                  Metrics.mainMinWidth, Metrics.headerHeight, Metrics.tabStripHeight, Metrics.statusBarHeight,
                                  Metrics.sessionRowHeight, Metrics.doneRowHeight, Metrics.groupHeaderHeight, Metrics.groupGap,
                                  Metrics.projectRowHeight, Metrics.sectionHeaderHeight, Metrics.addGroupRowHeight,
                                  Metrics.emptyProjectRowHeight, Metrics.sidebarInset]
        #expect(metrics == [72, 280, 220, 400, 560, 52, 30, 24, 38, 28, 22, 5, 22, 26, 38, 22, 6])
        #expect(TestSupport.rgb(NSColor(hex: 0x123456)) == [0x12, 0x34, 0x56])
        #expect(TestSupport.rgb(NSColor.white.mixed(with: .black, fraction: 0.5)) == [128, 128, 128])

        let weights: [Typeface.Weight] = [.regular, .medium, .semibold, .bold]
        #expect(weights.map(\.rawValue) == [400, 500, 600, 700])
        #expect(Typeface.mono(12).fontName.contains("JetBrains"))
        #expect(Typeface.mono(12, .bold).pointSize == 12)
        #expect(Typeface.display(13).fontName.contains("SpaceMono"))
        #expect(Typeface.lineHeight(Typeface.mono(13)) > 13)
        Typeface.registerBundledFontsIfNeeded()
    }

    @Test func drawingHelpersAndStyles() {
        var style = TextStyle(font: Typeface.mono(11), color: Palette.cream, tracking: 0.1, uppercase: true, shadow: nil)
        style.color = Palette.dim
        #expect(style.string("abc").string == "ABC")
        #expect(style.attributes()[.kern] as? CGFloat == 1.1)
        #expect(style.with(color: Palette.amber).color == Palette.amber)
        _ = TextStyle.mono(11, Palette.dim)
        _ = TextStyle.mono(11, Palette.dim, tracking: 0.04, .medium)
        _ = TextStyle.caps(10.5, Palette.dim)
        #expect(Draw.width(style.string("x")) > 0)

        let chip = ChipStyle(text: TextStyle.mono(10, .black), border: Palette.lineBright, fill: nil, dashed: true, height: 16, padding: 4)
        #expect(chip.size(for: "M4").height == 16)
        for preset in [ChipStyle.smallChip(Palette.cyan, border: Palette.cyan), .ext, .badge] { #expect(preset.height > 0) }

        // Draw.* and IconRenderer / drawSmallBracket need a graphics context: draw into a bitmap.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let context = rep.flatMap(NSGraphicsContext.init(bitmapImageRep:))
        #expect(context != nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = CGRect(x: 0, y: 0, width: 80, height: 40)
        Draw.fill(rect, Palette.bg)
        Draw.strokeRect(rect, color: Palette.lineBright)
        Draw.dashedRect(rect.insetBy(dx: 2, dy: 2), color: Palette.line)
        Draw.dashedLine(from: .zero, to: CGPoint(x: 80, y: 0), color: Palette.line)
        Draw.hGradient(rect, from: .clear, to: Palette.lineBright)
        Draw.caret(open: true, at: CGPoint(x: 4, y: 20), color: Palette.dim)
        #expect(Draw.text(style.string("ok"), x: 2, centerY: 20) > 0)
        #expect(chip.draw("M4", x: 0, centerY: 20) > 0)
        IconRenderer.draw(.sessions, in: CGRect(x: 0, y: 0, width: 20, height: 20), color: Palette.amber, flipped: false)
        CoddButton.drawSmallBracket("加入", in: CGRect(x: 0, y: 0, width: 60, height: 22))
        NSGraphicsContext.restoreGraphicsState()

        let icons: [Icon] = [.sessions, .notes, .status, .settings, .search, .files, .bottomTerminal, .plus, .window, .brand,
                             .folder, .maximize, .restore, .copy]
        #expect(icons.count == 14)
        #expect(SVGPath.tokenize("M2 11h3.5") == [SVGPath.Token.command("M"), .number(2), .number(11), .command("h"), .number(3.5)])
        #expect(!SVGPath.parse("M2 11h3.5l2-5.5").isEmpty)
    }

    @Test func openClassesCanBeSubclassedAndOverridden() {
        let flipped = ProbeFlippedView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let panel = ProbePanelView(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.line, dashed: [.bottom])
        panel.fill = Palette.bgLift
        #expect(panel.fillChanges == 1)
        panel.edges = [.top]
        panel.edgeColor = Palette.lineBright
        panel.dashedEdges = []
        let drag = ProbeDragView(fill: nil)
        let field = ProbeFieldBox(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        field.isFocused = true
        field.isDimmed = true
        field.fill = Palette.bg
        #expect(field.alphaValue == 0.55)

        for (view, size) in [(flipped as NSView, NSSize(width: 40, height: 20)), (panel, NSSize(width: 40, height: 20)),
                             (drag, NSSize(width: 40, height: 20)), (field, NSSize(width: 80, height: 30))] {
            _ = ViewSnapshot.render(view, size: size)
        }
        #expect(flipped.drawn >= 1)
        #expect(flipped.laidOut >= 1)
        #expect(panel.drawn >= 1)
        #expect(panel.laidOut >= 1)
        #expect(field.drawn >= 1)
        #expect(!drag.mouseDownCanMoveWindow)
        #expect(flipped.isFlipped)
    }

    @Test func basicViewsAndStacks() {
        let label = Label.make("hello", style: TextStyle.mono(12, Palette.cream))
        Label.set(label, "world", style: TextStyle.mono(12, Palette.cream))
        #expect(label.stringValue == "world")
        let wrapping = WrappingLabel("多行文字", style: TextStyle.mono(12, Palette.bone))
        let row = hStack([label, spacer()], spacing: 6)
        let column = vStack([row], spacing: 4, alignment: .leading)
        let full = columnStack([wrapping], spacing: 2)
        full.addFullWidth(ChipView("x", style: .badge))
        let host = FlippedView()
        host.addSubview(column)
        column.pinEdges(to: host, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        #expect(host.descendant(ofType: NSTextField.self) === label)
        #expect(full.arrangedSubviews.count == 2)
    }

    @Test func copiedControlsAreConstructible() {
        let chip = ChipView("MAX 20x", style: .smallChip(Palette.cyan, border: Palette.lineBright))
        chip.set("MAX 5x")
        _ = ChipView.kbd("⌘K")
        let styles: [CoddButton.Style] = [.bracket(.normal, small: false), .bracket(.primary, small: true), .bracket(.danger, small: false),
                                          .bracket(.accent, small: true), .icon(.plus), .icon(.search, size: 24), .glyph(), .glyph(size: 22),
                                          .key(cap: "1", danger: false), .pill(count: "3"), .smallPill, .tab(lamp: "●", lampColor: Palette.success),
                                          .link, .addRow, .plain]
        for style in styles {
            let button = CoddButton("Label", style: style, target: nil, action: nil)
            button.trailing = "⌘1"
            button.isOn = true
            button.tabMarks = [.running, .bell]
            #expect(button.intrinsicContentSize.height > 0)
            #expect(!button.isHovered)
        }
        #expect(CoddButton.markWidth == 12)

        let input = InputField(placeholder: "別名", size: 12.5, accessibilityLabel: "別名")
        input.text = "studio"
        input.onChange = { _ in }
        input.onFocusChange = { _ in }
        input.onCommand = { _ in false }
        input.isEnabled = false
        #expect(input.field.stringValue == "studio")
        #expect(!input.isComposing)
        let select = SelectButton(titles: ["a", "b"], selected: 1, accessibilityLabel: "選擇")
        select.onSelect = { _ in }
        select.setItems(["x", "y", "z"], selected: 2)
        select.displayTitle = "自訂"
        #expect(select.currentTitle == "自訂")
        #expect(select.selectedIndex == 2)
        let radio = RadioRowView(title: "跟隨", hint: "預設")
        radio.isOn = true
        radio.onClick = {}
        let toggle = SwitchToggle(label: "通知")
        toggle.isOn = true
        let area = TextAreaField(accessibilityLabel: "環境變數")
        area.text = "A=1"
        area.onChange = { _ in }
        let square = ColorSquareView(color: nil)
        square.color = Palette.cyan
        let segments = SegmentedSwitch(titles: ["A", "B"], raw: true)
        segments.selectedIndex = 1
        #expect(segments.titles == ["A", "B"])
        let toast = ToastView(text: "✕ 3 個 session 已封存", undo: {}, countdown: 5)
        toast.advanceCountdown()
        #expect(toast.remainingSeconds == 4)
        #expect(toast.countdownLabelText == "4s")
        #expect(ToastView.countdownText(3) == "3s")
        #expect(ToastView.countdownMessage("✕ x").string == "✕ x")
        let plainToast = ToastView(text: "已切換", undo: nil)
        plainToast.dismiss(after: 60)
        let item = ClosureMenuItem(title: "還原") {}
        #expect(item.target === item)
        let rule = DashedRuleView()
        #expect(rule.intrinsicContentSize.height == 1)
        let brightRule = DashedRuleView(color: Palette.lineBright, minimumWidth: 24)
        #expect(brightRule.minimumWidth == 24)
    }

    @Test func supportAndModel() async throws {
        let ticker = UITicker(windowIsVisible: { _ in true }, reduceMotion: { false })
        let probe = ProbeTicking()
        ticker.addSecond(probe)
        ticker.addPulse(probe)
        #expect(ticker.pulseSubscriberCount == 1)
        #expect(ticker.pulsesAllowed)
        #expect(!ticker.isSecondTimerRunning) // not in a window
        ticker.updateTimers()
        ticker.removeSecond(probe)
        ticker.removePulse(probe)
        ticker.clock = DisplayClock(offset: 60)
        #expect(ticker.clock.now().timeIntervalSinceNow > 50)
        _ = UITicker.shared
        _ = UITicker.isOnScreen(NSWindow())
        #if DEBUG
        _ = UITicker.forceVisible
        #endif

        let model = ProbeModel()
        var seen: [Int] = []
        let loop = ObservationLoop(track: { model.value }, apply: { seen.append($0) })
        model.value = 1
        try await Task.sleep(for: .milliseconds(50))
        loop.refresh()
        loop.cancel()
        #expect(loop.isCancelled)
        #expect(seen.first == 0)
        #expect(seen.contains(1))
        let simple = ObservationLoop { _ = model.value }
        simple.cancel()

        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DurationFormat.compact(72) == "1m12s")
        #expect(DurationFormat.countdown(to: now.addingTimeInterval(2 * 3600 + 57 * 60 + 30), now: now) == "2h57m後")
        #expect(DurationFormat.ago(now.addingTimeInterval(-12), now: now) == "12s 前")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12, minute: 0, second: 7)))
        #expect(ClockFormat.resetLabel(sunday, now: now, calendar: calendar) == "10/18 週日 12:00")
        #expect(ClockFormat.hourMinute(sunday, calendar: calendar) == "12:00")
        #expect(ClockFormat.hourMinuteSecond(sunday, calendar: calendar) == "12:00:07")
        #expect(PathFormat.short("~/a/b/c/d/e") == "~/…/d/e")
        #expect(PathFormat.lastComponent("~/Github/UsageBar") == "UsageBar")
        #expect(PathFormat.abbreviateHome("/Users/x/y", home: "/Users/x") == "~/y")
        #expect(PathFormat.expandTilde("~/x").hasSuffix("/x"))
        #expect(DisplayClock().offset == 0)
    }
}
