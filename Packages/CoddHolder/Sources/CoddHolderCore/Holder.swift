import CoddPosix
import CoddProtocol
import Darwin

/// kqueue `udata` tags of the fixed registrations. Connections get tags from `firstConnection` up.
enum HolderTag {
    static let master: UInt = 1
    static let listener: UInt = 2
    static let directory: UInt = 3
    static let child: UInt = 4
    static let signal: UInt = 5
    static let firstConnection: UInt = 1000
}

/// EVFILT_TIMER identifiers.
enum HolderTimer {
    static let submit: UInt = 1
    static let repaint: UInt = 2
    static let watchdog: UInt = 3
    static let exitLinger: UInt = 4
    static let meta: UInt = 5
    static let handshake: UInt = 6
    static let socketCheck: UInt = 7
    static let terminate: UInt = 8
    static let reap: UInt = 9
}

/// REPAINT in progress: the PTY is one column narrower until output goes quiet.
struct RepaintState {
    var active = false
    var startedAt: UInt64 = 0
    /// Last output after the shrink; 0 until the child has written something.
    var lastOutputAt: UInt64 = 0
}

/// One session's holder: owns the PTY child, the ring and the socket; serves one client at a time.
/// Everything runs on the calling thread inside `run()` (single kqueue loop, no locks).
final class Holder {
    static let version = "0.1"

    // Policy constants (docs/ARCHITECTURE.md).
    static let submitDelayNanoseconds: UInt64 = 10_000_000
    /// Submit after a paste (`input.paste`): a program that parses a bracketed paste may otherwise
    /// take a `\r` right behind the closing marker as part of the paste (docs/M2-PLAN.md D1).
    static let pasteSubmitDelayNanoseconds: UInt64 = 50_000_000
    static let repaintQuietNanoseconds: UInt64 = 30_000_000
    static let repaintMaxNanoseconds: UInt64 = 150_000_000
    static let stallNanoseconds: UInt64 = 500_000_000
    static let watchdogIntervalNanoseconds: UInt64 = 100_000_000
    static let handshakeTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let maxPendingConnections = 8
    static let inputPauseBytes = 4 << 20
    static let inputResumeBytes = 1 << 20
    static let metaDebounceNanoseconds: UInt64 = 500_000_000
    static let socketCheckNanoseconds: UInt64 = 30_000_000_000
    static let terminateGraceNanoseconds: UInt64 = 3_000_000_000

    let options: HolderOptions
    let log: HolderLog
    let loop: EventLoop
    let ring: RingBuffer
    let endpoint: ListenEndpoint
    let environment: [String]
    let startedAt: UInt64
    let bootSession: String?

    // Child / PTY.
    var masterFD: Int32 = -1
    var childPid: pid_t = 0
    var childExit: ProcessTermination?
    var childExitedAt: UInt64?
    var ptyReadable = false
    var ptyPaused = false
    var ptyWriteInterest = false
    var scanner = OutputScanner()
    var input = InputQueue()
    var submitArmed = false
    var lastInputWriteAt: UInt64 = 0
    var requestedSize: WindowSize
    var repaint = RepaintState()

    // Connections.
    var client: ClientConnection?
    var pendingConnections: [ClientConnection] = []
    var nextTag = HolderTag.firstConnection
    var handshakeTimerArmed = false
    var watchdogArmed = false
    var directoryFD: Int32 = -1

    // Lifecycle.
    var metaTimerArmed = false
    var exitCode: Int32?
    var terminating = false

    /// Scratch buffer for socket reads.
    let readBuffer: UnsafeMutableRawBufferPointer
    private var events: [kevent]

    /// Flow-control thresholds: pause the PTY above `highWater` pending bytes, resume below `lowWater`.
    /// `highWater` = min(`--flow-limit` (1 MiB), ring / 2); the half-ring bound keeps a protected
    /// client from being lapped (see `isProtectedClientOverHighWater`).
    let highWater: UInt64
    var lowWater: UInt64 { highWater / 2 }

    init(options: HolderOptions) throws(SystemError) {
        self.options = options
        log = HolderLog(path: options.logPath)
        Holder.raiseOpenFileLimit()
        Holder.configureSignals()

        try PosixFile.ensurePrivateDirectory(options.sessionDirectory)
        environment = try ChildEnvironment.load(envFile: options.envFile)
        ring = try RingBuffer(path: PosixFile.join(options.sessionDirectory, "ring"), capacity: options.ringSize)
        endpoint = try ListenEndpoint(path: options.socketPath)
        loop = try EventLoop()
        startedAt = Clock.wallMilliseconds()
        bootSession = ProcessQueries.bootSessionUUID()
        requestedSize = WindowSize(cols: options.cols, rows: options.rows)
        highWater = UInt64(min(options.flowControlLimit, ring.capacity / 2))
        readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
        events = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 64)

        try loop.watchSignal(SIGTERM, tag: HolderTag.signal)
        try loop.watchSignal(SIGINT, tag: HolderTag.signal)
        // Nothing below can fail the start any more: only now take over the ring header.
        ring.beginSession()
        ring.setSize(cols: options.cols, rows: options.rows)
        startChild()
        // Accept clients only now: a connectable socket implies meta.json exists (spawners wait for it).
        try endpoint.startListening()
        try loop.addRead(endpoint.fd, tag: HolderTag.listener)
        watchDirectory()
        loop.setTimer(HolderTimer.socketCheck, nanoseconds: Holder.socketCheckNanoseconds, repeating: true)
        log.info("started session \(options.session) child \(childPid) socket \(options.socketPath)")
    }

    deinit {
        readBuffer.deallocate()
    }

    /// Runs the event loop until the holder decides to exit; returns the process exit code.
    func run() -> Int32 {
        while exitCode == nil {
            let count = loop.wait(into: &events)
            for index in 0..<count {
                dispatch(events[index])
                if exitCode != nil { break }
            }
        }
        shutdown()
        return exitCode ?? 0
    }

    private func dispatch(_ event: kevent) {
        switch event.filter {
        case EventLoop.filterRead:
            switch event.tag {
            case HolderTag.master: readPTY()
            case HolderTag.listener: acceptConnections()
            default: if let connection = connection(tagged: event.tag) { connectionReadable(connection) }
            }
        case EventLoop.filterWrite:
            if event.tag == HolderTag.master {
                writePTY()
            } else if let connection = connection(tagged: event.tag) {
                flush(connection)
            }
        case EventLoop.filterTimer:
            timerFired(event.ident)
        case EventLoop.filterProcess:
            childDidExit()
        case EventLoop.filterSignal:
            beginTermination(reason: "signal \(event.ident)")
        case EventLoop.filterVnode:
            directoryChanged(flags: event.fflags)
        default:
            break
        }
    }

    private func timerFired(_ id: UInt) {
        switch id {
        case HolderTimer.submit: submitTimerFired()
        case HolderTimer.repaint: repaintTimerFired()
        case HolderTimer.watchdog: watchdogFired()
        case HolderTimer.exitLinger: lingerFired()
        case HolderTimer.meta:
            metaTimerArmed = false
            writeMeta()
        case HolderTimer.handshake: handshakeTimerFired()
        case HolderTimer.socketCheck: verifySocketPath()
        case HolderTimer.terminate: terminateGraceExpired()
        case HolderTimer.reap: childDidExit()
        default: break
        }
    }

    func connection(tagged tag: UInt) -> ClientConnection? {
        if let client, client.tag == tag { return client }
        return pendingConnections.first { $0.tag == tag }
    }

    // MARK: - Process setup

    /// Raises the soft RLIMIT_NOFILE (launchd gives 256) to min(hard, OPEN_MAX); inherited by the child.
    static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, rlim_t(OPEN_MAX))
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    /// SIGPIPE is handled as EPIPE; SIGTERM/SIGINT arrive through EVFILT_SIGNAL; SIGHUP is ignored
    /// (the holder is a session leader without a controlling terminal). The child resets all of these.
    /// SIGCHLD is forced back to SIG_DFL: a launcher that left it ignored would make the kernel reap
    /// the child itself, and `waitpid` could no longer report its exit status.
    static func configureSignals() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGCHLD, SIG_DFL)
    }
}
