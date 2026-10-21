import CoddPosix
import CoddProtocol
import Darwin
import Dispatch

/// The queue side of a `HolderStream`: socket I/O, framing, attach epochs, exit ordering,
/// keepalive. Only ever touched on the stream's serial queue (through `HolderStream`'s mutex,
/// which is therefore never contended) or from the owner's deinit.
///
/// Callbacks run while the core is in use. They may call any `HolderStream` method: those only
/// set atomics and dispatch to the queue, so nothing re-enters the core.
final class StreamCore {
    private static let readBufferBytes = 256 << 10
    /// Bytes read per readiness event before the queue serves writes and other work.
    private static let readBudget = 1 << 20

    let fd: Int32
    let queue: DispatchQueue
    let shared: StreamShared
    let options: HolderStreamOptions
    let clientName: String
    weak var owner: HolderStream?

    private let closer: DescriptorCloser
    private var started = false
    private var finished = false

    private var readSource: DispatchSourceRead?
    private var readSourceSuspended = false
    private var writeSource: DispatchSourceWrite?
    private var writeSourceRunning = false
    private var handshakeTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?

    private var decoder = FrameDecoder()
    private let readBuffer: UnsafeMutableRawBufferPointer
    private var outbox: [UInt8] = []
    private var outboxHead = 0

    // Handshake.
    private var welcome: Welcome?
    /// WELCOME `caps` contains `attach.ack`.
    private var ackSupported = false
    /// WELCOME `caps` contains `input.paste`.
    private var pasteSupported = false
    /// Newest modes the holder reported: WELCOME `modes`, then each ATTACHED's current modes. Used
    /// only to bracket a paste for a holder without `input.paste`.
    private var newestModes: TerminalModes?

    /// Input queued before WELCOME behind a paste: whether the client must bracket it depends on
    /// WELCOME `caps` (and `modes`). Sent, in order, when WELCOME arrives.
    private struct HeldInput {
        var bytes: [UInt8]
        var submit: Bool
        var paste: Bool
        var reserved: Int
    }
    private var heldInput: [HeldInput] = []

    // Attach epochs. OUTPUT and GAP are delivered only while `epochActive`: the latest requested
    // ATTACH was acknowledged and no DETACH followed.
    private var requested = AttachPoint.noAttach
    /// ATTACH frames sent whose ATTACHED has not arrived yet.
    private var pendingAcks = 0
    /// The last `attach(from:)` request applied (compared with `shared.attachRequests`).
    private var appliedRequests = 0
    private var epochActive = false
    /// Next stream offset expected in the active epoch.
    private var cursor: UInt64 = 0
    /// OUTPUT below this offset is replay.
    private var replayEnd: UInt64 = 0

    // Exit ordering.
    private var exitInfo: ExitInfo?
    private var exitDelivered = false
    /// `onExit` waits until `cursor` reaches this offset.
    private var exitThreshold: UInt64?

    // Keepalive.
    private var lastReceivedAt: UInt64
    private var keepaliveSentAt: UInt64?
    private var keepaliveCounter: UInt64 = 0

    init(fd: Int32, queue: DispatchQueue, shared: StreamShared, options: HolderStreamOptions, clientName: String) {
        self.fd = fd
        self.queue = queue
        self.shared = shared
        self.options = options
        self.clientName = clientName
        closer = DescriptorCloser(fd: fd)
        readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.readBufferBytes, alignment: 16)
        lastReceivedAt = Clock.monotonicNanoseconds()
    }

    deinit {
        readBuffer.deallocate()
    }

    // MARK: - Start

    func start(takeover: Bool, attach point: AttachPoint) {
        guard !started, !finished else { return }
        started = true
        // HELLO (and ATTACH) go in front of anything queued before start.
        var prefix: [UInt8] = []
        Message.hello(Hello(client: clientName, takeover: takeover, caps: HolderStream.clientCapabilities)).append(to: &prefix)
        if let offset = point.wireOffset {
            Message.attach(fromOffset: offset).append(to: &prefix)
            requested = point
            pendingAcks = 1
        }
        shared.outboundBytes.add(prefix.count, ordering: .relaxed)
        outbox = prefix + outbox[outboxHead...]
        outboxHead = 0

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let closer = self.closer
        closer.retain()
        source.setEventHandler { [weak owner] in owner?.withCore { $0.readable() } }
        source.setCancelHandler { closer.release() }
        readSource = source
        source.resume()
        syncReadState()

        handshakeTimer = makeTimer(after: options.handshakeTimeoutMilliseconds, repeating: nil) {
            $0.handshakeTimedOut()
        }
        if let interval = options.keepaliveIntervalMilliseconds, interval > 0 {
            keepaliveTimer = makeTimer(after: interval, repeating: interval) { $0.keepaliveTick() }
        }
        flush()
    }

    private func makeTimer(
        after milliseconds: Int, repeating interval: Int?, _ body: @escaping @Sendable (StreamCore) -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let deadline = DispatchTime.now() + .milliseconds(milliseconds)
        if let interval {
            timer.schedule(deadline: deadline, repeating: .milliseconds(interval), leeway: .milliseconds(max(1, interval / 10)))
        } else {
            timer.schedule(deadline: deadline, leeway: .milliseconds(10))
        }
        timer.setEventHandler { [weak owner] in owner?.withCore(body) }
        timer.resume()
        return timer
    }

    // MARK: - Reading

    func readable() {
        guard !finished else { return }
        if shared.paused.load(ordering: .acquiring) {
            syncReadState()
            return
        }
        var budget = Self.readBudget
        while budget > 0, !finished {
            let count = read(fd, readBuffer.baseAddress, readBuffer.count)
            if count > 0 {
                budget -= count
                lastReceivedAt = Clock.monotonicNanoseconds()
                keepaliveSentAt = nil
                guard dispatch(UnsafeRawBufferPointer(start: readBuffer.baseAddress, count: count)) else {
                    syncReadState()
                    return
                }
            } else if count == 0 {
                finish(.peerClosed, notify: true)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else if errno == ECONNRESET {
                finish(.peerClosed, notify: true)
            } else {
                finish(.ioError(.current("read")), notify: true)
            }
        }
    }

    /// Decodes and handles frames; false when delivery stopped (paused, closing, finished).
    private func dispatch(_ bytes: UnsafeRawBufferPointer) -> Bool {
        do throws(ProtocolError) {
            return try decoder.decode(bytes) { type, payload in handleFrame(type, payload) }
        } catch {
            finish(.protocolViolation(error.description), notify: true)
            return false
        }
    }

    /// The active epoch is the one the consumer wants: no `attach(from:)` is waiting for the queue.
    private var attachCurrent: Bool {
        epochActive && shared.attachRequests.load(ordering: .acquiring) == appliedRequests
    }

    /// No `attach(from:)` / `detach()` call is waiting for the queue.
    private var requestsSettled: Bool {
        shared.attachRequests.load(ordering: .acquiring) == appliedRequests
    }

    /// Delivery goes on while nothing asked to stop. Checked between frames, so a pause takes
    /// effect right after the callback that requested it.
    private var shouldDeliver: Bool {
        !finished && !shared.paused.load(ordering: .acquiring) && !shared.closeRequested.load(ordering: .acquiring)
    }

    /// Suspends or resumes the read source to match `paused`. On resume, frames received before
    /// the pause are delivered first.
    func syncReadState() {
        guard started, !finished, let readSource else { return }
        let paused = shared.paused.load(ordering: .acquiring)
        if paused {
            if !readSourceSuspended {
                readSourceSuspended = true
                readSource.suspend()
            }
            return
        }
        if decoder.bufferedByteCount > 0, !dispatch(UnsafeRawBufferPointer(start: nil, count: 0)) {
            // Paused again (or closed) while draining.
            if !finished, shared.paused.load(ordering: .acquiring), !readSourceSuspended {
                readSourceSuspended = true
                readSource.suspend()
            }
            return
        }
        guard !finished, readSourceSuspended else { return }
        readSourceSuspended = false
        // Bytes that arrived while paused say nothing about the holder's liveness right now.
        lastReceivedAt = Clock.monotonicNanoseconds()
        keepaliveSentAt = nil
        readSource.resume()
    }

    // MARK: - Frames

    private func handleFrame(_ type: FrameType, _ payload: UnsafeRawBufferPointer) -> Bool {
        guard shouldDeliver else { return false }
        if welcome == nil, type != .welcome, type != .error, type.name != nil {
            finish(.protocolViolation("\(type) before WELCOME"), notify: true)
            return false
        }
        do throws(ProtocolError) {
            switch type {
            case .output:
                guard payload.count >= 8 else {
                    throw .badPayload(type: .output, reason: "expected at least 8 bytes, got \(payload.count)")
                }
                handleOutput(offset: WireBytes.readUInt64(payload, at: 0), UnsafeRawBufferPointer(rebasing: payload[8...]))
            case .gap:
                handleGap(try GapInfo(payload: payload))
            case .attached:
                handleAttached(try AttachedInfo(payload: payload))
            case .welcome, .exit, .title, .cwd, .bell, .ping, .pong, .error:
                handle(try Message(frame: Frame(type: type, payload: Array(payload))))
            default:
                break  // client-to-holder types and unknown extensions are ignored
            }
        } catch {
            finish(.protocolViolation(error.description), notify: true)
            return false
        }
        return shouldDeliver
    }

    private func handle(_ message: Message) {
        switch message {
        case .welcome(let welcome):
            handleWelcome(welcome)
        case .exit(let info):
            guard exitInfo == nil else { return }
            exitInfo = info
            // Sent while the holder had us attached: it followed all output of that attach.
            // Sent before our latest ATTACH was processed (or while a new one waits for the
            // queue): wait for that attach's replay (`activate`) or a detach (`requestAttach`).
            if requestsSettled, requested == .noAttach || epochActive {
                deliverExit()
            }
        case .title(let title):
            handlers.title?(title)
        case .cwd(let cwd):
            handlers.cwd?(cwd)
        case .bell:
            handlers.bell?()
        case .ping(let token):
            enqueue(Message.pong(token: token).encoded(), counted: false)
        case .pong(let token):
            if token & HolderStream.keepaliveTokenBit == 0 { handlers.pong?(token) }
        case .error(let info):
            handlers.error?(info)
            finish(.holderError(info), notify: true)
        default:
            break
        }
    }

    private func handleWelcome(_ welcome: Welcome) {
        guard self.welcome == nil else { return }
        guard welcome.proto == Int(CoddProtocolVersion.current) else {
            finish(.protocolViolation("holder speaks proto \(welcome.proto)"), notify: true)
            return
        }
        self.welcome = welcome
        handshakeTimer?.cancel()
        handshakeTimer = nil
        ackSupported = welcome.caps.contains(HolderCapability.attachAck)
        pasteSupported = welcome.caps.contains(HolderCapability.inputPaste)
        shared.pasteSupported.store(pasteSupported, ordering: .releasing)
        newestModes = welcome.modes
        sendHeldInput()
        handlers.welcome?(welcome)
        if welcome.exited {
            exitInfo = ExitInfo(status: welcome.exitStatus ?? -1, signaled: welcome.signaled ?? false)
        }
        if !ackSupported {
            // No ATTACHED will come. The pipelined ATTACH was processed together with HELLO, so
            // WELCOME describes its start exactly.
            pendingAcks = 0
            if requested != .noAttach { activate(estimatedAttach(requested, welcome: welcome)) }
        }
        guard !finished, exitInfo != nil else { return }
        if requestsSettled, requested == .noAttach { deliverExit() }
    }

    private func estimatedAttach(_ point: AttachPoint, welcome: Welcome) -> HolderAttach {
        switch point {
        case .latestResync:
            HolderAttach(requested: point, start: welcome.resync, replayEnd: welcome.ringEnd, modes: welcome.resyncModes, acknowledged: false)
        case .offset(let offset):
            HolderAttach(requested: point, start: offset < welcome.ringStart ? offset : min(offset, welcome.ringEnd), replayEnd: welcome.ringEnd, modes: nil, acknowledged: false)
        case .noAttach:
            HolderAttach(requested: point, start: 0, replayEnd: 0, modes: nil, acknowledged: false)
        }
    }

    private func handleAttached(_ info: AttachedInfo) {
        guard pendingAcks > 0 else { return }  // not ours (a holder that sends it unasked)
        pendingAcks -= 1
        // Newer than WELCOME's, also for an attach that a later one superseded.
        if let current = info.currentModes { newestModes = current }
        // An ATTACHED for an attach that a later ATTACH or DETACH superseded opens no epoch.
        guard pendingAcks == 0, requested != .noAttach else { return }
        activate(HolderAttach(requested: requested, start: info.start, replayEnd: info.replayEnd, modes: info.modes,
                              currentModes: info.currentModes, acknowledged: true))
    }

    private func activate(_ attach: HolderAttach) {
        epochActive = true
        cursor = attach.start
        replayEnd = attach.replayEnd
        handlers.attach?(attach)
        if exitInfo != nil, !exitDelivered {
            // The child exited before this ATTACH was processed: its replay ends at the final offset.
            exitThreshold = attach.replayEnd
            deliverExitIfCaughtUp()
        }
    }

    private func handleOutput(offset: UInt64, _ bytes: UnsafeRawBufferPointer) {
        guard attachCurrent else { return }
        guard !bytes.isEmpty, let output = handlers.output else {
            advance(to: offset + UInt64(bytes.count))
            return
        }
        let end = offset + UInt64(bytes.count)
        if offset < replayEnd, end > replayEnd {
            // The frame straddles the replay/live boundary: two callbacks, one frame. A pause
            // requested in the first (a consumer's backlog mark) takes effect after the whole
            // frame, as for any other frame: the decoder has consumed it, so stopping here would
            // lose the live half without a GAP (review finding). Only a new attach or a close
            // stops it.
            let split = Int(replayEnd - offset)
            output(offset, UnsafeRawBufferPointer(rebasing: bytes[..<split]), .replay)
            guard attachCurrent, !finished, !shared.closeRequested.load(ordering: .acquiring) else { return }
            output(replayEnd, UnsafeRawBufferPointer(rebasing: bytes[split...]), .live)
        } else {
            output(offset, bytes, offset < replayEnd ? .replay : .live)
        }
        advance(to: end)
    }

    private func handleGap(_ gap: GapInfo) {
        guard attachCurrent else { return }
        replayEnd = max(replayEnd, gap.replayEnd ?? gap.to)
        handlers.gap?(gap)
        advance(to: gap.to)
    }

    private func advance(to offset: UInt64) {
        cursor = offset
        deliverExitIfCaughtUp()
    }

    private func deliverExitIfCaughtUp() {
        guard let threshold = exitThreshold, cursor >= threshold else { return }
        deliverExit()
    }

    private func deliverExit() {
        guard let exitInfo, !exitDelivered else { return }
        exitDelivered = true
        exitThreshold = nil
        handlers.exit?(exitInfo)
    }

    /// Current callbacks (copied out of the lock; invoked without holding it). Empty once the
    /// stream finished or `close()` was called, so nothing but `onClosed` runs after that.
    private var handlers: StreamHandlers {
        guard !finished, !shared.closeRequested.load(ordering: .acquiring) else { return StreamHandlers() }
        return shared.handlers.withLock { $0 }
    }

    // MARK: - Attach requests

    func requestAttach(_ point: AttachPoint, request: Int) {
        appliedRequests = max(appliedRequests, request)
        guard started, !finished else { return }
        guard let offset = point.wireOffset else {
            if requested != .noAttach {
                enqueue(Message.detach.encoded(), counted: false)
                requested = .noAttach
                epochActive = false
                exitThreshold = nil
            }
            // No output is coming any more: a held-back exit is due.
            if requestsSettled, exitInfo != nil { deliverExit() }
            return
        }
        enqueue(Message.attach(fromOffset: offset).encoded(), counted: false)
        requested = point
        epochActive = false
        exitThreshold = nil
        if let welcome, !ackSupported {
            // Best effort with a holder that does not acknowledge: frames of the previous attach
            // that are still in flight cannot be told apart.
            var estimate = estimatedAttach(point, welcome: welcome)
            estimate.start = point == .latestResync ? cursor : estimate.start
            estimate.replayEnd = estimate.start
            activate(estimate)
        } else {
            pendingAcks += 1
        }
    }

    // MARK: - Writing

    /// Appends encoded frames. `counted` says the bytes were already added to `outboundBytes`.
    func enqueue(_ bytes: [UInt8], counted: Bool = true) {
        guard !finished else {
            if counted { shared.outboundBytes.subtract(bytes.count, ordering: .relaxed) }
            return
        }
        if !counted { shared.outboundBytes.add(bytes.count, ordering: .relaxed) }
        outbox.append(contentsOf: bytes)
        flush()
    }

    /// `reserved` = `InputFraming.reservation`, already added to `outboundBytes`; whatever the
    /// frames do not use (no client bracket, markers stripped) is given back here.
    func enqueueInput(_ bytes: [UInt8], submit: Bool, paste: Bool, reserved: Int) {
        guard !finished else {
            shared.outboundBytes.subtract(reserved, ordering: .relaxed)
            return
        }
        if welcome == nil, paste || !heldInput.isEmpty {
            heldInput.append(HeldInput(bytes: bytes, submit: submit, paste: paste, reserved: reserved))
            return
        }
        let (payload, pasteFlag) = InputFraming.prepare(
            bytes, paste: paste, holderSupportsPaste: pasteSupported, modes: newestModes)
        let written = InputFraming.appendFrames(payload, submit: submit, paste: pasteFlag, to: &outbox)
        assert(written <= reserved, "INPUT frames exceed their reservation")
        if written < reserved { shared.outboundBytes.subtract(reserved - written, ordering: .relaxed) }
        flush()
    }

    /// WELCOME arrived: input held for it goes out in the order it was sent.
    private func sendHeldInput() {
        let held = heldInput
        heldInput = []
        for input in held {
            enqueueInput(input.bytes, submit: input.submit, paste: input.paste, reserved: input.reserved)
        }
    }

    private func flush() {
        guard started, !finished else { return }
        while outboxHead < outbox.count {
            let head = outboxHead
            let count = outbox.withUnsafeBytes { raw in write(fd, raw.baseAddress! + head, raw.count - head) }
            if count > 0 {
                outboxHead += count
                shared.outboundBytes.subtract(count, ordering: .relaxed)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                if outboxHead >= 256 << 10 {
                    outbox.removeFirst(outboxHead)
                    outboxHead = 0
                }
                setWriteInterest(true)
                return
            } else if count < 0 && (errno == EPIPE || errno == ECONNRESET) {
                finish(.peerClosed, notify: true)
                return
            } else {
                finish(.ioError(.current("write")), notify: true)
                return
            }
        }
        outbox.removeAll(keepingCapacity: outbox.capacity <= 1 << 20)
        outboxHead = 0
        setWriteInterest(false)
    }

    private func setWriteInterest(_ enabled: Bool) {
        if enabled, writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            let closer = self.closer
            closer.retain()
            source.setEventHandler { [weak owner] in owner?.withCore { $0.flush() } }
            source.setCancelHandler { closer.release() }
            writeSource = source
            writeSourceRunning = false
        }
        guard let writeSource, writeSourceRunning != enabled else { return }
        writeSourceRunning = enabled
        if enabled { writeSource.resume() } else { writeSource.suspend() }
    }

    // MARK: - Timers

    private func handshakeTimedOut() {
        guard welcome == nil else { return }
        finish(.handshakeTimeout, notify: true)
    }

    private func keepaliveTick() {
        guard !finished, welcome != nil, !shared.paused.load(ordering: .acquiring),
              let interval = options.keepaliveIntervalMilliseconds
        else { return }
        let now = Clock.monotonicNanoseconds()
        if let sentAt = keepaliveSentAt {
            if now - sentAt >= UInt64(options.keepaliveTimeoutMilliseconds) * 1_000_000 {
                finish(.keepaliveTimeout, notify: true)
            }
        } else if now - lastReceivedAt >= UInt64(interval) * 1_000_000 {
            keepaliveCounter += 1
            keepaliveSentAt = now
            enqueue(Message.ping(token: HolderStream.keepaliveTokenBit | keepaliveCounter).encoded(), counted: false)
        }
    }

    // MARK: - Teardown

    /// Ends the connection once: cancels sources and timers (the descriptor closes after their
    /// cancellation), discards unsent bytes, delivers a held-back exit and `onClosed`.
    func finish(_ reason: HolderStreamCloseReason, notify: Bool) {
        guard !finished else { return }
        finished = true
        shared.finished.store(true, ordering: .releasing)
        handshakeTimer?.cancel()
        handshakeTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let writeSource {
            // Cancelling (and releasing) a suspended source crashes libdispatch.
            if !writeSourceRunning { writeSource.resume() }
            writeSource.cancel()
        }
        if let readSource {
            if readSourceSuspended { readSource.resume() }
            readSource.cancel()
        }
        writeSource = nil
        readSource = nil
        closer.release()
        // Exactly what is discarded: reservations whose blocks are still queued subtract their own
        // share when they run, so the count returns to 0 without racing them.
        let heldBytes = heldInput.reduce(0) { $0 + $1.reserved }
        shared.outboundBytes.subtract(outbox.count - outboxHead + heldBytes, ordering: .relaxed)
        outbox = []
        outboxHead = 0
        heldInput = []
        // Released afterwards in any case: closures capturing the stream must not keep it alive.
        let released = shared.handlers.withLock { handlers in
            let current = handlers
            handlers = StreamHandlers()
            return current
        }
        guard notify else { return }
        if !shared.closeRequested.load(ordering: .acquiring), let exitInfo, !exitDelivered, let exit = released.exit {
            exitDelivered = true
            exit(exitInfo)
        }
        released.closed?(reason)
    }
}
