import CoddPosix
import CoddProtocol
import Dispatch

/// Where a `HolderStream` starts reading the session's output.
public enum AttachPoint: Sendable, Equatable, CustomStringConvertible {
    /// Replay from the latest resync point: reset the terminal, apply `HolderAttach.modes`, feed.
    case latestResync
    /// Continue from a stream offset (the next byte this terminal has not shown yet).
    case offset(UInt64)
    /// Control connection only: WELCOME, TITLE, CWD, BELL, EXIT, no OUTPUT until `attach(from:)`.
    case noAttach

    /// ATTACH payload, nil for `.noAttach`.
    var wireOffset: UInt64? {
        switch self {
        case .latestResync: Message.latestResync
        case .offset(let offset): offset
        case .noAttach: nil
        }
    }

    public var description: String {
        switch self {
        case .latestResync: "latest resync point"
        case .offset(let offset): "offset \(offset)"
        case .noAttach: "no attach"
        }
    }
}

/// Whether OUTPUT bytes are history or live (`HolderStream.onOutput`).
public enum OutputPhase: Sendable, Equatable {
    /// Written by the child before the current attach (or GAP) took effect. Feed it with engine
    /// replies suppressed: answering a query in history again would type garbage into the child.
    case replay
    /// Written by the child now; queries in it expect an answer.
    case live
}

/// An ATTACH took effect (`HolderStream.onAttach`). Everything delivered after it belongs to it.
public struct HolderAttach: Sendable, Equatable {
    public var requested: AttachPoint
    /// Offset of the first OUTPUT byte (a GAP follows instead when the requested offset fell out of
    /// the ring; the stream then continues at `GapInfo.to`).
    public var start: UInt64
    /// OUTPUT below this offset is `.replay`, from it on `.live`.
    public var replayEnd: UInt64
    /// Modes in effect at `start` when it is a resync point (always for `.latestResync`, unless no
    /// resync point survived in the ring). Apply `modes.restoreSequence()` after a terminal reset.
    public var modes: TerminalModes?
    /// Modes in effect at `replayEnd`, i.e. what the replay ends in (nil from a holder without
    /// `attach.modes`). A replay can start on the main screen while a full-screen program runs.
    public var currentModes: TerminalModes?
    /// False with a holder that lacks `attach.ack`: the fields are then the client's estimate from
    /// WELCOME, and only exact for the attach requested in `start(takeover:attachFrom:)`.
    public var acknowledged: Bool

    public init(requested: AttachPoint, start: UInt64, replayEnd: UInt64, modes: TerminalModes?, currentModes: TerminalModes? = nil,
                acknowledged: Bool) {
        self.requested = requested
        self.start = start
        self.replayEnd = replayEnd
        self.modes = modes
        self.currentModes = currentModes
        self.acknowledged = acknowledged
    }
}

/// Why a `HolderStream` ended (`onClosed`, delivered exactly once).
public enum HolderStreamCloseReason: Sendable, Equatable, CustomStringConvertible {
    /// `close()` was called.
    case closedLocally
    /// End of stream or connection reset: the holder exited, was killed, or closed the socket.
    case peerClosed
    /// The holder sent ERROR (busy, taken-over, unsupported-proto, bad-frame, hello-required,
    /// hello-timeout) and closes the connection. `onError` came first.
    case holderError(ErrorInfo)
    /// Framing error or a frame that does not fit the exchange.
    case protocolViolation(String)
    case ioError(SystemError)
    /// No WELCOME within `HolderStreamOptions.handshakeTimeoutMilliseconds`.
    case handshakeTimeout
    /// No byte from the holder for the keepalive timeout after a PING (a stopped or hung holder).
    case keepaliveTimeout

    public var description: String {
        switch self {
        case .closedLocally: "closed by the client"
        case .peerClosed: "holder closed the connection"
        case .holderError(let info): "holder error \(info)"
        case .protocolViolation(let reason): "protocol violation: \(reason)"
        case .ioError(let error): error.description
        case .handshakeTimeout: "no WELCOME from the holder"
        case .keepaliveTimeout: "holder stopped answering PING"
        }
    }
}

/// Errors thrown synchronously by `HolderStream`.
public enum HolderStreamError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The socket did not accept the connection (holder gone, path wrong, backlog full).
    case connectFailed(SystemError)
    /// The stream already ended; nothing was queued.
    case closed
    /// Accepting the input would exceed `HolderStreamOptions.maxOutboundBytes` of unsent data (the
    /// child is not reading its input). Nothing was queued; retry later or tell the user.
    case outboundQueueFull(pendingBytes: Int, limit: Int)

    public var description: String {
        switch self {
        case .connectFailed(let error): "cannot connect to the holder: \(error)"
        case .closed: "the holder stream is closed"
        case .outboundQueueFull(let pending, let limit):
            "input not sent: \(pending) bytes are still waiting for the holder (limit \(limit))"
        }
    }
}

/// Tuning for one `HolderStream`.
public struct HolderStreamOptions: Sendable, Equatable {
    /// Largest amount of unsent client data (INPUT plus control frames). The holder stops reading
    /// a client once 4 MiB of input wait for the PTY, so this only fills when the child does not
    /// read its input; `sendInput` then throws instead of dropping bytes.
    public var maxOutboundBytes = 16 << 20
    /// Send PING after this long without a byte from the holder; nil disables the keepalive.
    public var keepaliveIntervalMilliseconds: Int? = 10_000
    /// Close with `.keepaliveTimeout` when a PING stays unanswered (no byte at all) this long.
    /// Not checked while reading is paused.
    public var keepaliveTimeoutMilliseconds = 30_000
    /// Close with `.handshakeTimeout` when WELCOME does not arrive in time.
    public var handshakeTimeoutMilliseconds = 5_000
    /// SO_RCVBUF (the AF_UNIX default of 8 KiB would cap throughput).
    public var receiveBufferBytes: Int32 = 1 << 20
    /// SO_SNDBUF for INPUT.
    public var sendBufferBytes: Int32 = 256 << 10
    /// QoS of the stream's serial queue (the callbacks run there).
    public var qos: DispatchQoS = .userInitiated

    public init() {}
}

/// The consumer's callbacks. Each runs on the stream's serial queue, never concurrently.
struct StreamHandlers: Sendable {
    var welcome: (@Sendable (Welcome) -> Void)?
    var attach: (@Sendable (HolderAttach) -> Void)?
    var output: (@Sendable (UInt64, UnsafeRawBufferPointer, OutputPhase) -> Void)?
    var gap: (@Sendable (GapInfo) -> Void)?
    var title: (@Sendable (String) -> Void)?
    var cwd: (@Sendable (String) -> Void)?
    var bell: (@Sendable () -> Void)?
    var exit: (@Sendable (ExitInfo) -> Void)?
    var error: (@Sendable (ErrorInfo) -> Void)?
    var pong: (@Sendable (UInt64) -> Void)?
    var closed: (@Sendable (HolderStreamCloseReason) -> Void)?
}
