import AppKit
import Carbon.HIToolbox
import CoddUI

/// GENERAL › 全域快捷鍵 / SHORTCUTS Global row: the combo as a `.kbd.sx-hk` and `[修改]`. While
/// recording, a local key-down monitor takes the next key that has at least one of ⌘ ⌥ ⌃ (keys
/// without one are swallowed and recording goes on), ⎋ cancels; the kbd reads `按下新的組合鍵…`.
/// The recorder only reports: the owner decides whether the combo is taken and sets `combo`.
@MainActor
public final class HotkeyRecorderView: FlippedView {
    public var onRecorded: ((KeyCombo) -> Void)?
    public var onCancelled: (() -> Void)?
    /// Recording started (the app suspends its registered hotkey meanwhile).
    public var onStarted: (() -> Void)?
    public var combo: KeyCombo { didSet { if combo != oldValue { refresh() } } }
    public private(set) var isRecording = false
    /// `compact`: `⌥Space` (SHORTCUTS), else `⌥ Space` (GENERAL).
    public var compact = false { didSet { refresh() } }
    public var isEnabled = true {
        didSet {
            button.isEnabled = isEnabled
            if !isEnabled { cancelRecording() }
        }
    }

    public static let prompt = "按下新的組合鍵…"

    let kbd = ChipView("", style: HotkeyRecorderView.kbdStyle(recording: false))
    let button: CoddButton
    private var monitor: Any?
    private let kbdHeight: CGFloat

    /// - Parameter kbdColumnWidth: the kbd's column (SHORTCUTS: 120 + the 16 gap) so `[修改]`
    ///   lines up with the other rows' buttons; nil puts the button 8 after the kbd.
    public init(combo: KeyCombo, accessibilityLabel: String = "修改全域快捷鍵", kbdHeight: CGFloat = 24, kbdColumnWidth: CGFloat? = nil) {
        self.combo = combo
        button = CoddButton("修改", style: .bracket(.normal, small: true))
        self.kbdHeight = kbdHeight
        super.init(frame: .zero)
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = self
        button.action = #selector(buttonClicked)
        for view in [kbd, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = kbdColumnWidth.map { button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: $0) }
            ?? button.leadingAnchor.constraint(equalTo: kbd.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            kbd.leadingAnchor.constraint(equalTo: leadingAnchor),
            kbd.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading,
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: max(kbdHeight, 22)),
        ])
        if kbdColumnWidth != nil { kbd.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -4).isActive = true }
        kbd.setAccessibilityElement(true)
        kbd.setAccessibilityRole(.staticText)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `.kbd.sx-hk` (24 pt, 12 px cream, amber-dim border) or the SHORTCUTS `.kbd.sx-kbd`
    /// (22 pt, 11.5 px); recording: amber text and border.
    static func kbdStyle(recording: Bool, height: CGFloat = 24) -> ChipStyle {
        let size: CGFloat = height >= xz(24) ? xz(12) : xz(11.5)
        return ChipStyle(text: TextStyle.mono(size, recording ? Palette.amber : Palette.cream),
                         border: recording ? Palette.amber : (height >= 24 ? Palette.amberDim : Palette.lineBright),
                         fill: Palette.bg, height: height, padding: height >= 24 ? 9 : 8)
    }

    /// What the kbd shows now.
    public var displayedText: String {
        isRecording ? Self.prompt : (compact ? combo.compactDescription : combo.description)
    }

    private func refresh() {
        kbd.set(displayedText, style: Self.kbdStyle(recording: isRecording, height: kbdHeight))
        kbd.setAccessibilityValue(displayedText)
        button.label = isRecording ? "取消" : "修改"
    }

    @objc private func buttonClicked() {
        if isRecording { cancelRecording() } else { startRecording() }
    }

    public func startRecording() {
        guard isEnabled, !isRecording else { return }
        isRecording = true
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleKeyDown(keyCode: event.keyCode, flags: event.modifierFlags)
            }
            return consumed ? nil : event
        }
        onStarted?()
    }

    /// Ends recording without a combo (⎋, `取消`, the view leaving its window).
    public func cancelRecording() {
        guard isRecording else { return }
        stop()
        onCancelled?()
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refresh()
    }

    /// One key-down while recording; true when it was consumed (every key is, while recording).
    @discardableResult
    func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard isRecording else { return false }
        if Int(keyCode) == kVK_Escape {
            cancelRecording()
            return true
        }
        let candidate = KeyCombo(keyCode: keyCode, flags: flags)
        guard candidate.hasRequiredModifier else { return true }
        stop()
        onRecorded?(candidate)
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelRecording() }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        cancelRecording()
    }
}
