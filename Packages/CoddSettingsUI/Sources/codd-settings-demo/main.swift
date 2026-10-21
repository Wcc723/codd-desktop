import AppKit
import CoddPreferences
import CoddSettingsUI
import CoddUI

// codd-settings-demo [--fonts <dir>] [--snapshot <dir>]
//   --snapshot: renders all 13 sections with the SPEC §5 sample at 1040 × 720 (the app's Settings
//               window) and 1440 × 900, each section's full length at 1440 wide, and a few states
//               (auto-switch ON, search, hotkey refusal, CRT FULL, cswap state unavailable; M4: the
//               notebook facts missing / MCP stopped after a token rotation, the condense account
//               of the artboard, 永不 shown in ADVANCED while the index rebuilds); then exits.
//   otherwise:  opens the page in a 1040 × 720 window (edits print the changed preferences).

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    if let fonts = value(after: "--fonts"), !Typeface.registerFonts(in: URL(fileURLWithPath: fonts, isDirectory: true)) {
        FileHandle.standardError.write(Data("fonts not found in \(fonts)\n".utf8))
    }
    app.appearance = NSAppearance(named: .darkAqua)
    if let dir = value(after: "--snapshot") {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Demo.snapshots(into: url)
        print("SNAPSHOTS \(url.path)")
        exit(0)
    }
    app.setActivationPolicy(.regular)
    let demo = Demo()
    demo.show()
    app.activate()
    withExtendedLifetime(demo) { app.run() }
}

@MainActor
final class Demo {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
    private var root: SettingsRootView?

    static func makeRoot(preferences: CoddPreferences = .defaults, info: SettingsInfo = SettingsSamples.info(),
                         actions: SettingsActions = SettingsActions()) -> SettingsRootView {
        let model = SettingsModel(preferences: preferences, info: info)
        let root = SettingsRootView(model: model, actions: actions, profilesView: DemoProfilesView())
        root.topInset = 28
        return root
    }

    func show() {
        let root = Self.makeRoot(actions: SettingsActions(tryHotkey: { combo in
            print("tryHotkey \(combo.spec)")
            return nil
        }, setAlias: { id, alias in print("setAlias \(id) \(alias ?? "nil")") },
           openNotesFolder: { print("openNotesFolder") }, rotateMCPToken: { print("rotateMCPToken") },
           mcpRegistration: { print("mcpRegistration \($0)") }, rebuildNotesIndex: { print("rebuildNotesIndex") },
           openCleanup: { print("openCleanup") }, openOnboarding: { print("openOnboarding") }))
        root.model.onChange = { prefs in print("changed \(prefs.general.hotkey.display) crt=\(prefs.appearance.crt.rawValue)") }
        self.root = root
        window.title = "codd-settings-demo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.bg
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Snapshots

    static func snapshots(into dir: URL) {
        for section in SettingsSection.allCases {
            let name = "\(section.number)-\(section.rawValue)"
            for size in [NSSize(width: 1040, height: 720), NSSize(width: 1440, height: 900)] {
                let root = makeRoot()
                root.select(section)
                write(root, size: size, to: dir.appendingPathComponent("\(name)-\(Int(size.width)).png"))
            }
            let root = makeRoot()
            root.select(section)
            writeFull(root, width: 1440, to: dir.appendingPathComponent("\(name)-full.png"))
        }
        // States.
        var auto = CoddPreferences.defaults
        auto.accounts.autoSwitch.enabled = true
        let accounts = makeRoot(preferences: auto)
        accounts.select(.accounts)
        writeFull(accounts, width: 1440, to: dir.appendingPathComponent("state-accounts-autoswitch-on.png"))
        writeFull(makeAndSelect(.accounts, preferences: auto), width: 1040, to: dir.appendingPathComponent("state-accounts-autoswitch-on-1040.png"))

        var crt = CoddPreferences.defaults
        crt.appearance.crt = .full
        crt.appearance.terminalFontSize = 16
        crt.appearance.terminalFont = "Menlo"
        write(makeAndSelect(.appearance, preferences: crt), size: NSSize(width: 1040, height: 720),
              to: dir.appendingPathComponent("state-appearance-crt-full-16.png"))

        let search = makeRoot()
        search.setSearchQuery("通知")
        search.submitSearch()
        write(search, size: NSSize(width: 1040, height: 720), to: dir.appendingPathComponent("state-search-notify.png"))

        var info = SettingsSamples.info()
        info.hotkeyError = "⌥ Space 已被其他 App 使用，請改用別的組合鍵"
        info.loginItemStatus = "測試資料根目錄不會註冊登入項目"
        info.saveProblem = "preferences.json 來自較新版本，唯讀"
        write(makeAndSelect(.general, info: info), size: NSSize(width: 1040, height: 720),
              to: dir.appendingPathComponent("state-general-errors.png"))

        var empty = SettingsInfo(preferencesPath: "/tmp/codd-test/preferences.json", dataRootPath: "/tmp/codd-test")
        empty.cswap = SettingsCswapInfo(pathOK: false)
        writeFull(makeAndSelect(.accounts, info: empty), width: 1040, to: dir.appendingPathComponent("state-accounts-empty.png"))
        writeFull(makeAndSelect(.hooks, info: empty), width: 1040, to: dir.appendingPathComponent("state-hooks-empty.png"))

        // D1: cswap's state files unusable, `重新讀取` offered.
        var unavailable = SettingsSamples.info()
        unavailable.accounts = []
        unavailable.usageSources = []
        unavailable.accountsUnavailable = "sequence.json 無法解析"
        write(makeAndSelect(.accounts, info: unavailable), size: NSSize(width: 1040, height: 720),
              to: dir.appendingPathComponent("state-accounts-unavailable.png"))

        // M4: an M3 caller (no notebook facts): every value `—`, buttons disabled.
        var neutral = SettingsSamples.info()
        neutral.notebook = .unavailable
        neutral.condenseAccounts = []
        neutral.canOpenCleanup = false
        neutral.cleanupCandidateCount = nil
        for section in [SettingsSection.notebook, .cleanup, .advanced] {
            writeFull(makeAndSelect(section, info: neutral), width: 1040,
                      to: dir.appendingPathComponent("state-\(section.number)-\(section.rawValue)-neutral.png"))
        }
        // MCP stopped, the token rotated (Claude Code needs a new registration), Codex not wired yet.
        var stopped = SettingsSamples.info()
        stopped.notebook.mcpRunning = false
        stopped.notebook.mcpClients = 0
        stopped.notebook.registrations[0] = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: "需要重新註冊（token 已輪替）",
                                                                     actionTitle: "註冊", accent: true)
        stopped.notebook.registrations[1].actionEnabled = false
        writeFull(makeAndSelect(.notebook, info: stopped), width: 1040, to: dir.appendingPathComponent("state-08-notebook-stopped.png"))
        // The artboard's look of 交給 Claude 濃縮 (`#1 個人`).
        var account = CoddPreferences.defaults
        account.cleanup.condenseAccount = "1"
        write(makeAndSelect(.cleanup, preferences: account), size: NSSize(width: 1040, height: 720),
              to: dir.appendingPathComponent("state-09-cleanup-account-1.png"))
        writeFull(makeAndSelect(.cleanup, preferences: account), width: 1440, to: dir.appendingPathComponent("state-09-cleanup-account-1-full.png"))
        // 永不 chosen in CLEANUP shows as ADVANCED's title; the index is rebuilding.
        var never = CoddPreferences.defaults
        never.cleanup.scrollbackDeleteDays = nil
        var rebuilding = SettingsSamples.info()
        rebuilding.notebook.rebuilding = true
        rebuilding.notebook.indexLine = "重建中…"
        write(makeAndSelect(.advanced, preferences: never, info: rebuilding), size: NSSize(width: 1040, height: 720),
              to: dir.appendingPathComponent("state-12-advanced-never-rebuilding.png"))
    }

    static func makeAndSelect(_ section: SettingsSection, preferences: CoddPreferences = .defaults,
                              info: SettingsInfo = SettingsSamples.info()) -> SettingsRootView {
        let root = makeRoot(preferences: preferences, info: info)
        root.select(section)
        return root
    }

    /// The section's whole length: lays out at `width`, reads the scroll document's height.
    static func writeFull(_ root: SettingsRootView, width: CGFloat, to url: URL) {
        let window = host(root, size: NSSize(width: width, height: 900))
        // The content scroll view is the widest one (the sidebar nav scrolls too).
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { sub in (sub as? NSScrollView).map { [$0] } ?? scrollViews(in: sub) }
        }
        let content = scrollViews(in: root).max { $0.frame.width < $1.frame.width }
        let height = max(900, (content?.documentView?.frame.height ?? 900) + root.topInset)
        window.setContentSize(NSSize(width: width, height: height))
        render(window, to: url)
        window.contentView = nil
        window.close()
    }

    static func write(_ root: SettingsRootView, size: NSSize, to url: URL) {
        let window = host(root, size: size)
        render(window, to: url)
        window.contentView = nil
        window.close()
    }

    private static func host(_ root: SettingsRootView, size: NSSize) -> NSWindow {
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = TrafficLightHost(root)
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        return window
    }

    /// Renders the window's content view through `cacheDisplay` (works off screen) at 2x.
    static func render(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { return }
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A window AppKit never shrinks to the screen (snapshots larger than this Mac's display).
final class SnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The root view plus the window's traffic lights drawn where macOS puts them (for snapshots).
final class TrafficLightHost: FlippedView {
    init(_ root: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.bg.cgColor
        addSubview(root)
        root.pinEdges(to: self)
        let lights = TrafficLights()
        addSubview(lights)
        lights.frame = CGRect(x: 0, y: 0, width: 80, height: 28)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class TrafficLights: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            NSColor(hex: UInt32(hex)).setFill()
            NSBezierPath(ovalIn: CGRect(x: 13 + CGFloat(index) * 20, y: 8, width: 12, height: 12)).fill()
        }
    }
}

/// Stand-in for the app's M2 `ProfilesSettingsView` (section 04 is injected by the app).
final class DemoProfilesView: FlippedView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = Label.make("PROFILES", style: TextStyle.pageTitle)
        let zh = Label.make("啟動設定檔", style: TextStyle(font: NSFont(name: "PingFangTC-Medium", size: 15) ?? Typeface.mono(15),
                                                         color: Palette.bone, tracking: 0.04))
        let head = hStack([title, zh, spacer(), CoddButton("+ New profile", style: .bracket(.accent, small: true))], spacing: 12)
        let lead = Label.make("⌘N 新增 session 時可選的啟動方式。CODD 會自動補上 --session-id 與 -n 名稱。", style: TextStyle.mono(12, Palette.dim))
        let note = Label.make("// 這一頁由 App 的 ProfilesSettingsView 提供（M2），這裡是 demo 的替身", style: TextStyle.comment)
        let stack = columnStack([head, lead, note], spacing: 10, edgeInsets: NSEdgeInsets(top: 26, left: 40, bottom: 28, right: 40))
        addSubview(stack)
        stack.pinEdges(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
