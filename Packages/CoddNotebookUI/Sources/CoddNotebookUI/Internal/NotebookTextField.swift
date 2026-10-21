import AppKit
import CoddUI

/// A one-line field in the helmet `.input` box with an optional dim prefix (`/`) and a key cap
/// (`⌘F`), edited by the system field editor so input methods (注音) work.
///
/// IME rule (D11, non-negotiable): while the field editor has marked text nothing is reported:
/// `onChange`, `onSubmit`, `onCancel` and the ↑ ↓ moves stay silent and the keys belong to the
/// input method. The committed text is reported once the composition ends (the commit is an
/// ordinary text change).
final class NotebookTextField: FieldBoxView, NSTextFieldDelegate, NotebookTextProviding {
    let field = NSTextField()
    private let prefixText: String?
    private let keyCap: String?
    private let fontSize: CGFloat
    private let placeholder: String
    /// The last text reported through `onChange` (a commit without a change is not repeated).
    private(set) var reportedText = ""

    var onChange: ((String) -> Void)?
    /// ⏎ without marked text; the field's text.
    var onSubmit: ((String) -> Void)?
    /// ⎋ without marked text. Returns true when handled (else the field clears itself).
    var onCancel: (() -> Bool)?
    /// ↑ (-1) / ↓ (+1) without marked text (pickers move their highlight).
    var onMove: ((Int) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    init(placeholder: String, prefix: String? = nil, keyCap: String? = nil, fontSize: CGFloat = 11.5, accessibilityLabel: String) {
        self.prefixText = prefix
        self.keyCap = keyCap
        self.fontSize = fontSize
        self.placeholder = placeholder
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(fontSize)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(fontSize, Palette.dimmer).string(placeholder)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel(accessibilityLabel)
        addSubview(field)
    }

    var text: String {
        get { field.stringValue }
        set {
            guard field.stringValue != newValue else { return }
            field.stringValue = newValue
            reportedText = newValue
        }
    }

    /// The field editor has marked text (an input method is composing).
    var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    /// The field editor edits this field right now.
    var isEditing: Bool { field.currentEditor() != nil }

    var drawnTexts: [String] {
        var texts: [String] = []
        if let prefixText { texts.append(prefixText) }
        texts.append(field.stringValue.isEmpty ? placeholder : field.stringValue)
        if let keyCap { texts.append(keyCap) }
        return texts
    }

    func focus() { window?.makeFirstResponder(field) }

    // MARK: Layout

    private var prefixString: NSAttributedString? { prefixText.map { TextStyle.mono(fontSize, Palette.dimmer).string($0) } }
    private var keyCapChip: NotebookChip? {
        keyCap.map { NotebookChip(text: $0, style: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg,
                                  height: 18, padding: 5) }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = zp(8)
        if let prefixString { x += Draw.width(prefixString) + zp(6) }
        var right = bounds.width - zp(6)
        if let keyCapChip { right -= keyCapChip.width + zp(6) }
        let height = ceil(Typeface.lineHeight(Typeface.mono(fontSize))) + zp(2)
        field.frame = CGRect(x: x, y: round((bounds.height - height) / 2), width: max(0, right - x), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let prefixString { Draw.text(prefixString, x: zp(8), centerY: bounds.midY) }
        if let keyCapChip {
            let width = keyCapChip.width
            keyCapChip.draw(in: CGRect(x: bounds.width - zp(6) - width, y: 0, width: width, height: bounds.height))
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard !isComposing else { return }
        report()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
        isFocused = true
        onFocusChange?(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isFocused = false
        onFocusChange?(false)
    }

    /// Reports the text when it differs from the last report (also after a composition ends).
    func report() {
        let value = field.stringValue
        guard value != reportedText else { return }
        reportedText = value
        onChange?(value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Keys during a composition belong to the input method.
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            report()
            onSubmit?(field.stringValue)
            return onSubmit != nil
        case #selector(NSResponder.cancelOperation(_:)):
            if onCancel?() == true { return true }
            if !field.stringValue.isEmpty {
                field.stringValue = ""
                report()
                return true
            }
            return false
        case #selector(NSResponder.moveUp(_:)):
            guard let onMove else { return false }
            onMove(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard let onMove else { return false }
            onMove(1)
            return true
        default:
            return false
        }
    }
}
