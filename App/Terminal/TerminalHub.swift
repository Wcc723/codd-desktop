import AppKit
import CoddHolderClient
import CoddProtocol
import CoddTerminal
import Darwin
import Foundation
import os
import CoddUI

/// One PTY a terminal can show: a session's own (`tabID` nil) or one of its shell tabs.
struct TerminalKey: Hashable, Sendable, CustomStringConvertible {
    var sessionID: SessionID
    var tabID: String?

    init(sessionID: SessionID, tabID: String?) {
        self.sessionID = sessionID
        self.tabID = tabID
    }

    init(_ target: TerminalTarget) {
        sessionID = target.sessionID
        if case .shell(let id) = target.tab { tabID = id } else { tabID = nil }
    }

    var description: String {
        let session = String(sessionID.prefix(8))
        return tabID.map { "\(session)/\($0.prefix(8))" } ?? session
    }
}

/// A shell tab's holder: `sessions/<owner>/tabs/<tab id>/` (session discovery lists only the
/// direct children of `sessions/`, so tabs never show up as sidebar sessions).
@MainActor
final class ShellTabRuntime {
    let id: String
    let sessionID: SessionID
    let directory: String
    var socketPath: String?
    var holderPid: pid_t?
    /// The tab's shell (WELCOME `childPid`, or meta.json for a discovered holder): the running
    /// lamp reads its process group (D25).
    var childPid: pid_t?
    var connection: PtyConnection?
    var isSpawning = false
    /// Its holder was running when the app launched: connect instead of spawning.
    var holderAlive = false

    init(id: String, sessionID: SessionID, directory: String) {
        self.id = id
        self.sessionID = sessionID
        self.directory = directory
    }
}

/// Real-mode terminals: libghostty engines (CoddTerminal) fed by holder streams.
///
/// - Engines live in a `TerminalPool`: the terminals the pane's slots show are visible, up to 6
///   recently shown ones stay hot (occluded, still streaming, in their slot's deck), the rest are
///   cold (stream detached, surface disposed; showing one again replays it from the holder's ring).
/// - A session's own PTY uses the store's `PtyConnection`; shell tabs (and the ⌘J panel's shell)
///   are holders of their own, spawned in the session's folder the first time they are shown and
///   ended when the tab is closed or its shell exits.
/// - A new session's terminal is created and pinned before its holder starts and stays pinned
///   until it answered the first DA1 query (or 3 s after the holder came up): its startup probes
///   always reach an attached surface (M1 decision "Startup probes").
/// - A session whose holder is gone shows its last screen, read from the ring file and replayed
///   read-only with a dim footer (D7); a new process in it (RESUME, RESTART) gets a fresh surface.
/// - While the main window is closed or miniaturized every slot is occluded (D10): engines keep
///   parsing, nothing renders.
/// - Tabs of the ⌘J panel (D11) are shell tabs, listed in the layout's `panelTabs`; the panel
///   slot shows the selected one. Every extra terminal opens there (⌘T, `+`); strip shell tabs
///   an older panes.json still lists move into the panel at discovery. Shell tabs report their
///   OSC title and folder into `ShellState` (labels, the panel's cwd); a BEL from a PTY that is
///   not on screen marks its tab (D12); while the window shows, a 1 Hz poll of the shells'
///   process groups lights the running lamps (D25).
/// - Links (audit CODE-2): a ⌘-click goes through `linkOpener` (web and mail links open, file
///   links are shown in Finder, any other scheme asks first), and the link under the pointer
///   shows its real target in the bottom-left corner of the slot that shows that terminal.
@MainActor
final class TerminalHub: TerminalSurfaceFactory, ShellTabJobProbe {
    let store: HolderSessionStore
    let shell: ShellState
    private(set) var fontSize: CGFloat
    /// Tab holders were discovered (until then a shown tab waits instead of spawning a new shell).
    private(set) var isReady = false

    private let hotCapacity: Int
    private let probeWindowDuration: Duration
    private lazy var pool: TerminalPool<TerminalKey> = {
        let pool = TerminalPool<TerminalKey>(hotCapacity: hotCapacity) { [unowned self] key in self.makeEngine(key) }
        pool.onEvict = { [unowned self] key, _ in
            self.replayedKeys.remove(key)
            self.connection(for: key)?.detachEngine()
        }
        return pool
    }()
    private var surfaces: [TerminalSlot: HolderTerminalSurface] = [:]
    private var slotKeys: [TerminalSlot: TerminalKey] = [:]
    private var occludedSlots: Set<TerminalSlot> = []
    /// The main window is closed or miniaturized: every slot is occluded (D10).
    private(set) var isWindowOccluded = false
    /// DEBUG `-codd-force-render` (M5 D17): the window's state never occludes the terminals (the
    /// engines also ignore AppKit's occlusion, `TerminalEngine.rendersWhileWindowOccludedByDefault`),
    /// so a covered background window keeps drawing for GPU measurements. Tiers are unchanged.
    var forceRender = false
    /// Keys whose engine shows (or is about to show) a ring replay or the holder-gone note: a new
    /// process attaching to such an engine needs a fresh surface first (no old screen mixed in).
    private var replayedKeys: Set<TerminalKey> = []
    /// Sessions whose last screen was replayed from the ring since their last process (state dump).
    private var replayedSessions: Set<SessionID> = []
    private var tabs: [String: ShellTabRuntime] = [:]
    private var pinTimers: [TerminalKey: Task<Void, Never>] = [:]
    /// D25: the 1 Hz running-lamp poll (only while the window shows and a shell could run a job).
    private var runningTimer: Timer?
    /// The last poll: how many shells it read and how long it took (measurements, tests).
    private(set) var lastRunningPoll: (shells: Int, duration: Duration)?
    private let signposter = OSSignposter(subsystem: CoddIdentity.bundleIdentifier, category: "terminal")
    private let log: @MainActor (String) -> Void
    /// A session left CODD (after its terminals and tabs went): the pane's composer drops its
    /// draft and history from memory (review concurrency-perf-8).
    var onSessionDeleted: ((SessionID) -> Void)?
    /// Another session shown: its lamps are polled at once instead of within a second.
    private var currentSessionLoop: ObservationLoop?
    /// What a ⌘-clicked link in any terminal (main slot and panel) does; tests replace its steps.
    var linkOpener = TerminalLinkOpener()

    static let hotCapacity = 6
    /// A pinned terminal is released this long after its holder came up, DA1 answered or not.
    static let probeWindow: Duration = .seconds(3)
    /// Upper bound while the holder is still starting (login environment, socket).
    static let spawnPinLimit: Duration = .seconds(20)
    /// D25: how often the running lamps are refreshed.
    static let runningPollInterval: TimeInterval = 1

    init(store: HolderSessionStore, shell: ShellState, hotCapacity: Int = TerminalHub.hotCapacity,
         probeWindow: Duration = TerminalHub.probeWindow,
         log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.store = store
        self.shell = shell
        self.hotCapacity = hotCapacity
        probeWindowDuration = probeWindow
        self.log = log
        fontSize = CGFloat(shell.terminalFontSize)
        store.onConnection = { [weak self] id, connection in self?.connectionAppeared(id, connection) }
        store.prepareTerminal = { [weak self] id in self?.prepare(TerminalKey(sessionID: id, tabID: nil)) }
        store.terminalGrid = { [weak self] in self?.grid(for: .main) }
        store.onSessionDeleted = { [weak self] id, _ in self?.sessionDeleted(id) }
        store.shellTabHolders = { [weak self] in self?.tabHolders() ?? [] }
        store.onBell = { [weak self] id in self?.bell(TerminalKey(sessionID: id, tabID: nil)) }
        currentSessionLoop = ObservationLoop(track: { [weak shell] in shell?.currentSessionID }, apply: { [weak self] _ in
            guard let self, self.isRunningPollActive else { return }
            self.pollRunning()
        })
    }

    /// D6: the live shell-tab holders (a claude below one is EXT `在 CODD shell 中`).
    func tabHolders() -> [ShellTabHolder] {
        tabs.values.compactMap { runtime in
            guard let pid = runtime.connection?.welcome?.holderPid ?? runtime.holderPid, pid > 0 else { return nil }
            return ShellTabHolder(sessionID: runtime.sessionID, tabID: runtime.id, holderPid: Int(pid))
        }
    }

    // MARK: - TerminalSurfaceFactory

    func makeSurface(slot: TerminalSlot) -> TerminalSurface {
        let surface = HolderTerminalSurface(slot: slot, hub: self)
        surfaces[slot] = surface
        return surface
    }

    func closeShellTab(sessionID: SessionID, tabID: String) {
        if let runtime = tabs[tabID] {
            retire(runtime, terminate: true)
        } else {
            pool.remove(TerminalKey(sessionID: sessionID, tabID: tabID))
        }
    }

    // MARK: - Slots

    /// Shows `target` in `slot` (nil: nothing). Hot terminals are only revealed; a cold one gets
    /// a new engine that replays from its holder.
    func show(_ target: TerminalTarget?, in slot: TerminalSlot) {
        let key = target.map(TerminalKey.init)
        guard slotKeys[slot] != key else { return }
        let interval = signposter.beginInterval("show")
        #if DEBUG
        let start = ContinuousClock.now
        let tier = key.map { pool.tier(of: $0) }
        #endif
        slotKeys[slot] = key
        // The bubble was the previous terminal's; the new one reports its own on the next move.
        surfaces[slot]?.showHoverLink(nil)
        applyVisibility()
        signposter.endInterval("show", interval)
        #if DEBUG
        // Session-switch budget (hot < 16 ms): `TERMINAL show … tier=hot ms=…`.
        if let key, let tier {
            log(String(format: "TERMINAL show slot=%@ key=%@ tier=%@ ms=%.2f", "\(slot)", key.description, "\(tier)",
                       Self.milliseconds(ContinuousClock.now - start)))
        }
        #endif
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    func setOccluded(_ occluded: Bool, slot: TerminalSlot) {
        let changed = occluded ? occludedSlots.insert(slot).inserted : occludedSlots.remove(slot) != nil
        if changed { applyVisibility() }
    }

    /// D10: the main window closed or was miniaturized (true), or is shown again (false). Kept
    /// apart from the per-slot flags, which say what the pane hides on its own (a placeholder).
    /// The tiers do not change: the shown terminals stay hot and resume rendering on show.
    func setWindowOccluded(_ occluded: Bool) {
        if occluded, forceRender {
            log("terminals window-occluded=true ignored (force-render)")
            return
        }
        guard occluded != isWindowOccluded else { return }
        isWindowOccluded = occluded
        log("terminals window-occluded=\(occluded)")
        applyVisibility()
        updateRunningPoll()
    }

    private var visibleKeys: [TerminalKey] {
        var keys: [TerminalKey] = []
        for slot in TerminalSlot.allCases where !occludedSlots.contains(slot) {
            if let key = slotKeys[slot], !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    private func applyVisibility() {
        let shown = pool.show(visibleKeys)
        for slot in TerminalSlot.allCases {
            guard let surface = surfaces[slot] else { continue }
            guard !occludedSlots.contains(slot), let key = slotKeys[slot],
                  let item = shown.first(where: { $0.key == key }) else {
                surface.deck.showNothing()
                surface.showHoverLink(nil)
                continue
            }
            surface.deck.show(item.engine.view)
            if let grid = item.engine.gridSize { surface.showGrid(grid) }
        }
        // `pool.show` un-occludes what it shows; nothing renders while the window is away.
        if isWindowOccluded {
            for item in shown { item.engine.setOccluded(true) }
        } else {
            // D12: a PTY on screen has no pending bell.
            for key in visibleKeys { shell.clearBell(BellKey(key)) }
        }
    }

    /// Shown in a slot the pane does not hide, in the visible window.
    func isOnScreen(_ key: TerminalKey) -> Bool { !isWindowOccluded && visibleKeys.contains(key) }

    /// D12: a PTY rang its bell: its tab gets the amber `◆` unless it is on screen right now.
    private func bell(_ key: TerminalKey) {
        guard !isOnScreen(key) else { return }
        shell.ringBell(BellKey(key))
    }

    func send(_ input: TerminalInput, slot: TerminalSlot) {
        guard let key = slotKeys[slot] else { return }
        connection(for: key)?.send(input.bytes, submit: input.submits, paste: input.pastes)
    }

    /// The composer path to a PTY no slot needs to show (the error banner's resend, D26).
    @discardableResult
    func send(_ input: TerminalInput, to target: TerminalTarget) -> Bool {
        connection(for: TerminalKey(target))?.send(input.bytes, submit: input.submits, paste: input.pastes) ?? false
    }

    /// Whether what `slot` shows has a process that can take input: a connection that has not
    /// ended (a reconnecting one holds the input until it is back, D1).
    func acceptsInput(_ slot: TerminalSlot) -> Bool {
        guard let key = slotKeys[slot], let connection = connection(for: key) else { return false }
        switch connection.phase {
        case .connecting, .connected, .reconnecting: return true
        case .idle, .ended, .closed: return false
        }
    }

    func focus(_ slot: TerminalSlot) {
        guard let key = slotKeys[slot] else { return }
        pool.engine(for: key)?.focus()
    }

    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        for key in pool.liveKeys { pool.engine(for: key)?.fontSize = size }
    }

    /// Settings › 外觀 › 終端機字型 (M3 I3): engines are made with it from now on and the process's
    /// one libghostty configuration takes it at once (every terminal redraws in it).
    private(set) var fontFamily = CoddTerminalSetup.configuration.fontFamily

    func setFontFamily(_ family: String) {
        let configuration = CoddTerminalSetup.configuration(fontFamily: family)
        guard configuration.fontFamily != fontFamily else { return }
        fontFamily = configuration.fontFamily
        log("terminal font family=\(fontFamily)")
        // Before the first engine there is no libghostty app yet: the first engine brings it.
        if TerminalRuntime.configuration != nil { TerminalRuntime.apply(configuration) }
    }

    /// The grid of the terminal `slot` shows.
    func grid(for slot: TerminalSlot) -> TerminalGridSize? {
        guard let key = slotKeys[slot], let grid = pool.engine(for: key)?.gridSize else { return nil }
        return TerminalGridSize(columns: grid.columns, rows: grid.rows)
    }

    // MARK: - Engines

    private func makeEngine(_ key: TerminalKey) -> TerminalEngine {
        let engine = TerminalEngine(configuration: CoddTerminalSetup.configuration(fontFamily: fontFamily))
        if fontSize != CoddTerminalSetup.configuration.fontSize { engine.fontSize = fontSize }
        engine.onResize = { [weak self] size in self?.engineResized(key, size) }
        engine.onFontSizeChange = { [weak self] size in self?.engineFontSizeChanged(size) }
        engine.onFirstDeviceAttributesReply = { [weak self] in self?.unpin(key) }
        engine.onOpenURL = { [weak self, weak engine] url in self?.linkOpener.handle(url, window: engine?.view.window) }
        engine.onHoverLink = { [weak self] link in self?.engineHoverLink(key, link) }
        bind(engine, key)
        return engine
    }

    /// The link under the pointer in `key`'s terminal, shown by the slots that show it.
    private func engineHoverLink(_ key: TerminalKey, _ link: String?) {
        for (slot, shownKey) in slotKeys where shownKey == key { surfaces[slot]?.showHoverLink(link) }
    }

    /// Connects a new engine to its PTY: the store's connection for a session's own PTY, the
    /// tab's (connecting to or spawning its holder first) for a shell tab.
    private func bind(_ engine: TerminalEngine, _ key: TerminalKey) {
        if let tabID = key.tabID {
            guard let runtime = tabRuntime(tabID, session: key.sessionID) else { return }
            if let connection = runtime.connection {
                connection.attach(engine)
            } else if runtime.holderAlive {
                connectTab(runtime, engine: engine, freshSpawn: false)
            } else if isReady {
                spawnTab(runtime)
            }
        } else if let connection = store.connection(for: key.sessionID), connection.phase != .ended {
            connection.attach(engine)
        } else if store.isLoaded, let session = store.session(key.sessionID), session.state != .starting, !session.external {
            let connection = store.connection(for: key.sessionID)
            switch connection?.ending {
            case nil, .holderGone?:
                replayRing(into: engine, key)
            case .takenOver?, .failed?:
                // The holder still runs, held by someone else: nothing of ours to replay.
                connection?.attach(engine)
                if connection?.exitInfo == nil { engine.replay(CoddTerminalSetup.holderGoneNote) }
            }
        }
        // Before the store loaded: `discoverTabs` binds it once the sessions are known.
    }

    // MARK: - Dead sessions (D7)

    /// A ring file made ready off the main actor: the modes to restore and the filtered bytes.
    struct RingReplay: Sendable {
        var restore: [UInt8]
        var bytes: PreparedReplay
        var exitStatus: Int32?
        var modesKnown: Bool

        init(_ snapshot: RingSnapshot) {
            restore = snapshot.modes?.restoreSequence() ?? []
            bytes = PreparedReplay(snapshot.bytes)
            exitStatus = snapshot.exitStatus
            modesKnown = snapshot.modes != nil
        }
    }

    /// The connection of a session's own PTY that can still stream (not ended).
    private func liveConnection(for key: TerminalKey) -> PtyConnection? {
        guard key.tabID == nil, let connection = store.connection(for: key.sessionID), connection.phase != .ended else { return nil }
        return connection
    }

    /// Reads `<session dir>/ring` off the main actor and prepares it there (OSC 52 filtered, copied
    /// once: `PreparedReplay`), then, if the engine is still this key's and no process came back
    /// meanwhile, replays it read-only: reset, the modes at the replay point, the bytes (no
    /// replies), the dim footer, then `childExited` so keys go nowhere. The main actor only checks
    /// and hands the buffer over (review concurrency-perf-7). No usable ring: the M1 note.
    private func replayRing(into engine: TerminalEngine, _ key: TerminalKey) {
        replayedKeys.insert(key)
        guard let directory = store.runtime(key.sessionID)?.directory else {
            engine.replay(CoddTerminalSetup.holderGoneNote)
            engine.childExited(status: 0)
            return
        }
        let path = directory + "/ring"
        let began = ContinuousClock.now
        Task { [weak self, weak engine] in
            let (result, readTime) = await Task.detached(priority: .userInitiated) { () -> (Result<RingReplay, RingFileError>, Duration) in
                let start = ContinuousClock.now
                do throws(RingFileError) {
                    let snapshot = try RingFileReader.read(path: path)
                    return (.success(RingReplay(snapshot)), ContinuousClock.now - start)
                } catch {
                    return (.failure(error), ContinuousClock.now - start)
                }
            }.value
            guard let self, let engine, !engine.isDisposed, self.pool.engine(for: key) === engine, self.replayedKeys.contains(key),
                  self.liveConnection(for: key) == nil else { return }
            self.applyReplay(result, to: engine, key, began: began, readTime: readTime)
        }
    }

    /// Logs `ms` (bind to replayed), `readMs` (the file read and preparation, off main),
    /// `applyMs` (main actor).
    private func applyReplay(_ result: Result<RingReplay, RingFileError>, to engine: TerminalEngine, _ key: TerminalKey,
                             began: ContinuousClock.Instant, readTime: Duration) {
        let read = ContinuousClock.now
        switch result {
        case .success(let ring) where ring.bytes.count > 0:
            engine.reset()
            if !ring.restore.isEmpty { engine.replay(ring.restore) }
            engine.replay(ring.bytes)
            engine.replay(CoddTerminalSetup.replayFooter)
            engine.childExited(status: ring.exitStatus ?? 0)
            replayedSessions.insert(key.sessionID)
            store.onStatesChanged?()  // the state dump's `replayed`
            let done = ContinuousClock.now
            log(String(format: "replay session=%@ bytes=%d ms=%.2f readMs=%.2f applyMs=%.2f modes=%@", key.sessionID,
                       ring.bytes.count, Self.milliseconds(done - began), Self.milliseconds(readTime),
                       Self.milliseconds(done - read), ring.modesKnown ? "known" : "unknown"))
        case .success:
            log("replay session=\(key.sessionID) bytes=0 (empty ring)")
            engine.replay(CoddTerminalSetup.holderGoneNote)
            engine.childExited(status: 0)
        case .failure(let error):
            log("replay session=\(key.sessionID) none: \(error)")
            engine.replay(CoddTerminalSetup.holderGoneNote)
            engine.childExited(status: 0)
        }
    }

    /// Whether `id`'s last screen came from its ring file (no process since).
    func isReplayed(_ id: SessionID) -> Bool { replayedSessions.contains(id) }

    private func connection(for key: TerminalKey) -> PtyConnection? {
        if let tabID = key.tabID { return tabs[tabID]?.connection }
        return store.connection(for: key.sessionID)
    }

    private func engineResized(_ key: TerminalKey, _ size: TerminalResize) {
        connection(for: key)?.resize(size)
        for (slot, shownKey) in slotKeys where shownKey == key { surfaces[slot]?.showGrid(size) }
    }

    /// ⌘+ / ⌘- / ⌘0 inside a terminal: every terminal and the header follow.
    private func engineFontSizeChanged(_ size: CGFloat) {
        let clamped = min(max(Double(size), ShellState.fontSizeRange.lowerBound), ShellState.fontSizeRange.upperBound)
        if shell.terminalFontSize != clamped { shell.terminalFontSize = clamped }
    }

    /// The store made a connection for a session (spawn, restart, discovery).
    private func connectionAppeared(_ id: SessionID, _ connection: PtyConnection) {
        let key = TerminalKey(sessionID: id, tabID: nil)
        updateRunningPoll()
        if replayedSessions.remove(id) != nil { store.onStatesChanged?() }
        if let engine = pool.engine(for: key) {
            // A replayed (read-only, exited) screen must not carry over into the new process.
            if replayedKeys.remove(key) != nil, connection.engine !== engine { engine.rebuildForNewProcess() }
            connection.attach(engine)
        }
        if pinTimers[key] != nil { releasePin(key, after: probeWindowDuration) }
    }

    // MARK: - Startup probes

    /// Creates `key`'s engine before its holder starts (hot when no slot shows it) and pins it.
    private func prepare(_ key: TerminalKey) {
        pool.setPinned(true, for: key)
        releasePin(key, after: Self.spawnPinLimit)
        guard pool.engine(for: key) == nil else { return }
        let visible = visibleKeys
        for item in pool.show(visible + [key]) where item.key == key {
            surfaces[.main]?.deck.addSubview(item.engine.view)
            item.engine.view.frame = surfaces[.main]?.deck.bounds ?? .zero
            item.engine.view.isHidden = true
        }
        _ = pool.show(visible)
        applyVisibility()
    }

    private func releasePin(_ key: TerminalKey, after delay: Duration) {
        pinTimers[key]?.cancel()
        pinTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.unpin(key)
        }
    }

    private func unpin(_ key: TerminalKey) {
        guard let timer = pinTimers.removeValue(forKey: key) else { return }
        timer.cancel()
        pool.setPinned(false, for: key)
    }

    // MARK: - Shell tabs

    /// Tab ids come from panes.json and name directories: only lowercase UUIDs are accepted.
    nonisolated static func isValidTabID(_ id: String) -> Bool {
        id.utf8.count == 36 && UUID(uuidString: id) != nil && id == id.lowercased()
    }

    private func tabRuntime(_ tabID: String, session: SessionID) -> ShellTabRuntime? {
        if let runtime = tabs[tabID] { return runtime }
        guard Self.isValidTabID(tabID), let directory = store.runtime(session)?.directory else { return nil }
        let runtime = ShellTabRuntime(id: tabID, sessionID: session, directory: directory + "/tabs/" + tabID)
        tabs[tabID] = runtime
        updateRunningPoll()
        return runtime
    }

    private func spawnTab(_ runtime: ShellTabRuntime) {
        guard !runtime.isSpawning, let launcher = store.launcher, let uuid = UUID(uuidString: runtime.id),
              let owner = store.runtime(runtime.sessionID) else { return }
        runtime.isSpawning = true
        let key = TerminalKey(sessionID: runtime.sessionID, tabID: runtime.id)
        let cwd = owner.cwd
        Task { [weak self] in
            let login = await LoginEnvironment.current()
            guard let self else { return }
            let grid = self.pool.engine(for: key)?.gridSize.map { TerminalGridSize(columns: $0.columns, rows: $0.rows) }
            let plan: HolderStartPlan
            do throws(HolderStartError) {
                plan = try launcher.plan(sessionID: uuid, cwd: cwd, directory: runtime.directory, socketPath: runtime.socketPath,
                                         loginEnvironment: login, grid: grid ?? self.grid(for: .main))
            } catch {
                runtime.isSpawning = false
                self.store.report("shell 分頁無法啟動 · \(error.userMessage)", detail: "tab \(key): \(error.description)",
                                  sessionID: runtime.sessionID)
                return
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<pid_t, HolderStartError> in
                do throws(HolderStartError) {
                    return .success(try launcher.start(plan))
                } catch {
                    return .failure(error)
                }
            }.value
            runtime.isSpawning = false
            guard self.tabs[runtime.id] === runtime else {
                // Closed while it was starting.
                if case .success(let pid) = result { Self.terminate(pid) }
                return
            }
            switch result {
            case .success(let pid):
                runtime.holderPid = pid
                runtime.socketPath = plan.socketPath
                runtime.holderAlive = true
                self.log("spawned tab=\(key) holderPid=\(pid) socket=\(plan.socketPath)")
                self.connectTab(runtime, engine: self.pool.engine(for: key), freshSpawn: true)
                self.store.scheduleExternalRefresh()
            case .failure(let error):
                self.store.report("shell 分頁無法啟動 · \(error.userMessage)", detail: "tab \(key): \(error.description)",
                                  sessionID: runtime.sessionID)
            }
        }
    }

    /// A connection to the tab's (new or discovered) holder, with its engine attached first so
    /// the very first ATTACH replays into it. `engine` is passed in: while the pool creates an
    /// engine (`bind` runs inside `TerminalPool.show`) it cannot be looked up yet.
    private func connectTab(_ runtime: ShellTabRuntime, engine: TerminalEngine?, freshSpawn: Bool) {
        guard let socketPath = runtime.socketPath else { return }
        let key = TerminalKey(sessionID: runtime.sessionID, tabID: runtime.id)
        if let old = runtime.connection {
            old.detachEngine()
            old.close()
            engine?.rebuildForNewProcess()
        }
        let connection = PtyConnection(sessionID: runtime.id, socketPath: socketPath, directory: runtime.directory,
                                       tuning: store.connectionTuning, log: log)
        connection.onEvent = { [weak self, weak runtime] event in
            guard let self, let runtime else { return }
            self.tabEvent(event, runtime: runtime)
        }
        runtime.connection = connection
        if let engine { connection.attach(engine) }
        connection.connect(freshSpawn: freshSpawn)
        if freshSpawn, pinTimers[key] != nil { releasePin(key, after: probeWindowDuration) }
    }

    private func tabEvent(_ event: PtyEvent, runtime: ShellTabRuntime) {
        switch event {
        case .welcome(let welcome):
            if let pid = welcome.holderPid, runtime.holderPid != pid {
                runtime.holderPid = pid
                store.scheduleExternalRefresh()
            }
            if welcome.childPid > 0 { runtime.childPid = welcome.childPid }
            shell.setTabTitle(welcome.title, for: runtime.id)
            if let cwd = welcome.cwd { shell.setTabCwd(cwd, for: runtime.id) }
            if welcome.exited { tabEnded(runtime) } else { updateRunningPoll() }
        case .exit, .ended(.holderGone):
            tabEnded(runtime)
        case .ended(.takenOver), .ended(.failed):
            // Another client has the holder (a second CODD on this data root): never end it from
            // here. The terminal keeps its last screen; showing the tab cold again takes it back.
            log("tab released tab=\(runtime.sessionID.prefix(8))/\(runtime.id.prefix(8))")
            runtime.connection?.detachEngine()
            runtime.connection?.close()
            runtime.connection = nil
            runtime.holderAlive = true
        case .bell:
            store.session(runtime.sessionID)?.lastBellAt = store.clock.now()
            bell(TerminalKey(sessionID: runtime.sessionID, tabID: runtime.id))
        case .unreachable:
            break  // the tab waits; the row's UNREACHABLE is about the session's own holder
        case .title(let title):
            // D11: the tab's label (the session row keeps its own PTY's title).
            shell.setTabTitle(title, for: runtime.id)
        case .cwd(let cwd):
            shell.setTabCwd(cwd, for: runtime.id)
        }
    }

    /// The tab's shell is gone: the tab closes (the panel's `+` or ⌘T starts a new shell).
    private func tabEnded(_ runtime: ShellTabRuntime) {
        guard tabs[runtime.id] === runtime else { return }
        log("tab ended tab=\(runtime.sessionID.prefix(8))/\(runtime.id.prefix(8))")
        // Only this tab goes: the panel closes when it was its last one.
        if shell.pane(for: runtime.sessionID).panelTabs.contains(where: { $0.id == runtime.id }) {
            shell.removePanelTab(runtime.id, in: runtime.sessionID)
        } else {
            shell.removeShellTab(runtime.id, in: runtime.sessionID)
        }
        retire(runtime, terminate: true)
    }

    /// Forgets a tab: disposes its terminal, closes its connection, ends its holder and removes
    /// its directory once the holder is gone.
    private func retire(_ runtime: ShellTabRuntime, terminate: Bool) {
        // Detached here, not by the pool's eviction: that looks the connection up through `tabs`,
        // which no longer has the tab (an engine left attached kept itself, its view and the
        // sink alive through the sink's backlog handler).
        runtime.connection?.detachEngine()
        tabs[runtime.id] = nil
        let key = TerminalKey(sessionID: runtime.sessionID, tabID: runtime.id)
        pinTimers.removeValue(forKey: key)?.cancel()
        pool.remove(key)
        let holderPid = runtime.connection?.welcome?.holderPid ?? runtime.holderPid
        runtime.connection?.close()
        runtime.connection = nil
        shell.forgetTab(runtime.id)
        store.scheduleExternalRefresh()
        let directory = runtime.directory
        let socket = runtime.socketPath
        let sessions = store.root.sessionsPath + "/"
        let run = store.root.runPath + "/"
        Task.detached(priority: .utility) {
            if terminate, let holderPid { Self.terminate(holderPid, wait: true) }
            let manager = FileManager.default
            if directory.hasPrefix(sessions), directory.contains("/tabs/") { try? manager.removeItem(atPath: directory) }
            if let socket, socket.hasPrefix(run) { try? manager.removeItem(atPath: socket) }
        }
    }

    /// SIGTERM to a holder (never to a pid that no longer runs a holder executable).
    nonisolated static func terminate(_ pid: pid_t, wait: Bool = false) {
        guard pid > 0, SessionDirectory.isHolderProcess(pid) else { return }
        kill(pid, SIGTERM)
        guard wait else { return }
        for _ in 0..<150 where kill(pid, 0) == 0 { usleep(20_000) }
    }

    private func sessionDeleted(_ id: SessionID) {
        pool.remove(TerminalKey(sessionID: id, tabID: nil))
        replayedSessions.remove(id)
        for runtime in tabs.values where runtime.sessionID == id { retire(runtime, terminate: true) }
        shell.forgetSession(id)
        shell.panes[id] = nil
        onSessionDeleted?(id)
    }

    // MARK: - Discovery and shutdown

    /// Finds the tab holders of every known session (off the main actor). Live ones are
    /// connected when shown; a live holder the layout lost is added back as a panel tab. Then
    /// shown tabs that waited start or connect. First, the strip shell tabs an older panes.json
    /// still lists move into their panel (every extra terminal opens there now).
    func discoverTabs() async {
        shell.moveStripTabsToPanel()
        let directories = store.sessionDirectories
        let found = await Task.detached(priority: .userInitiated) { () -> [(SessionID, SessionRecord)] in
            var out: [(SessionID, SessionRecord)] = []
            for (session, directory) in directories {
                guard let records = try? SessionDirectory.list(root: directory + "/tabs") else { continue }
                out += records.map { (session, $0) }
            }
            return out
        }.value
        for (session, record) in found where Self.isValidTabID(record.meta.session) {
            // A tab shown before discovery finished has a runtime already, but no connection yet.
            let runtime = tabs[record.meta.session]
                ?? ShellTabRuntime(id: record.meta.session, sessionID: session, directory: record.directory)
            guard runtime.connection == nil, !runtime.isSpawning else { continue }
            runtime.socketPath = record.meta.socket.isEmpty ? nil : record.meta.socket
            runtime.holderAlive = record.holderAlive && !record.meta.exited
            runtime.holderPid = runtime.holderAlive ? record.meta.holderPid : nil
            runtime.childPid = runtime.holderAlive && record.meta.childPid > 0 ? record.meta.childPid : nil
            tabs[runtime.id] = runtime
            if runtime.holderAlive {
                adoptIntoLayout(runtime)
                // A tab not shown yet has no connection: label and folder come from meta.json.
                shell.setTabTitle(record.meta.title, for: runtime.id)
                shell.setTabCwd(record.meta.oscCwd, for: runtime.id)
            }
        }
        log("discovered tabs=\(found.count) live=\(found.filter { $0.1.holderAlive && !$0.1.meta.exited }.count)")
        isReady = true
        updateRunningPoll()
        store.scheduleExternalRefresh()
        for key in pool.liveKeys {
            guard let engine = pool.engine(for: key), connection(for: key) == nil else { continue }
            // A session shown before the store loaded waited (no connection known yet).
            if key.tabID == nil, replayedKeys.contains(key) { continue }
            bind(engine, key)
        }
    }

    /// A live tab holder the layout does not list joins the panel (after its tabs; the panel
    /// stays as it was, open or hidden).
    private func adoptIntoLayout(_ runtime: ShellTabRuntime) {
        var layout = shell.pane(for: runtime.sessionID)
        guard !layout.allShellTabs.contains(where: { $0.id == runtime.id }) else { return }
        layout.panelTabs.append(ShellTab(id: runtime.id, number: (layout.panelTabs.map(\.number).max() ?? 0) + 1))
        shell.panes[runtime.sessionID] = layout
    }

    /// D18 `全部停止並結束`: every shell tab's holder gets SIGTERM now (it ends its shell and jobs)
    /// and the tab leaves its strip or panel, so the next launch does not start it again.
    /// Returns how many holders were signalled.
    @discardableResult
    func stopAllTabs() -> Int {
        var signalled = 0
        for runtime in Array(tabs.values) {
            if let pid = runtime.connection?.welcome?.holderPid ?? runtime.holderPid, pid > 0 {
                Self.terminate(pid)
                signalled += 1
            }
            if shell.pane(for: runtime.sessionID).panelTabs.contains(where: { $0.id == runtime.id }) {
                shell.removePanelTab(runtime.id, in: runtime.sessionID)
            } else {
                shell.removeShellTab(runtime.id, in: runtime.sessionID)
            }
            retire(runtime, terminate: false)
        }
        if signalled > 0 { log("stopped tabs count=\(signalled)") }
        return signalled
    }

    /// App quit: connections close, holders keep running.
    func shutdown() {
        stopRunningPoll()
        for runtime in tabs.values { runtime.connection?.close() }
    }

    // MARK: - Running lamps (D25)

    /// Starts the 1 Hz poll while the window shows and some shell could run a job; stops it
    /// otherwise (a closed window or a CODD without shells has no timer).
    func updateRunningPoll() {
        let wanted = isReady && !isWindowOccluded && hasRunningCandidates
        if wanted, runningTimer == nil {
            let timer = Timer(timeInterval: Self.runningPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollRunning() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            runningTimer = timer
            pollRunning()
        } else if !wanted {
            stopRunningPoll()
        }
    }

    private func stopRunningPoll() {
        runningTimer?.invalidate()
        runningTimer = nil
    }

    var isRunningPollActive: Bool { runningTimer != nil }

    /// Shell tabs (strip and panel) and SHELL sessions whose holder may run.
    private var hasRunningCandidates: Bool {
        if tabs.values.contains(where: { $0.holderAlive || $0.connection != nil }) { return true }
        return store.sessionsByID.values.contains { session in
            guard session.kind == .shell, let connection = store.connection(for: session.id) else { return false }
            return connection.phase != .ended && connection.phase != .closed
        }
    }

    /// Reads the shown session's shells' `kinfo_proc` once (a sysctl each, main actor; a few µs
    /// per shell) and publishes the running set when it changed. Only the shown session's strip
    /// and panel draw lamps, so other sessions' shells are not read (review concurrency-perf-6);
    /// switching sessions polls again at once (`currentSessionLoop`).
    func pollRunning() {
        let start = ContinuousClock.now
        var running = Set<String>()
        var polled = 0
        let current = shell.currentSessionID
        for runtime in tabs.values where runtime.sessionID == current && runtime.connection?.exitInfo == nil {
            guard runtime.holderAlive || runtime.connection?.phase == .connected, let pid = runtime.childPid else { continue }
            polled += 1
            let holder = runtime.connection?.welcome?.holderPid ?? runtime.holderPid
            if ForegroundJob.isRunning(childPid: pid, holderPid: holder) { running.insert(runtime.id) }
        }
        for session in store.sessionsByID.values where session.id == current && session.kind == .shell && session.state.isLive {
            guard let connection = store.connection(for: session.id), connection.exitInfo == nil,
                  let welcome = connection.welcome, welcome.childPid > 0 else { continue }
            polled += 1
            let holder = welcome.holderPid ?? store.runtime(session.id)?.holderPid
            if ForegroundJob.isRunning(childPid: welcome.childPid, holderPid: holder) { running.insert(session.id) }
        }
        shell.setRunning(running)
        lastRunningPoll = (polled, ContinuousClock.now - start)
        if !hasRunningCandidates { stopRunningPoll() }
    }

    /// The holder of a shell or panel tab (state dump), when known.
    func tabHolderPid(_ tabID: String) -> pid_t? {
        guard let runtime = tabs[tabID] else { return nil }
        return runtime.connection?.welcome?.holderPid ?? runtime.holderPid
    }

    /// `ShellTabJobProbe`: closing a terminal asks first while this is true, i.e. the tab's shell
    /// runs a foreground job (the running lamp's rule, read now rather than at the last 1 Hz
    /// poll). A tab that never started, or whose shell ended, runs nothing.
    func runsForegroundJob(tabID: String) -> Bool {
        guard let runtime = tabs[tabID], runtime.connection?.exitInfo == nil,
              runtime.holderAlive || runtime.connection?.phase == .connected, let pid = runtime.childPid else { return false }
        return ForegroundJob.isRunning(childPid: pid, holderPid: runtime.connection?.welcome?.holderPid ?? runtime.holderPid)
    }

    // MARK: - Debug

    /// The visible text of what `slot` shows (parsed first), for `-codd-dump-terminal`.
    func viewportText(_ slot: TerminalSlot) -> String? {
        guard let key = slotKeys[slot], let engine = pool.engine(for: key) else { return nil }
        let parsed = engine.waitUntilParsed()
        let connection = connection(for: key)
        log("dump slot=\(slot) key=\(key) surface=\(engine.hasSurface) parsed=\(parsed) grid=\(engine.gridSize?.description ?? "-") "
            + "frame=\(engine.view.frame.size) hidden=\(engine.view.isHidden) window=\(engine.view.window != nil) "
            + "phase=\(connection.map { "\($0.phase)" } ?? "-") streaming=\(connection?.isStreaming ?? false)")
        return engine.readViewportText()
    }

    /// Whether `slot`'s terminal is connected and its replay started (debug input waits for it).
    func isStreaming(_ slot: TerminalSlot) -> Bool {
        guard let key = slotKeys[slot], let connection = connection(for: key) else { return false }
        return connection.phase == .connected && connection.isStreaming
    }

    func tier(of target: TerminalTarget) -> TerminalTier { pool.tier(of: TerminalKey(target)) }

    /// The engine `target` has right now, if any (tests).
    func engine(for target: TerminalTarget) -> TerminalEngine? { pool.engine(for: TerminalKey(target)) }

    /// Held for startup probes (see `prepare`).
    func isPinned(_ target: TerminalTarget) -> Bool { pinTimers[TerminalKey(target)] != nil }
}

extension BellKey {
    init(_ key: TerminalKey) {
        self.init(sessionID: key.sessionID, tabID: key.tabID)
    }
}
