import AppKit
import CoddUI

/// The store's latest problem (`StoreProblem`) as a dismissible banner: `▲ <message> · 12s 前`
/// `[知道了]`. The pane puts it above the session banner (for problems of every session or of the
/// one shown) and on the home page. Hidden while there is nothing to show; the owner's 1 Hz tick
/// keeps the age current. A data file moved aside (M5 D14) adds `[在 Finder 中顯示]`.
final class ProblemBannerView: NSView {
    private let banner = BannerView()
    private(set) var problem: StoreProblem?
    /// `[知道了]`.
    var onDismiss: (() -> Void)?
    /// `[在 Finder 中顯示]` (only while the problem names a file).
    var onReveal: (() -> Void)?

    static let revealTitle = "在 Finder 中顯示"
    static let dismissTitle = "知道了"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)
        banner.pinEdges(to: self)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The message line as drawn (tests).
    static func text(_ problem: StoreProblem, now: Date) -> String {
        "\(problem.message) · \(DurationFormat.ago(problem.at, now: now))"
    }

    func update(_ problem: StoreProblem?, now: Date) {
        self.problem = problem
        if isHidden != (problem == nil) { isHidden = problem == nil }
        render(now)
    }

    func tick(now: Date) {
        guard !isHidden else { return }
        render(now)
    }

    private func render(_ now: Date) {
        guard let problem else { return }
        var actions = [BannerAction(title: Self.dismissTitle, action: #selector(dismiss))]
        if problem.revealPath != nil { actions.insert(BannerAction(title: Self.revealTitle, action: #selector(reveal)), at: 0) }
        banner.show(.error, glyph: "▲", glyphColor: Palette.danger, message: Self.text(problem, now: now), actions: actions, target: self)
    }

    /// The banner's buttons (tests).
    var actionButtons: [CoddButton] { banner.actionButtons }

    @objc private func dismiss() { onDismiss?() }
    @objc private func reveal() { onReveal?() }
}
