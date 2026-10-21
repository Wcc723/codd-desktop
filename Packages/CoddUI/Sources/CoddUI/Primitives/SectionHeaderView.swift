import AppKit

/// Section and group headers with a dashed rule that takes the free width:
/// - `.section` (Status `.sx-sh`, gap 10, min 20 px): `HOST` (`.h-sub`), a `.hint`, `leading` views
///   (`cswap 0.26.0` chip, a path), the rule (--line-bright, at least 24 px), `trailing` views
///   (`● 正常` chip, hints);
/// - `.group` (Settings `.sx-gh`, gap 8): `prefix` views (`Phase 0` chip), the title in 10.5 px dim
///   caps (.18em), the 繁中 `hint` (`.cjk`, dimmer), a `count` (`.cnt`, amber-dim), `leading` views,
///   the rule, `trailing` views (`.r`, e.g. `trailingText`).
///
/// VoiceOver: a heading labelled `title hint` (its leading / trailing views stay its children).
public final class SectionHeaderView: NSView {
    public enum Style: Sendable, Equatable {
        case section, group
    }

    public let style: Style
    public var title: String { didSet { if title != oldValue { rebuild() } } }
    public var hint: String? { didSet { if hint != oldValue { rebuild() } } }
    public var count: String? { didSet { if count != oldValue { rebuild() } } }
    public private(set) var prefix: [NSView]
    public private(set) var leading: [NSView]
    public private(set) var trailing: [NSView]
    public let rule: DashedRuleView

    private let stack: NSStackView

    public init(title: String, style: Style = .section, hint: String? = nil, count: String? = nil,
                prefix: [NSView] = [], leading: [NSView] = [], trailing: [NSView] = []) {
        self.style = style
        self.title = title
        self.hint = hint
        self.count = count
        self.prefix = prefix
        self.leading = leading
        self.trailing = trailing
        rule = DashedRuleView(color: Palette.lineBright, minimumWidth: style == .section ? 24 : 0)
        stack = hStack([], spacing: style == .section ? 10 : 8)
        super.init(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 0).zoomed(style == .section ? 20 : 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func setPrefix(_ views: [NSView]) { prefix = views; rebuild() }
    public func setLeading(_ views: [NSView]) { leading = views; rebuild() }
    public func setTrailing(_ views: [NSView]) { trailing = views; rebuild() }

    /// A `.hint` label for `leading` / `trailing` (`依每週重置排序 · 越快重置越上面`).
    public static func hintLabel(_ text: String) -> NSTextField { Label.make(text, style: TextStyle.hint) }

    /// `.sx-gh .r`: the right-hand note of a group header (`剩餘 ≤ 2% · 5h + 每週 · 依排序`).
    public static func trailingText(_ text: String) -> NSTextField {
        Label.make(text, style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06))
    }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        var views = prefix
        switch style {
        case .section:
            views.append(Label.make(title, style: TextStyle.subTitle))
            if let hint, !hint.isEmpty { views.append(Self.hintLabel(hint)) }
        case .group:
            views.append(Label.make(title, style: TextStyle.caps(10.5, Palette.dim, tracking: 0.18)))
            if let hint, !hint.isEmpty { views.append(Label.make(hint, style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06))) }
        }
        if let count, !count.isEmpty { views.append(Label.make(count, style: TextStyle.mono(10.5, Palette.amberDim))) }
        views += leading
        views.append(rule)
        views += trailing
        // The rule (compression resistance 1) gives way first, down to its minimum width.
        for view in views { stack.addArrangedSubview(view) }
    }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// `title hint` unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? [title, hint].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }
}
