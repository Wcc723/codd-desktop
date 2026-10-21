import AppKit
import CoddUI

/// The sheet ⌘W shows for a dirty tab (D34 copy): `儲存「<name>」的變更？`, the hint
/// `不儲存的話，這次的修改會遺失。`, `[不儲存]` (danger) at the left and `[取消]` `[儲存]` (primary) at
/// the right, macOS's order. ⏎ = 儲存, ⎋ = 取消, ⌘D / ⌘⌫ = 不儲存 (the standard alert keys).
/// Quitting with dirty tabs (D24) uses the same sheet with its own texts (``init(title:hint:saveTitle:)``).
///
/// The `.modal` look (--bg-soft, --amber-dim frame, dashed rule over the footer) without the caps
/// header: a file name must keep its case. The sheet has no text field, so no input method can
/// own a key here.
public final class DirtyCloseSheetView: FlippedView {
    public static var width: CGFloat { fz(440) }

    public let title: String
    public var onChoice: ((DirtyCloseChoice) -> Void)?

    let titleLabel: DrawnLabel
    let hintLabel: DrawnLabel
    let discardButton = CoddButton("不儲存", style: .bracket(.danger, small: false))
    let cancelButton = CoddButton("取消", style: .bracket(.normal, small: false))
    let saveButton: CoddButton

    /// ⌘W on one dirty tab.
    public convenience init(fileName: String) {
        self.init(title: "儲存「\(fileName)」的變更？", hint: "不儲存的話，這次的修改會遺失。", saveTitle: "儲存")
    }

    public init(title: String, hint: String, saveTitle: String) {
        self.title = title
        titleLabel = DrawnLabel(title, style: TextStyle(font: Typeface.mono(14, .medium), color: Palette.cream))
        hintLabel = DrawnLabel(hint, style: TextStyle.hint)
        saveButton = CoddButton(saveTitle, style: .bracket(.primary, small: false))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [titleLabel, hintLabel, discardButton, cancelButton, saveButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for (button, selector) in [(discardButton, #selector(discardClicked)), (cancelButton, #selector(cancelClicked)),
                                   (saveButton, #selector(saveClicked))] {
            button.target = self
            button.action = selector
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(titleLabel.text)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Body `padding: 20px` (title + 8 + hint), the dashed rule, the 28 pt buttons in `12px 20px`.
    public static var height: CGFloat { fz(20) + fz(20) + fz(8) + fz(18) + fz(20) + 1 + fz(12) + fz(28) + fz(12) }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    public override func layout() {
        super.layout()
        let inner = bounds.width - fz(40)
        titleLabel.frame = CGRect(x: fz(20), y: fz(20), width: inner, height: fz(20))
        hintLabel.frame = CGRect(x: fz(20), y: fz(48), width: inner, height: fz(18))
        let buttonY = bounds.height - fz(12) - fz(28)
        let discard = discardButton.intrinsicContentSize
        discardButton.frame = CGRect(x: fz(20), y: buttonY, width: discard.width, height: fz(28))
        var right = bounds.width - fz(20)
        for button in [saveButton, cancelButton] {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: right - size.width, y: buttonY, width: size.width, height: fz(28))
            right -= size.width + fz(8)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.amberDim)
        let ruleY = bounds.height - fz(12) - fz(28) - fz(12) - 1
        Draw.dashedLine(from: CGPoint(x: 1, y: ruleY), to: CGPoint(x: bounds.width - 1, y: ruleY), color: Palette.line)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let choice = Self.choice(for: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, flags: flags) {
            onChoice?(choice)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The key map (tests): ⏎ / keypad enter → save, ⎋ → cancel, ⌘D / ⌘⌫ → discard.
    static func choice(for characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> DirtyCloseChoice? {
        let plain = flags.subtracting([.numericPad, .function]).isEmpty
        if plain, keyCode == 0x24 || keyCode == 0x4C { return .save }
        if plain, keyCode == 0x35 { return .cancel }
        if flags.subtracting([.numericPad, .function]) == .command, characters.lowercased() == "d" || keyCode == 0x33 { return .discard }
        return nil
    }

    public override func cancelOperation(_ sender: Any?) { onChoice?(.cancel) }

    @objc private func discardClicked() { onChoice?(.discard) }
    @objc private func cancelClicked() { onChoice?(.cancel) }
    @objc private func saveClicked() { onChoice?(.save) }
}
