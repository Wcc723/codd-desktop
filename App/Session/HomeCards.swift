import AppKit
import CoddUI

// The Home page's pieces (Home artboard `.hm-*`): custom-drawn, hand-laid views that keep their
// model and redraw their durations on the 1 Hz tick only when the drawn text changes.

/// A home-page length: a design point at the current interface zoom (the cards are drawn by
/// hand, so their offsets follow the zoom like their fonts; exact at UI 字級 13).
func hz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// Something on the home page that shows a duration.
@MainActor
protocol HomeTicking: AnyObject {
    func tick(now: Date)
}

/// `.hm-head`: `// 沒有選取 session`, `SESSIONS` with the live date on the right, the `.meta-rule`.
final class HomeHeaderView: FlippedView, HomeTicking {
    var comment = "// 沒有選取 session" { didSet { needsDisplay = true } }
    var counts = HomeModel.Counts() { didSet { if counts != oldValue { needsDisplay = true } } }
    private var dateText = ""

    static var height: CGFloat { hz(82) }

    /// `2026-10-15 週四 10:42`.
    static func dateText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let weekdays = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]
        return String(format: "%04d-%02d-%02d ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            + weekdays[((parts.weekday ?? 1) - 1) % 7] + " " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    func tick(now: Date) {
        let text = Self.dateText(now)
        guard text != dateText else { return }
        dateText = text
        needsDisplay = true
    }

    /// The meta rule's text with its amber and green counts.
    static func metaRule(_ c: HomeModel.Counts) -> NSAttributedString {
        let base = TextStyle.caps(11, Palette.dim, tracking: 0.18)
        let text = NSMutableAttributedString(attributedString: base.string("\(c.live) live · "))
        text.append(base.with(color: Palette.amber).string("◆ \(c.needsYou)"))
        text.append(base.string(" needs you · "))
        text.append(base.with(color: Palette.success).string("● \(c.working)"))
        text.append(base.string(" working · ✕ \(c.exited) exited"))
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(TextStyle.mono(12, Palette.dimmer).string(comment), x: 0, centerY: hz(9), maxWidth: bounds.width)
        var title = TextStyle(font: Typeface.display(26), color: Palette.amber, tracking: 0.02)
        title.shadow = Self.glow(Palette.amberGlow, radius: 12)
        let width = Draw.text(title.string("SESSIONS"), x: 0, centerY: hz(26 + 16))
        let date = TextStyle.mono(11, Palette.dim, tracking: 0.06).string(dateText)
        let dateWidth = Draw.width(date)
        let dateX = max(width + hz(16), bounds.width - dateWidth)
        Draw.text(date, x: dateX, centerY: hz(26 + 20), maxWidth: max(0, bounds.width - dateX))
        // `.meta-rule`: text in the middle, lines fading toward it from both sides (a narrow page
        // truncates the text and drops the lines).
        let rule = Self.metaRule(counts)
        let ruleWidth = min(Draw.width(rule), bounds.width)
        let y = hz(65 + 8.5)
        let textX = max(0, (bounds.width - ruleWidth) / 2)
        let gap = hz(12)
        let left = CGRect(x: 0, y: floor(y), width: max(0, textX - gap), height: 1)
        let right = CGRect(x: textX + ruleWidth + gap, y: floor(y), width: max(0, bounds.width - textX - ruleWidth - gap), height: 1)
        Draw.hGradient(left, from: Palette.lineBright, to: Palette.lineBright.withAlphaComponent(0))
        Draw.hGradient(right, from: Palette.lineBright.withAlphaComponent(0), to: Palette.lineBright)
        Draw.text(rule, x: textX, centerY: y, maxWidth: ruleWidth)
    }

    /// The glow moved to CoddUI (`Draw.glow`, M3 D30); kept for the App call sites.
    static func glow(_ color: NSColor, radius: CGFloat) -> NSShadow { Draw.glow(color, radius: radius) }
}

/// `.hm-sh`: `◆ NEEDS YOU` `3` ┄┄┄ (right-hand views laid out by the owner).
final class HomeSectionHeadView: FlippedView {
    let title: String
    let zh: String?
    let glyph: String?
    var badge: Int? { didSet { if badge != oldValue { needsDisplay = true } } }
    /// Views at the right end (the owner adds them as subviews; laid out here).
    var accessories: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            accessories.forEach { $0.translatesAutoresizingMaskIntoConstraints = true; addSubview($0) }
            needsLayout = true
        }
    }

    static var height: CGFloat { hz(20) }

    init(title: String, zh: String? = nil, glyph: String? = nil) {
        self.title = title
        self.zh = zh
        self.glyph = glyph
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title, zh].compactMap { $0 }.joined(separator: " "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the heading (and its badge) ends.
    private var headingWidth: CGFloat {
        var x: CGFloat = 0
        if let glyph { x += Draw.width(TextStyle.mono(12, Palette.amber).string(glyph)) + hz(8) }
        x += Draw.width(Self.heading.string(title))
        if let zh { x += hz(8) + Draw.width(Self.zhStyle.string(zh)) }
        if let badge { x += hz(10) + ChipStyle.badge.size(for: "\(badge)").width }
        return x
    }

    private static var heading: TextStyle { TextStyle(font: Typeface.display(12), color: Palette.amber, tracking: 0.16, uppercase: true) }
    private static var zhStyle: TextStyle { TextStyle.mono(12, Palette.dim, tracking: 0.06) }

    /// Accessories right-aligned; the leftmost gives up width rather than cover the heading.
    override func layout() {
        super.layout()
        let minX = headingWidth + hz(10)
        var x = bounds.width
        for view in accessories.reversed() {
            let size = view.intrinsicContentSize
            let left = max(minX, x - size.width)
            view.frame = CGRect(x: left, y: (bounds.height - size.height) / 2, width: max(0, x - left), height: size.height)
            // An accessory squeezed below half its width hides (a narrow page keeps the heading).
            view.isHidden = x - left < size.width / 2
            x = view.isHidden ? x : left - hz(8)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x: CGFloat = 0
        if let glyph { x += Draw.text(TextStyle.mono(12, Palette.amber).string(glyph), x: x, centerY: mid) + hz(8) }
        x += Draw.text(Self.heading.string(title), x: x, centerY: mid)
        if let zh { x += hz(8) + Draw.text(Self.zhStyle.string(zh), x: x + hz(8), centerY: mid) }
        if let badge {
            x += hz(10)
            x += ChipStyle.badge.draw("\(badge)", x: x, centerY: mid)
        }
        let shown = accessories.filter { !$0.isHidden }
        let ruleEnd = (shown.map(\.frame.minX).min() ?? bounds.width) - (shown.isEmpty ? 0 : hz(10))
        if ruleEnd - (x + hz(10)) >= hz(24) {
            Draw.dashedLine(from: CGPoint(x: x + hz(10), y: floor(mid)), to: CGPoint(x: ruleEnd, y: floor(mid)), color: Palette.lineBright)
        }
    }
}

/// `.card` box with the ASCII corners `┌─` / `─┘` drawn over the border. The view is taller than
/// the card by `outset` above and below (the corners stick out of the box).
class HomeCardBoxView: FlippedView {
    static var outset: CGFloat { hz(7) }
    var borderColor = Palette.lineBright { didSet { needsDisplay = true } }
    var cornerColor = Palette.amberDim { didSet { needsDisplay = true } }
    var corners = true

    /// The card's own rectangle inside the view.
    var box: CGRect { bounds.insetBy(dx: 0, dy: Self.outset) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(box, Palette.bgSoft)
        Draw.strokeRect(box, color: borderColor)
        guard corners else { return }
        let style = TextStyle.mono(11, cornerColor)
        let open = style.string("┌─")
        let openWidth = Draw.width(open) + hz(8)
        Draw.fill(CGRect(x: box.minX - 1, y: box.minY - hz(6), width: openWidth, height: hz(12)), Palette.bg)
        Draw.text(open, x: box.minX + hz(3), centerY: box.minY)
        let close = style.string("─┘")
        let closeWidth = Draw.width(close) + hz(8)
        Draw.fill(CGRect(x: box.maxX + 1 - closeWidth, y: box.maxY - hz(6), width: closeWidth, height: hz(12)), Palette.bg)
        Draw.text(close, x: box.maxX + 1 - closeWidth + hz(4), centerY: box.maxY)
    }
}

/// One NEEDS YOU card (`.card.hm-nc`, `.hot` while waiting, danger border on error).
final class NeedsYouCardView: HomeCardBoxView, HomeTicking {
    let card: HomeModel.NeedsYouCard
    private let allow: CoddButton?
    private let go: CoddButton
    private var duration = ""
    private var uptime = ""

    static var height: CGFloat { hz(158) }

    init(_ card: HomeModel.NeedsYouCard, now: Date, target: AnyObject, allowAction: Selector, goAction: Selector) {
        self.card = card
        if card.canAllow {
            let button = CoddButton("允許", style: .key(cap: "1", danger: false), target: target, action: allowAction)
            button.setAccessibilityLabel("允許 \(card.title)")
            allow = button
        } else {
            allow = nil
        }
        go = CoddButton("前往", style: .bracket(.normal, small: true), target: target, action: goAction)
        go.trailing = card.number.map { "⌘\($0)" }
        go.setAccessibilityLabel("前往 \(card.title)")
        super.init(frame: .zero)
        let error = card.state == .error
        borderColor = error ? Palette.danger.withAlphaComponent(0.5) : (card.state == .waiting ? Palette.amberDim : Palette.lineBright)
        cornerColor = error ? Palette.danger : Palette.amberDim
        for button in [allow, go].compactMap({ $0 }) { addSubview(button) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(card.head) · \(card.title)")
        tick(now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var stateColor: NSColor { card.state == .error ? Palette.danger : StateStyle.of(card.state).color }

    func tick(now: Date) {
        let d = DurationFormat.compact(now.timeIntervalSince(card.since))
        let up = card.startedAt.map { "up " + DurationFormat.compact(now.timeIntervalSince($0)) } ?? ""
        guard d != duration || up != uptime else { return }
        duration = d
        uptime = up
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inner = box.insetBy(dx: hz(14), dy: 0)
        let y = box.minY + hz(124)
        var x = inner.minX
        if let allow {
            let width = allow.intrinsicContentSize.width
            allow.frame = CGRect(x: x, y: y, width: width, height: hz(22))
            x += width + hz(8)
        }
        go.frame = CGRect(x: x, y: y, width: go.intrinsicContentSize.width, height: hz(22))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inner = box.insetBy(dx: hz(14), dy: 0)
        let left = inner.minX
        // Head: lamp, `WAITING · PERMISSION`, the duration on the right; dashed rule under it.
        let headY = box.minY + hz(12 + 8.5)
        let style = StateStyle.of(card.state)
        var x = left
        x += Draw.text(TextStyle.mono(12, stateColor).string(style.glyph), x: x, centerY: headY) + hz(8)
        let headStyle = TextStyle(font: Typeface.display(11), color: card.state == .error ? Palette.danger : Palette.amber,
                                  tracking: 0.16, uppercase: true)
        let dur = TextStyle.mono(11.5, stateColor, .medium).string(duration)
        let durWidth = Draw.width(dur)
        Draw.text(headStyle.string(card.head), x: x, centerY: headY, maxWidth: max(0, inner.maxX - durWidth - hz(8) - x))
        Draw.text(dur, x: inner.maxX - durWidth, centerY: headY)
        Draw.dashedLine(from: CGPoint(x: left, y: box.minY + hz(36)), to: CGPoint(x: inner.maxX, y: box.minY + hz(36)), color: Palette.lineBright)
        // Title with its tag square.
        let titleY = box.minY + hz(45 + 11.5)
        x = left
        if let tag = card.tag {
            Draw.fill(CGRect(x: x, y: round(titleY - hz(4)), width: hz(8), height: hz(8)), tag.color)
            x += hz(16)
        }
        Draw.text(TextStyle(font: Typeface.display(15), color: Palette.cream, tracking: 0.01).string(card.title), x: x,
                  centerY: titleY, maxWidth: inner.maxX - x)
        // `■ 藍鵲·網站 / orb-toolkit-backend · up 42m`.
        let pY = box.minY + hz(74 + 8.5)
        x = left
        if let color = card.groupColor {
            Draw.fill(CGRect(x: x, y: round(pY - hz(4)), width: hz(8), height: hz(8)), color.color)
            x += hz(14)
        }
        let place = TextStyle.mono(11.5, Palette.dim)
        let upText = uptime.isEmpty ? nil : place.string("·  " + uptime)
        let upWidth = upText.map(Draw.width) ?? 0
        x += Draw.text(place.string(card.location), x: x, centerY: pY, maxWidth: max(0, inner.maxX - x - upWidth - hz(6)))
        if let upText { Draw.text(upText, x: x + hz(6), centerY: pY, maxWidth: max(0, inner.maxX - x - hz(6))) }
        // Reason line.
        let rY = box.minY + hz(97 + 9)
        switch card.reason {
        case .code(let code, let text):
            let chip = ChipStyle(text: TextStyle.mono(11.5, Palette.bone), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 5)
            let width = chip.draw(code, x: left, centerY: rY, maxWidth: inner.width)
            if let text {
                Draw.text(TextStyle.mono(12, Palette.bone).string(text), x: left + width + hz(8), centerY: rY,
                          maxWidth: inner.maxX - left - width - hz(8))
            }
        case .quote(let quote):
            Draw.text(TextStyle.mono(12, Palette.cream).string(quote), x: left, centerY: rY, maxWidth: inner.width)
        case .text(let text):
            Draw.text(TextStyle.mono(12, Palette.bone).string(text), x: left, centerY: rY, maxWidth: inner.width)
        case .none:
            break
        }
        // Model · rc at the right of the actions.
        let meta = TextStyle.mono(10.5, Palette.dimmer).string(card.meta)
        let metaX = inner.maxX - Draw.width(meta)
        if metaX > go.frame.maxX + hz(8) { Draw.text(meta, x: metaX, centerY: box.minY + hz(124 + 11)) }
    }
}

/// `◇ 1 個待看 · <title> · <group / project> … 4m 前完成 Done` (`.hm-done`); click opens it, and so
/// do space / ⏎ with Full Keyboard Access (M5 D21).
final class DoneLineView: KeyFocusView, HomeTicking {
    let line: HomeModel.DoneLine
    var onClick: (() -> Void)?
    private var ago = ""
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    static var height: CGFloat { hz(28) }

    init(_ line: HomeModel.DoneLine, now: Date) {
        self.line = line
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(line.count) 個待看 · \(line.title)")
        tick(now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func tick(now: Date) {
        let text = DurationFormat.ago(line.since, now: now) + "完成"
        guard text != ago else { return }
        ago = text
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.dashedRect(bounds, color: hovered ? Palette.cyan : Palette.lineBright)
        let mid = bounds.midY
        let gap = hz(10)
        var x = gap
        x += Draw.text(TextStyle.mono(11, Palette.cyan).string("◇"), x: x, centerY: mid) + gap
        x += Draw.text(TextStyle.mono(11.5, Palette.cyan, tracking: 0.06).string("\(line.count) 個待看"), x: x, centerY: mid) + gap
        let pill = ChipStyle.statePill(StateStyle.of(.done))
        let pillWidth = pill.size(for: "Done").width
        let agoText = TextStyle.mono(11.5, Palette.dimmer).string(ago)
        let right = bounds.width - gap - pillWidth
        // A narrow line keeps the count, the title and Done; `4m 前完成` goes first.
        let showsAgo = right - gap - Draw.width(agoText) - x >= hz(80)
        let agoX = showsAgo ? right - gap - Draw.width(agoText) : right
        pill.draw("Done", x: right, centerY: mid)
        if showsAgo { Draw.text(agoText, x: agoX, centerY: mid) }
        let room = agoX - gap - x
        let title = TextStyle.mono(11.5, hovered ? Palette.cream : Palette.cream).string(line.title)
        let titleWidth = Draw.text(title, x: x, centerY: mid, maxWidth: max(0, room * 0.6))
        x += titleWidth + gap
        Draw.text(TextStyle.mono(11.5, Palette.dimmer).string(line.location), x: x, centerY: mid, maxWidth: max(0, agoX - gap - x))
    }
}

/// One LAUNCH card (`.hm-pc`): lg tag square, name, live lamps + `n live`, short path,
/// `[+ CLAUDE]` (accent, default profile) `[+ SHELL]`, `啟動 10:04`.
final class LaunchCardView: FlippedView, HomeTicking {
    let card: HomeModel.LaunchCard
    let claude: CoddButton
    let shellButton: CoddButton
    private var hovered = false
    private var trackingArea: NSTrackingArea?
    private var whenText = ""

    static var height: CGFloat { hz(92) }

    init(_ card: HomeModel.LaunchCard, now: Date, target: AnyObject, claudeAction: Selector, shellAction: Selector) {
        self.card = card
        claude = CoddButton("+ Claude", style: .bracket(.accent, small: true), target: target, action: claudeAction)
        shellButton = CoddButton("+ Shell", style: .bracket(.normal, small: true), target: target, action: shellAction)
        super.init(frame: .zero)
        claude.setAccessibilityLabel("在 \(card.name) 開 Claude session")
        shellButton.setAccessibilityLabel("在 \(card.name) 開 Shell session")
        addSubview(claude)
        addSubview(shellButton)
        setAccessibilityRole(.group)
        setAccessibilityLabel(card.name)
        tick(now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func tick(now: Date) {
        let text = card.known ? (card.lastActivity.map { HomeModel.launchedText($0, now: now) } ?? "") : "未加入"
        guard text != whenText else { return }
        whenText = text
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func layout() {
        super.layout()
        let y = hz(10 + 20 + 5 + 17 + 5 + 4)
        let w1 = claude.intrinsicContentSize.width
        claude.frame = CGRect(x: hz(12), y: y, width: w1, height: hz(22))
        shellButton.frame = CGRect(x: hz(12) + w1 + hz(6), y: y, width: shellButton.intrinsicContentSize.width, height: hz(22))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: hovered ? Palette.amberDim : Palette.lineBright)
        let inner = bounds.insetBy(dx: hz(12), dy: hz(10))
        let headY = inner.minY + hz(10)
        var x = inner.minX
        let square = hz(10)
        if let tag = card.tag {
            let rect = CGRect(x: x, y: round(headY - square / 2), width: square, height: square)
            NSGraphicsContext.saveGraphicsState()
            HomeHeaderView.glow(tag.color, radius: 6).set()
            Draw.fill(rect, tag.color)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Draw.dashedRect(CGRect(x: x, y: round(headY - square / 2), width: square, height: square), color: Palette.dimmer)
        }
        x += hz(18)
        // Live lamps + `n live` at the right.
        var right = inner.maxX
        if card.live > 0 {
            let live = TextStyle.mono(10.5, Palette.dim).string("\(card.live) live")
            right -= Draw.width(live)
            Draw.text(live, x: right, centerY: headY)
            for lamp in card.lamps.reversed() {
                let style = lamp.unreachable ? StateStyle.unreachable : StateStyle.of(lamp.state)
                let glyph = TextStyle.mono(11, style.color).string(style.glyph)
                right -= hz(5) + Draw.width(glyph)
                Draw.text(glyph, x: right, centerY: headY)
            }
            right -= hz(8)
        }
        Draw.text(TextStyle.mono(13, Palette.cream, .semibold).string(card.name), x: x, centerY: headY, maxWidth: max(0, right - x))
        let path = TextStyle.mono(11, Palette.dim).string(card.shortPath, lineBreak: .byTruncatingHead)
        Draw.text(path, x: inner.minX, centerY: inner.minY + hz(20 + 5 + 8.5), maxWidth: inner.width)
        let when = TextStyle.mono(10.5, Palette.dimmer).string(whenText)
        // `啟動 10:04` only where it does not run into the buttons (a narrow card).
        if inner.maxX - Draw.width(when) >= shellButton.frame.maxX + hz(8) {
            Draw.text(when, x: inner.maxX - Draw.width(when), centerY: shellButton.frame.midY)
        }
    }
}

/// The `.panel` list of RECENTLY STOPPED 可接續: lamp, title, meta, `[⟲ RESUME]` per row.
final class StoppedListView: FlippedView, HomeTicking {
    let rows: [HomeModel.StoppedRow]
    private var buttons: [CoddButton] = []
    private var ages: [String] = []
    var onResume: ((HomeModel.StoppedRow) -> Void)?

    static var rowHeight: CGFloat { hz(51) }

    init(_ rows: [HomeModel.StoppedRow], now: Date) {
        self.rows = rows
        super.init(frame: .zero)
        for (index, row) in rows.enumerated() {
            let button = CoddButton("⟲ Resume", style: .bracket(.normal, small: true), target: self, action: #selector(resume(_:)))
            button.tag = index
            button.setAccessibilityLabel("接續「\(row.title)」")
            buttons.append(button)
            addSubview(button)
        }
        setAccessibilityRole(.list)
        setAccessibilityLabel("Recently stopped 可接續")
        tick(now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var height: CGFloat { CGFloat(max(1, rows.count)) * Self.rowHeight + 2 }

    func tick(now: Date) {
        let fresh = rows.map { row in
            row.kind == .session ? DurationFormat.ago(row.date, now: now) : HomeModel.transcriptAge(row.date, now: now)
        }
        guard fresh != ages else { return }
        ages = fresh
        needsDisplay = true
    }

    /// The meta line of a row as drawn: `orb-toolkit-backend · ⎇ fix/refresh · 2d · 1.2MB`.
    func metaText(_ index: Int) -> String {
        let row = rows[index]
        var parts = row.meta
        if ages.indices.contains(index) { parts.append(ages[index]) }
        if let size = row.sizeBytes { parts.append(HomeModel.size(size)) }
        return parts.joined(separator: " · ")
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: bounds.width - hz(12) - size.width,
                                  y: 1 + CGFloat(index) * Self.rowHeight + (Self.rowHeight - hz(22)) / 2, width: size.width, height: hz(22))
        }
    }

    @objc private func resume(_ sender: CoddButton) {
        guard rows.indices.contains(sender.tag) else { return }
        onResume?(rows[sender.tag])
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        if rows.isEmpty {
            Draw.text(TextStyle.mono(12, Palette.dimmer).string("// 沒有可接續的對話"), x: hz(12), centerY: bounds.midY,
                      maxWidth: bounds.width - hz(24))
            return
        }
        for (index, row) in rows.enumerated() {
            let top = 1 + CGFloat(index) * Self.rowHeight
            if index < rows.count - 1 {
                Draw.dashedLine(from: CGPoint(x: 1, y: top + Self.rowHeight - 1), to: CGPoint(x: bounds.width - 1, y: top + Self.rowHeight - 1),
                                color: Palette.line)
            }
            let style = StateStyle.of(row.state)
            Draw.text(TextStyle.mono(11, style.color).string(style.glyph), x: hz(12), centerY: top + Self.rowHeight / 2)
            let textX = hz(12 + 12 + 10)
            let maxWidth = (buttons.indices.contains(index) ? buttons[index].frame.minX : bounds.width) - hz(10) - textX
            Draw.text(TextStyle.mono(12.5, Palette.bone).string(row.title), x: textX, centerY: top + hz(8 + 9.5), maxWidth: maxWidth)
            Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(metaText(index)), x: textX, centerY: top + hz(8 + 19 + 1 + 8),
                      maxWidth: maxWidth)
        }
    }
}

/// The `.panel` of USAGE 剩餘 rows (`.hm-acct`, R7 order): `#2 藍鵲`, `1w 重置 1d12h後`, the
/// source age, the 5h / 1w quota rows with their reset times, the ACTIVE marker and the pace line.
final class UsageListView: FlippedView, HomeTicking {
    let rows: [HomeModel.UsageRow]
    /// Each row's capture time, read at the tick (not part of the model, see `UsageRow`).
    private let sourceAt: (AccountID) -> Date?
    private var texts: [[String]] = []

    init(_ rows: [HomeModel.UsageRow], now: Date, sourceAt: @escaping (AccountID) -> Date? = { _ in nil }) {
        self.rows = rows
        self.sourceAt = sourceAt
        super.init(frame: .zero)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Usage 剩餘")
        tick(now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func rowHeight(_ row: HomeModel.UsageRow) -> CGFloat { hz(row.weekExhaustsAt == nil ? 70 : 76) }

    var height: CGFloat { rows.map(Self.rowHeight).reduce(0, +) + 2 }

    /// `[1w countdown, source age, 5h reset, 1w reset, pace]` for one row.
    static func texts(_ row: HomeModel.UsageRow, sourceAt: Date? = nil, now: Date) -> [String] {
        let weekCountdown = row.week.resetsAt.map { "1w 重置 " + DurationFormat.countdown(to: $0, now: now) } ?? "1w 未知"
        let source = row.sourceLine(sourceAt: sourceAt, now: now)
        var five = "未開始"
        if row.fiveHour.started, let reset = row.fiveHour.resetsAt {
            five = ClockFormat.resetLabel(reset, now: now)
            if row.active { five += " · " + DurationFormat.countdown(to: reset, now: now) }
        }
        let week = row.week.resetsAt.map { ClockFormat.resetLabel($0, now: now) } ?? ""
        var pace = ""
        if let empty = row.weekExhaustsAt, row.week.resetsAt.map({ empty < $0 }) ?? true {
            let parts = Calendar.current.dateComponents([.month, .day], from: empty)
            pace = "1w 用量超前預期 · 預估 \(parts.month ?? 0)/\(parts.day ?? 0) \(ClockFormat.hourMinute(empty)) 用完"
        }
        return [weekCountdown, source, five, week, pace]
    }

    func tick(now: Date) {
        let fresh = rows.map { Self.texts($0, sourceAt: sourceAt($0.id), now: now) }
        guard fresh != texts else { return }
        texts = fresh
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        var top: CGFloat = 1
        for (index, row) in rows.enumerated() {
            let height = Self.rowHeight(row)
            let rect = CGRect(x: 1, y: top, width: bounds.width - 2, height: height)
            if row.active {
                Draw.hGradient(CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.6, height: rect.height),
                               from: Palette.amber.withAlphaComponent(0.05), to: Palette.amber.withAlphaComponent(0))
                Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: hz(2), height: rect.height), Palette.amber)
            }
            if index < rows.count - 1 {
                Draw.dashedLine(from: CGPoint(x: 1, y: rect.maxY - 1), to: CGPoint(x: rect.maxX, y: rect.maxY - 1), color: Palette.line)
            }
            let t = texts.indices.contains(index) ? texts[index] : ["", "", "", "", ""]
            drawRow(row, texts: t, in: rect)
            top += height
        }
    }

    private func drawRow(_ row: HomeModel.UsageRow, texts t: [String], in rect: CGRect) {
        let left = rect.minX + hz(12)
        let idTop = rect.minY + (rect.height - hz(56)) / 2
        var x = left
        x += Draw.text(TextStyle.mono(12.5, Palette.amber, .bold).string(row.slot), x: x, centerY: idTop + hz(9)) + hz(6)
        x += Draw.text(TextStyle.mono(12.5, Palette.cream).string(row.alias), x: x, centerY: idTop + hz(9),
                       maxWidth: max(0, left + hz(136) - x)) + hz(6)
        if row.active {
            let chip = ChipStyle(text: TextStyle.caps(9.5, Palette.amber, tracking: 0.1), border: Palette.amberDim, fill: nil, height: 16, padding: 4)
            chip.draw("Active", x: x, centerY: idTop + hz(9))
        }
        let idWidth = hz(136)
        Draw.text(TextStyle.mono(10.5, Palette.bone).string(t[0]), x: left, centerY: idTop + hz(21 + 8), maxWidth: idWidth)
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(t[1]), x: left, centerY: idTop + hz(40 + 8), maxWidth: idWidth)
        // Quotas: `5h ▮▮▮▮▮▮▮▮▮▯ 98% 13:19` and `1w … 10/16 週五 22:59`.
        let qx = left + idWidth + hz(12)
        let qWidth = rect.maxX - hz(12) - qx
        let lines = t[4].isEmpty ? 2 : 3
        let line = hz(16.5)
        let qTop = rect.minY + (rect.height - (CGFloat(lines) * line + CGFloat(lines - 1) * hz(4))) / 2
        let resetWidth = hz(118)
        QuotaRowRenderer.draw(key: "5h", quota: row.fiveHour, trailing: nil, compact: false, threshold: row.threshold,
                              in: CGRect(x: qx, y: qTop, width: qWidth - resetWidth - hz(8), height: line))
        QuotaRowRenderer.draw(key: "1w", quota: row.week, trailing: nil, compact: false, threshold: row.threshold,
                              in: CGRect(x: qx, y: qTop + hz(20.5), width: qWidth - resetWidth - hz(8), height: line))
        for (offset, text) in [(hz(0), t[2]), (hz(20.5), t[3])] {
            let reset = TextStyle.mono(10.5, Palette.dim).string(text)
            Draw.text(reset, x: rect.maxX - hz(12) - min(resetWidth, Draw.width(reset)), centerY: qTop + offset + line / 2,
                      maxWidth: resetWidth)
        }
        if !t[4].isEmpty {
            Draw.text(TextStyle.mono(10.5, Palette.amber).string(t[4]), x: qx, centerY: qTop + hz(41) + line / 2, maxWidth: qWidth)
        }
    }
}

/// `Profile · claude-default ▾` (`.pillbtn`, the profile name keeps its case).
final class ProfilePillButton: NSButton {
    var profileName: String { didSet { if profileName != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(profileName: String) {
        self.profileName = profileName
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityLabel("啟動設定檔：\(profileName)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func parts(_ hot: Bool) -> NSAttributedString {
        let color = hot ? Palette.amber : Palette.bone
        let text = NSMutableAttributedString(attributedString: TextStyle.caps(11, color, tracking: 0.08).string("Profile · "))
        text.append(TextStyle.mono(11, color, tracking: 0.02).string(profileName + " ▾"))
        return text
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(parts(false)) + 16, height: 24) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let hot = hovered || isHighlighted
        Draw.strokeRect(bounds, color: hot ? Palette.amberDim : Palette.lineBright)
        Draw.text(parts(hot), x: 8, centerY: bounds.midY)
    }
}

/// A dim text link (`全部對話紀錄 →`, `設定 →`): cream on hover.
final class HomeLinkButton: NSButton {
    private let text: String
    private let size: CGFloat
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(_ text: String, size: CGFloat = 11) {
        self.text = text
        self.size = size
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(TextStyle.mono(size, Palette.dim).string(text)), height: 18) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(TextStyle.mono(size, hovered || isHighlighted ? Palette.cream : Palette.dim).string(text), x: 0, centerY: bounds.midY)
    }
}

/// `自動切換 OFF · 剩餘 ≤ 2% 時切換 · 設定 →` (`.autosw.hm-asw`).
final class AutoSwitchLineView: FlippedView {
    let link = HomeLinkButton("設定 →", size: 10.5)
    var on = false { didSet { needsDisplay = true } }
    var threshold = 2 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        link.translatesAutoresizingMaskIntoConstraints = true
        addSubview(link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var text: NSAttributedString {
        let base = TextStyle.mono(10.5, Palette.dim)
        let out = NSMutableAttributedString(attributedString: base.string("自動切換  "))
        out.append(TextStyle.mono(10.5, on ? Palette.success : Palette.dimmer, tracking: 0.08).string(on ? "ON" : "OFF"))
        out.append(base.string("  ·  剩餘 ≤ \(threshold)% 時切換  ·  "))
        return out
    }

    override func layout() {
        super.layout()
        let size = link.intrinsicContentSize
        link.frame = CGRect(x: 2 + Draw.width(text), y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(text, x: 2, centerY: bounds.midY)
    }
}
