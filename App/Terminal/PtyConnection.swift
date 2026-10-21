import CoddHolderClient
import CoddProtocol
import CoddTerminal
import Foundation
import Synchronization

/// What a PTY connection reports to its owner, on the main actor, in wire order.
enum PtyEvent: Sendable, Equatable {
    case welcome(Welcome)
    case title(String)
    case cwd(String)
    case bell
    /// The child exited (at most once per process; after all of its output).
    case exit(ExitInfo)
    /// D8: the holder runs (meta.json says so) but connects or handshakes have failed for
    /// `PtyConnectionTuning.unreachableAfter` (true, once per outage), or it answered again (false,
    /// right before the next `.welcome`). A connection that ends reports `.ended` instead.
    case unreachable(Bool)
    /// The connection is over for good: no reconnect follows.
    case ended(PtyEnding)
}

/// Timings of a `PtyConnection`: the holder stream's keepalive and handshake limits, the
/// reconnect backoff and when a silent live holder counts as UNREACHABLE. DEBUG
/// `-codd-keepalive <idleMs>,<timeoutMs>` and `-codd-unreachable-after <s>` set them for every
/// connection of a run (sessions and shell tabs); tests shorten them.
struct PtyConnectionTuning: Sendable, Equatable {
    var stream = HolderStreamOptions()
    /// Reconnects (or one handshake) failing this long while the holder runs: UNREACHABLE.
    var unreachableAfter: Duration = .seconds(5)
    /// Delays between reconnect attempts while the holder is alive.
    var reconnectDelays: [Duration] = Self.defaultReconnectDelays
    /// Once `reconnectDelays` are spent: a holder that meta.json says runs is tried this often
    /// (the UNREACHABLE banner says 每 10 秒重試一次).
    var slowReconnectDelay: Duration = .seconds(10)

    static let defaultReconnectDelays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500), .seconds(1),
                                                     .seconds(2), .seconds(4)]
}

enum PtyEnding: Sendable, Equatable, CustomStringConvertible {
    /// Another client (a second CODD on the same data root) took the holder over.
    case takenOver
    /// The holder is not running any more (killed, crashed, or it lingered out after the exit,
    /// which `exit` then carries).
    case holderGone(exit: ExitInfo?)
    /// Refused in a way a reconnect cannot fix (unsupported protocol, holder never answering).
    case failed(String)

    var description: String {
        switch self {
        case .takenOver: "taken over by another client"
        case .holderGone(let exit): exit.map { "holder gone after exit \($0.status)" } ?? "holder gone"
        case .failed(let reason): reason
        }
    }
}

/// One PTY's holder connection (a session's own PTY or a shell tab) and the terminal engine its
/// output feeds, if any.
///
/// The `HolderStream` is the only client of its holder (HELLO with takeover). Without an engine it
/// stays a control connection (no ATTACH: title, cwd, bell and exit still arrive); attaching an
/// engine replays from the latest resync point, detaching (the tab went cold) sends DETACH.
/// OUTPUT goes from the stream's queue straight into the engine (`PtySink`): terminal bytes never
/// reach the main actor. When the connection drops without an exit it reconnects with backoff
/// while meta.json says the holder still runs (slowly, but never giving up, once the backoff is
/// spent), and reports `.ended` otherwise. Reconnects ask without takeover: a close nobody
/// explained may be another client that took the holder over (its ERROR can be lost when this
/// side stopped reading), and taking it back would start a fight that never ends. Keys typed
/// while reconnecting are held (bounded) and sent once the new connection is up.
@MainActor
final class PtyConnection {
    enum Phase: Equatable {
        case idle, connecting, connected, reconnecting, ended, closed
    }

    let sessionID: String
    let socketPath: String
    /// The holder's `--dir` (meta.json, ring).
    let directory: String
    var onEvent: ((PtyEvent) -> Void)?

    private(set) var phase = Phase.idle
    private(set) var welcome: Welcome?
    private(set) var exitInfo: ExitInfo?
    private(set) var engine: TerminalEngine?
    /// Why the connection ended (`phase == .ended`): the hub replays the ring of a gone holder.
    private(set) var ending: PtyEnding?
    /// `.unreachable(true)` was reported and no WELCOME followed yet.
    private(set) var isUnreachable = false
    /// Wall-clock start of the outage while `isUnreachable` (the row counts `holder 無回應 · 30s` from it).
    var unreachableSince: Date? { isUnreachable ? failingSinceDate : nil }
    /// The engine has received the start of an attach (its replay is flowing).
    var isStreaming: Bool { sink.isAttached }
    /// The engine's unparsed backlog has the stream paused (tests, diagnostics).
    var isBacklogged: Bool { sink.isBacklogged }

    private var stream: HolderStream?
    private let sink = PtySink()
    private var generation = 0
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    /// HELLO asks for takeover: a connect the app asked for (launch, spawn, a tab shown), not a
    /// reconnect.
    private var takeoverOnOpen = true
    /// `busy` answers to reconnects since the last WELCOME.
    private var busyRetries = 0
    /// When the current connection's WELCOME arrived: the backoff starts over only after a
    /// connection that held (a holder that accepts and drops at once must not reconnect at 10 Hz).
    private var welcomedAt: ContinuousClock.Instant?
    /// Set by `connect(freshSpawn: true)`: until 3 s after it, the first replay is fed live.
    private var spawnedAt: ContinuousClock.Instant?
    /// Start of the current run of connects without a WELCOME (the drop, or the first attempt).
    private var failingSince: ContinuousClock.Instant?
    private var failingSinceDate: Date?
    private var unreachableTask: Task<Void, Never>?
    let tuning: PtyConnectionTuning
    private let log: @MainActor (String) -> Void

    static let clientName = "CODD/0.1"
    /// Unparsed bytes in the engine above which the stream stops reading (and below which it
    /// reads again): bounds what a reattach replay or a flood queues in memory.
    static let backlogHighWater = 4 << 20
    static let backlogLowWater = 1 << 20
    /// How long after a spawn the first replay still counts as unanswered startup output.
    static let freshSpawnWindow: Duration = .seconds(3)
    /// A connection that stayed up this long resets the backoff.
    static let stableConnection: Duration = .seconds(5)
    /// A reconnect answered `busy` is tried once more after this (our own previous connection
    /// may not have been noticed gone yet).
    static let busyRetryDelay: Duration = .milliseconds(500)

    init(sessionID: String, socketPath: String, directory: String, tuning: PtyConnectionTuning = PtyConnectionTuning(),
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.sessionID = sessionID
        self.socketPath = socketPath
        self.directory = directory
        self.tuning = tuning
        self.log = log
    }

    // MARK: - Lifecycle

    /// Connects (takeover) unless already connected. `freshSpawn`: this app just started the
    /// holder, so nobody answered the child's startup queries yet; the first replay is fed live
    /// (replies on) as long as it starts within 3 s.
    func connect(freshSpawn: Bool = false) {
        if freshSpawn { spawnedAt = .now }
        guard phase == .idle || phase == .reconnecting, stream == nil else { return }
        if phase == .idle { takeoverOnOpen = true }
        open()
    }

    /// A new process in the same holder directory (RESTART / RESUME): the engine gets a fresh
    /// surface and the connection starts over against the new holder.
    func restartedProcess() {
        reconnectTask?.cancel()
        reconnectTask = nil
        clearOutage()
        ending = nil
        generation += 1
        stream?.close()
        stream = nil
        sink.setStream(nil)
        welcome = nil
        exitInfo = nil
        reconnectAttempt = 0
        sink.holdInput(false)
        phase = .idle
        engine?.rebuildForNewProcess()
        // The old process's backlog (if any) is gone with its session; the new one starts empty.
        sink.clearBacklog()
        sink.forgetPosition()
        connect(freshSpawn: true)
    }

    /// Lets go of the holder without reporting anything (RESUME / RESTART end the old holder
    /// before the new one starts in the same directory; its close must not look like a crash).
    /// `restartedProcess()` connects again once the new holder is up.
    func quiesce() {
        reconnectTask?.cancel()
        reconnectTask = nil
        clearOutage()
        ending = nil
        generation += 1
        stream?.close()
        stream = nil
        sink.setStream(nil)
        sink.holdInput(false)
        if phase != .closed { phase = .idle }
    }

    /// Closes for good (app quit, tab closed). The holder keeps running; nothing is reported.
    func close() {
        reconnectTask?.cancel()
        reconnectTask = nil
        clearOutage()
        generation += 1
        stream?.close()
        stream = nil
        sink.setStream(nil)
        sink.holdInput(false)
        phase = .closed
    }

    private func open() {
        generation += 1
        let generation = self.generation
        phase = .connecting
        noteFailing()
        let stream: HolderStream
        do {
            stream = try HolderStream(socketPath: socketPath, clientName: Self.clientName, options: tuning.stream)
        } catch {
            log("connect failed session=\(sessionID) \(error)")
            streamClosed(generation, reason: nil)
            return
        }
        wire(stream, generation: generation)
        self.stream = stream
        sink.setStream(stream)
        let point: AttachPoint
        if engine != nil {
            point = sink.resumeOffset.map(AttachPoint.offset) ?? .latestResync
            sink.prepareAttach(replayIsLive: isFresh)
        } else {
            point = .noAttach
        }
        stream.start(takeover: takeoverOnOpen, attachFrom: point)
    }

    private var isFresh: Bool {
        guard let spawnedAt else { return false }
        return ContinuousClock.now - spawnedAt < Self.freshSpawnWindow
    }

    /// `[↻ 立即重試]` (D8): skips the backoff, or gives up a handshake that hangs (a stopped
    /// holder never answers HELLO), and connects now. Nothing happens while connected or ended.
    func retryNow() {
        switch phase {
        case .reconnecting:
            reconnectTask?.cancel()
            reconnectTask = nil
            guard stream == nil else { return }
            log("reconnect session=\(sessionID) now")
            open()
        case .connecting:
            stream?.close()
            stream = nil
            sink.setStream(nil)
            log("reconnect session=\(sessionID) now (handshake pending)")
            open()  // the new generation ignores the old stream's close
        case .idle, .connected, .ended, .closed:
            break
        }
    }

    // MARK: - UNREACHABLE

    /// A connect attempt or a drop: the outage clock starts unless it already runs.
    private func noteFailing() {
        guard failingSince == nil else { return }
        let since = ContinuousClock.now
        failingSince = since
        failingSinceDate = Date()
        let directory = self.directory
        let delay = tuning.unreachableAfter
        unreachableTask?.cancel()
        unreachableTask = Task { [weak self] in
            try? await Task.sleep(until: since + delay, clock: .continuous)
            guard let self, self.isStillFailing(since) else { return }
            // Only a holder that meta.json says runs is unreachable; a gone one is about to end.
            let status = await Task.detached(priority: .utility) { Self.holderStatus(directory: directory) }.value
            guard self.isStillFailing(since), case .alive = status else { return }
            self.isUnreachable = true
            self.log("unreachable session=\(self.sessionID) after=\(delay)")
            self.onEvent?(.unreachable(true))
        }
    }

    private func isStillFailing(_ since: ContinuousClock.Instant) -> Bool {
        !Task.isCancelled && failingSince == since && !isUnreachable && (phase == .connecting || phase == .reconnecting)
    }

    /// The outage is over (WELCOME) or no longer this connection's business (closed, ended,
    /// a new process). Reports nothing.
    private func clearOutage() {
        unreachableTask?.cancel()
        unreachableTask = nil
        failingSince = nil
        failingSinceDate = nil
        isUnreachable = false
    }

    // MARK: - Engine

    /// Feeds this PTY into `engine` from now on: replays from the latest resync point (an engine
    /// that is attached again after a reconnect continues where it stopped).
    func attach(_ engine: TerminalEngine) {
        guard self.engine !== engine else { return }
        if self.engine != nil { detachEngine() }
        self.engine = engine
        let sink = self.sink
        sink.setEngine(engine)
        engine.onWrite = { bytes in sink.write(bytes) }
        engine.setOutputBacklogHandler(highWater: Self.backlogHighWater, lowWater: Self.backlogLowWater) { [weak engine] backlogged in
            sink.setBacklogged(backlogged, from: engine)
        }
        if let exitInfo { engine.childExited(status: exitInfo.status) }
        switch phase {
        case .connecting, .connected:
            sink.prepareAttach(replayIsLive: isFresh)
            stream?.attach(from: .latestResync)
        case .idle, .reconnecting, .ended, .closed:
            // connect() attaches it; an ended connection has nothing to stream (the hub replays
            // the ring of a gone holder or writes its note).
            break
        }
    }

    /// Stops feeding the engine (it went cold or is being disposed). The connection stays.
    func detachEngine() {
        guard let engine else { return }
        if phase == .connecting || phase == .connected { stream?.detach() }
        // Also resumes the stream: nothing parses for it any more, so it must not stay paused for
        // that engine (a late crossing from it is ignored).
        sink.setEngine(nil)
        engine.onWrite = nil
        engine.setOutputBacklogHandler(highWater: Self.backlogHighWater, lowWater: Self.backlogLowWater, nil)
        self.engine = nil
    }

    // MARK: - Sending

    /// Queues INPUT (held while reconnecting, sent once connected again, with its flags). False
    /// when there is no connection to send it on, the holder is not reading, or too much is held
    /// already. `paste` asks the holder to bracket the bytes as one paste (`input.paste`, D1).
    @discardableResult
    func send(_ bytes: [UInt8], submit: Bool = false, paste: Bool = false) -> Bool {
        if phase == .reconnecting, stream == nil {
            return sink.hold(bytes, submit: submit, paste: paste)
        }
        guard let stream, phase == .connected || phase == .connecting else { return false }
        do {
            try stream.sendInput(bytes, submit: submit, paste: paste)
            return true
        } catch {
            log("input dropped session=\(sessionID) \(error)")
            return false
        }
    }

    func resize(_ size: TerminalResize) {
        guard let stream, size.columns > 0, size.rows > 0 else { return }
        stream.resize(Self.windowSize(size))
    }

    static func windowSize(_ size: TerminalResize) -> WindowSize {
        func clamp(_ value: Int) -> UInt16 { UInt16(clamping: max(0, value)) }
        return WindowSize(cols: clamp(size.columns), rows: clamp(size.rows), pixelWidth: clamp(size.pixelWidth),
                          pixelHeight: clamp(size.pixelHeight))
    }

    // MARK: - Stream callbacks

    private func wire(_ stream: HolderStream, generation: Int) {
        let sink = self.sink
        stream.onWelcome = { [weak self] welcome in
            Self.onMain { self?.didWelcome(welcome, generation: generation) }
        }
        stream.onAttach = { [weak self] attach in
            sink.didAttach(attach)
            Self.onMain { self?.didAttach(attach, generation: generation) }
        }
        stream.onOutput = { offset, bytes, phase in
            sink.output(offset, bytes, phase)
        }
        stream.onGap = { [weak self] gap in
            sink.gap(gap)
            Self.onMain { self?.log("gap session=\(self?.sessionID ?? "?") from=\(gap.from) to=\(gap.to)") }
        }
        // Latest wins, one main-queue hop at a time: a program printing OSC titles in a loop sent
        // one TITLE per PTY read and saturated the main thread (review F3). The holder reports
        // only changes, so nothing but intermediate values is lost.
        let titles = LatestValueRelay<String>()
        stream.onTitle = { [weak self] title in
            guard titles.store(title) else { return }
            Self.onMain {
                guard let title = titles.take() else { return }
                self?.report(.title(title), generation: generation)
            }
        }
        let directories = LatestValueRelay<String>()
        stream.onCwd = { [weak self] cwd in
            guard directories.store(cwd) else { return }
            Self.onMain {
                guard let cwd = directories.take() else { return }
                self?.report(.cwd(cwd), generation: generation)
            }
        }
        stream.onBell = { [weak self] in Self.onMain { self?.report(.bell, generation: generation) } }
        stream.onExit = { [weak self] info in Self.onMain { self?.didExit(info, generation: generation) } }
        stream.onError = { [weak self] info in
            Self.onMain { self?.log("holder error session=\(self?.sessionID ?? "?") \(info)") }
        }
        stream.onClosed = { [weak self] reason in Self.onMain { self?.streamClosed(generation, reason: reason) } }
    }

    /// Stream callbacks hop here in the order they ran.
    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    private func report(_ event: PtyEvent, generation: Int) {
        guard generation == self.generation else { return }
        onEvent?(event)
    }

    private func didWelcome(_ welcome: Welcome, generation: Int) {
        guard generation == self.generation else { return }
        self.welcome = welcome
        phase = .connected
        welcomedAt = .now
        busyRetries = 0
        let wasUnreachable = isUnreachable
        clearOutage()
        if wasUnreachable {
            log("reachable session=\(sessionID)")
            onEvent?(.unreachable(false))
        }
        onEvent?(.welcome(welcome))
    }

    private func didAttach(_ attach: HolderAttach, generation: Int) {
        guard generation == self.generation, let stream, let engine else { return }
        if let grid = engine.gridSize { stream.resize(Self.windowSize(grid)) }
        // A full-screen program in the replay was drawn for whatever size it had then; make it
        // redraw for this terminal. What the replay ends in decides (it may start on the main
        // screen before the program); a holder without `attach.modes` only says where it starts.
        let altScreen = attach.currentModes?.altScreen ?? attach.modes?.altScreen ?? welcome?.modes.altScreen ?? false
        if altScreen, attach.requested == .latestResync, exitInfo == nil {
            stream.repaint()
            log("repaint session=\(sessionID)")
        }
    }

    private func didExit(_ info: ExitInfo, generation: Int) {
        guard generation == self.generation, exitInfo == nil else { return }
        exitInfo = info
        engine?.childExited(status: info.status)
        onEvent?(.exit(info))
    }

    /// `reason` nil: the connect itself failed.
    private func streamClosed(_ generation: Int, reason: HolderStreamCloseReason?) {
        guard generation == self.generation else { return }
        stream = nil
        sink.setStream(nil)
        if let reason { log("closed session=\(sessionID) reason=\(reason)") }
        switch reason {
        case .closedLocally?:
            if phase != .closed { phase = .idle }
        case .holderError(let info)? where info.code == HolderErrorCode.takenOver:
            end(.takenOver)
        case .holderError(let info)? where info.code == HolderErrorCode.busy:
            // Asked without takeover and refused: another client holds the holder. Our own
            // previous connection may still count as attached for a moment, so once more first.
            if !takeoverOnOpen, busyRetries < 1 {
                busyRetries += 1
                phase = .reconnecting
                reopen(after: Self.busyRetryDelay)
            } else {
                end(.takenOver)
            }
        case .holderError(let info)? where info.code == HolderErrorCode.unsupportedProto:
            end(.failed(info.description))
        default:
            if let welcomedAt, ContinuousClock.now - welcomedAt >= Self.stableConnection { reconnectAttempt = 0 }
            welcomedAt = nil
            takeoverOnOpen = false
            phase = .reconnecting
            noteFailing()
            sink.holdInput(true)
            checkHolder()
        }
    }

    private func reopen(after delay: Duration) {
        let generation = self.generation
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, generation == self.generation, self.phase == .reconnecting else { return }
            self.log("reconnect session=\(self.sessionID) after busy")
            self.open()
        }
    }

    /// Reads meta.json off the main actor: reconnect while the holder runs, else end.
    private func checkHolder() {
        let directory = self.directory
        let generation = self.generation
        reconnectTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) { Self.holderStatus(directory: directory) }.value
            guard let self, generation == self.generation, self.phase == .reconnecting else { return }
            switch status {
            case .alive:
                // Spent backoff: keep trying slowly. The holder runs (stopped, briefly unable to
                // re-bind its socket, ...); ending here showed a running session as STOPPED for
                // the rest of the run, and RESUME then killed it (review finding).
                let attempt = self.reconnectAttempt
                let delays = self.tuning.reconnectDelays
                if attempt == delays.count {
                    self.log("holder unreachable session=\(self.sessionID), retrying every \(self.tuning.slowReconnectDelay)")
                }
                let delay = attempt < delays.count ? delays[attempt] : self.tuning.slowReconnectDelay
                self.reconnectAttempt += 1
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, generation == self.generation, self.phase == .reconnecting else { return }
                self.log("reconnect session=\(self.sessionID) attempt=\(self.reconnectAttempt)")
                self.open()
            case .gone(let exit):
                self.end(.holderGone(exit: self.exitInfo ?? exit))
            }
        }
    }

    private func end(_ ending: PtyEnding) {
        phase = .ended
        self.ending = ending
        reconnectTask = nil
        clearOutage()
        sink.holdInput(false)
        if case .holderGone(let exit?) = ending, exitInfo == nil {
            exitInfo = exit
            engine?.childExited(status: exit.status)
        }
        onEvent?(.ended(ending))
    }

    enum HolderStatus: Sendable {
        case alive
        case gone(ExitInfo?)
    }

    /// Blocking file read: call off the main actor.
    nonisolated static func holderStatus(directory: String) -> HolderStatus {
        guard let meta = SessionDirectory.readMeta(directory: directory) else { return .gone(nil) }
        let exit = meta.exited ? ExitInfo(status: meta.exitStatus ?? 0, signaled: meta.signaled ?? false) : nil
        if exit == nil, SessionDirectory.isLive(meta) { return .alive }
        return .gone(exit)
    }
}

/// Hands the latest of a stream of values from one thread to another: `store` says whether the
/// caller must schedule a `take` (true only when none is pending), `take` returns the newest value
/// and re-arms. Any number of stores before the take cost one hop.
final class LatestValueRelay<Value: Sendable>: Sendable {
    private struct Slot {
        var value: Value?
        var scheduled = false
    }

    private let slot = Mutex(Slot())

    func store(_ value: Value) -> Bool {
        slot.withLock { slot in
            slot.value = value
            guard !slot.scheduled else { return false }
            slot.scheduled = true
            return true
        }
    }

    func take() -> Value? {
        slot.withLock { slot in
            slot.scheduled = false
            defer { slot.value = nil }
            return slot.value
        }
    }
}

/// The thread-crossing half of a `PtyConnection`: which engine and stream the bytes go to. The
/// stream's queue feeds the engine here; libghostty's IO thread sends keys and replies here.
final class PtySink: Sendable {
    private struct State {
        var engine: TerminalEngine?
        var stream: HolderStream?
        /// Offset after the last byte the engine received (an engine that stays alive across a
        /// reconnect continues from it).
        var nextOffset: UInt64?
        /// Feed replayed bytes live (fresh spawn: the child's startup queries are unanswered).
        var replayIsLive = false
        var attached = false
        var backlogged = false
        /// Reconnecting: input without a stream is held instead of dropped.
        var holdsInput = false
        var heldInput: [HeldInput] = []
        var heldBytes = 0
    }

    /// Input waiting for the next stream, with the flags it was sent with.
    struct HeldInput: Equatable, Sendable {
        var bytes: [UInt8]
        var submit: Bool
        var paste: Bool
    }

    /// Bound on input held while reconnecting: one composer send (256 KiB, D2) plus typing; more
    /// is dropped.
    static let heldInputLimit = 320 * 1024

    private let state = Mutex(State())

    var resumeOffset: UInt64? { state.withLock { $0.nextOffset } }
    var isAttached: Bool { state.withLock { $0.attached } }

    /// A new engine (or none) starts unbacklogged: its own handler reports a crossing.
    func setEngine(_ engine: TerminalEngine?) {
        state.withLock { state in
            state.engine = engine
            state.nextOffset = nil
            state.replayIsLive = false
            state.attached = false
            Self.apply(false, to: &state)
        }
    }

    /// Pause and resume are applied under the lock, in the order the state changed: a reconnect
    /// racing a backlog crossing can never leave a stream paused for a state that already ended.
    func setStream(_ stream: HolderStream?) {
        state.withLock { state in
            state.stream = stream
            if stream == nil { state.attached = false }
            if state.backlogged { stream?.pauseReading() }
            guard let stream, !state.heldInput.isEmpty else { return }
            // Queued before `start`: sent right behind HELLO, ahead of anything typed later.
            for input in state.heldInput { try? stream.sendInput(input.bytes, submit: input.submit, paste: input.paste) }
            state.heldInput = []
            state.heldBytes = 0
        }
    }

    /// Reconnecting (true): input without a stream is held for the next one. False drops it.
    func holdInput(_ holds: Bool) {
        state.withLock { state in
            state.holdsInput = holds
            if !holds {
                state.heldInput = []
                state.heldBytes = 0
            }
        }
    }

    /// Holds input for the next stream; false when not reconnecting or over the bound.
    func hold(_ bytes: [UInt8], submit: Bool, paste: Bool = false) -> Bool {
        state.withLock { Self.hold(bytes, submit: submit, paste: paste, in: &$0) }
    }

    private static func hold(_ bytes: [UInt8], submit: Bool, paste: Bool, in state: inout State) -> Bool {
        guard state.holdsInput, state.heldBytes + bytes.count <= heldInputLimit else { return false }
        state.heldInput.append(HeldInput(bytes: bytes, submit: submit, paste: paste))
        state.heldBytes += bytes.count
        return true
    }

    var heldInputByteCount: Int { state.withLock { $0.heldBytes } }
    /// What is held right now, in order (tests).
    var heldInputs: [HeldInput] { state.withLock { $0.heldInput } }

    /// The engine started a new process (its old session and backlog are gone).
    func clearBacklog() {
        state.withLock { Self.apply(false, to: &$0) }
    }

    func forgetPosition() {
        state.withLock { $0.nextOffset = nil }
    }

    func prepareAttach(replayIsLive: Bool) {
        state.withLock { $0.replayIsLive = replayIsLive }
    }

    // MARK: Stream queue

    func didAttach(_ attach: HolderAttach) {
        let engine = state.withLock { state -> TerminalEngine? in
            state.nextOffset = attach.start
            state.attached = true
            return state.engine
        }
        guard let engine, attach.requested == .latestResync else { return }
        // A clean slate in the modes of the resync point, queued before its replay.
        engine.reset()
        if let restore = attach.modes?.restoreSequence(), !restore.isEmpty { engine.replay(restore) }
    }

    func output(_ offset: UInt64, _ bytes: UnsafeRawBufferPointer, _ phase: OutputPhase) {
        let (engine, live) = state.withLock { state -> (TerminalEngine?, Bool) in
            state.nextOffset = offset + UInt64(bytes.count)
            if phase == .live { state.replayIsLive = false }
            return (state.engine, phase == .live || state.replayIsLive)
        }
        guard let engine else { return }
        if live { engine.feed(bytes) } else { engine.replay(bytes) }
    }

    /// Bytes were lost: reset, restore the modes at the resync point, keep feeding.
    func gap(_ gap: GapInfo) {
        let engine = state.withLock { state -> TerminalEngine? in
            state.nextOffset = gap.to
            state.replayIsLive = false
            return state.engine
        }
        guard let engine else { return }
        engine.reset()
        if let restore = gap.resumeModes?.restoreSequence(), !restore.isEmpty { engine.replay(restore) }
    }

    // MARK: Engine side

    /// Keys, pastes and query replies (libghostty's IO thread). Held while reconnecting.
    func write(_ bytes: [UInt8]) {
        let stream = state.withLock { state -> HolderStream? in
            if let stream = state.stream { return stream }
            _ = Self.hold(bytes, submit: false, paste: false, in: &state)
            return nil
        }
        // A full outbound queue means the child stopped reading its input: nothing to do but drop.
        try? stream?.sendInput(bytes)
    }

    /// The engine's unparsed backlog crossed a mark: pause or resume reading the holder. Ignored
    /// unless `engine` is the one attached (a detached engine's last crossing may still arrive).
    /// The engine delivers crossings one at a time with the state current when each runs, and
    /// this applies them under the lock, so the stream's pause flag always ends at the engine's
    /// state (review F1: a stale `true` applied last used to freeze the terminal for good).
    func setBacklogged(_ backlogged: Bool, from engine: TerminalEngine?) {
        state.withLock { state in
            guard let engine, state.engine === engine else { return }
            Self.apply(backlogged, to: &state)
        }
    }

    var isBacklogged: Bool { state.withLock { $0.backlogged } }

    /// `pauseReading` / `resumeReading` only set a flag and queue a block: safe under the lock.
    private static func apply(_ backlogged: Bool, to state: inout State) {
        guard state.backlogged != backlogged else { return }
        state.backlogged = backlogged
        if backlogged { state.stream?.pauseReading() } else { state.stream?.resumeReading() }
    }
}
