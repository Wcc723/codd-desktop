/// Where a terminal's surface lives.
public enum TerminalTier: Sendable, Equatable {
    /// On screen and rendering.
    case visible
    /// Occluded: the surface is kept (grid, scrollback, modes) and keeps parsing, but does not draw.
    case hot
    /// No surface. Showing it again needs a new surface and a replay from the holder's ring.
    case cold
}

/// The visible / hot / cold policy behind `TerminalPool`, as a pure value so it is tested without
/// AppKit or libghostty.
///
/// Hot keys form a segmented LRU (M5 D15, review F5) of at most `hotCapacity` entries, so that
/// scanning through many terminals (⌃Tab, ⌘K) does not push out the ones the user works in:
/// - **protected** (at most `protectedCapacity`): terminals the user worked in, i.e. hidden after a
///   showing of at least `protectingDwell`, or revealed from hot again (a revisit);
/// - **probation** (the rest of the capacity, at least 2 by default): quick flips.
///
/// Both lists are most recently hidden first. Pushing past the capacity turns probation's oldest
/// key cold first (protected only when probation has nothing left to give); a full protected
/// segment demotes its oldest key to probation's head. Plain "second access" SLRU is not enough:
/// with a probation of 2, "work in X, glance at A, B, C, back to X" would evict X, so the time a
/// terminal was shown counts as well (measured with the injected monotonic clock).
///
/// A pinned key is never turned cold (CODD pins a `claude` surface until the terminal answered its
/// startup probes): pinned keys count toward the capacity but are skipped when choosing what to
/// evict, so the hot keys exceed the capacity only while more of them are pinned than it holds.
public struct TerminalTierPolicy<Key: Hashable & Sendable>: Sendable {
    /// What one call changed. A key appears in at most one list.
    public struct Changes: Sendable, Equatable {
        /// Hot → visible: the surface exists; just stop occluding it.
        public var revealed: [Key] = []
        /// Cold → visible: create a surface; the owner must replay its history.
        public var created: [Key] = []
        /// Visible → hot: occlude the surface.
        public var hidden: [Key] = []
        /// Hot → cold: dispose of the surface.
        public var evicted: [Key] = []

        public init(revealed: [Key] = [], created: [Key] = [], hidden: [Key] = [], evicted: [Key] = []) {
            self.revealed = revealed
            self.created = created
            self.hidden = hidden
            self.evicted = evicted
        }

        public var isEmpty: Bool {
            revealed.isEmpty && created.isEmpty && hidden.isEmpty && evicted.isEmpty
        }
    }

    /// A showing at least this long means the user worked in the terminal (D15): it is hidden into
    /// the protected segment. Shorter ones are quick flips (probation).
    public static var protectingDwell: Duration { .seconds(5) }

    /// What `init(hotCapacity:)` leaves to probation: enough for a quick back-and-forth between two
    /// terminals on top of the protected ones (2 + 4 = the 6 hot surfaces of M1).
    public static var defaultProbationCapacity: Int { 2 }

    public let hotCapacity: Int
    /// The most hot keys kept in the protected segment; probation gets the rest of `hotCapacity`
    /// (and any protected slot not in use).
    public let protectedCapacity: Int
    /// In the order last passed to `setVisible`.
    public private(set) var visible: [Key] = []
    /// Worked-in terminals, most recently hidden first.
    public private(set) var protected: [Key] = []
    /// Quick flips (and demoted protected keys), most recently hidden first; evicted first.
    public private(set) var probation: [Key] = []
    public private(set) var pinned: Set<Key> = []

    /// Every hot key, the one kept longest first: protected, then probation. Without pins the last
    /// one is the next to turn cold.
    public var hot: [Key] { protected + probation }

    private struct Showing: Sendable {
        var since: ContinuousClock.Instant
        /// Revealed from hot (a revisit) rather than created.
        var revealed: Bool
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    /// The current showing of every visible key.
    private var showings: [Key: Showing] = [:]

    /// - Parameters:
    ///   - hotCapacity: hidden surfaces kept alive (6 in CODD).
    ///   - protectedCapacity: the protected segment's size, clamped to `hotCapacity`; nil leaves
    ///     `defaultProbationCapacity` to probation (`hotCapacity` 6 → 4 protected, 2 or less → 0,
    ///     which is a plain LRU).
    ///   - clock: a monotonic "now" (tests inject one they move by hand).
    public init(
        hotCapacity: Int = 6,
        protectedCapacity: Int? = nil,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        let capacity = max(0, hotCapacity)
        self.hotCapacity = capacity
        let requested = protectedCapacity ?? (capacity - Self.defaultProbationCapacity)
        self.protectedCapacity = min(capacity, max(0, requested))
        now = clock
    }

    public func tier(of key: Key) -> TerminalTier {
        if visible.contains(key) { return .visible }
        if protected.contains(key) || probation.contains(key) { return .hot }
        return .cold
    }

    /// Makes exactly `keys` visible (duplicates ignored). Previously visible keys that are not in
    /// `keys` become hot (protected or probation by how their showing went); the hot keys are
    /// then trimmed to the capacity.
    @discardableResult
    public mutating func setVisible(_ keys: [Key]) -> Changes {
        var seen = Set<Key>()
        let next = keys.filter { seen.insert($0).inserted }
        var changes = Changes()
        let time = now()

        for key in visible where !seen.contains(key) {
            hide(key, at: time)
            changes.hidden.append(key)
        }
        for key in next where !visible.contains(key) {
            if removeFromHot(key) {
                changes.revealed.append(key)
                showings[key] = Showing(since: time, revealed: true)
            } else {
                changes.created.append(key)
                showings[key] = Showing(since: time, revealed: false)
            }
        }
        visible = next
        trim(into: &changes)
        return changes
    }

    /// Pins or unpins `key`. Unpinning can turn hot keys cold if they were over capacity.
    @discardableResult
    public mutating func setPinned(_ isPinned: Bool, for key: Key) -> Changes {
        var changes = Changes()
        if isPinned {
            pinned.insert(key)
        } else if pinned.remove(key) != nil {
            trim(into: &changes)
        }
        return changes
    }

    /// Forgets `key` entirely (its session was deleted). Returns the tier it had.
    @discardableResult
    public mutating func remove(_ key: Key) -> TerminalTier {
        let tier = tier(of: key)
        visible.removeAll { $0 == key }
        _ = removeFromHot(key)
        showings[key] = nil
        pinned.remove(key)
        return tier
    }

    /// A worked-in or revisited key goes to protected's head (demoting protected's oldest to
    /// probation's head when full), a quick flip to probation's head.
    private mutating func hide(_ key: Key, at time: ContinuousClock.Instant) {
        let showing = showings.removeValue(forKey: key)
        let workedIn = showing.map { $0.revealed || time - $0.since >= Self.protectingDwell } ?? false
        guard workedIn else {
            probation.insert(key, at: 0)
            return
        }
        protected.insert(key, at: 0)
        if protected.count > protectedCapacity {
            probation.insert(protected.removeLast(), at: 0)
        }
    }

    private mutating func removeFromHot(_ key: Key) -> Bool {
        if let index = protected.firstIndex(of: key) {
            protected.remove(at: index)
            return true
        }
        if let index = probation.firstIndex(of: key) {
            probation.remove(at: index)
            return true
        }
        return false
    }

    /// Turns the oldest unpinned keys cold, probation first, until the hot keys fit.
    private mutating func trim(into changes: inout Changes) {
        for segment in [\Self.probation, \Self.protected] {
            var index = self[keyPath: segment].count - 1
            while protected.count + probation.count > hotCapacity, index >= 0 {
                let key = self[keyPath: segment][index]
                if !pinned.contains(key) {
                    self[keyPath: segment].remove(at: index)
                    if let hiddenIndex = changes.hidden.firstIndex(of: key) {
                        changes.hidden.remove(at: hiddenIndex)
                    }
                    changes.evicted.append(key)
                }
                index -= 1
            }
        }
    }
}
