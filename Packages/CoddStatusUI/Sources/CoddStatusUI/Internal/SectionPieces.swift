import AppKit
import CoddUI

/// Text styles of the Status artboard not in CoddUI's presets.
@MainActor
enum StatusStyles {
    /// Card body text (`.codd` 13 px).
    static func body(_ color: NSColor = Palette.cream) -> TextStyle { TextStyle.mono(13, color) }
}

/// `.sx-sh`: `HOST hint ┄┄┄┄┄ [● 正常]` — the section title, items after it, a dashed
/// `--line-bright` rule that takes the rest (min 24), then right-side items; gap 10.
final class SectionHeaderRow: FlippedView {
    let title: TextLine
    private(set) var leading: [NSView] = []
    private(set) var trailing: [NSView] = []
    private let rule = RuleLine(color: Palette.lineBright)
    /// Leading items that may truncate when the row is narrow (hints).
    var shrinkingLeading: Set<ObjectIdentifier> = []

    init(title: String) {
        self.title = TextLine(title, style: TextStyle.subTitle)
        super.init(frame: .zero)
        addSubview(self.title)
        addSubview(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setLeading(_ views: [NSView]) {
        leading.forEach { $0.removeFromSuperview() }
        leading = views
        views.forEach { addSubview($0) }
        needsLayout = true
    }

    func setTrailing(_ views: [NSView]) {
        trailing.forEach { $0.removeFromSuperview() }
        trailing = views
        views.forEach { addSubview($0) }
        needsLayout = true
    }

    static var height: CGFloat { sz(21) }

    /// The dashed rule's frame (tests: no hint sits on it).
    var ruleFrame: CGRect { rule.frame }

    override func layout() {
        super.layout()
        var items: [RowItem] = [RowItem(title, height: title.lineHeight)]
        for view in leading {
            items.append(RowItem(view, shrinkingLeading.contains(ObjectIdentifier(view)) ? .shrink : .intrinsic))
        }
        items.append(RowItem(rule, .flex(min: sz(24)), height: 1))
        // A narrow row (small window, zoom 20) cuts the hints first; the right-side chip (`● 正常`)
        // only gives way when the title, the rule and the chip alone do not fit.
        let gap = sz(10)
        let trailingWidth = trailing.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + gap }
        let trailingShrinks = title.intrinsicContentSize.width + gap + sz(24) + trailingWidth > bounds.width
        for view in trailing { items.append(RowItem(view, trailingShrinks ? .shrink : .intrinsic)) }
        RowLayout.layout(items, in: bounds, gap: gap)
    }
}

/// `.meta-rule`: `──── UPDATED 10:42:07 · 每 5 秒 ────` with gradient lines fading toward the
/// text (11 px caps .18em, `--dim`).
final class MetaRuleView: NSView, StatusTextShowing {
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var style: TextStyle { TextStyle.caps(11, Palette.dim, tracking: 0.18) }

    var displayedText: String { text.uppercased() }

    @discardableResult
    func set(_ value: String) -> Bool {
        guard value != text else { return false }
        text = value
        setAccessibilityValue(displayedText)
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let string = style.string(text)
        let width = Draw.width(string)
        let x = round((bounds.width - width) / 2)
        let mid = floor(bounds.midY)
        let left = CGRect(x: 0, y: mid, width: max(0, x - sz(12)), height: 1)
        let right = CGRect(x: x + width + sz(12), y: mid, width: max(0, bounds.width - x - width - sz(12)), height: 1)
        Draw.hGradient(left, from: Palette.lineBright, to: Palette.lineBright.withAlphaComponent(0))
        Draw.hGradient(right, from: Palette.lineBright.withAlphaComponent(0), to: Palette.lineBright)
        Draw.text(string, x: x, centerY: bounds.midY)
    }
}

/// A target for AppKit actions that runs a closure (CoddButton uses target / action).
@MainActor
final class ButtonAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire(_ sender: Any?) { run() }
}

extension CoddButton {
    /// Wires the button to a closure kept alive by the returned object (store it).
    @MainActor
    func onPress(_ run: @escaping () -> Void) -> ButtonAction {
        let action = ButtonAction(run)
        target = action
        self.action = #selector(ButtonAction.fire(_:))
        return action
    }
}
