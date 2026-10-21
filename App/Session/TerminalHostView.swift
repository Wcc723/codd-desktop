import AppKit
import CoddUI

/// Black area of the session pane that hosts the engine's view (`TerminalSurface.view`) and,
/// when no session is shown, a `// …` placeholder line. The engine view is placed directly in
/// the AppKit tree (never inside SwiftUI) so the engine keeps its own display link.
final class TerminalHostView: PanelView {
    let surface: TerminalSurface
    private let placeholder = Label.make(style: TextStyle.mono(12, Palette.dimmer))
    /// Read-only content instead of a terminal (an external session, D6): comment lines and an
    /// optional `[前往 shell]` action.
    private let readOnlyStack = NSStackView()
    private let readOnlyAction = CoddButton("前往 shell", style: .bracket(.normal, small: true))
    private var readOnly: ReadOnlyContent?
    /// `[前往 shell]` was pressed.
    var onReadOnlyAction: (() -> Void)?
    /// A placeholder or read-only content covers the terminal.
    private var isCovered = false
    /// Hidden by the pane on purpose (the ⌘J panel is maximized, D11): the surface is occluded,
    /// its terminal stays hot, whatever the placeholder state.
    var isSuppressed = false {
        didSet { if isSuppressed != oldValue { applySurfaceVisibility() } }
    }

    /// What `showReadOnly` draws (compared, so an unchanged render touches nothing).
    struct ReadOnlyContent: Equatable {
        /// The first line is the `// …` comment (dimmer); the rest (`最近 prompt：…`) are dim.
        var lines: [String]
        /// Title of the action button (nil: none).
        var action: String?
    }

    init(surface: TerminalSurface) {
        self.surface = surface
        super.init(fill: Palette.termBackground)
        let surfaceView = surface.view
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)
        surfaceView.pinEdges(to: self)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        addSubview(placeholder)
        readOnlyStack.orientation = .vertical
        readOnlyStack.alignment = .leading
        readOnlyStack.spacing = 8
        readOnlyStack.translatesAutoresizingMaskIntoConstraints = false
        readOnlyStack.isHidden = true
        addSubview(readOnlyStack)
        readOnlyAction.target = self
        readOnlyAction.action = #selector(readOnlyActionPressed)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            readOnlyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            readOnlyStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            readOnlyStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    /// Shows the terminal (nil) or a placeholder comment instead of it. The surface is told
    /// it is occluded only when that actually changes.
    func showPlaceholder(_ text: String?) {
        if let text {
            Label.set(placeholder, text, style: TextStyle.mono(12, Palette.dimmer))
        }
        if readOnly != nil {
            readOnly = nil
            readOnlyStack.isHidden = true
        }
        placeholder.isHidden = text == nil
        isCovered = text != nil
        applySurfaceVisibility()
    }

    /// D6: an external session's read-only pane instead of a terminal (top left, like terminal
    /// output): `// 這個 session 在 CODD 外面執行（pid 48211 · cli）· …`, `最近 prompt：…`.
    func showReadOnly(_ content: ReadOnlyContent) {
        placeholder.isHidden = true
        isCovered = true
        applySurfaceVisibility()
        readOnlyStack.isHidden = false
        guard content != readOnly else { return }
        readOnly = content
        readOnlyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, line) in content.lines.enumerated() {
            let label = WrappingLabel(line, style: TextStyle.mono(12, index == 0 ? Palette.dimmer : Palette.dim))
            readOnlyStack.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40).isActive = true
        }
        if let action = content.action {
            readOnlyAction.label = action
            readOnlyStack.addArrangedSubview(readOnlyAction)
        }
    }

    /// The read-only lines shown now (tests, state checks).
    var readOnlyLines: [String] { readOnly?.lines ?? [] }

    private func applySurfaceVisibility() { setSurfaceHidden(isCovered || isSuppressed) }

    private func setSurfaceHidden(_ hidden: Bool) {
        guard surface.view.isHidden != hidden else { return }
        surface.view.isHidden = hidden
        surface.setOccluded(hidden)
    }

    @objc private func readOnlyActionPressed() { onReadOnlyAction?() }
}
