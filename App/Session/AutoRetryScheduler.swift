import Foundation

/// `⟲ 稍後自動重試` on the error banner (D26): one resend armed per failed session, `delay` after
/// the click, shown as `⟲ 60s 後重試` counting down. A second click cancels; a session that left
/// ERROR (or failed again: its `stateSince` changed) loses it. Nothing is persisted.
@MainActor
final class AutoRetryScheduler {
    struct Armed: Equatable {
        /// Display clock time the resend goes out.
        var deadline: Date
        /// The failure it was armed for (a new failure has a new `stateSince`).
        var stateSince: Date
    }

    let delay: TimeInterval
    private let clock: () -> Date
    private(set) var armed: [SessionID: Armed] = [:]
    private var timers: [SessionID: Task<Void, Never>] = [:]
    /// Whether the session still shows the failure it was armed for (state ERROR, same `stateSince`).
    var isStillFailing: (SessionID, Date) -> Bool = { _, _ in false }
    /// The time came and the session still fails: resend.
    var onFire: ((SessionID) -> Void)?

    static let defaultDelay: TimeInterval = 60

    init(delay: TimeInterval = AutoRetryScheduler.defaultDelay, clock: @escaping () -> Date = { Date() }) {
        self.delay = delay
        self.clock = clock
    }

    /// Arms one resend (`delay` from now), or cancels the armed one. True when armed afterwards.
    @discardableResult
    func toggle(_ id: SessionID, stateSince: Date) -> Bool {
        if armed[id] != nil {
            cancel(id)
            return false
        }
        armed[id] = Armed(deadline: clock().addingTimeInterval(delay), stateSince: stateSince)
        let delay = self.delay
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            self?.fire(id)
        }
        return true
    }

    func isArmed(_ id: SessionID) -> Bool { armed[id] != nil }

    /// Whole seconds left (rounded up, at least 1 while armed); nil when not armed.
    func remainingSeconds(_ id: SessionID, now: Date) -> Int? {
        guard let entry = armed[id] else { return nil }
        return max(1, Int(entry.deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The banner's button title.
    func title(for id: SessionID, now: Date) -> String {
        remainingSeconds(id, now: now).map { "⟲ \($0)s 後重試" } ?? "⟲ 稍後自動重試"
    }

    func cancel(_ id: SessionID) {
        armed[id] = nil
        timers.removeValue(forKey: id)?.cancel()
    }

    /// Drops every armed resend whose session left its failure.
    func dropStale() {
        for (id, entry) in armed where !isStillFailing(id, entry.stateSince) { cancel(id) }
    }

    private func fire(_ id: SessionID) {
        guard let entry = armed[id] else { return }
        armed[id] = nil
        timers[id] = nil
        guard isStillFailing(id, entry.stateSince) else { return }
        onFire?(id)
    }
}
