import os
import Synchronization

/// Pairs keyDown events with the next PTY write and records the latency.
///
/// `keyDown(eventTimestamp:)` is called on the main thread by the app's local
/// event monitor, before the engine handles the event. `ptyWritten()` is called
/// on the PTY queue right after a `write(2)` succeeds. Pairing is FIFO; a
/// keyDown that produced no write within `staleAfterNanos` (a modifier-only
/// chord, a key the engine ignored) is dropped and counted.
///
/// Keys an input method consumes into a composition (the first key of a 注音
/// syllable writes nothing) must be withdrawn with `cancel(_:)` as soon as the
/// caller knows; otherwise FIFO pairing would match them with the *next*
/// write and report the time the user spent composing as latency.
public final class KeyLatencyTracker: Sendable {
    /// Identifies one pending keyDown (see `cancel(_:)`).
    public struct Token: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    /// keyDown seen by the app → PTY write returned.
    public let hostPath = LatencyRecorder()
    /// HID event timestamp (`NSEvent.timestamp`) → PTY write returned.
    public let eventToWrite = LatencyRecorder()

    private struct Pending: Sendable {
        var id: UInt64
        var beginNanos: UInt64
        var eventNanos: UInt64
        var signpost: SignpostState
    }

    private let pending = Mutex<[Pending]>([])
    private let unmatched = Atomic<Int>(0)
    private let nextID = Atomic<UInt64>(1)
    private let staleAfterNanos: UInt64
    private let signposter: OSSignposter

    /// - Parameter emitsSignposts: false for a second tracker on the same keys
    ///   (e.g. keyDown→engine output), so Instruments shows one interval per key.
    public init(staleAfterNanos: UInt64 = 1_000_000_000, emitsSignposts: Bool = true) {
        self.staleAfterNanos = staleAfterNanos
        signposter = emitsSignposts ? Signposts.latency : .disabled
    }

    /// Number of keyDowns that never produced a PTY write.
    public var unmatchedCount: Int { unmatched.load(ordering: .relaxed) }

    @discardableResult
    public func keyDown(eventTimestamp: Double) -> Token {
        let now = Monotonic.nanos()
        let token = Token(id: nextID.wrappingAdd(1, ordering: .relaxed).oldValue)
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(Signposts.keyToWrite, id: id)
        let entry = Pending(
            id: token.id,
            beginNanos: now,
            eventNanos: Monotonic.nanos(fromUptimeSeconds: eventTimestamp),
            signpost: SignpostState(state)
        )
        let dropped: [Pending] = pending.withLock { queue in
            let stale = queue.filter { now - $0.beginNanos > staleAfterNanos }
            queue.removeAll { now - $0.beginNanos > staleAfterNanos }
            queue.append(entry)
            return stale
        }
        for item in dropped {
            signposter.endInterval(Signposts.keyToWrite, item.signpost.state, "unmatched")
            unmatched.add(1, ordering: .relaxed)
        }
        return token
    }

    /// Withdraws a keyDown that will not produce a write (it went into an IME
    /// composition). No-op when the key already paired with a write.
    public func cancel(_ token: Token) {
        let removed: Pending? = pending.withLock { queue in
            guard let index = queue.firstIndex(where: { $0.id == token.id }) else { return nil }
            return queue.remove(at: index)
        }
        guard let removed else { return }
        signposter.endInterval(Signposts.keyToWrite, removed.signpost.state, "composing")
        unmatched.add(1, ordering: .relaxed)
    }

    public func ptyWritten() {
        let now = Monotonic.nanos()
        guard let entry = pending.withLock({ queue -> Pending? in
            queue.isEmpty ? nil : queue.removeFirst()
        }) else { return }
        signposter.endInterval(Signposts.keyToWrite, entry.signpost.state)
        guard now - entry.beginNanos <= staleAfterNanos else {
            unmatched.add(1, ordering: .relaxed)
            return
        }
        hostPath.record(Monotonic.millis(from: entry.beginNanos, to: now))
        if entry.eventNanos > 0 {
            eventToWrite.record(Monotonic.millis(from: entry.eventNanos, to: now))
        }
    }

    public func reset() {
        pending.withLock { $0.removeAll() }
        hostPath.reset()
        eventToWrite.reset()
        unmatched.store(0, ordering: .relaxed)
    }
}

/// `OSSignpostIntervalState` is an immutable token that os_signpost documents
/// as safe to end from any thread; the box only carries it across isolation.
struct SignpostState: @unchecked Sendable {
    let state: OSSignpostIntervalState
    init(_ state: OSSignpostIntervalState) { self.state = state }
}
