import CoddPosix
import CoddProtocol
import Darwin
import Dispatch
import Synchronization

/// Data-plane client for one holder: a non-blocking AF_UNIX connection driven by dispatch sources
/// on a private serial queue (docs/ARCHITECTURE.md, "Holder wire protocol v1").
///
/// Every callback runs on `callbackQueue`, one at a time, in wire order, never on the main actor
/// (terminal bytes must not go through it). Set the callbacks before `start`, or later from any
/// thread (the setters are locked); a callback set later sees only what arrives after it.
///
/// Sequence a consumer sees:
/// - `onWelcome` once, then `onAttach` when the requested ATTACH took effect (again after every
///   `attach(from:)`). Reset the terminal on `onAttach` when replaying, then apply `modes`.
/// - `onOutput(offset, bytes, phase)` in stream order. `bytes` points into the stream's buffers
///   and is valid only during the call (feed or copy it). `.replay` bytes are history.
/// - `onGap` when the holder dropped bytes for a stalled client: reset the terminal, apply
///   `resumeModes`, keep feeding (OUTPUT continues at the resync point `to`).
/// - `onTitle` / `onCwd` / `onBell` at the stream position the child produced them.
/// - `onExit` at most once, after all OUTPUT up to the exit (see below).
/// - `onError` (an ERROR frame), then `onClosed` exactly once; nothing follows `onClosed`.
///
/// EXIT ordering: the holder sends EXIT immediately to a client that has not attached (yet), so
/// on the wire EXIT can precede the replay of an ATTACH processed after it, and a child that
/// exited before HELLO produces no EXIT frame at all (WELCOME says `exited`). The stream hides
/// both: while an attach is requested, `onExit` is held back until the replay reached the
/// session's final offset (`HolderAttach.replayEnd` of the attach that saw the exit). Without an
/// attach it fires right away, also when WELCOME reported the exit. A known exit that is still
/// held back when the connection ends is delivered just before `onClosed`.
///
/// Backpressure: `pauseReading()` stops delivering after the current frame and stops reading the
/// socket; the holder then pauses the child (over 1 MiB pending) and, after 500 ms without
/// progress, switches to drop mode and later sends GAP. `resumeReading()` continues.
///
/// Keep a strong reference while the stream is in use: dropping the last one closes the
/// connection without callbacks.
public final class HolderStream: Sendable {
    public let socketPath: String
    public let clientName: String
    public let options: HolderStreamOptions
    /// The private serial queue all callbacks run on.
    public let callbackQueue: DispatchQueue

    private let shared: StreamShared
    private let core: Mutex<StreamCore>

    /// PONG tokens with this bit set belong to the keepalive and are not reported to `onPong`.
    public static let keepaliveTokenBit: UInt64 = 1 << 63
    /// Numbers the queues (labels show up in crash logs and Instruments).
    private static let instances = Atomic<Int>(0)
    /// HELLO `caps` this client understands.
    public static let clientCapabilities = [HolderCapability.attachAck, HolderCapability.gapResync]

    /// Connects right away (a local connect never blocks), so a dead holder fails here. Nothing
    /// is sent until `start`.
    public init(socketPath: String, clientName: String, options: HolderStreamOptions = HolderStreamOptions()) throws(HolderStreamError) {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketPath)
            try Descriptor.setNonBlocking(fd)
        } catch {
            throw .connectFailed(error)
        }
        UnixSocket.setBufferSizes(fd, send: options.sendBufferBytes, receive: options.receiveBufferBytes)
        self.socketPath = socketPath
        self.clientName = clientName
        self.options = options
        let serial = Self.instances.add(1, ordering: .relaxed).newValue
        let queue = DispatchQueue(label: "app.codd.holder-stream.\(serial)", qos: options.qos)
        callbackQueue = queue
        let shared = StreamShared()
        self.shared = shared
        core = Mutex(StreamCore(fd: fd, queue: queue, shared: shared, options: options, clientName: clientName))
        core.withLock { $0.owner = self }
    }

    deinit {
        core.withLock { $0.finish(.closedLocally, notify: false) }
    }

    /// Runs `body` on the core; only ever called on `callbackQueue` (or from deinit).
    func withCore(_ body: (StreamCore) -> Void) {
        core.withLock { body($0) }
    }

    private func onQueue(_ body: @escaping @Sendable (StreamCore) -> Void) {
        callbackQueue.async { [weak self] in self?.withCore(body) }
    }

    // MARK: - Lifecycle

    /// Sends HELLO and, unless `.noAttach`, the ATTACH right behind it in the same write, so the
    /// holder processes both in one pass: WELCOME and the attach describe the same ring state.
    /// Calling it again has no effect.
    public func start(takeover: Bool, attachFrom: AttachPoint) {
        onQueue { $0.start(takeover: takeover, attach: attachFrom) }
    }

    /// Requests a new ATTACH on the open connection (`.noAttach` = DETACH); call it after `start`.
    /// From the moment it returns (also when called from a callback), no OUTPUT or GAP of the
    /// previous attach is delivered; `onAttach` marks where the new one starts.
    public func attach(from point: AttachPoint) {
        let request = shared.attachRequests.add(1, ordering: .acquiringAndReleasing).newValue
        onQueue { $0.requestAttach(point, request: request) }
    }

    /// Stops OUTPUT (DETACH); the connection stays open for control frames.
    public func detach() {
        attach(from: .noAttach)
    }

    /// Ends the connection; unsent frames are discarded. `onClosed(.closedLocally)` follows unless
    /// the stream had already ended. No other callback runs after this call returns, except a
    /// callback already running on the queue.
    public func close() {
        shared.closeRequested.store(true, ordering: .releasing)
        onQueue { $0.finish(.closedLocally, notify: true) }
    }

    /// True once the connection ended (or `close()` was called).
    public var isClosed: Bool {
        shared.finished.load(ordering: .acquiring) || shared.closeRequested.load(ordering: .acquiring)
    }

    // MARK: - Backpressure

    /// Stops delivering frames after the current one and stops reading the socket. Idempotent.
    public func pauseReading() {
        shared.paused.store(true, ordering: .releasing)
        onQueue { $0.syncReadState() }
    }

    /// Delivers what was received before the pause, then reads again. Idempotent.
    public func resumeReading() {
        shared.paused.store(false, ordering: .releasing)
        onQueue { $0.syncReadState() }
    }

    public var isReadingPaused: Bool { shared.paused.load(ordering: .acquiring) }

    /// Client data accepted but not yet written to the socket.
    public var pendingOutboundBytes: Int { shared.outboundBytes.load(ordering: .relaxed) }

    // MARK: - Sending

    /// Queues INPUT (split into frames as needed; only the last carries `submit`, so the holder
    /// writes `\r` 10 ms after the last byte reached the PTY). Throws instead of dropping bytes:
    /// `.closed` after the stream ended, `.outboundQueueFull` when the child is not reading.
    ///
    /// `paste`: the bytes are one paste (the composer's multi-line prompt). A holder with
    /// `input.paste` (`supportsPaste`) wraps them in `ESC [ 200 ~ … ESC [ 201 ~` when the child has
    /// `?2004` on and writes the submit `\r` 50 ms after the paste. With an older holder the stream
    /// brackets itself when the newest modes it knows (WELCOME, then ATTACHED) have `?2004`, and the
    /// submit is the plain 10 ms one. A paste sent before WELCOME waits for it (input sent after it
    /// waits too, to keep the order). One frame is one paste: more than `Message.maxInputChunk`
    /// bytes reach a holder with the capability as consecutive pastes.
    public func sendInput(_ bytes: [UInt8], submit: Bool = false, paste: Bool = false) throws(HolderStreamError) {
        guard !bytes.isEmpty || submit else { return }
        let size = InputFraming.reservation(byteCount: bytes.count, paste: paste)
        try reserve(size)
        onQueue { $0.enqueueInput(bytes, submit: submit, paste: paste, reserved: size) }
    }

    /// WELCOME `caps` lists `input.paste` (false before WELCOME): the holder brackets pastes itself.
    public var supportsPaste: Bool { shared.pasteSupported.load(ordering: .acquiring) }

    /// TIOCSWINSZ on the PTY (cols and rows must be non-zero; the holder ignores zero sizes).
    public func resize(_ size: WindowSize) {
        send(.resize(size))
    }

    /// Delivers `signo` (1...31) to the PTY's foreground process group.
    public func signal(_ signo: Int32) {
        guard (1...31).contains(signo) else { return }
        send(.signal(UInt8(signo)))
    }

    /// Asks the child to redraw (the holder narrows the PTY by one column, then restores it).
    public func repaint() {
        send(.repaint)
    }

    /// Sends PING; `onPong` reports the token. Tokens with `keepaliveTokenBit` are reserved.
    public func ping(token: UInt64) {
        send(.ping(token: token & ~Self.keepaliveTokenBit))
    }

    /// Control frames are small and never refused; they count toward `pendingOutboundBytes`.
    private func send(_ message: Message) {
        guard !isClosed else { return }
        let bytes = message.encoded()
        shared.outboundBytes.add(bytes.count, ordering: .relaxed)
        onQueue { $0.enqueue(bytes) }
    }

    private func reserve(_ size: Int) throws(HolderStreamError) {
        guard !isClosed else { throw .closed }
        let limit = options.maxOutboundBytes
        var current = shared.outboundBytes.load(ordering: .relaxed)
        while true {
            guard current + size <= limit else { throw .outboundQueueFull(pendingBytes: current, limit: limit) }
            let (exchanged, original) = shared.outboundBytes.compareExchange(
                expected: current, desired: current + size, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    // MARK: - Callbacks

    /// WELCOME (session snapshot); first callback of a successful handshake.
    public var onWelcome: (@Sendable (Welcome) -> Void)? {
        get { shared.handlers.withLock { $0.welcome } }
        set { shared.handlers.withLock { $0.welcome = newValue } }
    }

    /// An ATTACH took effect; OUTPUT of it follows.
    public var onAttach: (@Sendable (HolderAttach) -> Void)? {
        get { shared.handlers.withLock { $0.attach } }
        set { shared.handlers.withLock { $0.attach = newValue } }
    }

    /// `(offset of the first byte, bytes valid only during the call, phase)`.
    public var onOutput: (@Sendable (UInt64, UnsafeRawBufferPointer, OutputPhase) -> Void)? {
        get { shared.handlers.withLock { $0.output } }
        set { shared.handlers.withLock { $0.output = newValue } }
    }

    /// Bytes `[from, to)` were lost; reset, apply `resumeModes`, continue.
    public var onGap: (@Sendable (GapInfo) -> Void)? {
        get { shared.handlers.withLock { $0.gap } }
        set { shared.handlers.withLock { $0.gap = newValue } }
    }

    public var onTitle: (@Sendable (String) -> Void)? {
        get { shared.handlers.withLock { $0.title } }
        set { shared.handlers.withLock { $0.title = newValue } }
    }

    public var onCwd: (@Sendable (String) -> Void)? {
        get { shared.handlers.withLock { $0.cwd } }
        set { shared.handlers.withLock { $0.cwd = newValue } }
    }

    public var onBell: (@Sendable () -> Void)? {
        get { shared.handlers.withLock { $0.bell } }
        set { shared.handlers.withLock { $0.bell = newValue } }
    }

    /// The child exited (at most once; ordering rules in the type documentation).
    public var onExit: (@Sendable (ExitInfo) -> Void)? {
        get { shared.handlers.withLock { $0.exit } }
        set { shared.handlers.withLock { $0.exit = newValue } }
    }

    /// The holder sent ERROR; `onClosed(.holderError)` follows immediately.
    public var onError: (@Sendable (ErrorInfo) -> Void)? {
        get { shared.handlers.withLock { $0.error } }
        set { shared.handlers.withLock { $0.error = newValue } }
    }

    /// PONG for a token passed to `ping(token:)`.
    public var onPong: (@Sendable (UInt64) -> Void)? {
        get { shared.handlers.withLock { $0.pong } }
        set { shared.handlers.withLock { $0.pong = newValue } }
    }

    /// The connection ended; exactly once, last callback. All callbacks are released after it, so
    /// closures that capture the stream do not keep it alive.
    public var onClosed: (@Sendable (HolderStreamCloseReason) -> Void)? {
        get { shared.handlers.withLock { $0.closed } }
        set { shared.handlers.withLock { $0.closed = newValue } }
    }
}

/// State shared between the public API (any thread) and the queue side.
final class StreamShared: Sendable {
    let handlers = Mutex(StreamHandlers())
    /// The consumer asked for backpressure; checked between frames.
    let paused = Atomic<Bool>(false)
    /// `close()` was called: deliver nothing but `onClosed`.
    let closeRequested = Atomic<Bool>(false)
    /// Number of `attach(from:)` / `detach()` calls; the core delivers OUTPUT only once it applied
    /// the latest one, so a request takes effect before the queue even gets to it.
    let attachRequests = Atomic<Int>(0)
    /// Set on the queue when the connection ended.
    let finished = Atomic<Bool>(false)
    /// Bytes accepted by the send methods and not yet written to the socket.
    let outboundBytes = Atomic<Int>(0)
    /// WELCOME `caps` contains `input.paste`.
    let pasteSupported = Atomic<Bool>(false)
}

/// Closes the descriptor once every dispatch source watching it finished cancelling (closing it
/// earlier is undefined behaviour for the sources) and the owner let go of it.
final class DescriptorCloser: Sendable {
    let fd: Int32
    private let shares = Atomic<Int>(1)

    init(fd: Int32) {
        self.fd = fd
    }

    func retain() {
        shares.add(1, ordering: .relaxed)
    }

    func release() {
        if shares.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            Descriptor.closeQuietly(fd)
        }
    }
}
