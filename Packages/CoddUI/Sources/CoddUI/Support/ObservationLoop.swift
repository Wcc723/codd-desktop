import Foundation
import Observation

/// Re-runs a tracked read whenever an `@Observable` property it touched changes.
///
/// `withObservationTracking` fires `onChange` once, synchronously in the mutation's `willSet`;
/// we hop to the next main-actor turn and run again (which re-registers). Every mutation made
/// in the same turn collapses into one re-run, so a burst of state changes costs one update.
/// The optional `apply` step runs outside tracking, so UI work it triggers (e.g. an outline
/// asking its data source) never widens what this loop observes. `cancel()` stops the loop;
/// a pending hop then does nothing.
@MainActor
public final class ObservationLoop {
    private var step: (() -> Void)?
    private var generation = 0
    public private(set) var isCancelled = false

    /// Tracks and applies in one closure (fine when `body` only reads the model and sets
    /// plain view properties).
    public convenience init(_ body: @escaping @MainActor () -> Void) {
        self.init(track: body, apply: { _ in })
    }

    /// Tracks `track`, then hands its result to `apply` (untracked). Runs once immediately.
    public init<Value>(track: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        step = { [unowned self] in
            let token = self.generation
            let value = withObservationTracking {
                track()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.changed(token) }
            }
            apply(value)
        }
        step?()
    }

    /// Stops tracking.
    public func cancel() {
        isCancelled = true
        generation += 1
        step = nil
    }

    /// Runs again now (e.g. after a non-observable input changed).
    public func refresh() {
        guard !isCancelled else { return }
        generation += 1
        step?()
    }

    private func changed(_ token: Int) {
        guard !isCancelled, token == generation else { return }
        generation += 1
        step?()
    }
}
