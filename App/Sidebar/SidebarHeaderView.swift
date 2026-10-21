import AppKit
import CoddUI

/// Sidebar head (52 px, drags the window): `CODD` · ⌘K · `[+ NEW ▾]`.
final class SidebarHeaderView: WindowDragView {
    let searchButton = CoddButton("快速切換 ⌘K", style: .icon(.search))
    let newButton = CoddButton("+ New ▾", style: .bracket(.accent, small: true))

    init() {
        super.init(fill: Palette.bg, edges: [.bottom], edgeColor: Palette.line, dashed: [.bottom])
        let brand = Label.make("CODD", style: TextStyle(font: Typeface.display(15), color: Palette.amber, tracking: 0.04,
                                                             shadow: Self.glow(radius: 8)))
        searchButton.setAccessibilityLabel("快速切換 ⌘K")
        let stack = hStack([brand, spacer(), searchButton, newButton], spacing: 6,
                           edgeInsets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10))
        addSubview(stack)
        stack.pinEdges(to: self)
    }

    static func glow(radius: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = Palette.amberGlow
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        return shadow
    }
}

/// `/ 篩選 session、專案…` square input (custom border, system field editor so IME works).
final class FilterField: PanelView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: ((String) -> Void)?

    init() {
        super.init(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        let slash = Label.make("/", style: TextStyle.mono(11.5, Palette.dimmer))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(11.5)
        field.textColor = Palette.cream
        field.placeholderAttributedString = Self.placeholder(short: false)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("篩選")
        let stack = hStack([slash, field], spacing: 6, edgeInsets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        addSubview(stack)
        stack.pinEdges(to: self)
    }

    /// `篩選 session、專案…`, or `篩選…` where the field is narrower than that: a scrollable field
    /// never truncates its placeholder, it would be cut off mid-word (narrow sidebar, zoom).
    static func placeholder(short: Bool) -> NSAttributedString {
        TextStyle.mono(11.5, Palette.dimmer).string(short ? "篩選…" : "篩選 session、專案…")
    }

    override func layout() {
        super.layout()
        let full = Self.placeholder(short: false)
        let short = field.bounds.width < Draw.width(full) + 4
        let wanted = short ? Self.placeholder(short: true) : full
        if field.placeholderAttributedString != wanted { field.placeholderAttributedString = wanted }
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
        edgeColor = Palette.amber
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        edgeColor = Palette.lineBright
    }

    /// Esc clears the filter (after the IME has had its chance: this is `doCommandBy`).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !field.stringValue.isEmpty {
            field.stringValue = ""
            onChange?("")
            return true
        }
        return false
    }
}
