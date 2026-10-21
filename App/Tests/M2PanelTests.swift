import AppKit
import CoddHolderClient
import CoddProtocol
import CoddTerminal
import Darwin
import Foundation
import Testing
@testable import CODD

// M2 I5: the ⌘J panel's tabs, maximize, bells, OSC titles and the running lamp (D11–D13, D25).

@MainActor
private func pause(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

private let uuidA = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
private let uuidB = "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
private let uuidC = "2b3c4d5e-6f7a-4b9c-8d1e-2f3a4b5c6d7e"

// MARK: - Model and panes.json

@MainActor
@Suite("Panel layout (I5, D11–D13)")
struct PanelLayoutTests {
    @Test func panelTabsOpenAddSelectAndRemove() throws {
        let shell = ShellState()
        // ⌘J with no tabs creates `zsh 1`.
        let first = try #require(shell.togglePanel(in: "s"))
        #expect(first.number == 1)
        #expect(shell.label(for: first, inPanel: true) == "zsh 1")
        #expect(shell.pane(for: "s").panelTabs == [first])
        // `+` appends, selects and keeps the panel open.
        let second = shell.addPanelTab(in: "s")
        let third = shell.addPanelTab(in: "s")
        #expect(second.number == 2 && third.number == 3)
        #expect(shell.pane(for: "s").panel == third)
        shell.selectPanelTab(second.id, in: "s")
        #expect(shell.pane(for: "s").panel == second)
        // Closing ⌘J keeps the tabs; reopening shows the same one.
        #expect(shell.togglePanel(in: "s") == nil)
        #expect(shell.pane(for: "s").panelTabs.count == 3)
        #expect(shell.togglePanel(in: "s") == second)
        // Removing the shown tab shows the one before it; a hidden one leaves the selection alone.
        shell.removePanelTab(second.id, in: "s")
        #expect(shell.pane(for: "s").panel == first)
        shell.removePanelTab(third.id, in: "s")
        #expect(shell.pane(for: "s").panel == first)
        // A closed number is not reused while a higher one is open; the strip is untouched.
        let fourth = shell.addPanelTab(in: "s")
        #expect(fourth.number == 2)
        #expect(shell.pane(for: "s").tabs.isEmpty)
        shell.removePanelTab(first.id, in: "s")
        #expect(shell.pane(for: "s").panel == fourth, "the first tab gone: the next one shows")
        // The last one closes the panel; the next ⌘J starts over at `zsh 1`.
        shell.removePanelTab(fourth.id, in: "s")
        #expect(!shell.pane(for: "s").panelOpen && shell.pane(for: "s").panel == nil)
        #expect(shell.togglePanel(in: "s")?.number == 1)
    }

    @Test func maximizeOnlyWhileOpen() throws {
        let shell = ShellState()
        #expect(!shell.toggleMaximize(in: "s"), "no panel: nothing to maximize")
        let tab = try #require(shell.togglePanel(in: "s"))
        #expect(shell.toggleMaximize(in: "s"))
        #expect(shell.pane(for: "s").isPanelMaximized)
        #expect(!shell.toggleMaximize(in: "s"))
        shell.toggleMaximize(in: "s")
        // Closing the panel ends maximize: ⌘J later brings back the split.
        shell.togglePanel(in: "s")
        #expect(!shell.pane(for: "s").panelMaximized)
        shell.togglePanel(in: "s")
        #expect(!shell.pane(for: "s").isPanelMaximized)
        shell.toggleMaximize(in: "s")
        shell.removePanelTab(tab.id, in: "s")
        #expect(!shell.pane(for: "s").panelMaximized && !shell.pane(for: "s").panelOpen)
    }

    @Test func labelsUseOSCTitles() {
        let shell = ShellState()
        let strip1 = ShellTab(id: uuidA, number: 1)
        let strip2 = ShellTab(id: uuidB, number: 2)
        #expect(shell.label(for: strip1, inPanel: false) == "zsh")
        #expect(shell.label(for: strip2, inPanel: false) == "zsh 2")
        #expect(shell.label(for: strip1, inPanel: true) == "zsh 1")
        shell.setTabTitle("npm run dev", for: uuidA)
        #expect(shell.label(for: strip1, inPanel: true) == "npm run dev")
        shell.setTabTitle("   ", for: uuidA)
        #expect(shell.label(for: strip1, inPanel: true) == "zsh 1", "a blank title gives the number back")
    }

    @Test func tabTitleCleaning() {
        #expect(ShellState.tabTitle("npm run dev") == "npm run dev")
        #expect(ShellState.tabTitle("  vim\n main.swift\t ") == "vim main.swift")
        #expect(ShellState.tabTitle("a\u{1B}b\u{7}c\u{9B}d") == "a b c d")
        #expect(ShellState.tabTitle("\u{202E}evil") == "evil")
        #expect(ShellState.tabTitle("\u{0}\u{1}") == nil)
        let long = ShellState.tabTitle("dev@mbp: ~/Project/Northstar/websites")
        #expect(long == "dev@mbp: ~/Project/Nort…")
        #expect(long?.count == ShellState.tabTitleLimit)
        #expect(ShellState.tabTitle("打卡頁 RWD 調整 · 前端 dev server 正在跑") == "打卡頁 RWD 調整 · 前端 dev ser…")
    }

    @Test func bellsTitlesAndLampsGoWithTheirTab() throws {
        let shell = ShellState()
        let panel = try #require(shell.togglePanel(in: "s"))
        let strip = shell.addShellTab(in: "s", kind: .claude)
        shell.setTabTitle("npm run dev", for: panel.id)
        shell.setTabCwd("/tmp", for: panel.id)
        shell.ringBell(BellKey(sessionID: "s", tabID: panel.id))
        shell.ringBell(BellKey(sessionID: "s", tabID: strip.id))
        shell.ringBell(BellKey(sessionID: "s", tabID: nil))
        shell.setRunning([panel.id, strip.id, "s"])
        shell.removePanelTab(panel.id, in: "s")
        #expect(shell.tabTitles[panel.id] == nil && shell.tabCwds[panel.id] == nil)
        #expect(!shell.runningTabs.contains(panel.id))
        #expect(!shell.hasBell(BellKey(sessionID: "s", tabID: panel.id)))
        #expect(shell.hasBell(BellKey(sessionID: "s", tabID: strip.id)))
        shell.clearBell(BellKey(sessionID: "s", tabID: strip.id))
        #expect(!shell.hasBell(BellKey(sessionID: "s", tabID: strip.id)))
        shell.forgetSession("s")
        #expect(shell.bells.isEmpty && shell.runningTabs.isEmpty)
    }

    /// D13: an M1 file has a single `panel`; it becomes the only panel tab, open as it was.
    @Test func m1FileMigratesItsPanel() throws {
        let json = """
        {"version":1,"sessions":{"s":{"tabs":[{"id":"\(uuidA)","number":1}],"selected":"\(uuidA)",
        "panel":{"id":"\(uuidB)","number":1},"panelOpen":true,"panelHeight":300}}}
        """
        let layout = try #require(PaneLayoutStore.decode(Data(json.utf8))?["s"])
        #expect(layout.tabs.map(\.id) == [uuidA])
        #expect(layout.selected == .shell(uuidA))
        #expect(layout.panelTabs == [ShellTab(id: uuidB, number: 1)])
        #expect(layout.panel?.id == uuidB)
        #expect(layout.panelOpen && !layout.panelMaximized)
        #expect(layout.panelHeight == 300)
        #expect(!layout.composerOpen)
    }

    @Test func roundTripKeepsPanelTabsAndWritesPanelForM1() throws {
        let shell = ShellState()
        _ = try #require(shell.togglePanel(in: "s"))
        let second = shell.addPanelTab(in: "s")
        let third = shell.addPanelTab(in: "s")
        shell.selectPanelTab(second.id, in: "s")
        shell.toggleMaximize(in: "s")
        shell.setComposerOpen(true, in: "s")
        shell.setPanelHeight(240, in: "s")
        let data = try #require(PaneLayoutStore.encode(shell.panes))
        let decoded = try #require(PaneLayoutStore.decode(data))
        #expect(decoded == shell.panes)
        #expect(decoded["s"]?.panel == second)
        #expect(decoded["s"]?.isPanelMaximized == true)

        // What an M1 build decodes (its Entry knew only these keys): the shown panel tab as `panel`.
        struct M1File: Decodable {
            struct Entry: Decodable { var tabs: [ShellTab]?; var selected: String?; var panel: ShellTab?; var panelOpen: Bool?; var panelHeight: Double? }
            var version: Int
            var sessions: [String: Entry]
        }
        let m1 = try JSONDecoder().decode(M1File.self, from: data)
        #expect(m1.version == 1)
        #expect(m1.sessions["s"]?.panel == second)
        #expect(m1.sessions["s"]?.panelOpen == true)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((object["sessions"] as? [String: Any])?["s"] as? [String: Any])
        #expect((entry["panelTabs"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == shell.pane(for: "s").panelTabs.map(\.id))
        #expect(entry["panelSelected"] as? String == second.id)
        #expect(entry["panelMaximized"] as? Bool == true)
        #expect(entry["composerOpen"] as? Bool == true)
        _ = third
    }

    @Test func decodingIsTolerantPerField() throws {
        let json = """
        {"version":1,"sessions":{
          "s":{"tabs":[{"id":"\(uuidA)","number":1}],
               "panelTabs":[{"id":"\(uuidA)","number":1},{"id":"../../etc","number":2},{"bogus":true},7,{"id":"\(uuidB)","number":2},{"id":"\(uuidC)","number":3}],
               "panelSelected":"\(uuidC)","panelOpen":"yes","panelMaximized":true,"panelHeight":"tall","composerOpen":true},
          "t":{"panelTabs":[{"id":"\(uuidB)","number":1}],"panelSelected":"gone","panelOpen":true,"panelMaximized":true},
          "u":42}}
        """
        let panes = try #require(PaneLayoutStore.decode(Data(json.utf8)))
        let s = try #require(panes["s"])
        #expect(s.tabs.map(\.id) == [uuidA])
        #expect(s.panelTabs.map(\.id) == [uuidB, uuidC], "a strip tab, a bad id and broken entries are dropped")
        #expect(s.panelSelected == uuidC)
        #expect(!s.panelOpen && !s.panelMaximized, "a wrong-typed panelOpen reads as closed; maximize needs open")
        #expect(s.panelHeight == PaneLayout.defaultPanelHeight)
        #expect(s.composerOpen, "the other fields still load")
        let t = try #require(panes["t"])
        #expect(t.panel?.id == uuidB, "an unknown selection shows the first tab")
        #expect(t.isPanelMaximized)
        #expect(panes["u"] == PaneLayout())
    }

    @Test func storeKeepsPanelTabsAcrossARelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codd-i5-panes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = CoddDataRoot(path: dir.path)
        let first = ShellState()
        let writer = PaneLayoutStore(root: root, shell: first)
        await writer.load()
        _ = first.togglePanel(in: "s1")
        first.addPanelTab(in: "s1")
        first.toggleMaximize(in: "s1")
        writer.flush()
        let reader = ShellState()
        await PaneLayoutStore(root: root, shell: reader).load()
        #expect(reader.panes == first.panes)
        #expect(reader.pane(for: "s1").panelTabs.count == 2 && reader.pane(for: "s1").isPanelMaximized)
    }

    @Test func foregroundJobRule() {
        func status(_ pgid: pid_t, _ tpgid: pid_t) -> ForegroundJob.Status {
            ForegroundJob.Status(pid: 100, parentPid: 99, processGroup: pgid, terminalProcessGroup: tpgid)
        }
        #expect(!ForegroundJob.isRunning(status(100, 100)), "at its prompt: the shell's own group is in front")
        #expect(ForegroundJob.isRunning(status(100, 230)), "a job's group is in front")
        #expect(!ForegroundJob.isRunning(status(100, 0)))
        #expect(!ForegroundJob.isRunning(status(100, -1)), "no controlling terminal")
        #expect(ForegroundJob.status(of: -5) == nil)
        let me = ForegroundJob.status(of: getpid())
        #expect(me?.pid == getpid() && me?.parentPid == getppid())
        #expect(!ForegroundJob.isRunning(childPid: getpid(), holderPid: 1), "not that holder's child")
    }
}

// MARK: - Pane (mock mode)

@MainActor
private final class PanelPaneHarness {
    let store = MockSessionStore(shiftClock: false)
    let shell = ShellState()
    let pane: SessionPaneViewController
    let window: NSWindow

    init(current: SessionID = "s9") {
        shell.currentSessionID = current
        pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell,
                                         surfaceFactory: FakeTerminalSurfaceFactory { _ in "<d>></d> mock" })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.layoutIfNeeded()
    }

    deinit { MainActor.assumeIsolated { window.close() } }
}

@MainActor
@Suite("Panel pane (I5)", .serialized)
struct PanelPaneTests {
    @Test func panelTabsCloseOneAtATimeWithCommandW() async throws {
        let h = PanelPaneHarness()
        await pause()
        h.pane.toggleBottomTerminal()
        h.pane.newPanelTab()
        let layout = h.shell.pane(for: "s9")
        #expect(layout.panelTabs.count == 2 && layout.panel?.number == 2)
        await pause()
        #expect(h.pane.panelStrip.tabButtons.map(\.label) == ["zsh 1", "zsh 2"])
        #expect(h.pane.panelStrip.tabButtons.map(\.isOn) == [false, true])
        #expect(h.pane.panelSurface.hasFocus)
        // ⌘T adds to the panel too (the user's note 2026-10-19: every extra terminal opens there).
        h.pane.newShellTab()
        #expect(h.shell.pane(for: "s9").tabs.isEmpty && h.shell.pane(for: "s9").panelTabs.count == 3)
        // ⌘W with the panel focused closes its shown tab only.
        h.pane.panelSurface.focus()
        #expect(h.pane.handleCloseCommand())
        #expect(h.shell.pane(for: "s9").panelTabs.map(\.number) == [1, 2])
        #expect(h.shell.pane(for: "s9").panelOpen && h.pane.panelSurface.hasFocus)
        #expect(h.pane.handleCloseCommand())
        #expect(h.pane.handleCloseCommand())
        #expect(!h.shell.pane(for: "s9").panelOpen && h.shell.pane(for: "s9").panelTabs.isEmpty)
        // An older layout's strip shell tab is next (its terminal has the keyboard again).
        h.shell.addShellTab(in: "s9", kind: .claude)
        #expect(h.pane.handleCloseCommand())
        #expect(h.shell.pane(for: "s9").tabs.isEmpty)
    }

    @Test func maximizeHidesTheTopTerminalAndTheComposer() async throws {
        let h = PanelPaneHarness()
        await pause()
        h.pane.toggleComposer()
        #expect(h.pane.isComposerShown)
        h.pane.toggleBottomTerminal()
        h.pane.toggleMaximizePanel()
        await pause()
        #expect(h.pane.isPanelMaximized && h.shell.pane(for: "s9").isPanelMaximized)
        #expect(!h.pane.isComposerShown, "suppressed while maximized")
        #expect(h.shell.pane(for: "s9").composerOpen, "but still open for the session")
        #expect(h.pane.panelStrip.isMaximized)
        #expect(h.pane.panelStrip.maximizeButton.accessibilityLabel() == PanelStripView.restoreLabel)
        #expect(h.pane.surface.view.isHidden && h.pane.panelSurface.hasFocus)
        #expect(!h.pane.composer.bar.hasFocus)
        // Restore gives everything back.
        h.pane.toggleMaximizePanel()
        await pause()
        #expect(!h.pane.isPanelMaximized && h.pane.isComposerShown && !h.pane.surface.view.isHidden)
        #expect(h.pane.panelStrip.maximizeButton.accessibilityLabel() == PanelStripView.maximizeLabel)
        // ⌘L while maximized restores and focuses the composer; a strip tab click restores too.
        h.pane.toggleMaximizePanel()
        h.pane.toggleComposer()
        #expect(!h.pane.isPanelMaximized && h.pane.composer.bar.hasFocus)
        h.pane.toggleMaximizePanel()
        h.pane.sessionTabStrip.tabButtons[0].performClick(nil)
        #expect(!h.shell.pane(for: "s9").isPanelMaximized)
        // ⌘W with a maximized panel closes its tab; the last one gives the split back.
        h.pane.toggleMaximizePanel()
        #expect(h.pane.handleCloseCommand())
        await pause()
        #expect(!h.shell.pane(for: "s9").panelOpen && !h.pane.isPanelMaximized && !h.pane.surface.view.isHidden)
    }

    /// The strip's own buttons (target / action wiring): `+`, a tab, maximize, `✕ ⌘J`.
    @Test func panelStripButtonsDriveThePanel() async throws {
        let h = PanelPaneHarness()
        await pause()
        h.pane.toggleBottomTerminal()
        await pause()
        let strip = h.pane.panelStrip
        #expect(strip.addTab.accessibilityLabel() == "新增終端機")
        #expect(strip.closeButton.accessibilityLabel() == "關閉下方終端機 ⌘J" && strip.closeButton.label == "✕ ⌘J")
        strip.addTab.performClick(nil)
        await pause()
        #expect(h.shell.pane(for: "s9").panelTabs.count == 2)
        strip.tabButtons[0].performClick(nil)
        #expect(h.shell.pane(for: "s9").panel?.number == 1)
        strip.maximizeButton.performClick(nil)
        #expect(h.shell.pane(for: "s9").isPanelMaximized)
        strip.maximizeButton.performClick(nil)
        #expect(!h.shell.pane(for: "s9").isPanelMaximized)
        strip.closeButton.performClick(nil)
        #expect(!h.shell.pane(for: "s9").panelOpen && h.shell.pane(for: "s9").panelTabs.count == 2, "hidden, shells kept")
    }

    @Test func stripsDrawTitlesLampsAndBells() async throws {
        let h = PanelPaneHarness()
        await pause()
        h.pane.toggleBottomTerminal()
        let first = try #require(h.shell.pane(for: "s9").panel)
        h.pane.newPanelTab()
        let panelTabs = h.shell.pane(for: "s9").panelTabs
        let strip = h.shell.addShellTab(in: "s9", kind: .claude)
        h.shell.select(.claude, in: "s9")
        h.shell.setTabTitle("npm run dev", for: panelTabs[1].id)
        h.shell.setRunning([panelTabs[1].id, strip.id])
        h.shell.ringBell(BellKey(sessionID: "s9", tabID: first.id))
        h.shell.ringBell(BellKey(sessionID: "s9", tabID: strip.id))
        h.shell.setTabCwd(NSHomeDirectory() + "/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend", for: panelTabs[1].id)
        await pause()
        let panel = h.pane.panelStrip
        #expect(panel.tabButtons.map(\.label) == ["zsh 1", "npm run dev"])
        #expect(panel.tabButtons.map(\.tabMarks) == [[.bell], [.running]])
        #expect(panel.tabButtons[1].accessibilityLabel() == "npm run dev，執行中")
        #expect(panel.cwdText == "~/…/orb-toolkit-suite/orb-toolkit-frontend", "Split artboard `.ell`")
        let main = h.pane.sessionTabStrip.tabButtons
        #expect(main.map(\.label) == ["Claude", "zsh"])
        #expect(main[1].tabMarks == [.running, .bell])
        #expect(main[0].tabMarks.isEmpty)
        // The dump reads the same.
        let dump = try #require(h.pane.paneDump(holderPid: { _ in nil }))
        #expect(dump["session"] as? String == "s9")
        let tabs = try #require(dump["tabs"] as? [[String: Any]])
        #expect(tabs.map { $0["id"] as? String } == ["main", strip.id])
        #expect(tabs[1]["running"] as? Bool == true && tabs[1]["bell"] as? Bool == true)
        #expect(tabs[0]["selected"] as? Bool == true)
        let rows = try #require(dump["panelTabs"] as? [[String: Any]])
        #expect(rows.map { $0["label"] as? String } == ["zsh 1", "npm run dev"])
        #expect(rows.map { $0["bell"] as? Bool } == [true, false])
        #expect(dump["panelSelected"] as? String == panelTabs[1].id)
        #expect(dump["panelOpen"] as? Bool == true && dump["panelMaximized"] as? Bool == false)
        #expect(dump["composerOpen"] as? Bool == false)
        // A new title relabels the same button (a click in progress survives).
        let button = panel.tabButtons[1]
        let stripButton = main[1]
        h.shell.setTabTitle("vite build --watch", for: panelTabs[1].id)
        h.shell.setTabTitle("tail -f log", for: strip.id)
        await pause()
        #expect(panel.tabButtons[1] === button && button.label == "vite build --watch")
        #expect(h.pane.sessionTabStrip.tabButtons[1] === stripButton && stripButton.label == "tail -f log")
        // Clicking a panel tab shows it.
        h.pane.selectPanelTab(first.id)
        #expect(h.shell.pane(for: "s9").panel == first)
    }
}

// MARK: - Real holders

/// Real holders (the copy in CODD.app) in a temp data root, streamed into libghostty terminals in a
/// window that is never ordered on screen. Children are `/bin/sh`, `cat` and `zsh -f`; never
/// `claude`, never the user's rc files.
@MainActor
@Suite("Panel terminals (I5)", .serialized)
final class PanelTerminalTests {
    private let rootPath: String
    private let window: NSWindow
    private let container: NSView

    private static let echoArgv = ["/bin/sh", "-c", "printf 'hello-from-holder\\n'; exec /bin/cat"]

    init() throws {
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/codd-p.XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        rootPath = CoddDataRoot(path: String(cString: created)).path
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = container
    }

    deinit {
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

    /// `panes` are in place before discovery, as `PaneLayoutStore.load` runs before it in the app.
    private func makeRig(argv: [String] = PanelTerminalTests.echoArgv, panes: [SessionID: PaneLayout] = [:]) async throws -> Rig {
        let root = CoddDataRoot(path: rootPath)
        let executable = try #require(HolderBinary.install(root: root) { _ in }, "CODD.app/Contents/MacOS/codd-holder is missing")
        let launcher = HolderLauncher(holderExecutable: executable, root: root, shellArgvOverride: argv)
        let logs = Recorder<String>()
        let store = HolderSessionStore(root: root, launcher: launcher) { logs.append($0) }
        let shell = ShellState()
        shell.panes = panes
        let hub = TerminalHub(store: store, shell: shell, probeWindow: .milliseconds(100)) { logs.append($0) }
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
    }

    private func occurrences(_ needle: String, in text: String?) -> Int {
        (text ?? "").components(separatedBy: needle).count - 1
    }

    private func tabMeta(_ rig: Rig, _ session: SessionID, _ tab: String) -> HolderMeta? {
        SessionDirectory.readMeta(directory: rig.store.root.sessionDirectory(session) + "/tabs/" + tab)
    }

    @Test func twoPanelTabsAreTwoHoldersAndCloseOneAtATime() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        let first = try #require(rig.shell.togglePanel(in: id))
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(first.id)))
        await waitUntil("first panel tab streams") { rig.hub.isStreaming(.panel) }
        let second = rig.shell.addPanelTab(in: id)
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(second.id)))
        await waitUntil("second panel tab streams") { rig.hub.isStreaming(.panel) }
        await waitUntil("both meta.json") { self.tabMeta(rig, id, first.id) != nil && self.tabMeta(rig, id, second.id) != nil }
        let metaA = try #require(tabMeta(rig, id, first.id))
        let metaB = try #require(tabMeta(rig, id, second.id))
        #expect(metaA.holderPid != metaB.holderPid)
        #expect(SessionDirectory.isHolderProcess(metaA.holderPid) && SessionDirectory.isHolderProcess(metaB.holderPid))
        #expect(rig.hub.tier(of: TerminalTarget(sessionID: id, tab: .shell(first.id))) == .hot, "the hidden panel tab stays hot")
        #expect(rig.shell.pane(for: id).tabs.isEmpty)
        // Tabs are never sessions of their own.
        #expect(try SessionDirectory.list(root: rig.store.root.sessionsPath).map(\.meta.session) == [id])

        // Closing the shown tab ends only its holder; the panel shows the other one.
        rig.shell.removePanelTab(second.id, in: id)
        rig.hub.closeShellTab(sessionID: id, tabID: second.id)
        await waitUntil("second holder gone") { !SessionDirectory.isHolderProcess(metaB.holderPid) }
        #expect(SessionDirectory.isHolderProcess(metaA.holderPid))
        #expect(rig.shell.pane(for: id).panel == first && rig.shell.pane(for: id).panelOpen)

        // A shell that exits by itself removes only its tab: the last one closes the panel.
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(first.id)))
        await waitUntil("first streams again") { rig.hub.isStreaming(.panel) }
        rig.panel.send(.text("\u{04}", submit: false))
        await waitUntil("panel closed") { rig.shell.pane(for: id).panelTabs.isEmpty }
        #expect(!rig.shell.pane(for: id).panelOpen)
        await waitUntil("first holder gone") { !SessionDirectory.isHolderProcess(metaA.holderPid) }
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    /// Relaunch: panes.json says both tabs are the panel's; discovery finds their holders and
    /// keeps them there (never adopted into the strip), and showing one reattaches to the same holder.
    @Test func discoveryAfterARelaunchKeepsPanelTabsInThePanel() async throws {
        let first = try await makeRig()
        let id = try #require(first.store.spawnShell(in: "/tmp"))
        first.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        let a = try #require(first.shell.togglePanel(in: id))
        first.panel.attach(TerminalTarget(sessionID: id, tab: .shell(a.id)))
        await waitUntil("a streams") { first.hub.isStreaming(.panel) }
        let b = first.shell.addPanelTab(in: id)
        first.panel.attach(TerminalTarget(sessionID: id, tab: .shell(b.id)))
        await waitUntil("b streams") { first.hub.isStreaming(.panel) }
        first.panel.send(.text("before-relaunch-b", submit: true))
        await waitUntil("b echo") { self.occurrences("before-relaunch-b", in: first.hub.viewportText(.panel)) >= 2 }
        first.shell.toggleMaximize(in: id)
        let layout = first.shell.pane(for: id)
        let pidA = try #require(first.hub.tabHolderPid(a.id))
        let pidB = try #require(first.hub.tabHolderPid(b.id))
        // Through the file, as the app does it.
        let data = try #require(PaneLayoutStore.encode(first.shell.panes))
        tearDown(first)
        first.main.view.removeFromSuperview()
        first.panel.view.removeFromSuperview()

        let second = try await makeRig(panes: try #require(PaneLayoutStore.decode(data)))
        defer { tearDown(second) }
        #expect(second.logs.values.contains("discovered tabs=2 live=2"))
        let restored = second.shell.pane(for: id)
        #expect(restored.tabs.isEmpty, "panel tabs are never adopted into the strip")
        #expect(restored.panelTabs == layout.panelTabs)
        #expect(restored.panel == b && restored.isPanelMaximized)
        #expect(second.hub.tabHolderPid(a.id) == pidA && second.hub.tabHolderPid(b.id) == pidB)
        second.panel.attach(TerminalTarget(sessionID: id, tab: .shell(b.id)))
        await waitUntil("b replays") {
            second.hub.isStreaming(.panel) && self.occurrences("before-relaunch-b", in: second.hub.viewportText(.panel)) >= 2
        }
        #expect(second.hub.tabHolderPid(b.id) == pidB)
        #expect(!second.logs.values.contains { $0.hasPrefix("spawned tab=") })
        second.store.stop([id])
        await waitUntil("exit") { second.store.session(id)?.state == .exited }
    }

    @Test func maximizeOccludesTheTopSurfaceAndKeepsItHot() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let area = TerminalAreaView(top: TerminalHostView(surface: rig.main), panelHost: TerminalHostView(surface: rig.panel))
        area.frame = container.bounds
        container.addSubview(area)
        defer { area.removeFromSuperview() }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let top = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(top)
        await waitUntil("session streams") { rig.hub.isStreaming(.main) }
        let tab = try #require(rig.shell.togglePanel(in: id))
        area.setPanel(open: true, height: 200)
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        await waitUntil("panel streams") { rig.hub.isStreaming(.panel) }
        #expect(rig.hub.tier(of: top) == .visible)

        area.setPanel(open: true, height: 200, maximized: true)
        #expect(area.isPanelMaximized && area.top.isHidden && area.splitter.isHidden)
        #expect(area.panel.frame == area.bounds)
        #expect(rig.hub.tier(of: top) == .hot, "occluded, not cold")
        #expect(!rig.hub.isOnScreen(TerminalKey(top)))
        // It keeps streaming while hidden.
        rig.store.connection(for: id)?.send(Array("while-maximized".utf8), submit: true)
        try? await Task.sleep(for: .milliseconds(300))
        area.setPanel(open: true, height: 200, maximized: false)
        #expect(!area.top.isHidden && rig.hub.tier(of: top) == .visible)
        #expect(area.panel.frame.height == 200)
        await waitUntil("output kept") { self.occurrences("while-maximized", in: rig.hub.viewportText(.main)) >= 2 }
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    @Test func bellMarksTabsThatAreNotOnScreenAndShowingClearsIt() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let own = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(own)
        await waitUntil("session streams") { rig.hub.isStreaming(.main) }
        let tab = rig.shell.addShellTab(in: id, kind: .shell)
        let tabTarget = TerminalTarget(sessionID: id, tab: .shell(tab.id))
        rig.main.attach(tabTarget)
        await waitUntil("tab streams") { rig.hub.isStreaming(.main) }
        let ownBell = BellKey(sessionID: id, tabID: nil)
        let tabBell = BellKey(sessionID: id, tabID: tab.id)

        // The session's own PTY is hidden behind the tab: its BEL (cat prints it back) marks it.
        rig.hub.send(.text("\u{07}", submit: true), to: own)
        await waitUntil("own bell marked") { rig.shell.hasBell(ownBell) }
        // The tab on screen rings: nothing to mark.
        rig.main.send(.text("\u{07}", submit: true))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!rig.shell.hasBell(tabBell))
        // Showing the session clears its mark; now the hidden tab rings.
        rig.main.attach(own)
        #expect(!rig.shell.hasBell(ownBell))
        rig.hub.send(.text("\u{07}", submit: true), to: tabTarget)
        await waitUntil("tab bell marked") { rig.shell.hasBell(tabBell) }
        // A closed window shows nothing: even the shown PTY's bell is kept until it is back.
        rig.hub.setWindowOccluded(true)
        rig.hub.send(.text("\u{07}", submit: true), to: own)
        await waitUntil("bell while the window is away") { rig.shell.hasBell(ownBell) }
        rig.hub.setWindowOccluded(false)
        #expect(!rig.shell.hasBell(ownBell))
        #expect(rig.shell.hasBell(tabBell))
        rig.main.attach(tabTarget)
        #expect(!rig.shell.hasBell(tabBell))
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    @Test func oscTitleBecomesTheTabLabel() async throws {
        let rig = try await makeRig(argv: ["/bin/sh", "-c", "printf '\\033]0;npm run dev\\007'; exec /bin/cat"])
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        let panelTab = try #require(rig.shell.togglePanel(in: id))
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(panelTab.id)))
        await waitUntil("panel title") { rig.shell.tabTitles[panelTab.id] == "npm run dev" }
        #expect(rig.shell.label(for: panelTab, inPanel: true) == "npm run dev")
        // A later title replaces it, cleaned and capped (cat prints the OSC back).
        rig.panel.send(.text("\u{1B}]0;watch  the build of orb-toolkit-frontend\u{07}", submit: true))
        await waitUntil("new title") { rig.shell.tabTitles[panelTab.id]?.hasPrefix("watch the build") == true }
        #expect(rig.shell.label(for: panelTab, inPanel: true) == "watch the build of orb-…")
        // The strip's shell tabs too; the session's own PTY title stays the row title.
        let stripTab = rig.shell.addShellTab(in: id, kind: .shell)
        rig.main.attach(TerminalTarget(sessionID: id, tab: .shell(stripTab.id)))
        await waitUntil("strip title") { rig.shell.label(for: stripTab, inPanel: false) == "npm run dev" }
        #expect(rig.store.session(id)?.title == "npm run dev")
        #expect(rig.shell.tabTitles[id] == nil)
        // A closed tab forgets its title.
        rig.shell.removePanelTab(panelTab.id, in: id)
        rig.hub.closeShellTab(sessionID: id, tabID: panelTab.id)
        #expect(rig.shell.tabTitles[panelTab.id] == nil)
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    /// D25 with a real interactive shell: `sleep 3` runs in its own process group in front of the
    /// terminal, so the lamp is on; back at the prompt it is off. Panel tab and SHELL session.
    @Test func runningLampFollowsForegroundJobs() async throws {
        let rig = try await makeRig(argv: ["/bin/zsh", "-f", "-i"])
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        rig.shell.currentSessionID = id  // the lamps of the shown session are polled
        rig.main.attach(TerminalTarget(sessionID: id, tab: .claude))
        await waitUntil("session streams") { rig.hub.isStreaming(.main) }
        let tab = try #require(rig.shell.togglePanel(in: id))
        rig.panel.attach(TerminalTarget(sessionID: id, tab: .shell(tab.id)))
        await waitUntil("panel streams") { rig.hub.isStreaming(.panel) }
        await waitUntil("poll running") { rig.hub.isRunningPollActive }
        try? await Task.sleep(for: .milliseconds(500))  // the prompt
        rig.hub.pollRunning()
        #expect(rig.shell.runningTabs.isEmpty, "both shells sit at their prompt")

        rig.panel.send(.text("sleep 3", submit: true))
        await waitUntil("panel lamp on", timeout: .seconds(3)) {
            rig.hub.pollRunning()
            return rig.shell.runningTabs.contains(tab.id)
        }
        #expect(!rig.shell.runningTabs.contains(id))
        let polled = try #require(rig.hub.lastRunningPoll)
        #expect(polled.shells == 2)
        // Review concurrency-perf-6: another session shown, these shells are not read.
        rig.shell.currentSessionID = "another-session"
        rig.hub.pollRunning()
        #expect(rig.hub.lastRunningPoll?.shells == 0)
        #expect(rig.shell.runningTabs.isEmpty)
        rig.shell.currentSessionID = id
        await waitUntil("panel lamp off", timeout: .seconds(8)) {
            rig.hub.pollRunning()
            return !rig.shell.runningTabs.contains(tab.id)
        }

        // The SHELL session's own PTY.
        rig.main.send(.text("sleep 3", submit: true))
        await waitUntil("session lamp on", timeout: .seconds(3)) {
            rig.hub.pollRunning()
            return rig.shell.runningTabs.contains(id)
        }
        // The 1 Hz timer alone also sees it go off.
        await waitUntil("session lamp off by the timer", timeout: .seconds(8)) { !rig.shell.runningTabs.contains(id) }

        // The shell's own status: a child of its holder, in front of its own terminal.
        let pid = try #require(rig.store.connection(for: id)?.welcome?.childPid)
        let status = try #require(ForegroundJob.status(of: pid))
        #expect(status.parentPid == rig.store.runtime(id)?.holderPid)
        #expect(status.processGroup == pid && status.terminalProcessGroup == pid)

        // Cost of one shell's check (MEASURE).
        let rounds = 2000
        let start = ContinuousClock.now
        for _ in 0..<rounds { _ = ForegroundJob.isRunning(childPid: pid, holderPid: status.parentPid) }
        let perShell = TerminalHub.milliseconds(ContinuousClock.now - start) * 1000 / Double(rounds)
        rig.hub.pollRunning()
        let poll = try #require(rig.hub.lastRunningPoll)
        print(String(format: "MEASURE running lamp: %.2f µs per shell (sysctl KERN_PROC_PID), poll of %d shells %.2f µs",
                     perShell, poll.shells, TerminalHub.milliseconds(poll.duration) * 1000))
        #expect(perShell < 200)

        // No timer while the window is away.
        rig.hub.setWindowOccluded(true)
        #expect(!rig.hub.isRunningPollActive)
        rig.hub.setWindowOccluded(false)
        #expect(rig.hub.isRunningPollActive)
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }
}

// MARK: - M2 review round 1

/// Review concurrency-perf-4: a shell tab's OSC title change invalidates only what reads that
/// tab's label (the pane of its session), not every pane render.
@MainActor
@Suite("M2 review fixes: tab title observation")
struct TabTitleObservationTests {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    @Test func aTitleChangeInvalidatesOnlyReadersOfThatTab() {
        let shell = ShellState()
        let shown = ShellTab(id: "tab-shown", number: 1)
        let other = ShellTab(id: "tab-other", number: 2)
        let flag = Flag()
        withObservationTracking {
            _ = shell.label(for: shown, inPanel: true)
            _ = shell.tabCwd(shown.id)
        } onChange: {
            flag.fired = true
        }
        shell.setTabTitle("⠋ claude spinner", for: other.id)
        shell.setTabCwd("/tmp", for: other.id)
        #expect(!flag.fired, "another tab's title does not re-render the shown pane")
        shell.setTabTitle("npm run dev", for: shown.id)
        #expect(flag.fired)
        #expect(shell.label(for: shown, inPanel: true) == "npm run dev")
        #expect(shell.label(for: other, inPanel: false) == "⠋ claude spinner")
        #expect(shell.tabTitles == ["tab-shown": "npm run dev", "tab-other": "⠋ claude spinner"])
        #expect(shell.tabCwds == ["tab-other": "/tmp"])
        shell.forgetTab(other.id)
        #expect(shell.tabTitles["tab-other"] == nil && shell.tabCwds.isEmpty)
        #expect(shell.label(for: other, inPanel: false) == "zsh 2")
    }
}
