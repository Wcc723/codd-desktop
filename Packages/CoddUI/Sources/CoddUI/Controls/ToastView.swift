import AppKit

/// A toast. Two looks:
/// - default (Main `.mn-toast`): amber left bar, message, `[UNDO]`, `✕`; dismisses itself after a
///   few seconds (one-shot timer; no repeating work);
/// - countdown (SidebarStates C `.toast`): `✕ 3 個 session 已封存  [UNDO]  5s`, no bar and no `✕`
///   button; the seconds count down once a second and the toast leaves at 0.
public final class ToastView: PanelView {
    private let message = NSTextField(wrappingLabelWithString: "")
    private var undo: (@MainActor () -> Void)?
    private var dismissTask: Task<Void, Never>?
    private let countdownLabel = Label.make(style: TextStyle.mono(12, Palette.dim))
    /// Seconds left on a countdown toast (nil for the default look).
    public private(set) var remainingSeconds: Int?
    private let showsBar: Bool

    public init(text: String, undo: (@MainActor () -> Void)?, countdown: Int? = nil) {
        self.undo = undo
        showsBar = countdown == nil
        remainingSeconds = countdown
        super.init(fill: Palette.bgLift, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        self.shadow = shadow

        message.maximumNumberOfLines = 3
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [message]
        let undoButton = CoddButton("Undo", style: .bracket(.accent, small: true), target: self, action: #selector(undoClicked))
        let stack: NSStackView
        if let countdown {
            message.attributedStringValue = Self.countdownMessage(text)
            if undo != nil { views.append(undoButton) }
            Label.set(countdownLabel, Self.countdownText(countdown), style: TextStyle.mono(12, Palette.dim))
            countdownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(countdownLabel)
            // `.toast{gap:12px;padding:6px 8px 6px 12px}`.
            stack = hStack(views, spacing: 12, edgeInsets: NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8))
        } else {
            message.attributedStringValue = TextStyle.mono(11.5, Palette.cream).string(text, lineBreak: .byWordWrapping)
            if undo != nil { views.append(undoButton) }
            let close = CoddButton("✕", style: .glyph(size: 22), target: self, action: #selector(closeClicked))
            close.setAccessibilityLabel("關閉通知")
            views.append(close)
            stack = hStack(views, spacing: 8, edgeInsets: NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 4))
            stack.alignment = .top
        }
        addSubview(stack)
        stack.pinEdges(to: self)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    /// `5s` (`.muted.num`).
    public static func countdownText(_ seconds: Int) -> String { "\(max(0, seconds))s" }

    /// The countdown look's message: 12 px `--bone`, a leading `✕` in amber (`<span class="amber">`).
    public static func countdownMessage(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: TextStyle.mono(12, Palette.bone).string(text, lineBreak: .byWordWrapping))
        if text.hasPrefix("✕") { out.addAttribute(.foregroundColor, value: Palette.amber, range: NSRange(location: 0, length: 1)) }
        return out
    }

    /// The countdown label as shown (tests).
    public var countdownLabelText: String? { remainingSeconds == nil ? nil : countdownLabel.stringValue }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsBar { Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), Palette.amber) }
    }

    /// Removes the toast after `seconds` unless it is dismissed earlier.
    public func dismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.removeAnimated()
        }
    }

    /// Counts the seconds down (one sleep per second while the toast is up) and leaves at 0.
    public func startCountdown(tick: Duration = .seconds(1)) {
        guard remainingSeconds != nil else { return }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            while let left = self?.remainingSeconds, left > 0 {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled, let self else { return }
                self.advanceCountdown()
            }
        }
    }

    /// One second passed (the countdown task, tests).
    public func advanceCountdown() {
        guard let left = remainingSeconds, left > 0 else { return }
        remainingSeconds = left - 1
        Label.set(countdownLabel, Self.countdownText(left - 1), style: TextStyle.mono(12, Palette.dim))
        if left - 1 == 0 { removeAnimated() }
    }

    @objc private func undoClicked() { performUndo() }

    /// Whether the toast still offers UNDO.
    public var hasUndo: Bool { undo != nil }

    /// `[UNDO]` pressed (also DEBUG `-codd-undo-switch` and tests): runs it once, then leaves.
    public func performUndo() {
        undo?()
        undo = nil
        removeAnimated()
    }

    @objc private func closeClicked() { removeAnimated() }

    private func removeAnimated() {
        dismissTask?.cancel()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }
}
