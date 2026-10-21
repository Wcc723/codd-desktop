import AppKit
import CoddTerminal
import Synchronization

/// One window, one `TerminalEngine`, one local PTY.
///
/// Every PTY output chunk is kept in `history` (the demo's stand-in for the holder's ring) and fed
/// to the current engine under the same lock, so "dispose and replay" can hand a fresh engine the
/// exact history and then continue live without losing or reordering a byte.
@MainActor
final class DemoController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let container = NSView()
    private let argv: [String]
    private let options: DemoOptions
    private var engine: TerminalEngine
    private var pty: DemoPTY?
    private let stream = DemoStream()
    private var status = ""
    private var lastReplyBytes: Int?
    private var exited = false

    init(argv: [String], options: DemoOptions = DemoOptions()) {
        self.argv = argv
        self.options = options
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: options.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        engine = TerminalEngine(configuration: options.configuration)
        super.init()
        window.title = "codd-term-demo"
        window.delegate = self
        window.backgroundColor = .black
        window.contentView = container
        window.center()
        install(engine)
    }

    func start() {
        if options.background {
            // Behind every other window, never front, never key through activation: the user keeps
            // working while a measurement runs (the window is covered, so measurements that need
            // drawing pass --force-render).
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        spawnShell()
        engine.focus()
        if let issue = TerminalRuntime.lastConfigurationIssue {
            log("CONFIG ISSUE \(issue)")
        }
    }

    // MARK: - Menu actions

    /// Disposes of the engine, builds a new one and replays the captured history into it, followed
    /// by startup probes (DA1, DA2, XTVERSION, DSR, DECRQM, kitty keyboard query). A replay must not
    /// answer any of them; the subtitle reports how many bytes the engine wrote while replaying.
    @objc func replayIntoFreshSurface(_: Any?) {
        Task { await replayHistory() }
    }

    @discardableResult
    func replayHistory() async -> Int {
        let old = engine
        let fresh = TerminalEngine(configuration: old.configuration)
        fresh.fontSize = old.fontSize
        old.dispose()
        install(fresh)
        let counter = ByteCounter()
        let pty = pty
        fresh.onWrite = { bytes in
            counter.add(bytes.count)
            pty?.write(bytes)
        }
        let probes = Array("\u{1B}[c\u{1B}[>c\u{1B}[>0q\u{1B}[6n\u{1B}[?2026$p\u{1B}[?u".utf8)
        let replayed = stream.switchTarget(to: fresh) { history in
            fresh.replay(history)
            fresh.replay(probes)
            return history.count
        }
        fresh.focus()
        await fresh.parsed()
        try? await Task.sleep(for: .milliseconds(50))
        let written = counter.value
        log("REPLAY history=\(replayed) bytes, probes=\(probes.count) bytes, engine wrote \(written) bytes during replay")
        status = "replayed \(replayed) B · \(written) reply bytes"
        lastReplyBytes = written
        updateTitle()
        return written
    }

    @objc func resetTerminal(_: Any?) {
        engine.reset()
        engine.waitUntilParsed()
        // Ask the shell to draw its prompt again on the clean screen.
        pty?.write([0x0C])
    }

    @objc func restartShell(_: Any?) {
        pty?.terminate()
        pty = nil
        engine.rebuildForNewProcess()
        stream.clearHistory()
        spawnShell()
    }

    @objc func biggerFont(_: Any?) {
        engine.fontSize += 1
    }

    @objc func smallerFont(_: Any?) {
        engine.fontSize -= 1
    }

    /// Bound to the app's reserved shortcuts (⌘K, ⌘1…⌘9, …): proves they reach the menu.
    @objc func reservedShortcut(_ sender: NSMenuItem) {
        log("APP SHORTCUT \(sender.title) reached the main menu")
        status = "\(sender.title) → app menu"
        updateTitle()
    }

    func windowWillClose(_: Notification) {
        pty?.terminate()
        engine.dispose()
        NSApp.terminate(nil)
    }

    // MARK: - Wiring

    private func install(_ engine: TerminalEngine) {
        self.engine = engine
        let view = engine.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let pty = pty
        engine.onWrite = { bytes in pty?.write(bytes) }
        engine.onResize = { [weak self] size in
            self?.pty?.resize(
                columns: size.columns, rows: size.rows, pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight
            )
            self?.updateTitle()
        }
        engine.onTitle = { [weak self] _ in self?.updateTitle() }
        engine.onWorkingDirectory = { path in log("CWD \(path)") }
        engine.onBell = { NSSound.beep() }
        engine.onFirstDeviceAttributesReply = { log("DA1 reply written (startup probes answered)") }
        engine.onFontSizeChange = { size in log("FONT \(size) pt") }
        engine.setOutputBacklogHandler(highWater: 1 << 20, lowWater: 256 << 10) { [stream] backlogged in
            stream.setPaused(backlogged)
        }
    }

    // MARK: - Smoke test

    /// `--smoke`: types into the shell through the real key path, waits for the output, replays the
    /// history into a fresh surface (no reply bytes may leak), checks the reserved shortcuts, exits
    /// the shell and quits. Prints `SMOKE OK` or `SMOKE FAIL <reason>`; the exit code follows.
    func runSmoke() async {
        func fail(_ reason: String) -> Never {
            log("SMOKE FAIL \(reason)")
            pty?.terminate()
            exit(1)
        }
        func wait(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + timeout
            while !condition() {
                if ContinuousClock.now >= deadline { fail("timed out waiting for \(what)") }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await wait("the surface") { engine.hasSurface && engine.gridSize != nil }
        await wait("the zsh prompt") { (engine.readViewportText() ?? "").contains("%") }
        type("echo CODD_SMOKE_$((6*7)) 注音\r")
        await wait("the echo output") { screenLines().contains("CODD_SMOKE_42 注音") }
        let replies = await replayHistory()
        guard replies == 0 else { fail("replay wrote \(replies) reply bytes") }
        await wait("the replayed output") { screenLines().contains("CODD_SMOKE_42 注音") }
        type("echo AFTER_$((1+1))\r")
        await wait("live output after the replay") { screenLines().contains("AFTER_2") }
        let commandK = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k",
            isARepeat: false, keyCode: 0x28
        )
        guard let commandK, engine.isReservedKeyEquivalent(commandK), !engine.view.performKeyEquivalent(with: commandK)
        else { fail("⌘K was not left to the app") }
        type("exit\r")
        await wait("the shell to exit") { exited }
        log("SMOKE OK grid=\(engine.gridSize?.description ?? "?") replyBytesDuringReplay=\(lastReplyBytes ?? -1)")
        exit(0)
    }

    // MARK: - Measurement (M5 F2)

    /// `--measure <s>`: one `MEASURE t=… footprint_mb=… frames=…` line per second (frames = frames
    /// libghostty presented since the previous line), then a summary line, then exit 0
    /// with the child ended. The external footprint / vmmap samples are taken by the caller.
    func runMeasurement(seconds: Double) async {
        let start = ContinuousClock.now
        var applied = false
        // libghostty's renderer thread presents each frame by handing its IOSurface layer a new
        // `contents` (on the main queue): counting those changes counts presented frames.
        let presented = ByteCounter()
        var observation: NSKeyValueObservation?
        var lastFrames = 0
        var second = 0
        log("MEASURE pid=\(getpid()) argv=\(argv.joined(separator: " ")) forceRender=\(options.forceRender)")
        while ContinuousClock.now - start < .seconds(seconds) {
            try? await Task.sleep(for: .seconds(1))
            second += 1
            if !applied, engine.hasSurface {
                applied = applyMetalOptions()
                observation = engine.view.layer?.observe(\.contents, options: []) { _, _ in presented.add(1) }
            }
            let frames = presented.value
            let footprint = Self.physFootprint().map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "?"
            log("MEASURE t=\(second) footprint_mb=\(footprint) frames=\(frames - lastFrames) occlusion=\(window.occlusionState.contains(.visible) ? "visible" : "covered")")
            lastFrames = frames
        }
        observation?.invalidate()
        log("MEASURE done layer=\(layerDescription()) frames_total=\(presented.value)")
        pty?.terminate()
        exit(0)
    }

    /// The view's backing layer, as libghostty left it.
    private func layerDescription() -> String {
        guard let layer = engine.view.layer else { return "none" }
        var text = String(describing: Swift.type(of: layer))
        if let metal = layer as? CAMetalLayer {
            text += " drawables=\(metal.maximumDrawableCount) timeout=\(metal.allowsNextDrawableTimeout)"
        }
        return text
    }

    /// `--metal-drawables`, `--metal-no-timeout`: only meaningful when the layer is a CAMetalLayer.
    private func applyMetalOptions() -> Bool {
        guard options.metalDrawables != nil || options.metalNoTimeout else { return true }
        guard let metal = engine.view.layer as? CAMetalLayer else {
            log("MEASURE metal options skipped: layer is \(layerDescription())")
            return true
        }
        if let count = options.metalDrawables { metal.maximumDrawableCount = min(3, max(2, count)) }
        if options.metalNoTimeout { metal.allowsNextDrawableTimeout = false }
        log("MEASURE metal options applied: \(layerDescription())")
        return true
    }

    /// `phys_footprint` (what Activity Monitor calls Memory; `footprint` reports the same).
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Typed through the terminal view's keyDown (interpretKeyEvents → libghostty → onWrite → PTY).
    private func type(_ text: String) {
        window.makeFirstResponder(engine.view)
        for character in text {
            let string = String(character)
            let keyCode: UInt16 = string == "\r" ? 0x24 : 0x00
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: string,
                charactersIgnoringModifiers: string, isARepeat: false, keyCode: keyCode
            )
            if let event { engine.view.keyDown(with: event) }
        }
    }

    private func screenLines() -> [String] {
        (engine.readViewportText() ?? "").components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func spawnShell() {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GHOSTTY_") || key.hasPrefix("DYLD_") || key.hasPrefix("__CF") {
            environment[key] = nil
        }
        environment.merge(TerminalRuntime.childEnvironment) { _, terminal in terminal }
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let grid = engine.gridSize ?? TerminalResize(columns: 100, rows: 30)
        let size = winsize(
            ws_row: UInt16(clamping: grid.rows), ws_col: UInt16(clamping: grid.columns),
            ws_xpixel: UInt16(clamping: grid.pixelWidth), ws_ypixel: UInt16(clamping: grid.pixelHeight)
        )
        let stream = stream
        do {
            let pty = try DemoPTY(
                argv: argv,
                environment: environment,
                directory: FileManager.default.homeDirectoryForCurrentUser.path,
                size: size,
                onOutput: { bytes in stream.receive(bytes) },
                onExit: { [weak self] status in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.childExited(status) }
                    }
                }
            )
            self.pty = pty
            stream.setPTY(pty)
            stream.switchTarget(to: engine) { _ in 0 }
            engine.onWrite = { bytes in pty.write(bytes) }
            status = "\(argv.joined(separator: " ")) · pid \(pty.pid)"
            log("SPAWN \(argv.joined(separator: " ")) pid=\(pty.pid)")
        } catch {
            status = "spawn failed: \(error)"
        }
        updateTitle()
    }

    private func childExited(_ status: Int32) {
        exited = true
        engine.childExited(status: status)
        let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        self.status = "EXITED \(code) · Terminal ▸ Restart Shell"
        log("EXIT status=\(status)")
        updateTitle()
    }

    private func updateTitle() {
        let title = engine.title.isEmpty ? "codd-term-demo" : engine.title
        window.title = title
        window.subtitle = [engine.gridSize?.description, status].compactMap { $0 }.joined(separator: " · ")
    }
}

/// PTY output fan-in: history capture plus feeding the current engine, under one lock.
final class DemoStream: Sendable {
    private struct State {
        var history: [UInt8] = []
        var target: TerminalEngine?
        var pty: DemoPTY?
    }

    /// The demo's stand-in for a holder ring.
    static let historyLimit = 8 << 20
    private let state = Mutex(State())

    func setPTY(_ pty: DemoPTY) {
        state.withLock { $0.pty = pty }
    }

    func receive(_ bytes: UnsafeRawBufferPointer) {
        state.withLock { state in
            state.history.append(contentsOf: bytes)
            if state.history.count > Self.historyLimit {
                state.history.removeFirst(state.history.count - Self.historyLimit)
            }
            state.target?.feed(bytes)
        }
    }

    /// Switches the live target; `prepare` runs under the lock with the history so far, so no chunk
    /// lands between the replay and the live feed.
    @discardableResult
    func switchTarget(to engine: TerminalEngine, prepare: ([UInt8]) -> Int) -> Int {
        state.withLock { state in
            state.target = engine
            return prepare(state.history)
        }
    }

    func clearHistory() {
        state.withLock { $0.history = [] }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { $0.pty }?.setReadingPaused(paused)
    }
}

final class ByteCounter: Sendable {
    private let count = Atomic<Int>(0)

    func add(_ value: Int) {
        count.add(value, ordering: .relaxed)
    }

    var value: Int {
        count.load(ordering: .relaxed)
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("codd-term-demo: \(message)\n".utf8))
}
