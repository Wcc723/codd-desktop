import AppKit
import CoddHolderClient
import CoddProtocol
import CoddTerminal
import Darwin
import Foundation
import Testing
@testable import CODD

/// Real holders (the copy embedded in CODD.app, installed into a temp data root) streamed into
/// real libghostty terminals in a window that is never ordered on screen. Children are `/bin/sh`
/// and `cat`; never `claude`, never the user's login shell or rc files.
@MainActor
@Suite("Terminal hub", .serialized)
final class TerminalHubTests {
    private let rootPath: String
    private let window: NSWindow
    private let container: NSView

    /// Prints a line, then echoes whatever it is sent.
    private static let echoArgv = ["/bin/sh", "-c", "printf 'hello-from-holder\\n'; exec /bin/cat"]

    init() throws {
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/codd-h.XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        // `$TMPDIR` ends in `/`: normalized like every data root, so prefixes and pkill match.
        rootPath = CoddDataRoot(path: String(cString: created)).path
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = container
    }

    deinit {
        // Every holder of this test's data root (sessions and tabs): their command lines name it.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", rootPath + "/"]
        try? pkill.run()
        pkill.waitUntilExit()
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    private struct Rig {
        let store: HolderSessionStore
        let shell: ShellState
        let hub: TerminalHub
        let main: TerminalSurface
        let panel: TerminalSurface
        let logs: Recorder<String>
    }

    /// A store spawning `argv` from the installed holder binary, a hub, and both slots in the window.
    private func makeRig(argv: [String] = TerminalHubTests.echoArgv, hotCapacity: Int = 6) async throws -> Rig {
        let root = CoddDataRoot(path: rootPath)
        let executable = try #require(HolderBinary.install(root: root) { _ in }, "CODD.app/Contents/MacOS/codd-holder is missing")
        #expect(executable.hasPrefix(rootPath + "/bin/codd-holder-"))
        let launcher = HolderLauncher(holderExecutable: executable, root: root, shellArgvOverride: argv)
        let logs = Recorder<String>()
        let store = HolderSessionStore(root: root, launcher: launcher) { logs.append($0) }
        let shell = ShellState()
        let hub = TerminalHub(store: store, shell: shell, hotCapacity: hotCapacity, probeWindow: .milliseconds(100)) {
            logs.append($0)
        }
        let main = hub.makeSurface(slot: .main)
        let panel = hub.makeSurface(slot: .panel)
        for (surface, y) in [(main, 300.0), (panel, 0.0)] {
            surface.view.frame = NSRect(x: 0, y: y, width: 900, height: 300)
            container.addSubview(surface.view)
        }
        await store.start()
        await hub.discoverTabs()
        return Rig(store: store, shell: shell, hub: hub, main: main, panel: panel, logs: logs)
    }

    private func tearDown(_ rig: Rig) {
        rig.hub.shutdown()
        rig.store.shutdown()
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(8), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition(), "timed out waiting for \(what)")
        if !condition() { print("TIMEOUT \(what)") }
    }

    private func occurrences(_ needle: String, in text: String?) -> Int {
        (text ?? "").components(separatedBy: needle).count - 1
    }

    @Test func sessionStreamsIntoATerminalTakesInputAndReplaysWhenCold() async throws {
        let rig = try await makeRig(hotCapacity: 0)
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let target = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(target)
        await waitUntil("output in the terminal") { rig.hub.viewportText(.main)?.contains("hello-from-holder") == true }
        #expect(rig.hub.tier(of: target) == .visible)

        // Answer-bar style input through the stream: the PTY echoes it and cat prints it again.
        await waitUntil("streaming") { rig.hub.isStreaming(.main) }
        rig.main.send(.text("ping-42", submit: true))
        await waitUntil("echo") { occurrences("ping-42", in: rig.hub.viewportText(.main)) >= 2 }
        let grid = try #require(rig.hub.grid(for: .main))
        #expect(grid.columns > 40 && grid.rows > 5)

        // Hidden with no hot slot: the engine goes cold (disposed, stream detached) once the
        // startup pin is released ...
        await waitUntil("pin released") { !rig.hub.isPinned(target) }
        rig.main.detach()
        #expect(rig.hub.tier(of: target) == .cold)
        #expect(rig.store.connection(for: id)?.engine == nil)
        // ... and comes back with its history replayed from the holder's ring.
        rig.main.attach(target)
        await waitUntil("replay") {
            let text = rig.hub.viewportText(.main)
            return text?.contains("hello-from-holder") == true && occurrences("ping-42", in: text) >= 2
        }
        #expect(rig.logs.values.contains { $0.hasPrefix("TERMINAL show slot=main") && $0.contains("tier=cold") })

        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    @Test func hotTerminalsKeepStreamingWhileHidden() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let first = try #require(rig.store.spawnShell(in: "/tmp"))
        let second = try #require(rig.store.spawnShell(in: "/tmp"))
        let a = TerminalTarget(sessionID: first, tab: .claude)
        let b = TerminalTarget(sessionID: second, tab: .claude)
        rig.main.attach(a)
        await waitUntil("first streams") { rig.hub.isStreaming(.main) }
        rig.main.attach(b)
        #expect(rig.hub.tier(of: a) == .hot)
        // Input to the hidden (hot) session still reaches its terminal.
        rig.store.connection(for: first)?.send(Array("while-hidden".utf8), submit: true)
        await waitUntil("second streams") { rig.hub.isStreaming(.main) }
        rig.main.attach(a)
        #expect(rig.hub.tier(of: a) == .visible)
        await waitUntil("hidden output") { occurrences("while-hidden", in: rig.hub.viewportText(.main)) >= 2 }
        let switches = rig.logs.values.filter { $0.hasPrefix("TERMINAL show slot=main") && $0.contains("tier=hot") }
        #expect(!switches.isEmpty)
        rig.store.stop([first, second])
        await waitUntil("exits") { rig.store.session(first)?.state == .exited && rig.store.session(second)?.state == .exited }
    }

    @Test func shellTabSpawnsLazilyAndClosesWithItsHolder() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        await waitUntil("session streams") { rig.hub.isStreaming(.main) }

        let tab = rig.shell.addShellTab(in: id, kind: .shell)
        let tabDirectory = rig.store.root.sessionDirectory(id) + "/tabs/" + tab.id
        #expect(!FileManager.default.fileExists(atPath: tabDirectory))
        rig.main.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        await waitUntil("tab output") { rig.hub.viewportText(.main)?.contains("hello-from-holder") == true }
        await waitUntil("tab meta.json") { FileManager.default.fileExists(atPath: tabDirectory + "/meta.json") }
        let meta = try #require(SessionDirectory.readMeta(directory: tabDirectory))
        #expect(SessionDirectory.isHolderProcess(meta.holderPid))
        #expect(meta.cwd == "/tmp")

        // Tabs never show up as sessions of their own (what the store's discovery lists).
        let listed = try SessionDirectory.list(root: rig.store.root.sessionsPath)
        #expect(listed.map(\.meta.session) == [id])

        // ⌘W on the tab: its holder ends and its directory goes away.
        weak let tabEngine = rig.hub.engine(for: TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        #expect(tabEngine != nil)
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        rig.shell.removeShellTab(tab.id, in: id)
        rig.hub.closeShellTab(sessionID: id, tabID: tab.id)
        await waitUntil("tab holder gone") { !SessionDirectory.isHolderProcess(meta.holderPid) }
        await waitUntil("tab directory removed") { !FileManager.default.fileExists(atPath: tabDirectory) }
        // Review F4: the closed tab's engine (and its view and sink) is released.
        await waitUntil("tab engine released") { tabEngine == nil }

        // Removing the session releases its own engine the same way.
        weak let sessionEngine = rig.hub.engine(for: TerminalTarget(sessionID: id, tab: .claude))
        #expect(sessionEngine != nil)
        rig.main.detach()
        rig.store.removeSessions([id])
        await waitUntil("session engine released") { sessionEngine == nil }
    }

    /// Relaunch: the tab's holder kept running; a new hub finds it, reattaches and replays it
    /// (the engine is created inside the pool while it binds, so it must be passed along).
    @Test func discoveredTabHolderReattachesAndReplays() async throws {
        let first = try await makeRig()
        let id = try #require(first.store.spawnShell(in: "/tmp"))
        first.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        await waitUntil("session streams") { first.hub.isStreaming(.main) }
        let tab = first.shell.addShellTab(in: id, kind: .shell)
        first.main.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        await waitUntil("tab streams") { first.hub.isStreaming(.main) }
        first.main.send(.text("before-relaunch", submit: true))
        await waitUntil("tab echo") { occurrences("before-relaunch", in: first.hub.viewportText(.main)) >= 2 }
        let layout = first.shell.pane(for: id)
        tearDown(first)
        first.main.view.removeFromSuperview()
        first.panel.view.removeFromSuperview()

        let second = try await makeRig()
        defer { tearDown(second) }
        #expect(second.logs.values.contains("discovered tabs=1 live=1"))
        second.shell.panes[id] = layout
        second.main.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        await waitUntil("tab replay after relaunch") {
            second.hub.isStreaming(.main) && occurrences("before-relaunch", in: second.hub.viewportText(.main)) >= 2
        }
        #expect(!second.logs.values.contains { $0.hasPrefix("spawned tab=") })
        second.store.stop([id])
        await waitUntil("exit") { second.store.session(id)?.state == .exited }
    }

    /// A full-screen program (alternate screen) is asked to redraw when a terminal reattaches.
    @Test func reattachRepaintsAlternateScreenPrograms() async throws {
        let rig = try await makeRig(argv: ["/bin/sh", "-c", "printf '\\033[?1049hfull-screen'; exec /bin/cat"], hotCapacity: 0)
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let target = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(target)
        await waitUntil("alt screen output") { rig.hub.viewportText(.main)?.contains("full-screen") == true }
        await waitUntil("pin released") { !rig.hub.isPinned(target) }
        let before = rig.logs.values.filter { $0.hasPrefix("repaint session=\(id)") }.count
        rig.main.detach()
        rig.main.attach(target)
        await waitUntil("repaint on reattach") { rig.logs.values.filter { $0.hasPrefix("repaint session=\(id)") }.count > before }
        await waitUntil("alt screen replayed") { rig.hub.viewportText(.main)?.contains("full-screen") == true }
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    @Test func panelShellThatExitsClosesThePanel() async throws {
        let rig = try await makeRig(argv: ["/bin/sh", "-c", "printf 'panel-up\\n'; exec /bin/cat"])
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        let panel = try #require(rig.shell.togglePanel(in: id))
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(panel.id)))
        await waitUntil("panel output") { rig.hub.viewportText(.panel)?.contains("panel-up") == true }
        await waitUntil("panel streams") { rig.hub.isStreaming(.panel) }
        // Ctrl+D ends cat: the shell exits, the panel closes and forgets its shell.
        rig.panel.send(.text("\u{04}", submit: false))
        await waitUntil("panel closed") { rig.shell.pane(for: id).panel == nil }
        #expect(!rig.shell.pane(for: id).panelOpen)
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    /// Audit CODE-2: the main slot's terminal and the panel's both send ⌘-clicked links through
    /// the hub's opener (replaced here: nothing opens, no sheet) and show their hovered link in
    /// their own slot only; switching the slot to another terminal clears it.
    @Test func terminalsInBothSlotsRouteLinksAndShowTheHoveredTarget() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let opened = Recorder<URL>(), revealed = Recorder<URL>(), asked = Recorder<(URL, NSWindow?)>()
        rig.hub.linkOpener = TerminalLinkOpener(open: { opened.append($0) }, reveal: { revealed.append($0) },
                                                confirm: { url, window, answer in asked.append((url, window)); answer(false) })
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let mainTarget = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(mainTarget)
        let panelTab = try #require(rig.shell.togglePanel(in: id))
        let panelTarget = TerminalTarget(sessionID: id, tab: .shell(panelTab.id))
        rig.panel.attach(panelTarget)
        let main = try #require(rig.main as? HolderTerminalSurface)
        let panel = try #require(rig.panel as? HolderTerminalSurface)

        for target in [mainTarget, panelTarget] {
            let engine = try #require(rig.hub.engine(for: target))
            let onOpenURL = try #require(engine.onOpenURL, "\(target)")
            onOpenURL(try #require(URL(string: "https://example.com/docs")))
            onOpenURL(try #require(URL(string: "file:///tmp/evil-repo/setup.command")))
            onOpenURL(try #require(URL(string: "smb://server/share")))
        }
        #expect(opened.values.map(\.absoluteString) == ["https://example.com/docs", "https://example.com/docs"])
        #expect(revealed.values.map(\.path) == ["/tmp/evil-repo/setup.command", "/tmp/evil-repo/setup.command"])
        #expect(asked.values.map { $0.0.absoluteString } == ["smb://server/share", "smb://server/share"])
        #expect(asked.values.allSatisfy { $0.1 === window })

        let mainEngine = try #require(rig.hub.engine(for: mainTarget))
        let panelEngine = try #require(rig.hub.engine(for: panelTarget))
        mainEngine.onHoverLink?("file:///tmp/evil-repo/setup.command")
        #expect(main.hoverLinkText == "file:///tmp/evil-repo/setup.command" && panel.hoverLinkText == nil)
        panelEngine.onHoverLink?("https://example.com/\u{202E}txt.exe")
        #expect(panel.hoverLinkText == "https://example.com/%E2%80%AEtxt.exe")
        mainEngine.onHoverLink?(nil)
        #expect(main.hoverLinkText == nil && panel.hoverLinkText != nil)
        // Another terminal in the slot: the bubble was the previous one's.
        let tab = rig.shell.addShellTab(in: id, kind: .shell)
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        #expect(panel.hoverLinkText == nil)

        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    /// Startup probes (M1 decision): the child asks DA1 before any client could attach; a
    /// terminal attached to a fresh spawn answers it anyway.
    @Test func freshSpawnAnswersStartupQueries() async throws {
        let script = "stty -echo -icanon min 1; printf '\\033[c'; dd bs=1 count=5 2>/dev/null | od -An -tx1; exec /bin/cat"
        let rig = try await makeRig(argv: ["/bin/sh", "-c", script])
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        // `od` prints the first 5 reply bytes: ESC [ ? 6 2 (libghostty answers `ESC [ ? 62 ; …`).
        await waitUntil("DA1 reply reached the child") {
            let words = (rig.hub.viewportText(.main) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return words.contains("1b 5b 3f 36 32")
        }
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    /// A second client taking a tab's holder over must never make this app end that holder.
    @Test func takenOverTabKeepsItsHolder() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let tab = rig.shell.addShellTab(in: id, kind: .shell)
        rig.main.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        await waitUntil("tab streams") { rig.hub.isStreaming(.main) }
        let tabDirectory = rig.store.root.sessionDirectory(id) + "/tabs/" + tab.id
        let meta = try #require(SessionDirectory.readMeta(directory: tabDirectory))
        let intruder = PtyConnection(sessionID: tab.id, socketPath: meta.socket, directory: tabDirectory)
        intruder.connect()
        await waitUntil("released") { rig.logs.values.contains { $0.hasPrefix("tab released") } }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(SessionDirectory.isHolderProcess(meta.holderPid))
        #expect(rig.shell.pane(for: id).tabs.map(\.id) == [tab.id])
        #expect(intruder.phase == .connected)
        intruder.close()
        kill(meta.holderPid, SIGTERM)
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    @Test func takeoverEndsTheConnectionWithoutReconnecting() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        await waitUntil("connected") { rig.store.connection(for: id)?.phase == .connected }
        let runtime = try #require(rig.store.runtime(id))
        let intruder = PtyConnection(sessionID: id, socketPath: runtime.socketPath, directory: runtime.directory)
        intruder.connect()
        await waitUntil("taken over") { rig.store.connection(for: id)?.phase == .ended }
        #expect(rig.store.session(id)?.state == .stopped)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(intruder.phase == .connected)
        intruder.close()
        if let pid = runtime.holderPid { kill(pid, SIGTERM) }
    }
}
