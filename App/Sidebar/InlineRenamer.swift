import AppKit
import CoddUI

/// Inline rename over a sidebar row using a plain NSTextField and the window's field editor
/// (so Zhuyin and every other IME behave). Return commits, Esc cancels, focus loss commits.
/// Commit/cancel decisions happen in `doCommandBy`, i.e. after the input method.
@MainActor
final class InlineRenamer: NSObject, NSTextFieldDelegate {
    private var field: NSTextField?
    private var commit: ((String) -> Void)?
    private var onEnd: (() -> Void)?
    private var cancelled = false
    private var ending = false

    var isActive: Bool { field != nil }

    func begin(in host: NSView, frame: CGRect, text: String, font: NSFont,
               commit: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        end(commit: true)
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = font
        field.textColor = Palette.cream
        field.backgroundColor = Palette.bgRaise
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.wantsLayer = true
        field.layer?.borderColor = Palette.amber.cgColor
        field.layer?.borderWidth = 1
        field.delegate = self
        field.setAccessibilityLabel("重新命名")
        host.addSubview(field)
        self.field = field
        self.commit = commit
        self.onEnd = onEnd
        cancelled = false
        host.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Ends editing (commit = keep what was typed).
    func end(commit shouldCommit: Bool) {
        guard let field, !ending else { return }
        ending = true
        let value = field.stringValue
        let commit = self.commit
        let onEnd = self.onEnd
        self.field = nil
        self.commit = nil
        self.onEnd = nil
        let window = field.window
        field.delegate = nil
        field.removeFromSuperview()
        if shouldCommit, !cancelled { commit?(value) }
        onEnd?()
        ending = false
        if let outline = window.flatMap({ findOutline(in: $0.contentView) }) { window?.makeFirstResponder(outline) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            end(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            end(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        end(commit: true)
    }

    private func findOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for sub in view.subviews { if let found = findOutline(in: sub) { return found } }
        return nil
    }
}
