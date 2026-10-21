import AppKit
import CoddPreferences
import CoddUI

/// 02 APPEARANCE 外觀: the `Preview 預覽` card, CRT, density (`M5`), UI font size (10–20, the
/// interface zoom: ⌘+ / ⌘− / ⌘0 change it too), terminal font and size (8–28), native vibrancy
/// (`M5`), reduce motion.
final class AppearanceSectionView: SettingsSectionView {
    private(set) var preview: AppearancePreviewView?
    private var previewHead: SxGroupHead?
    private(set) var fontStepper: SxStepper?

    override func build() {
        let reset = button("還原本頁預設") { [weak self] in
            self?.model.resetSection(.appearance)
            self?.actions.resetSection(.appearance)
        }
        add(pageHead(lead: SxRich("Phosphor Console 的螢幕效果、密度與字級。"), actions: [reset]))

        let head = groupHead("Preview", cjk: "預覽")
        previewHead = head
        let preview = AppearancePreviewView()
        self.preview = preview
        bind { [weak head, weak preview] prefs, _ in
            let a = prefs.appearance
            head?.setRight("UI \(a.uiFontSize)px · TERM \(a.terminalFontSize)px · CRT \(a.crt.rawValue.uppercased())")
            preview?.configure(crt: a.crt, terminalFont: a.terminalFont, terminalFontSize: CGFloat(a.terminalFontSize))
        }
        add(sxGroup(head, [preview]))

        let crtTitles = ["Full", "Subtle", "Off"]
        let crt = row("appearance.crt", "CRT 效果", en: "CRT effect", hint: "掃描線與暗角；OFF 時仍保留琥珀光暈。",
                      controls: [segmented("appearance.crt", titles: crtTitles, values: [CoddPreferences.CRT.full, .subtle, .off],
                                           label: "CRT 效果", get: { $0.appearance.crt }, set: { $0.appearance.crt = $1 })],
                      keywords: crtTitles)
        let densityTitles = ["Compact", "Comfort"]
        let density = row("appearance.density", "介面密度", en: "Density", hint: "COMPACT 側欄每列 38px；COMFORT 46px。",
                          controls: [segmented("appearance.density", titles: densityTitles,
                                               values: [CoddPreferences.Density.compact, .comfort], label: "介面密度",
                                               get: { $0.appearance.density }, set: { $0.appearance.density = $1 })],
                          milestone: "M5", keywords: densityTitles)
        let sizes = CoddPreferences.Appearance.uiFontSizeOptions
        let uiSize = row("appearance.uiFontSize", "UI 字級", en: "UI font size", hint: "介面文字大小；終端機另外設定。",
                         controls: [select("appearance.uiFontSize", titles: sizes.map(OptionLabels.uiFontSize), values: sizes, width: 160,
                                           label: "UI 字級", get: { $0.appearance.uiFontSize }, set: { $0.appearance.uiFontSize = $1 },
                                           unknownTitle: { "\($0) px" })],
                         keywords: ["zoom", "縮放", "⌘+", "⌘−"])
        add(sxGroup(groupHead("Display", cjk: "畫面"), [SxCard([crt, density, uiSize])]))

        let fonts = CoddPreferences.Appearance.terminalFontOptions
        let font = row("appearance.terminalFont", "終端機字型", en: "Terminal font", hint: "等寬字型；中文自動改用 PingFang TC。",
                       controls: [select("appearance.terminalFont", titles: fonts, values: fonts, width: 200, label: "終端機字型",
                                         get: { $0.appearance.terminalFont }, set: { $0.appearance.terminalFont = $1 })],
                       keywords: fonts)
        let stepper = SxStepper(minus: "A−", plus: "A+", value: "\(model.preferences.appearance.terminalFontSize)",
                                accessibilityLabel: "終端機字級")
        stepper.onStep = { [weak self] delta in
            let range = CoddPreferences.Appearance.terminalFontSizeRange
            self?.edit { $0.appearance.terminalFontSize = min(range.upperBound, max(range.lowerBound, $0.appearance.terminalFontSize + delta)) }
        }
        bind { [weak stepper] prefs, _ in stepper?.value = "\(prefs.appearance.terminalFontSize)" }
        registerControl("appearance.terminalFontSize", stepper)
        fontStepper = stepper
        let fontSize = row("appearance.terminalFontSize", "終端機字級", en: "Terminal font size",
                           hint: "也可在 session 標題列用 A− / A+ 調整，範圍 8–28。", controls: [stepper])
        add(sxGroup(groupHead("Terminal", cjk: "終端機"), [SxCard([font, fontSize])]))

        let vibrancy = row("appearance.nativeVibrancy", "原生玻璃側欄", en: "Native vibrancy",
                           hint: "側欄改用 macOS 毛玻璃材質；與 CRT 同時開啟較耗 GPU。",
                           chips: [chip("實驗", .amber, mini: true)],
                           controls: [toggle("appearance.nativeVibrancy", label: "原生玻璃側欄", get: { $0.appearance.nativeVibrancy },
                                             set: { $0.appearance.nativeVibrancy = $1 })],
                           milestone: "M5")
        let motions = CoddPreferences.ReduceMotion.allCases
        let motion = row("appearance.reduceMotion", "減少動態", en: "Reduce motion", hint: "關閉燈號脈動、游標閃爍與掃描動畫。",
                         controls: [select("appearance.reduceMotion", titles: motions.map(OptionLabels.reduceMotion), values: motions,
                                           width: 160, label: "減少動態", get: { $0.appearance.reduceMotion },
                                           set: { $0.appearance.reduceMotion = $1 })],
                         keywords: motions.map(OptionLabels.reduceMotion))
        add(sxGroup(groupHead("System", cjk: "系統"), [SxCard([vibrancy, motion])]))
    }

    var previewLabel: String? { previewHead?.right?.string }
}

/// `.sx-prev`: 270 px of sample sidebar rows (s1 waiting, s9 busy) and five terminal lines in
/// the chosen terminal font and size, under the chosen CRT overlay (scanlines; FULL adds the
/// vignette). Drawn in one pass, 116 pt tall, clipped like the artboard.
final class AppearancePreviewView: FlippedView {
    private(set) var crt: CoddPreferences.CRT = .off
    private(set) var terminalFontName = "JetBrains Mono"
    private(set) var terminalFontSize: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 116).zoomed(116).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(crt: CoddPreferences.CRT, terminalFont: String, terminalFontSize: CGFloat) {
        guard crt != self.crt || terminalFont != terminalFontName || terminalFontSize != self.terminalFontSize else { return }
        self.crt = crt
        terminalFontName = terminalFont
        self.terminalFontSize = terminalFontSize
        needsDisplay = true
    }

    /// The terminal font as new terminals get it (`SF Mono` is the system monospaced face), with
    /// PingFang TC for CJK.
    static func terminalFont(_ name: String, size: CGFloat) -> NSFont {
        let base: NSFont
        switch name {
        case "SF Mono": base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "Menlo": base = NSFont(name: "Menlo-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default: return Typeface.fixed(size)
        }
        let cascade = base.fontDescriptor.addingAttributes([.cascadeList: [NSFontDescriptor(name: "PingFangTC-Regular", size: size)]])
        return NSFont(descriptor: cascade, size: size) ?? base
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        let side = CGRect(x: 1, y: 1, width: UIZoom.pt(269), height: bounds.height - 2)
        drawSidebar(in: side)
        Draw.fill(CGRect(x: side.maxX, y: 1, width: 1, height: bounds.height - 2), Palette.line)
        let term = CGRect(x: side.maxX + 1, y: 1, width: max(0, bounds.width - side.maxX - 2), height: bounds.height - 2)
        Draw.fill(term, Palette.termBackground)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: term).addClip()
        drawTerminal(in: term)
        NSGraphicsContext.restoreGraphicsState()
        drawCRT(in: bounds.insetBy(dx: 1, dy: 1))
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    private func drawSidebar(in rect: CGRect) {
        let z = UIZoom.pt
        let rowHeight = z(44)
        let first = CGRect(x: rect.minX + z(6), y: rect.minY + z(8), width: rect.width - z(12), height: rowHeight)
        Draw.hGradient(first, from: Palette.amber.withAlphaComponent(0.09), to: Palette.amber.withAlphaComponent(0.02))
        Draw.fill(CGRect(x: first.minX, y: first.minY, width: 2, height: first.height), Palette.amber)
        drawRow(in: first, lamp: "◆", lampColor: Palette.amber, glow: nil, tag: NSColor(hex: 0xEF5B5B), title: "修正登入 API 401",
                titleColor: Palette.cream, state: "Perm", stateFilled: true, stateColor: Palette.amber,
                line2: [("3m", Palette.amber), ("·", Palette.dimmer), ("藍鵲·網站 / orb-toolkit-backend", Palette.dimmer)])
        let second = first.offsetBy(dx: 0, dy: rowHeight + z(2))
        drawRow(in: second, lamp: "●", lampColor: Palette.success, glow: Palette.success.withAlphaComponent(0.55), tag: NSColor(hex: 0xFF7CB5),
                title: "打卡頁 RWD 調整", titleColor: Palette.bone, state: "Busy", stateFilled: false, stateColor: Palette.success,
                line2: [("Edit · 6m", Palette.success), ("·", Palette.dimmer), ("up 1h18m", Palette.dimmer)])
    }

    private func drawRow(in rect: CGRect, lamp: String, lampColor: NSColor, glow: NSColor?, tag: NSColor, title: String, titleColor: NSColor,
                         state: String, stateFilled: Bool, stateColor: NSColor, line2: [(String, NSColor)]) {
        let z = UIZoom.pt
        let s = UIZoom.scaled
        let l1 = rect.minY + s(4 + 9.5)
        let l2 = l1 + s(9.5 + 1 + 8)
        var x = rect.minX + z(10)
        var lampStyle = TextStyle.mono(lamp == "◆" ? 12 : 11, lampColor)
        if let glow { lampStyle.shadow = Draw.glow(glow, radius: 6) }
        let lampText = lampStyle.string(lamp)
        Draw.text(lampText, x: x + (z(12) - Draw.width(lampText)) / 2, centerY: l1)
        x += z(12 + 7)
        let side = z(8)
        Draw.fill(CGRect(x: x, y: round(l1 - side / 2), width: side, height: side), tag)
        x += side + z(7)
        let pillStyle = TextStyle(font: Typeface.mono(9.5, stateFilled ? .bold : .medium), color: stateFilled ? .black : stateColor,
                                  tracking: 0.14, uppercase: true)
        let pill = ChipStyle(text: pillStyle, border: stateColor, fill: stateFilled ? stateColor : nil, height: 15, padding: 5)
        let pillWidth = pill.size(for: state).width
        let right = rect.maxX - z(8)
        Draw.text(TextStyle.mono(12.5, titleColor).string(title), x: x, centerY: l1, maxWidth: max(0, right - pillWidth - z(7) - x))
        pill.draw(state, x: right - pillWidth, centerY: l1)
        var x2 = rect.minX + z(10 + 19)
        for (text, color) in line2 {
            x2 += Draw.text(TextStyle.mono(10.5, color).string(text), x: x2, centerY: l2, maxWidth: max(0, right - x2)) + z(6)
        }
    }

    private func drawTerminal(in rect: CGRect) {
        let font = Self.terminalFont(terminalFontName, size: terminalFontSize)
        let lineHeight = ceil(terminalFontSize * 1.45)
        func style(_ color: NSColor, bold: Bool = false) -> [NSAttributedString.Key: Any] {
            var f = font
            if bold { f = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if bold, terminalFontName == "JetBrains Mono" { f = Typeface.fixed(terminalFontSize, .bold) }
            return [.font: f, .foregroundColor: color, .ligature: 0]
        }
        let fg = Palette.termForeground
        let dim = Palette.termDim
        let lines: [[(String, NSColor, Bool)]] = [
            [(">", dim, false), (" 登入 API 在 token 過期後會回 401，幫我修好並補測試", fg, false)],
            [("●", Palette.termClaude, false), (" ", fg, false), ("Update", Palette.termWhite, true), ("(src/middleware/auth.ts)", fg, false)],
            [("  ⎿  Updated src/middleware/auth.ts with 12 additions and 3 removals", dim, false)],
            [("●", Palette.termClaude, false), (" ", fg, false), ("Bash", Palette.termWhite, true), ("(npm test -- auth.spec.ts)", fg, false)],
            [("  Do you want to proceed?  ", fg, false), ("❯ 1. Yes", Palette.amber, false)],
        ]
        var y = rect.minY + 10
        for line in lines {
            let text = NSMutableAttributedString()
            for (piece, color, bold) in line { text.append(NSAttributedString(string: piece, attributes: style(color, bold: bold))) }
            text.draw(with: CGRect(x: rect.minX + 14, y: y, width: 4000, height: lineHeight + 4), options: [.usesLineFragmentOrigin])
            y += lineHeight
            if y > rect.maxY { break }
        }
    }

    /// helmet `.crt-subtle::after` / `.crt-full::after`: an amber line every 3 pt (1 pt tall),
    /// FULL twice as strong plus the radial vignette. The alphas match the app's overlay.
    private func drawCRT(in rect: CGRect) {
        guard crt != .off else { return }
        let alpha: CGFloat = crt == .full ? 0.06 : 0.03
        let color = NSColor(srgbRed: 1, green: 176 / 255, blue: 0, alpha: alpha)
        var y = rect.minY
        while y < rect.maxY {
            Draw.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 1), color)
            y += 3
        }
        guard crt == .full, let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.42).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0.55, 1]) else { return }
        context.saveGState()
        context.clip(to: rect)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // `radial-gradient(ellipse at center …)`: an ellipse reaching the corners.
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: rect.width / max(1, rect.height), y: 1)
        let radius = rect.height / 2 * sqrt(2)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [.drawsAfterEndLocation])
        context.restoreGState()
    }
}
