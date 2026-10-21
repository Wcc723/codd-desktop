import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Dispatch
import Synchronization

/// Records every `HolderStream` callback in order, checks OUTPUT contiguity per attach epoch,
/// that callbacks run on the stream's queue and that nothing follows `onClosed`.
final class StreamRecorder: Sendable {
    enum Event: Sendable, Equatable {
        case welcome(Welcome)
        case attach(HolderAttach)
        case output(offset: UInt64, count: Int, phase: OutputPhase)
        case gap(GapInfo)
        case title(String)
        case cwd(String)
        case bell
        case exit(ExitInfo)
        case error(ErrorInfo)
        case pong(UInt64)
        case closed(HolderStreamCloseReason)
        /// Written by a test (e.g. "re-attach requested here").
        case mark(String)
    }

    struct State: Sendable {
        var events: [Event] = []
        /// Tail of the OUTPUT bytes (all of them when `byteLimit` is nil).
        var bytes: [UInt8] = []
        var byteLimit: Int?
        var totalBytes = 0
        /// Next offset expected in the current epoch (reset by attach, moved by GAP).
        var nextOffset: UInt64?
        var discontinuities = 0
        var wrongQueue = 0
        var afterClosed = 0
        var closed = false

        var text: String { String(decoding: bytes, as: UTF8.self) }

        func tailContains(_ marker: String, within count: Int = 512) -> Bool {
            String(decoding: bytes.suffix(count), as: UTF8.self).contains(marker)
        }

        var welcome: Welcome? {
            for case .welcome(let welcome) in events { return welcome }
            return nil
        }

        var attaches: [HolderAttach] {
            events.compactMap { if case .attach(let attach) = $0 { attach } else { nil } }
        }

        var gaps: [GapInfo] {
            events.compactMap { if case .gap(let gap) = $0 { gap } else { nil } }
        }

        var exits: [ExitInfo] {
            events.compactMap { if case .exit(let info) = $0 { info } else { nil } }
        }

        var closeReasons: [HolderStreamCloseReason] {
            events.compactMap { if case .closed(let reason) = $0 { reason } else { nil } }
        }

        var errors: [ErrorInfo] {
            events.compactMap { if case .error(let info) = $0 { info } else { nil } }
        }

        var pongs: [UInt64] {
            events.compactMap { if case .pong(let token) = $0 { token } else { nil } }
        }

        func index(of predicate: (Event) -> Bool) -> Int? { events.firstIndex(where: predicate) }

        func lastIndex(of predicate: (Event) -> Bool) -> Int? { events.lastIndex(where: predicate) }
    }

    private let state: Mutex<State>
    private let queueLabel: String

    /// Installs all callbacks on `stream`.
    init(_ stream: HolderStream, byteLimit: Int? = 1 << 20) {
        state = Mutex(State(byteLimit: byteLimit))
        queueLabel = stream.callbackQueue.label
        stream.onWelcome = { [self] in record(.welcome($0)) }
        stream.onAttach = { [self] attach in
            record(.attach(attach)) { $0.nextOffset = attach.start }
        }
        stream.onOutput = { [self] offset, bytes, phase in recordOutput(offset, bytes, phase) }
        stream.onGap = { [self] gap in
            record(.gap(gap)) { state in
                if let next = state.nextOffset, next != gap.from { state.discontinuities += 1 }
                state.nextOffset = gap.to
            }
        }
        stream.onTitle = { [self] in record(.title($0)) }
        stream.onCwd = { [self] in record(.cwd($0)) }
        stream.onBell = { [self] in record(.bell) }
        stream.onExit = { [self] in record(.exit($0)) }
        stream.onError = { [self] in record(.error($0)) }
        stream.onPong = { [self] in record(.pong($0)) }
        stream.onClosed = { [self] in record(.closed($0)) }
    }

    var snapshot: State { state.withLock { $0 } }

    /// Cheap read for callbacks (a snapshot copies every event).
    var totalBytes: Int { state.withLock { $0.totalBytes } }

    /// Runs `body` on the state under the lock, without copying it (large captures).
    func read<R>(_ body: (State) -> R) -> R {
        state.withLock { body($0) }
    }

    func mark(_ name: String) {
        state.withLock { $0.events.append(.mark(name)) }
    }

    func recordOutput(_ offset: UInt64, _ bytes: UnsafeRawBufferPointer, _ phase: OutputPhase) {
        let onQueue = currentQueueLabel() == queueLabel
        state.withLock { state in
            if !onQueue { state.wrongQueue += 1 }
            if state.closed { state.afterClosed += 1 }
            if let next = state.nextOffset, next != offset { state.discontinuities += 1 }
            state.nextOffset = offset + UInt64(bytes.count)
            state.events.append(.output(offset: offset, count: bytes.count, phase: phase))
            state.bytes.append(contentsOf: bytes)
            state.totalBytes += bytes.count
            if let limit = state.byteLimit, state.bytes.count > limit * 2 {
                state.bytes.removeFirst(state.bytes.count - limit)
            }
        }
    }

    private func record(_ event: Event, _ update: (inout State) -> Void = { _ in }) {
        let onQueue = currentQueueLabel() == queueLabel
        state.withLock { state in
            if !onQueue { state.wrongQueue += 1 }
            if state.closed { state.afterClosed += 1 }
            update(&state)
            state.events.append(event)
            if case .closed = event { state.closed = true }
        }
    }

    /// Polls until `condition` holds or the timeout passes.
    @discardableResult
    func wait(timeoutMilliseconds: Int = 10_000, until condition: (State) -> Bool) -> Bool {
        let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        while Clock.monotonicNanoseconds() < deadline {
            if state.withLock({ condition($0) }) { return true }
            Clock.sleep(milliseconds: 2)
        }
        return state.withLock { condition($0) }
    }
}

/// A flag a `@Sendable` closure can capture (an `Atomic` itself is not copyable).
final class TestFlag: Sendable {
    private let value = Atomic<Bool>(false)

    /// Sets the flag; true only for the first caller.
    func setOnce() -> Bool { !value.exchange(true, ordering: .relaxed) }
}

/// Label of the dispatch queue the caller runs on.
func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}
