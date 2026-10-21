import AppKit
import CoddUI

/// Placeholder engine: draws the mock transcript of the attached tab as styled text on black.
/// No PTY, no parsing, no timers; it redraws only when the content or size changes.
final class FakeTerminalSurface: TerminalSurface {
    private let terminalView = FakeTerminalView()
    private let content: @MainActor (TerminalTarget) -> String
    private(set) var target: TerminalTarget?
    /// Inputs received (lets the shell be exercised without an engine).
    private(set) var sentInputs: [TerminalInput] = []
    var onGridSizeChange: ((TerminalGridSize) -> Void)?

    init(content: @escaping @MainActor (TerminalTarget) -> String) {
        self.content = content
        terminalView.onResize = { [weak self] in self?.notifyGrid() }
    }

    var view: NSView { terminalView }

    var fontSize: CGFloat {
        get { terminalView.fontSize }
        set {
            guard newValue != terminalView.fontSize else { return }
            terminalView.fontSize = newValue
            notifyGrid()
        }
    }

    var gridSize: TerminalGridSize { terminalView.gridSize }

    func attach(_ target: TerminalTarget) {
        guard target != self.target else { return }
        self.target = target
        terminalView.followsBottom = echoes[target] != nil
        terminalView.markup = content(target) + echoed(for: target)
    }

    func detach() {
        guard target != nil else { return }
        target = nil
        terminalView.markup = ""
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// Re-reads the mock content (e.g. after the session state changed).
    func reload() {
        guard let target else { return }
        terminalView.markup = content(target) + echoed(for: target)
    }

    func setOccluded(_ occluded: Bool) {}

    func send(_ input: TerminalInput) {
        sentInputs.append(input)
        if sentInputs.count > 64 { sentInputs.removeFirst(sentInputs.count - 64) } // bounded: it lives for the app's lifetime
        guard let target else { return }
        record(input, for: target)
    }

    /// Text the composer (or the error banner) sent to `target`: mock mode has no PTY, so the
    /// fake terminal prints each send as a prompt line under its transcript.
    private var echoes: [TerminalTarget: [String]] = [:]

    func record(_ input: TerminalInput, for target: TerminalTarget) {
        guard case .payload(let bytes, _, _) = input else { return }
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
        var lines = echoes[target] ?? []
        lines.append(text)
        echoes[target] = Array(lines.suffix(8))
        if target == self.target {
            terminalView.followsBottom = true
            terminalView.markup = content(target) + echoed(for: target)
        }
    }

    private func echoed(for target: TerminalTarget) -> String {
        guard let lines = echoes[target], !lines.isEmpty else { return "" }
        return lines.map { "\n\n<d>❯</d> " + Self.literal($0).replacingOccurrences(of: "\n", with: "\n  ") }.joined()
    }

    /// Keeps `<d>`-like text literal (TermMarkup would style it).
    private static func literal(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "<\u{200B}")
    }

    private var lastGrid: TerminalGridSize?
    private func notifyGrid() {
        let grid = gridSize
        guard grid != lastGrid else { return }
        lastGrid = grid
        onGridSizeChange?(grid)
    }
}

final class FakeTerminalSurfaceFactory: TerminalSurfaceFactory {
    let content: @MainActor (TerminalTarget) -> String
    /// The surfaces made so far (a send to a target no slot shows is recorded on the main one).
    private var surfaces: [TerminalSlot: FakeTerminalSurface] = [:]

    init(content: @escaping @MainActor (TerminalTarget) -> String) {
        self.content = content
    }

    func makeSurface(slot: TerminalSlot) -> TerminalSurface {
        let surface = FakeTerminalSurface(content: content)
        surfaces[slot] = surface
        return surface
    }

    func send(_ input: TerminalInput, to target: TerminalTarget) -> Bool {
        if let shown = surfaces.values.first(where: { $0.target == target }) {
            shown.send(input)
        } else {
            surfaces[.main]?.record(input, for: target)
        }
        return true
    }
}

/// Draws TermMarkup text: JetBrains Mono, line height 1.45, padding 10 / 16 (`.term`).
final class FakeTerminalView: NSView {
    var fontSize: CGFloat = 13 { didSet { if fontSize != oldValue { rebuild() } } }
    var markup = "" { didSet { if markup != oldValue { rebuild() } } }
    /// Keeps the last lines in view when the text is taller than the view (a send was echoed,
    /// like a terminal scrolling).
    var followsBottom = false { didSet { if followsBottom != oldValue { needsDisplay = true } } }
    var onResize: (() -> Void)?
    private var rendered = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("終端機")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Takes focus like a terminal would, so ⌘W and ⌘J can tell which slot the user is in.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    private var lineHeight: CGFloat { round(fontSize * 1.45) }

    var gridSize: TerminalGridSize {
        let font = Typeface.fixed(fontSize)
        let advance = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        return TerminalGridSize(columns: max(1, Int((bounds.width - 32) / advance)),
                                rows: max(1, Int((bounds.height - 20) / lineHeight)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    private func rebuild() {
        // Terminal text has its own size (Settings › 終端機字級), never the interface zoom.
        rendered = TermMarkup.attributed(markup, font: Typeface.fixed(fontSize), boldFont: Typeface.fixed(fontSize, .bold),
                                         lineHeight: lineHeight)
        setAccessibilityValue(rendered.string)
        needsDisplay = true
        onResize?()
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.termBackground)
        let area = CGRect(x: 16, y: 10, width: bounds.width - 32, height: bounds.height - 20)
        var origin = area.minY
        if followsBottom {
            let height = ceil(rendered.boundingRect(with: CGSize(width: area.width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin]).height)
            if height > area.height { origin = area.maxY - height }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: area).addClip()
        rendered.draw(with: CGRect(x: area.minX, y: origin, width: area.width, height: area.maxY - origin),
                      options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
}
