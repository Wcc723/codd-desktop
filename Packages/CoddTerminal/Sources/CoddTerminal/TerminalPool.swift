/// Keeps the terminals of the visible tabs rendering, up to `hotCapacity` hidden ones alive but
/// occluded, and disposes of the rest (`TerminalTierPolicy` decides: a segmented LRU in which the
/// terminals the user worked in outlive quick flips).
///
/// The pool owns engine lifetimes but not their placement: the owner puts `engine.view` in the
/// window when it is shown, keeps hot views in a window (hidden is fine) and attaches each engine's
/// holder stream. A cold key has no engine; showing it again creates a fresh one, reported as
/// `isNew`, and the owner must replay its history from the holder's ring.
@MainActor
public final class TerminalPool<Key: Hashable & Sendable> {
    public struct Shown {
        public let key: Key
        public let engine: TerminalEngine
        /// The engine was created by this call: attach its stream and replay.
        public let isNew: Bool
    }

    /// Called right before an engine is disposed because its key went cold or was removed: detach
    /// the stream feeding it.
    public var onEvict: ((Key, TerminalEngine) -> Void)?

    public var hotCapacity: Int { policy.hotCapacity }

    /// How long an evicted engine waits before its surface is freed. Freeing costs 5-16 ms on the
    /// main thread (Metal teardown), and the switch that evicted it should not pay for it: the
    /// engine is detached and hidden at once, freed a moment later, one per main-queue turn
    /// (review F5). Zero frees immediately.
    public var disposalDelay: Duration

    private var policy: TerminalTierPolicy<Key>
    private var engines: [Key: TerminalEngine] = [:]
    private let makeEngine: (Key) -> TerminalEngine
    private var pendingDisposals: [TerminalEngine] = []
    private var disposalScheduled = false

    public init(hotCapacity: Int = 6, disposalDelay: Duration = .milliseconds(150), makeEngine: @escaping (Key) -> TerminalEngine) {
        policy = TerminalTierPolicy(hotCapacity: hotCapacity)
        self.disposalDelay = disposalDelay
        self.makeEngine = makeEngine
    }

    /// Engines evicted and not freed yet (tests).
    public var pendingDisposalCount: Int { pendingDisposals.count }

    public func engine(for key: Key) -> TerminalEngine? {
        engines[key]
    }

    public func tier(of key: Key) -> TerminalTier {
        engines[key] == nil ? .cold : policy.tier(of: key)
    }

    /// Keys that currently have an engine, visible first, then hot (protected, then probation, each
    /// most recently hidden first).
    public var liveKeys: [Key] {
        (policy.visible + policy.hot).filter { engines[$0] != nil }
    }

    /// Makes exactly `keys` visible (in that order) and returns their engines. Engines that stop
    /// being visible are occluded; hot overflow is disposed.
    @discardableResult
    public func show(_ keys: [Key]) -> [Shown] {
        let changes = policy.setVisible(keys)
        apply(changes)
        var created = Set(changes.created)
        var shown: [Shown] = []
        for key in policy.visible {
            let engine: TerminalEngine
            if let existing = engines[key], !existing.isDisposed {
                engine = existing
            } else {
                // A key reported as revealed whose engine the owner disposed counts as new.
                engine = makeEngine(key)
                engines[key] = engine
                created.insert(key)
            }
            engine.setOccluded(false)
            shown.append(Shown(key: key, engine: engine, isNew: created.contains(key)))
        }
        return shown
    }

    /// While pinned, `key` is never disposed for capacity (a `claude` surface waiting for its first
    /// DA1 reply). Unpinning may dispose hot overflow.
    public func setPinned(_ pinned: Bool, for key: Key) {
        apply(policy.setPinned(pinned, for: key))
    }

    /// Disposes of `key`'s engine and forgets it (session deleted or tab closed).
    public func remove(_ key: Key) {
        policy.remove(key)
        dispose(key)
    }

    public func removeAll() {
        for key in Array(engines.keys) {
            remove(key)
        }
    }

    private func apply(_ changes: TerminalTierPolicy<Key>.Changes) {
        for key in changes.evicted {
            dispose(key)
        }
        for key in changes.hidden {
            engines[key]?.setOccluded(true)
        }
    }

    private func dispose(_ key: Key) {
        guard let engine = engines.removeValue(forKey: key) else { return }
        onEvict?(key, engine)
        guard disposalDelay > .zero else {
            engine.dispose()
            return
        }
        engine.setOccluded(true)
        engine.view.isHidden = true
        pendingDisposals.append(engine)
        scheduleDisposal(after: disposalDelay)
    }

    private func scheduleDisposal(after delay: Duration) {
        guard !disposalScheduled else { return }
        disposalScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.disposeNext()
        }
    }

    /// Frees one engine; the next one waits for another main-queue turn.
    private func disposeNext() {
        disposalScheduled = false
        guard !pendingDisposals.isEmpty else { return }
        pendingDisposals.removeFirst().dispose()
        if !pendingDisposals.isEmpty { scheduleDisposal(after: .zero) }
    }

    /// Frees every evicted engine now (app quit, tests).
    public func flushDisposals() {
        let engines = pendingDisposals
        pendingDisposals = []
        for engine in engines { engine.dispose() }
    }
}
