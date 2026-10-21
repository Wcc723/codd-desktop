import AppKit
import TermSpikeKit

/// The interactive comparison window:
/// `[GHOSTTY | SWIFTTERM | SIDE BY SIDE]`, a command field, `[START]`, a
/// TERM_PROGRAM selector, and one pane per engine, each with its own PTY.
@MainActor
final class SpikeWindowController: NSWindowController, NSWindowDelegate {
    enum Layout: Int {
        case ghostty = 0
        case swiftterm = 1
        case sideBySide = 2
    }

    /// TERM_PROGRAM choices; Claude gates some features on it (critique H5).
    private static let termPrograms: [(label: String, value: String?)] = [
        ("TERM_PROGRAM: (unset)", nil),
        ("TERM_PROGRAM: ghostty", "ghostty"),
        ("TERM_PROGRAM: CODD", "CODD"),
    ]

    private let ghosttyPane = EnginePane(kind: .ghostty)
    private let swiftTermPane = EnginePane(kind: .swiftterm)
    private let layoutControl = NSSegmentedControl(
        labels: ["GHOSTTY", "SWIFTTERM", "SIDE BY SIDE"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let commandField = NSTextField(string: "zsh -l")
    private let startButton = NSButton(title: "START", target: nil, action: nil)
    private let stopButton = NSButton(title: "STOP", target: nil, action: nil)
    private let patternButton = NSButton(title: "PATTERN", target: nil, action: nil)
    private let termProgramPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hint = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private var keyRouter: KeyRouter?
    private var headerTimer: Timer?

    private var panes: [EnginePane] { [ghosttyPane, swiftTermPane] }

    init(options: InteractiveOptions = InteractiveOptions()) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TermSpike · GHOSTTY vs SWIFTTERM"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CoddTheme.chromeBackground
        window.setFrameAutosaveName("TermSpikeMain")
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        commandField.stringValue = options.command
        layoutControl.selectedSegment = options.layout
        apply(layout: layout)
        keyRouter = KeyRouter { [weak self] in self?.panes ?? [] }
        keyRouter?.install()
        headerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.panes.forEach { $0.refreshHeader() } }
        }
        if let delay = options.dumpAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for pane in self.visiblePanes(for: self.layout) {
                        pane.refreshHeader()
                        print("==== \(pane.host.kind.label) \(pane.host.io.currentSize?.description ?? "?") ====")
                        print(pane.host.screenText())
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        if options.autostart || options.pattern {
            Task { @MainActor [weak self] in
                // Start only once the split layout has settled, so the child's
                // first `stty size` already sees the final grid.
                await self?.waitForStableGrid()
                if options.autostart { self?.start(nil) }
                if options.pattern {
                    try? await Task.sleep(for: .seconds(1))
                    self?.feedPattern(nil)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = CoddTheme.chromeBackground.cgColor

        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        layoutControl.selectedSegment = Layout.ghostty.rawValue
        layoutControl.font = CoddTheme.chromeFont(size: 11)

        commandField.font = CoddTheme.chromeFont(size: 12)
        commandField.placeholderString = "zsh -l  ·  claude"
        commandField.target = self
        commandField.action = #selector(start(_:))
        commandField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        // No key equivalent on START: a default button would steal Return from the terminal.
        startButton.target = self
        startButton.action = #selector(start(_:))
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        patternButton.target = self
        patternButton.action = #selector(feedPattern(_:))
        patternButton.toolTip = "把渲染測試圖樣直接送進可見的引擎（不經過 PTY）"


        for (index, choice) in Self.termPrograms.enumerated() {
            termProgramPopup.addItem(withTitle: choice.label)
            termProgramPopup.item(at: index)?.representedObject = choice.value
        }
        termProgramPopup.font = CoddTheme.chromeFont(size: 11)

        hint.font = CoddTheme.chromeFont(size: 10.5)
        hint.textColor = CoddTheme.chromeDim
        hint.stringValue = "每個引擎各自一個 PTY · 隱藏的引擎持續解析但不繪製 · os_signpost: app.fancycodd.TermSpike"
        hint.lineBreakMode = .byTruncatingTail

        let commandLabel = NSTextField(labelWithString: "CMD")
        commandLabel.font = CoddTheme.chromeFont(size: 10.5)
        commandLabel.textColor = CoddTheme.chromeDim

        let bar = NSStackView(views: [layoutControl, commandLabel, commandField, startButton, stopButton, patternButton, termProgramPopup, hint])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false

        split.isVertical = true
        split.dividerStyle = .thin
        split.arrangesAllSubviews = true
        split.addArrangedSubview(ghosttyPane)
        split.addArrangedSubview(swiftTermPane)
        split.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(bar)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
    }

    private var layout: Layout {
        Layout(rawValue: layoutControl.selectedSegment) ?? .ghostty
    }

    private func visiblePanes(for layout: Layout) -> [EnginePane] {
        switch layout {
        case .ghostty: [ghosttyPane]
        case .swiftterm: [swiftTermPane]
        case .sideBySide: [ghosttyPane, swiftTermPane]
        }
    }

    private func apply(layout: Layout) {
        let visible = visiblePanes(for: layout)
        for pane in panes {
            let show = visible.contains { $0 === pane }
            pane.isHidden = !show
            pane.setSuspended(!show)
        }
        split.adjustSubviews()
        if layout == .sideBySide {
            equalizeSplit()
            // The first layout pass may not have happened yet (window just built).
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.equalizeSplit() }
            }
        }
        visible.first?.focusTerminal()
        panes.forEach { $0.refreshHeader() }
    }

    /// Gives both panes half the width (NSSplitView keeps a just-unhidden
    /// pane at whatever width it had, often zero).
    private func equalizeSplit() {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard split.bounds.width > 0 else { return }
        split.setPosition((split.bounds.width - split.dividerThickness) / 2, ofDividerAt: 0)
    }

    /// Waits (at most `timeout`) until every visible engine reports a grid
    /// and none changed over the last three 100 ms polls.
    private func waitForStableGrid(timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last: [PTYWindowSize?] = []
        var stablePolls = 0
        while clock.now < deadline {
            let sizes = visiblePanes(for: layout).map { $0.host.io.currentSize }
            if !sizes.contains(where: { $0 == nil }), sizes == last {
                stablePolls += 1
                if stablePolls >= 3 { return }
            } else {
                stablePolls = 0
            }
            last = sizes
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Actions

    @objc private func layoutChanged(_: Any?) {
        apply(layout: layout)
    }

    @objc private func start(_: Any?) {
        let command = commandField.stringValue
        let termProgram = termProgramPopup.selectedItem?.representedObject as? String
        for pane in visiblePanes(for: layout) {
            do {
                try pane.start(command: command, termProgram: termProgram)
            } catch {
                presentError(error)
            }
        }
        visiblePanes(for: layout).first?.focusTerminal()
    }

    @objc private func stop(_: Any?) {
        visiblePanes(for: layout).forEach { $0.stop() }
    }

    /// Feeds the render test pattern into every visible engine, from a
    /// background queue like PTY output would be.
    @objc private func feedPattern(_: Any?) {
        for pane in visiblePanes(for: layout) {
            let feeder = pane.host.feeder
            DispatchQueue.global(qos: .userInitiated).async {
                feeder.feed(RenderTestPattern.bytes)
            }
        }
    }

    // MARK: - Teardown

    func windowWillClose(_: Notification) {
        shutdown()
    }

    func shutdown() {
        headerTimer?.invalidate()
        headerTimer = nil
        keyRouter?.uninstall()
        panes.forEach { $0.stop() }
    }

    /// Latency summary for stdout when the app quits.
    func latencyReport() -> String {
        panes.map { pane in
            let host = pane.tracker.hostPath.summary()
            let event = pane.tracker.eventToWrite.summary()
            return "\(pane.host.kind.label) keyDown→ptyWrite \(host.compact) · HID event→ptyWrite \(event.compact) · unmatched \(pane.tracker.unmatchedCount)"
        }.joined(separator: "\n")
    }
}
