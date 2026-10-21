import AppKit
import CoddUI

/// `.sd-acct` (dialog A): `FROM · 剩餘` + chips, `#3 工作` + plan chip, the 5h / 1w `.qrow`s and
/// the reset / source lines. The `to` card has the amber-dim border and inner glow. The two
/// bottom lines tick (`3d01h後`, `12s 前`) in their own small view, so a tick never redraws the
/// card or its bars.
final class AccountMiniCardView: FlippedView {
    enum Role { case from, to }

    let role: Role
    private(set) var account: DialogAccount
    private let fiveHour = QuotaBarRowView(key: "5h", remainingPercent: nil)
    private let weekly = QuotaBarRowView(key: "1w", remainingPercent: nil)
    private let lines = ResetLinesView()

    static var height: CGFloat { dz(149) }
    private static var padX: CGFloat { dz(12) }
    private static var padY: CGFloat { dz(10) }

    init(role: Role, account: DialogAccount, now: Date) {
        self.role = role
        self.account = account
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [fiveHour, weekly, lines] { addSubview(view) }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(account, now: now, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var slotColor: NSColor { role == .from ? Palette.amber : Palette.cyan }
    var headerLabel: String { role == .from ? "From · 剩餘" : "To · 剩餘" }

    func update(_ next: DialogAccount, now: Date) {
        apply(next, now: now, force: false)
    }

    private func apply(_ next: DialogAccount, now: Date, force: Bool) {
        let old = account
        account = next
        if force || old.slot != next.slot || old.alias != next.alias || old.plan != next.plan || old.chips != next.chips {
            needsDisplay = true
        }
        fiveHour.row = QuotaBarRow(key: "5h", remainingPercent: next.fiveHourRemaining, tone: next.fiveHourTone)
        weekly.row = QuotaBarRow(key: "1w", remainingPercent: next.weeklyRemaining, tone: next.weeklyTone)
        tick(now: now)
        setAccessibilityLabel("\(headerLabel) \(next.name) 5h \(fiveHour.row.valueText) 1w \(weekly.row.valueText)")
    }

    /// The two bottom lines for `now` (only redrawn when the text changed).
    func tick(now: Date) {
        var reset = account.reset
        if let at = account.resetsAt { reset += " · " + DurationFormat.countdown(to: at, now: now) }
        var source = account.source
        if let at = account.sourceAt { source += " · " + DurationFormat.ago(at, now: now) }
        lines.set(reset, source)
    }

    /// Lines as drawn (tests).
    var resetLine: String { lines.first }
    var sourceLine: String { lines.second }
    var fiveHourRow: QuotaBarRowView { fiveHour }
    var weeklyRow: QuotaBarRowView { weekly }

    override func layout() {
        super.layout()
        let width = bounds.width - Self.padX * 2
        fiveHour.frame = CGRect(x: Self.padX, y: dz(63), width: width, height: dz(16))
        weekly.frame = CGRect(x: Self.padX, y: dz(85), width: width, height: dz(16))
        lines.frame = CGRect(x: Self.padX, y: dz(107), width: width, height: dz(32))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        if role == .to {
            Self.innerGlow(bounds, color: Palette.amber.withAlphaComponent(0.06), radius: 14)
            Draw.strokeRect(bounds, color: Palette.amberDim)
        } else {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
        let left = Self.padX
        let right = bounds.width - Self.padX

        // `.sd-ah`: label left, chips right (20 pt).
        let headerMid = Self.padY + dz(10)
        var chipX = right
        for chip in account.chips.reversed() {
            let style = DialogChipStyle.style(chip)
            chipX -= style.size(for: chip.text).width
            style.draw(chip.text, x: chipX, centerY: headerMid)
            chipX -= dz(6)
        }
        Draw.text(DialogText.label.string(headerLabel), x: left, centerY: headerMid, maxWidth: max(0, chipX - dz(8) - left))

        // `.sd-an`: slot (Space Mono 700) · alias (14 cream) · plan chip at the right.
        let nameMid: CGFloat = dz(36) + dz(10.5)
        var planX = right
        if let plan = account.plan, !plan.isEmpty {
            let style = DialogChipStyle.style(.plain)
            planX -= style.size(for: plan).width
            style.draw(plan, x: planX, centerY: nameMid)
            planX -= dz(8)
        }
        var x = left
        x += Draw.text(TextStyle(font: Typeface.display(14), color: slotColor).string(account.slot), x: x, centerY: nameMid,
                       maxWidth: max(0, planX - x))
        x += dz(8)
        if x < planX {
            Draw.text(TextStyle.mono(14, Palette.cream).string(account.alias), x: x, centerY: nameMid, maxWidth: planX - x)
        }
    }

    /// CSS `box-shadow: inset 0 0 <radius> <color>`: a frame around `rect` drawn outside the clip
    /// casts its blurred shadow inwards.
    static func innerGlow(_ rect: CGRect, color: NSColor, radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        shadow.set()
        let frame = NSBezierPath(rect: rect.insetBy(dx: -radius * 2, dy: -radius * 2))
        frame.append(NSBezierPath(rect: rect))
        frame.windingRule = .evenOdd
        NSColor.black.setFill()
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `.sd-reset`: two 10.5 pt dimmer lines, 1 pt apart.
    private final class ResetLinesView: FlippedView {
        private(set) var first = ""
        private(set) var second = ""

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func set(_ first: String, _ second: String) {
            guard first != self.first || second != self.second else { return }
            self.first = first
            self.second = second
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let style = TextStyle.mono(10.5, Palette.dimmer)
            Draw.text(style.string(first), x: 0, centerY: dz(8), maxWidth: bounds.width)
            Draw.text(style.string(second), x: 0, centerY: dz(16) + 1 + dz(8), maxWidth: bounds.width)
        }
    }
}
