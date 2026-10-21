import AppKit
import CoddUI
import Testing

/// M4 interface zoom: the scale math, fonts and lengths at a zoom, styles kept from another zoom,
/// and the in-place refresh. Every test runs synchronously on the main actor and puts the zoom
/// back to the default before it returns (other suites draw at the design size).
@Suite("Interface zoom")
@MainActor
struct ZoomTests {
    init() { TestSupport.prepare() }

    @Test func scaleMathAndClamping() {
        #expect(UIZoom.defaultFontSize == 13 && UIZoom.fontSizeRange == 10...20)
        #expect(UIZoom.scale(forFontSize: 13) == 1, "the default is exactly 1")
        // The expected values are typed: an untyped `14.0 / 13.0` on the right of `==` inside
        // `#expect` compares false on this toolchain although both sides print the same bits.
        #expect(UIZoom.scale(forFontSize: 14) == CGFloat(14) / 13)
        #expect(UIZoom.scale(forFontSize: 4) == CGFloat(10) / 13, "clamped to 10")
        #expect(UIZoom.scale(forFontSize: 40) == CGFloat(20) / 13, "clamped to 20")
        #expect(UIZoom.clamped(9) == 10 && UIZoom.clamped(21) == 20 && UIZoom.clamped(16) == 16)
    }

    @Test func lengthsAreExactAtTheDefaultAndWholePointsOtherwise() {
        #expect(UIZoom.scale == 1)
        #expect(UIZoom.pt(9.5) == 9.5, "nothing is rounded at the default")
        #expect(UIZoom.pt(38) == 38)
        #expect(UIZoom.scaled(3.2) == 3.2)
        #expect(UIZoom.length(38, scale: 14.0 / 13.0) == 41)
        #expect(UIZoom.length(9.5, scale: 14.0 / 13.0) == 10)
        #expect(UIZoom.length(52, scale: 20.0 / 13.0) == 80)
        UIZoom.withScale(1.5) {
            #expect(UIZoom.pt(22) == 33)
            #expect(UIZoom.scaled(3) == 4.5)
            let insets = UIZoom.insets(NSEdgeInsets(top: 4, left: 6, bottom: 8, right: 10))
            #expect(insets.top == 6 && insets.left == 9 && insets.bottom == 12 && insets.right == 15)
            #expect(Metrics.sessionRowHeight == 57 && Metrics.headerHeight == 78)
            #expect(Metrics.mainMinWidth == Metrics.Design.mainMinWidth, "the pane's minimum never zooms")
        }
        #expect(UIZoom.scale == 1, "withScale restores the scale")
        #expect(Metrics.sessionRowHeight == Metrics.Design.sessionRowHeight)
    }

    @Test func fontsFollowTheZoomAndFixedFontsDoNot() {
        #expect(Typeface.mono(13).pointSize == 13)
        #expect(Typeface.display(26).pointSize == 26)
        UIZoom.withScale(14.0 / 13.0) {
            #expect(abs(Typeface.mono(13).pointSize - 14) < 0.001)
            #expect(abs(Typeface.display(26).pointSize - 28) < 0.001)
            #expect(Typeface.fixed(13).pointSize == 13, "terminal text keeps its own size")
            #expect(Typeface.mono(13).fontName.contains("JetBrains"))
        }
    }

    /// AppKit shares one instance per identical descriptor; made fonts must not, or `mono(14)` and
    /// a zoomed `mono(13)` (both 14 pt) would lose their design sizes.
    @Test func fontsOfTheSameSizeKeepTheirDesignSpecs() {
        let fourteen = Typeface.mono(14)
        let zoomedThirteen = UIZoom.withScale(14.0 / 13.0) { Typeface.mono(13) }
        #expect(abs(fourteen.pointSize - zoomedThirteen.pointSize) < 0.001)
        #expect(fourteen !== zoomedThirteen)
        #expect(Typeface.spec(of: fourteen)?.size == 14)
        #expect(Typeface.spec(of: zoomedThirteen)?.size == 13)
        #expect(Typeface.scale(of: fourteen) == 1)
        #expect(Typeface.spec(of: NSFont.systemFont(ofSize: 13)) == nil, "a foreign font is unknown")
        UIZoom.withScale(1.5) {
            #expect(abs(Typeface.current(fourteen).pointSize - 21) < 0.001)
            #expect(abs(Typeface.current(zoomedThirteen).pointSize - 19.5) < 0.001)
            let system = NSFont.systemFont(ofSize: 13)
            #expect(Typeface.current(system) === system)
            let fixed = Typeface.fixed(13)
            #expect(Typeface.current(fixed) === fixed)
        }
        #expect(Typeface.current(fourteen) === fourteen, "back at its own zoom: the same font")
    }

    @Test func storedStylesAndChipsFollowTheZoom() {
        let style = TextStyle.mono(12, Palette.cream, tracking: 0.1)
        var chip = ChipStyle(text: TextStyle.mono(10, Palette.amber), height: 20, padding: 7)
        #expect(chip.height == 20 && chip.padding == 7)
        UIZoom.withScale(1.5) {
            #expect(abs(style.font.pointSize - 18) < 0.001, "a style made at 13 draws at the new zoom")
            let kern = style.attributes()[.kern] as? CGFloat
            #expect(kern.map { abs($0 - 1.8) < 0.001 } == true, "letter spacing is in em")
            #expect(chip.height == 30 && chip.padding == 11)
            chip.height = 16
            #expect(chip.height == 24, "set in design points, read at the zoom")
        }
        #expect(abs(style.font.pointSize - 12) < 0.001)
        #expect(chip.height == 16)
        let lineHeight = style.attributes(lineHeight: 18)[.paragraphStyle] as? NSParagraphStyle
        #expect(lineHeight?.minimumLineHeight == 18)
    }

    @Test func attributedStringsAreRescaledWithTheirTypeLengths() throws {
        let base = TextStyle.mono(12, Palette.cream, tracking: 0.1).string("打卡 RWD", lineHeight: 18)
        #expect(Typeface.rescaled(base) == nil, "already current")
        let scaled = try #require(UIZoom.withScale(1.5) { Typeface.rescaled(base) })
        let font = try #require(scaled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - 18) < 0.001)
        let kern = try #require(scaled.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)
        #expect(abs(kern.doubleValue - 1.8) < 0.001)
        let paragraph = try #require(scaled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(paragraph.minimumLineHeight - 27) < 0.001)
        #expect(scaled.string == base.string)
        let foreign = NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        #expect(UIZoom.withScale(1.5) { Typeface.rescaled(foreign) } == nil)
    }

    @Test func applyRefreshesLabelsConstraintsAndZoomViewsInPlace() {
        defer { UIZoom.apply(fontSize: UIZoom.defaultFontSize) }
        let root = FlippedView()
        let label = Label.make("UI 字級", style: TextStyle.mono(12, Palette.bone))
        let probe = ZoomProbeView()
        let height = probe.heightAnchor.constraint(equalToConstant: 0).zoomed(24)
        height.isActive = true
        #expect(height.constant == 24 && height.zoomDesignValue == 24)
        root.addSubview(label)
        root.addSubview(probe)
        let window = TestSupport.host(root, size: NSSize(width: 300, height: 120))
        defer { window.close() }
        let notified = ScaleRecorder()
        let observer = NotificationCenter.default.addObserver(forName: UIZoom.didChangeNotification, object: nil, queue: nil) { note in
            if let value = note.userInfo?["new"] as? CGFloat { notified.append(value) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(UIZoom.apply(fontSize: 13) == false, "the default is already applied")
        #expect(UIZoom.apply(fontSize: 26) == true)
        #expect(UIZoom.fontSize == 20, "clamped to 20")
        let font = label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font.map { abs($0.pointSize - 12 * 20 / 13) < 0.001 } == true)
        #expect(height.constant == UIZoom.length(24, scale: 20.0 / 13.0))
        #expect(probe.refreshes == 1)
        #expect(notified.values == [20.0 / 13.0])

        #expect(UIZoom.apply(fontSize: 13) == true)
        let back = label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(back?.pointSize == 12)
        #expect(height.constant == 24)
        #expect(probe.refreshes == 2)
    }

    @Test func trackedViewsOutOfAWindowAreRefreshedToo() {
        defer { UIZoom.apply(fontSize: UIZoom.defaultFontSize) }
        let probe = ZoomProbeView()
        UIZoom.track(probe)
        UIZoom.apply(fontSize: 15)
        #expect(probe.refreshes == 1)
        UIZoom.apply(fontSize: 13)
        #expect(probe.refreshes == 2)
    }
}

/// Counts its zoom refreshes.
@MainActor
private final class ZoomProbeView: NSView, ZoomRefreshing {
    private(set) var refreshes = 0
    func zoomDidChange() { refreshes += 1 }
}

/// Scales seen by a notification observer (its closure is `@Sendable`).
private final class ScaleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CGFloat] = []
    func append(_ value: CGFloat) { lock.withLock { recorded.append(value) } }
    var values: [CGFloat] { lock.withLock { recorded } }
}
