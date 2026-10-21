import AppKit
import TermSpikeKit

/// One engine with its own PTY: a one-line header (engine, command, pid, grid,
/// title, live keyDown→PTY-write latency) above the terminal view.
@MainActor
final class EnginePane: NSView {
    /// Replaced by a fresh engine when a session that ended on its own is
    /// restarted: Ghostty stops sending keys once it was told the child
    /// exited (`ghostty_surface_process_exit`; see the probe's "input after
    /// reported exit" check), so its surface cannot host the next session.
    private(set) var host: any TerminalEngineHost
    let tracker = KeyLatencyTracker()

    private let header = NSTextField(labelWithString: "")
    private let container = NSView()
    private var current: (generation: Int, session: PTYSession)?
    /// Sessions that were replaced or stopped, kept until their exit is reaped
    /// so no zombie is left behind.
    private var retiring: [Int: PTYSession] = [:]
    private var nextGeneration = 0
    private var exitNote: String?
    private(set) var isSuspended = false

    init(kind: EngineKind) {
        host = EngineFactory.make(kind)
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        header.font = CoddTheme.chromeFont(size: 10.5)
        header.textColor = CoddTheme.chromeText
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(container)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 16),
            container.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        attachTerminalView()
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        host.viewDidChangeWindow()
    }

    // MARK: - Process lifecycle

    func start(command: String, termProgram: String?) throws {
        stop()
        if exitNote != nil {
            replaceEngine()
        }
        // Reset the engine (RIS) so the new program starts from a clean screen.
        // Fed synchronously here, before the child exists, so it cannot race
        // (and wipe) the child's first output arriving on the PTY queue. It is
        // two bytes; all program output goes through the PTY queue.
        host.feeder.feed(Array("\u{1B}c".utf8))
        nextGeneration += 1
        let generation = nextGeneration
        let session = try PTYSession(
            host: host,
            command: command,
            termProgram: termProgram,
            tracker: tracker,
            onExit: { [weak self] status in self?.sessionExited(generation, status: status) }
        )
        current = (generation, session)
        exitNote = nil
        tracker.reset()
        refreshHeader()
    }

    func stop() {
        guard let (generation, session) = current else { return }
        current = nil
        retiring[generation] = session
        session.detachAndTerminate()
        refreshHeader()
    }

    var isRunning: Bool { current != nil }

    func sendRaw(_ bytes: [UInt8]) {
        current?.session.sendRaw(bytes)
    }

    private func sessionExited(_ generation: Int, status: Int32) {
        retiring[generation] = nil
        guard current?.generation == generation else { return }
        current = nil
        exitNote = WaitStatus.describe(status)
        host.processExited(status: status)
        refreshHeader()
    }

    // MARK: - Visibility and focus

    /// Hidden panes keep their PTY and keep parsing; only rendering stops.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        host.setRenderingSuspended(suspended)
        if host.kind == .swiftterm {
            // SwiftTerm only pauses its frame driver for window-level
            // invisibility, so take the view out of the window instead.
            if suspended {
                host.view.removeFromSuperview()
            } else {
                attachTerminalView()
            }
            host.viewDidChangeWindow()
        }
    }

    func focusTerminal() {
        window?.makeFirstResponder(host.view)
    }

    /// Whether `responder` is this pane's terminal view (or inside it).
    func owns(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === host.view || view.isDescendant(of: host.view)
    }

    /// Swaps in a new engine of the same kind, in the same place.
    private func replaceEngine() {
        let hadFocus = owns(window?.firstResponder)
        host.tearDown()
        host = EngineFactory.make(host.kind)
        if isSuspended {
            host.setRenderingSuspended(true)
            if host.kind == .ghostty { attachTerminalView() }
        } else {
            attachTerminalView()
        }
        host.viewDidChangeWindow()
        if hadFocus { focusTerminal() }
    }

    private func attachTerminalView() {
        let terminal = host.view
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
    }

    // MARK: - Header

    func refreshHeader() {
        var parts = [host.kind.label]
        if let current {
            parts.append(current.session.commandLine)
            parts.append("pid \(current.session.process.pid)")
        } else if let exitNote {
            parts.append("EXITED · \(exitNote)")
        } else {
            parts.append("IDLE · press START")
        }
        if let size = host.io.currentSize {
            parts.append(size.description)
        }
        if let swiftTerm = host as? SwiftTermHost {
            parts.append(swiftTerm.usesMetal ? "metal" : "coregraphics")
        }
        if isSuspended {
            parts.append("HIDDEN")
        }
        let latency = tracker.hostPath.summary()
        if latency.count > 0 {
            parts.append("KEY→PTY p50 \(fmt(latency.p50)) p99 \(fmt(latency.p99)) max \(fmt(latency.max)) ms n=\(latency.count)")
        }
        if !host.title.isEmpty {
            parts.append("「\(host.title)」")
        }
        header.stringValue = parts.joined(separator: "  ·  ")
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
