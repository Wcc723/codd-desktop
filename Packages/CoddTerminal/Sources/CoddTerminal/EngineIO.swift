import Foundation
internal import GhosttyWrapper
import Synchronization

/// Grid size the terminal reports for the PTY (`TIOCSWINSZ` / holder RESIZE).
public struct TerminalResize: Sendable, Equatable, CustomStringConvertible {
    public var columns: Int
    public var rows: Int
    /// Device pixels (the backing scale is applied), as libghostty reports them; what `CSI 14 t`
    /// and kitty graphics expect in `ws_xpixel` / `ws_ypixel`.
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var description: String {
        "\(columns)×\(rows)"
    }
}

/// The thread-crossing half of a `TerminalEngine`: the session bytes are fed to, and the sink the
/// surface's replies and keys go out through. Everything here is safe from any thread.
///
/// The write sink runs on libghostty's IO thread (one per surface). It delivers under its lock so
/// bytes reach `onWrite` in the order libghostty produced them even while the handler is being
/// replaced; a handler must therefore not set a new handler on the same engine from inside itself.
final class EngineIO: Sendable {
    /// Something that happened off the main thread and is delivered to the engine on the main queue.
    enum Event: Sendable {
        case deviceAttributesReplyWritten(generation: Int)
        case resized
    }

    private struct Sink {
        var onWrite: (@Sendable ([UInt8]) -> Void)?
        /// Bytes produced before a handler was set (keys typed or replies generated while the
        /// owner was still connecting its stream), delivered when one is set.
        var pending: [UInt8] = []
        var inputEnabled = true
        var detector = DeviceAttributesReplyDetector()
        var deviceAttributesWritten = false
        /// Bumped for every new process; a stale DA1 notification is ignored.
        var generation = 0
    }

    private struct Backlog {
        var highWater: Int
        var lowWater: Int
        var handler: @Sendable (Bool) -> Void
    }

    private struct ResizeState {
        var latest: TerminalResize?
        var deliveryScheduled = false
    }

    /// Bound on bytes held while no write handler is set.
    static let pendingWriteLimit = 64 * 1024

    private let sink = Mutex(Sink())
    private let currentSession = Mutex<InMemoryTerminalSession?>(nil)
    private let clipboardFilter = Mutex(ReplayClipboardFilter())
    private let backlog = Mutex<Backlog?>(nil)
    private let resize = Mutex(ResizeState())
    private let events = Mutex<(@Sendable (Event) -> Void)?>(nil)

    // MARK: - Session

    var session: InMemoryTerminalSession? {
        currentSession.withLock { $0 }
    }

    /// A new session for a new surface, wired to this sink. The backlog handler carries over.
    func makeSession() -> InMemoryTerminalSession {
        let session = InMemoryTerminalSession(
            write: { [self] data in handleWrite(data) },
            resize: { [self] viewport in handleResize(viewport) }
        )
        if let backlog = backlog.withLock({ $0 }) {
            session.setOutputBacklogHandler(
                highWater: backlog.highWater, lowWater: backlog.lowWater, backlog.handler
            )
        }
        let previous = currentSession.withLock { current -> InMemoryTerminalSession? in
            defer { current = session }
            return current
        }
        previous?.setOutputBacklogHandler(highWater: 1, lowWater: 0, nil)
        resetClipboardFilter()
        return session
    }

    // MARK: - Replayed clipboard writes

    /// Replayed bytes without OSC 52 (nil: unchanged). See `ReplayClipboardFilter`.
    func filterReplay(_ bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        clipboardFilter.withLock { $0.filterReplay(bytes) }
    }

    /// Live bytes, filtered only while a sequence the replay ended in is unfinished.
    func filterLive(_ bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        clipboardFilter.withLock { $0.isIdle ? nil : $0.filterLive(bytes) }
    }

    func resetClipboardFilter() {
        clipboardFilter.withLock { $0.reset() }
    }

    /// Stops routing bytes anywhere (dispose). The backlog handler goes too: a disposed engine
    /// must not keep its owner's closures (they hold the owner, which holds the engine).
    func detachSession() {
        let previous = currentSession.withLock { current -> InMemoryTerminalSession? in
            defer { current = nil }
            return current
        }
        backlog.withLock { $0 = nil }
        previous?.setOutputBacklogHandler(highWater: 1, lowWater: 0, nil)
        sink.withLock { state in
            state.onWrite = nil
            state.pending = []
            state.inputEnabled = false
        }
        events.withLock { $0 = nil }
    }

    func setBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {
        precondition(lowWater < highWater, "lowWater must be below highWater")
        backlog.withLock { state in
            state = handler.map { Backlog(highWater: highWater, lowWater: lowWater, handler: $0) }
        }
        session?.setOutputBacklogHandler(highWater: highWater, lowWater: lowWater, handler)
    }

    // MARK: - Write sink

    func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        events.withLock { $0 = handler }
    }

    func setWriteHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        var notify: Int?
        sink.withLock { state in
            state.onWrite = handler
            guard let handler, !state.pending.isEmpty else { return }
            let bytes = state.pending
            state.pending = []
            notify = Self.deliver(bytes, to: handler, state: &state)
        }
        if let notify { post(.deviceAttributesReplyWritten(generation: notify)) }
    }

    var writeHandler: (@Sendable ([UInt8]) -> Void)? {
        sink.withLock { $0.onWrite }
    }

    /// From libghostty's IO thread: keys, pastes and query replies for the program.
    func handleWrite(_ data: Data) {
        guard !data.isEmpty else { return }
        var notify: Int?
        sink.withLock { state in
            guard state.inputEnabled else { return }
            guard let handler = state.onWrite else {
                let room = Self.pendingWriteLimit - state.pending.count
                if room > 0 { state.pending.append(contentsOf: data.prefix(room)) }
                return
            }
            notify = Self.deliver(Array(data), to: handler, state: &state)
        }
        if let notify { post(.deviceAttributesReplyWritten(generation: notify)) }
    }

    /// Hands `bytes` to the handler and returns the generation to report when they completed the
    /// first DA1 reply of this process.
    private static func deliver(
        _ bytes: [UInt8], to handler: @Sendable ([UInt8]) -> Void, state: inout Sink
    ) -> Int? {
        handler(bytes)
        guard !state.deviceAttributesWritten, state.detector.consume(bytes) else { return nil }
        state.deviceAttributesWritten = true
        return state.generation
    }

    /// The child exited (false) or a new one starts (true).
    func setInputEnabled(_ enabled: Bool) {
        sink.withLock { state in
            state.inputEnabled = enabled
            if !enabled { state.pending = [] }
        }
    }

    /// A new process starts: input flows again and its first DA1 reply is reported again.
    func beginGeneration() -> Int {
        sink.withLock { state in
            state.generation += 1
            state.inputEnabled = true
            state.pending = []
            state.detector.reset()
            state.deviceAttributesWritten = false
            return state.generation
        }
    }

    var generation: Int {
        sink.withLock { $0.generation }
    }

    var deviceAttributesWritten: Bool {
        sink.withLock { $0.deviceAttributesWritten }
    }

    // MARK: - Resize

    /// From libghostty's IO thread, right before the grid reflows. Coalesced: the main queue gets
    /// one delivery for any number of sizes reported before it runs, carrying the latest.
    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        let size = TerminalResize(
            columns: Int(viewport.columns),
            rows: Int(viewport.rows),
            pixelWidth: Int(viewport.widthPixels),
            pixelHeight: Int(viewport.heightPixels)
        )
        let schedule = resize.withLock { state -> Bool in
            state.latest = size
            guard !state.deliveryScheduled else { return false }
            state.deliveryScheduled = true
            return true
        }
        if schedule { post(.resized) }
    }

    func takeLatestResize() -> TerminalResize? {
        resize.withLock { state in
            state.deliveryScheduled = false
            return state.latest
        }
    }

    private func post(_ event: Event) {
        events.withLock { $0 }?(event)
    }
}
