import Foundation
import Synchronization

/// Wall-clock time plus sleeping, injectable so the state engine's batching, grace periods and
/// timestamps can be driven deterministically in tests.
///
/// Wall-clock `Date`s (not a monotonic clock) because every timestamp the engine produces ends up
/// in hook records and UI durations as ISO strings, exactly like the original status-writer.js.
public protocol HookClock: Sendable {
    func now() -> Date
    /// Returns at or after `deadline` (immediately when it has passed); throws on cancellation.
    func sleep(until deadline: Date) async throws
}

/// The real clock.
public struct SystemHookClock: HookClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let seconds = deadline.timeIntervalSinceNow
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
}

/// A clock that only moves when told to (tests). Sleepers whose deadline is reached by
/// ``advance(by:)`` / ``set(_:)`` resume; a sleep whose deadline already passed returns at once,
/// so a sleeper registering after the advance cannot be lost.
public final class ManualHookClock: HookClock {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state: Mutex<State>

    public init(now: Date) {
        state = Mutex(State(now: now))
    }

    public func now() -> Date { state.withLock { $0.now } }

    /// Number of sleepers currently waiting (lets a test wait until a timer is armed).
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func advance(by seconds: TimeInterval) {
        set(now().addingTimeInterval(seconds))
    }

    public func set(_ date: Date) {
        let due: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            s.now = date
            let ready = s.sleepers.filter { $0.value.deadline <= date }
            for key in ready.keys { s.sleepers[key] = nil }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }

    public func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                // The cancellation flag is set before onCancel runs, so checking it under the lock
                // closes the window where onCancel ran before this sleeper was registered.
                let outcome: Int = state.withLock { s in
                    if Task.isCancelled { return -1 }
                    if deadline <= s.now { return 1 }
                    s.sleepers[id] = Sleeper(deadline: deadline, continuation: c)
                    return 0
                }
                if outcome == 1 { c.resume() }
                if outcome == -1 { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c = state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }
            c?.resume(throwing: CancellationError())
        }
    }
}
