import AppKit
import CoddTerminal
import Foundation
import Testing
@testable import CODD

@MainActor
@Suite("Pane tabs and panel")
struct PaneLayoutTests {
    @Test func claudeSessionsOfferAPendingZshTab() {
        let shell = ShellState()
        #expect(shell.tabItems(for: "s1", kind: .claude) == [.main, .pendingShell])
        #expect(shell.tabItems(for: "x", kind: .shell) == [.main])
        #expect(shell.tab(for: "s1") == .claude)

        let tab = shell.selectFirstShellTab(in: "s1", kind: .claude)
        #expect(tab.number == 1)
        #expect(shell.tabItems(for: "s1", kind: .claude) == [.main, .shell(tab)])
        #expect(shell.tab(for: "s1") == .shell(tab.id))
        // Opening it again selects the same tab instead of creating one.
        shell.select(.claude, in: "s1")
        #expect(shell.selectFirstShellTab(in: "s1", kind: .claude) == tab)
        #expect(TerminalHub.isValidTabID(tab.id))
    }

    @Test func newTabsNumberUpAndClosingFallsBack() {
        let shell = ShellState()
        let first = shell.addShellTab(in: "s1", kind: .claude)
        let second = shell.addShellTab(in: "s1", kind: .claude)
        #expect(first.number == 1 && second.number == 2)
        #expect(shell.tab(for: "s1") == .shell(second.id))
        shell.removeShellTab(second.id, in: "s1")
        #expect(shell.tab(for: "s1") == .shell(first.id))
        shell.removeShellTab(first.id, in: "s1")
        #expect(shell.tab(for: "s1") == .claude)
        #expect(shell.tabItems(for: "s1", kind: .claude) == [.main, .pendingShell])
        // A SHELL session is `zsh` itself: its first extra tab is `zsh 2`.
        #expect(shell.addShellTab(in: "sh", kind: .shell).number == 2)
        #expect(TabStripView.label(.shell(ShellTab(id: "a", number: 2)), isShellSession: true) == "zsh 2")
        #expect(TabStripView.label(.main, isShellSession: true) == "zsh")
    }

    @Test func selectionOfAMissingTabFallsBackToTheSession() {
        var layout = PaneLayout()
        layout.selected = .shell("gone")
        #expect(layout.effectiveSelection == .claude)
    }

    @Test func panelTogglesKeepsItsShellAndCloses() {
        let shell = ShellState()
        let panel = shell.togglePanel(in: "s1")
        #expect(panel != nil)
        #expect(shell.pane(for: "s1").panelOpen)
        #expect(shell.togglePanel(in: "s1") == nil)
        #expect(shell.pane(for: "s1").panel == panel)
        #expect(shell.togglePanel(in: "s1") == panel)
        shell.setPanelHeight(320, in: "s1")
        #expect(shell.pane(for: "s1").panelHeight == 320)
        shell.removePanel(in: "s1")
        #expect(shell.pane(for: "s1").panel == nil)
        #expect(!shell.pane(for: "s1").panelOpen)
    }

    @Test func layoutsRoundTripThroughTheFileFormat() throws {
        let shell = ShellState()
        let tab = shell.addShellTab(in: "a", kind: .claude)
        let panel = try #require(shell.togglePanel(in: "a"))
        shell.setPanelHeight(333, in: "a")
        shell.select(.shell(tab.id), in: "a")
        let data = try #require(PaneLayoutStore.encode(shell.panes))
        let decoded = try #require(PaneLayoutStore.decode(data))
        #expect(decoded == shell.panes)
        #expect(decoded["a"]?.panel == panel)
        // Untouched layouts are not written.
        #expect(PaneLayoutStore.encode(["b": PaneLayout()]).flatMap(PaneLayoutStore.decode)?.isEmpty == true)
    }

    @Test func decodingDropsBadTabIDsAndReadsNewerVersions() throws {
        let json = """
        {"version":1,"sessions":{"s":{"tabs":[{"id":"../../etc","number":1},{"id":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0","number":2}],
        "selected":"../../etc","panel":{"id":"NOT-A-UUID","number":1},"panelOpen":true,"panelHeight":-5}}}
        """
        let layout = try #require(PaneLayoutStore.decode(Data(json.utf8))?["s"])
        #expect(layout.tabs.map(\.id) == ["0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"])
        #expect(layout.selected == .claude)
        #expect(layout.panel == nil && !layout.panelOpen)
        #expect(layout.panelHeight == PaneLayout.defaultPanelHeight)
        // M5 D14: a newer version's file is read as far as it decodes (and never saved over).
        #expect(PaneLayoutStore.decode(Data(#"{"version":2,"sessions":{}}"#.utf8))?.isEmpty == true)
        #expect(PaneLayoutStore.decodeFile(Data(#"{"version":2,"sessions":{}}"#.utf8))?.version == 2)
        #expect(PaneLayoutStore.decode(Data("not json".utf8)) == nil)
    }

    @Test func storeSavesAndLoadsInATempRoot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codd-panes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = CoddDataRoot(path: dir.path)
        let first = ShellState()
        let writer = PaneLayoutStore(root: root, shell: first)
        await writer.load()
        first.addShellTab(in: "s1", kind: .claude)
        _ = first.togglePanel(in: "s1")
        writer.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: writer.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let second = ShellState()
        let reader = PaneLayoutStore(root: root, shell: second)
        await reader.load()
        #expect(second.panes == first.panes)
        reader.prune(keeping: [])
        #expect(second.panes.isEmpty)
    }
}

@MainActor
@Suite("Terminal setup")
struct TerminalSetupTests {
    @Test func libghosttyAcceptsTheConfiguration() {
        #expect(TerminalRuntime.diagnostics(for: CoddTerminalSetup.configuration).isEmpty)
        let rendered = CoddTerminalSetup.configuration.renderedGhosttyConfig
        #expect(rendered.contains("keybind = ctrl+tab=unbind"))
        #expect(rendered.contains("cursor-style-blink = false"))
    }

    @Test func appShortcutsAreLeftToTheMenu() {
        let policy = CoddTerminalSetup.keyEquivalents
        #expect(policy.isReserved(characters: "\t", keyCode: 0x30, modifiers: .control))
        #expect(policy.isReserved(characters: "\u{19}", keyCode: 0x30, modifiers: [.control, .shift]))
        #expect(policy.isReserved(characters: "\r", keyCode: 0x24, modifiers: .command))
        #expect(policy.isReserved(characters: "j", keyCode: 0x26, modifiers: .command))
        #expect(policy.isReserved(characters: "t", keyCode: 0x11, modifiers: .command))
        #expect(policy.isReserved(characters: "w", keyCode: 0x0D, modifiers: .command))
        #expect(!policy.isReserved(characters: "c", keyCode: 0x08, modifiers: .command))
        #expect(!policy.isReserved(characters: "\t", keyCode: 0x30, modifiers: []))
        #expect(!policy.isReserved(characters: "\r", keyCode: 0x24, modifiers: []))
    }

    @Test func answerKeysBecomePtyBytes() {
        #expect(TerminalInput.key("1").bytes == [0x31])
        #expect(TerminalInput.key("esc").bytes == [0x1B])
        #expect(TerminalInput.key("enter").bytes == [0x0D])
        #expect(TerminalInput.text("ls", submit: true).bytes == Array("ls".utf8))
        #expect(TerminalInput.text("ls", submit: true).submits)
        #expect(!TerminalInput.key("1").submits)
    }
}

@Suite("Shell environment")
struct ShellEnvironmentTests {
    @Test func loginEnvironmentLosesForeignVariables() {
        let login = ["PATH": "/opt/x/bin:/usr/bin", "FOO": "bar", "PWD": "/somewhere", "DYLD_INSERT_LIBRARIES": "x",
                     "CLAUDECODE": "1", "TERM_PROGRAM": "iTerm.app", "__CFBundleIdentifier": "x", "LC_ALL": "C",
                     "GHOSTTY_RESOURCES_DIR": "/x", "CODD_HOOK_TOKEN": "t", "NODE_EXTRA_CA_CERTS": "/ca.pem", "bad-name": "x"]
        let clean = ShellEnvironment.sanitized(login: login)
        #expect(clean["FOO"] == "bar")
        #expect(clean["NODE_EXTRA_CA_CERTS"] == "/ca.pem")
        for name in ["PWD", "DYLD_INSERT_LIBRARIES", "CLAUDECODE", "TERM_PROGRAM", "__CFBundleIdentifier", "LC_ALL",
                     "GHOSTTY_RESOURCES_DIR", "CODD_HOOK_TOKEN", "bad-name"] {
            #expect(clean[name] == nil, "\(name)")
        }
        #expect(ShellEnvironment.sanitized(login: ["LC_ALL": "zh_TW.UTF-8"])["LC_ALL"] == "zh_TW.UTF-8")
    }

    @Test func childEnvironmentHasTheTerminalVariables() {
        let id = UUID()
        let env = ShellEnvironment.build(base: ["HOME": "/Users/t", "SHELL": "/bin/zsh", "LANG": "C"],
                                         login: ["PATH": "/opt/x/bin:/usr/bin", "FOO": "bar", "LANG": "zh_TW.UTF-8"],
                                         sessionID: id)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(env["TERM_PROGRAM_VERSION"] == TerminalRuntime.libghosttyVersion)
        #expect(env["PATH"] == "/opt/x/bin:/usr/bin")
        #expect(env["FOO"] == "bar")
        #expect(env["LANG"] == "zh_TW.UTF-8")
        #expect(env["LC_CTYPE"] == "zh_TW.UTF-8")
        #expect(env["CODD_SESSION_ID"] == id.uuidString.lowercased())
        // Without a captured environment: defaults, UTF-8 forced.
        let bare = ShellEnvironment.build(base: ["HOME": "/Users/t", "LANG": "C"], login: nil, sessionID: id)
        #expect(bare["LANG"]?.hasSuffix("UTF-8") == true)
        #expect(bare["PATH"]?.contains("/usr/bin") == true)
    }
}

@Suite("Real mode options (terminal)")
struct RealModeTerminalOptionsTests {
    private func parse(_ args: [String]) -> RealModeOptions {
        RealModeOptions.parse(arguments: ["CODD"] + args, environment: [:], home: "/Users/t")
    }

    @Test func debugTerminalFlags() {
        let options = parse(["-codd-dump-terminal", "~/d.txt", "-codd-send-input", "echo hi", "-codd-send-panel-input", "pwd",
                             "-codd-open-zsh-tab", "YES", "-codd-open-panel", "-codd-spawn-count", "4", "-codd-login-env", "NO"])
        #expect(options.dumpTerminalPath == "/Users/t/d.txt")
        #expect(options.sendInput == "echo hi")
        #expect(options.sendPanelInput == "pwd")
        #expect(options.openZshTab && options.openPanel)
        #expect(options.spawnCount == 4)
        #expect(!options.captureLoginEnvironment)
        #expect(parse([]).captureLoginEnvironment)
        #expect(parse(["-codd-spawn-count", "999"]).spawnCount == 32)
    }
}

@MainActor
@Suite("Terminal deck")
struct TerminalDeckTests {
    @Test func showsOneViewAndMovesFocusAlong() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let deck = TerminalDeckView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = deck
        let a = FocusableView(), b = FocusableView()
        deck.show(a)
        #expect(a.frame == deck.bounds && !a.isHidden)
        window.makeFirstResponder(a)
        deck.show(b)
        #expect(a.isHidden && !b.isHidden)
        #expect(window.firstResponder === b)
        deck.showNothing()
        #expect(b.isHidden)
        #expect(window.firstResponder !== b)
        #expect(deck.subviews.count == 2) // hot views stay in the window

        // Collapsing to nothing leaves the terminals' frames alone.
        deck.frame = NSRect(x: 0, y: 0, width: 10, height: 0)
        deck.layoutSubtreeIfNeeded()
        #expect(a.frame.width == 400)
        deck.frame = NSRect(x: 0, y: 0, width: 500, height: 320)
        deck.layoutSubtreeIfNeeded()
        #expect(a.frame.size == NSSize(width: 500, height: 320))
        window.close()
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
