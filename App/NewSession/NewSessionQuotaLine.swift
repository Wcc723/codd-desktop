import AppKit
import CoddUI

/// What the ⌘N sheet's `.ns-quota` line shows (NewSession artboard): the account the session will
/// use and its remaining 5h / 1w, so the user sees them before starting (D12 turned the select on).
struct NewSessionQuota: Equatable {
    /// `#3 工作`.
    var name: String
    var fiveHour: QuotaWindow
    var week: QuotaWindow

    /// `#3 工作 5h 91% 1w 15% 剩餘` (dump, accessibility).
    var text: String { "\(name) 5h \(fiveHour.valueText) 1w \(week.valueText) 剩餘" }

    /// The line for an account option id: `follow` (or none) is the active account, a pin its own.
    /// nil without such an account (no cswap accounts, or the store has not read them yet).
    @MainActor
    static func make(option id: String?, accounts: any AccountStore) -> NewSessionQuota? {
        let accountID = id == nil || id == NewSessionAccountOption.followID ? accounts.activeAccountID : id
        guard let accountID, let account = accounts.account(accountID) else { return nil }
        return NewSessionQuota(name: account.displayName, fiveHour: account.fiveHour, week: account.week)
    }
}

/// `.ns-quota`: 10.5 px, gap 12 — the account in cyan, `5h` + a 40 px meter + the remaining % in
/// its tone, the same for `1w`, then `剩餘` (faint). Hidden while there is nothing to show.
final class NewSessionQuotaLineView: FlippedView {
    var quota: NewSessionQuota? {
        didSet {
            guard quota != oldValue else { return }
            isHidden = quota == nil
            setAccessibilityLabel(quota?.text)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    static let height: CGFloat = 16
    static let meterWidth: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).zoomed(Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private static let dim = TextStyle.mono(10.5, Palette.dim)

    private static func tone(_ window: QuotaWindow) -> NSColor {
        switch window.tone {
        case .ok: Palette.success
        case .warn: Palette.amber
        case .crit: Palette.danger
        case .muted: Palette.dimmer
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let quota else { return }
        let mid = bounds.midY
        var x: CGFloat = 0
        x += Draw.text(TextStyle.mono(10.5, Palette.cyan).string(quota.name), x: x, centerY: mid) + 12
        for (key, window) in [("5h", quota.fiveHour), ("1w", quota.week)] {
            x += Draw.text(Self.dim.string(key), x: x, centerY: mid) + 5
            let track = CGRect(x: x, y: floor(mid) - 1, width: Self.meterWidth, height: 2)
            Draw.fill(track, Palette.lineBright)
            if window.known {
                let share = window.started ? CGFloat(max(0, min(100, window.remainingPercent))) / 100 : 1
                Draw.fill(CGRect(x: track.minX, y: track.minY, width: track.width * share, height: 2), Self.tone(window))
            }
            x += Self.meterWidth + 5
            x += Draw.text(TextStyle.mono(10.5, Self.tone(window)).string(window.valueText), x: x, centerY: mid) + 12
        }
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string("剩餘"), x: x, centerY: mid)
    }
}
