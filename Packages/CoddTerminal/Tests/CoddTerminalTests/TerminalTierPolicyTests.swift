import Synchronization
import Testing
@testable import CoddTerminal

/// A monotonic clock the test moves by hand.
private final class ManualClock: Sendable {
    private let origin = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)

    var now: ContinuousClock.Instant { origin + offset.withLock { $0 } }

    func advance(_ duration: Duration) {
        offset.withLock { $0 += duration }
    }
}

@Suite("Terminal tiers (segmented LRU policy)")
struct TerminalTierPolicyTests {
    typealias Policy = TerminalTierPolicy<String>

    private let clock = ManualClock()

    /// The default split (2 + 4) on the test's clock.
    private func policy(hotCapacity: Int = 6, protectedCapacity: Int? = nil) -> Policy {
        let clock = clock
        return Policy(hotCapacity: hotCapacity, protectedCapacity: protectedCapacity) { clock.now }
    }

    /// Shows `key` alone for `duration`; returns what showing it changed.
    @discardableResult
    private func show(_ key: String, for duration: Duration, in policy: inout Policy) -> Policy.Changes {
        let changes = policy.setVisible([key])
        clock.advance(duration)
        return changes
    }

    @Test func newKeysAreCreatedVisible() {
        var policy = Policy(hotCapacity: 2)
        let changes = policy.setVisible(["a", "b"])
        #expect(changes == Policy.Changes(created: ["a", "b"]))
        #expect(policy.tier(of: "a") == .visible)
        #expect(policy.tier(of: "z") == .cold)
    }

    @Test func hidingKeepsSurfacesHotInRecencyOrder() {
        var policy = Policy(hotCapacity: 3)
        policy.setVisible(["a"])
        #expect(policy.setVisible(["b"]) == Policy.Changes(created: ["b"], hidden: ["a"]))
        policy.setVisible(["c"])
        #expect(policy.hot == ["b", "a"])
        // Showing a hot key again reveals it without a new surface.
        #expect(policy.setVisible(["a"]) == Policy.Changes(revealed: ["a"], hidden: ["c"]))
        #expect(policy.hot == ["c", "b"])
    }

    @Test func overflowEvictsTheLeastRecentlyHidden() {
        var policy = Policy(hotCapacity: 2)
        for key in ["a", "b", "c"] {
            policy.setVisible([key])
        }
        #expect(policy.hot == ["b", "a"])
        let changes = policy.setVisible(["d"])
        #expect(changes.hidden == ["c"])
        #expect(changes.evicted == ["a"])
        #expect(policy.hot == ["c", "b"])
        #expect(policy.tier(of: "a") == .cold)
        // A cold key comes back as created (needs a new surface and a replay).
        #expect(policy.setVisible(["a"]).created == ["a"])
    }

    @Test func defaultKeepsSixHot() {
        var policy = Policy()
        #expect(policy.hotCapacity == 6)
        for index in 0 ..< 10 {
            policy.setVisible(["s\(index)"])
        }
        #expect(policy.visible == ["s9"])
        #expect(policy.hot == ["s8", "s7", "s6", "s5", "s4", "s3"])
        #expect((0 ... 2).allSatisfy { policy.tier(of: "s\($0)") == .cold })
    }

    @Test func severalVisibleAtOnce() {
        var policy = Policy(hotCapacity: 1)
        policy.setVisible(["claude", "shell"])
        let changes = policy.setVisible(["shell", "other"])
        #expect(changes == Policy.Changes(created: ["other"], hidden: ["claude"]))
        #expect(policy.visible == ["shell", "other"])
        #expect(policy.setVisible(["other", "other"]) == Policy.Changes(hidden: ["shell"], evicted: ["claude"]))
        #expect(policy.visible == ["other"])
    }

    @Test func hiddenAndEvictedInOneCallIsReportedOnlyAsEvicted() {
        var policy = Policy(hotCapacity: 0)
        policy.setVisible(["a"])
        #expect(policy.setVisible(["b"]) == Policy.Changes(created: ["b"], evicted: ["a"]))
    }

    @Test func pinnedKeysAreNeverEvicted() {
        var policy = Policy(hotCapacity: 1)
        policy.setVisible(["a"])
        policy.setPinned(true, for: "a")
        policy.setVisible(["b"])
        // a is older but pinned, so the unpinned b goes instead.
        #expect(policy.setVisible(["c"]) == Policy.Changes(created: ["c"], evicted: ["b"]))
        #expect(policy.hot == ["a"])
        #expect(policy.tier(of: "b") == .cold)
        // Pinned keys count toward the capacity: c cannot stay hot next to a.
        #expect(policy.setVisible(["d"]) == Policy.Changes(created: ["d"], evicted: ["c"]))
        #expect(policy.setPinned(false, for: "a").isEmpty)
        #expect(policy.hot == ["a"])
    }

    @Test func allPinnedMayExceedCapacity() {
        var policy = Policy(hotCapacity: 1)
        for key in ["a", "b", "c"] {
            policy.setVisible([key])
            policy.setPinned(true, for: key)
        }
        policy.setVisible([])
        #expect(policy.hot == ["c", "b", "a"])
        #expect(policy.setPinned(false, for: "b") == Policy.Changes(evicted: ["b"]))
        #expect(policy.hot == ["c", "a"])
    }

    @Test func removeForgetsEverywhere() {
        var policy = Policy(hotCapacity: 2)
        policy.setVisible(["a"])
        policy.setPinned(true, for: "a")
        #expect(policy.remove("a") == .visible)
        #expect(policy.visible.isEmpty && !policy.pinned.contains("a"))
        policy.setVisible(["b"])
        policy.setVisible(["c"])
        #expect(policy.remove("b") == .hot)
        #expect(policy.remove("zzz") == .cold)
        #expect(policy.hot.isEmpty)
    }

    @Test func unchangedVisibilityChangesNothing() {
        var policy = Policy(hotCapacity: 2)
        policy.setVisible(["a", "b"])
        #expect(policy.setVisible(["a", "b"]).isEmpty)
        #expect(policy.setVisible(["b", "a"]).isEmpty)
        #expect(policy.visible == ["b", "a"])
    }

    // MARK: - Segmented LRU (M5 D15)

    @Test func defaultSplitIsTwoProbationAndFourProtected() {
        #expect(policy().protectedCapacity == 4)
        #expect(policy(hotCapacity: 10).protectedCapacity == 8)
        #expect(policy(hotCapacity: 2).protectedCapacity == 0)
        #expect(policy(hotCapacity: 1).protectedCapacity == 0)
        #expect(policy(hotCapacity: 0).protectedCapacity == 0)
        #expect(policy(hotCapacity: 3, protectedCapacity: 9).protectedCapacity == 3)
        #expect(policy(hotCapacity: 3, protectedCapacity: -1).protectedCapacity == 0)
    }

    /// The critique's case: plain "second access" SLRU with a probation of 2 evicts X here.
    @Test func workedInTerminalSurvivesThreeGlances() {
        var policy = policy()
        for key in ["p1", "p2", "p3", "p4"] {
            show(key, for: .seconds(10), in: &policy)
        }
        show("x", for: .seconds(30), in: &policy)
        for key in ["a", "b", "c"] {
            show(key, for: .seconds(1), in: &policy)
        }
        #expect(policy.protected == ["x", "p4", "p3", "p2"])
        let back = policy.setVisible(["x"])
        #expect(back == Policy.Changes(revealed: ["x"], hidden: ["c"]))
        #expect(policy.protected == ["p4", "p3", "p2"])
        #expect(policy.probation == ["c", "b", "a"])
        #expect(policy.tier(of: "p1") == .cold)
    }

    @Test func scanOfQuickFlipsKeepsProtectedHot() {
        var policy = policy()
        for key in ["w1", "w2", "w3", "w4"] {
            show(key, for: .seconds(8), in: &policy)
        }
        var evicted: [String] = []
        for index in 0 ..< 10 {
            evicted += show("s\(index)", for: .milliseconds(300), in: &policy).evicted
        }
        #expect(policy.protected == ["w4", "w3", "w2", "w1"])
        #expect(policy.probation == ["s8", "s7"])
        #expect(evicted == (0 ..< 7).map { "s\($0)" }, "the scan churns probation only")
        for key in ["w1", "w2", "w3", "w4"] {
            #expect(show(key, for: .seconds(1), in: &policy).revealed == [key])
        }
    }

    @Test func revisitPromotesAQuickFlip() {
        var policy = policy()
        show("a", for: .seconds(1), in: &policy)
        show("b", for: .seconds(1), in: &policy)
        #expect(policy.probation == ["a"])
        #expect(show("a", for: .seconds(1), in: &policy).revealed == ["a"])
        show("c", for: .seconds(1), in: &policy)
        #expect(policy.protected == ["a"], "revealed from hot, so hidden into protected")
        #expect(policy.probation == ["b"])
        // A cold key shown again briefly is a new showing, not a revisit.
        var tiny = self.policy(hotCapacity: 0)
        show("z", for: .seconds(1), in: &tiny)
        show("y", for: .seconds(1), in: &tiny)
        #expect(show("z", for: .seconds(1), in: &tiny).created == ["z"])
    }

    @Test func dwellAtTheThresholdProtects() {
        var policy = policy()
        show("long", for: Policy.protectingDwell, in: &policy)
        show("short", for: Policy.protectingDwell - .milliseconds(1), in: &policy)
        show("next", for: .seconds(1), in: &policy)
        #expect(policy.protected == ["long"])
        #expect(policy.probation == ["short"])
    }

    @Test func evictionTakesProbationsOldestFirst() {
        var policy = policy(hotCapacity: 4, protectedCapacity: 2)
        show("w1", for: .seconds(6), in: &policy)
        show("w2", for: .seconds(6), in: &policy)
        var evicted: [String] = []
        for key in ["q1", "q2", "q3", "q4", "q5"] {
            evicted += show(key, for: .seconds(1), in: &policy).evicted
        }
        // Probation holds 2 next to the 2 protected keys: q1 and q2 went cold, oldest first.
        #expect(evicted == ["q1", "q2"])
        #expect(policy.hot == ["w2", "w1", "q4", "q3"])
        #expect(policy.setVisible(["q1"]).evicted == ["q3"])
        #expect(policy.hot == ["w2", "w1", "q5", "q4"])
    }

    @Test func fullProtectedDemotesItsOldestToProbationsHead() {
        var policy = policy(hotCapacity: 4, protectedCapacity: 2)
        show("q0", for: .seconds(1), in: &policy)
        for key in ["w1", "w2", "w3"] {
            show(key, for: .seconds(6), in: &policy)
        }
        show("x", for: .seconds(1), in: &policy)
        #expect(policy.protected == ["w3", "w2"])
        #expect(policy.probation == ["w1", "q0"], "the demoted key is probation's newest")
        // The next quick flip pushes probation's oldest out, not the demoted key.
        #expect(show("y", for: .seconds(1), in: &policy).evicted == ["q0"])
        #expect(policy.probation == ["x", "w1"])
        #expect(show("z", for: .seconds(1), in: &policy).evicted == ["w1"])
    }

    @Test func pinnedKeysAreSkippedInBothSegments() {
        var policy = policy(hotCapacity: 3, protectedCapacity: 1)
        show("w", for: .seconds(10), in: &policy)
        show("a", for: .seconds(1), in: &policy)
        policy.setPinned(true, for: "a")
        show("b", for: .seconds(1), in: &policy)
        policy.setPinned(true, for: "b")
        show("c", for: .seconds(1), in: &policy)
        #expect(policy.protected == ["w"] && policy.probation == ["b", "a"])
        // Probation's unpinned c goes before the older, pinned a and b.
        #expect(show("d", for: .seconds(1), in: &policy) == Policy.Changes(created: ["d"], evicted: ["c"]))
        policy.setPinned(true, for: "d")
        // Probation holds only pins now: protected's unpinned w goes.
        #expect(show("e", for: .seconds(1), in: &policy) == Policy.Changes(created: ["e"], hidden: ["d"], evicted: ["w"]))
        #expect(policy.protected.isEmpty && policy.probation == ["d", "b", "a"])
        policy.setPinned(true, for: "e")
        // Every hot key is pinned: over capacity until one is unpinned, which trims the oldest.
        #expect(show("f", for: .seconds(1), in: &policy) == Policy.Changes(created: ["f"], hidden: ["e"]))
        #expect(policy.hot == ["e", "d", "b", "a"])
        #expect(policy.setPinned(false, for: "a") == Policy.Changes(evicted: ["a"]))
        #expect(policy.setPinned(false, for: "d").isEmpty)
    }

    @Test func capacityZeroKeepsNothingHot() {
        var policy = policy(hotCapacity: 0)
        show("a", for: .seconds(30), in: &policy)
        #expect(show("b", for: .seconds(1), in: &policy) == Policy.Changes(created: ["b"], evicted: ["a"]))
        #expect(policy.hot.isEmpty)
    }

    @Test func capacityOneIsAPlainLRUByDefault() {
        var policy = policy(hotCapacity: 1)
        show("a", for: .seconds(30), in: &policy)
        show("b", for: .seconds(1), in: &policy)
        #expect(show("c", for: .seconds(1), in: &policy).evicted == ["a"])
        #expect(policy.hot == ["b"])
    }

    @Test func capacityOneAllProtectedKeepsTheWorkedInTerminal() {
        var policy = policy(hotCapacity: 1, protectedCapacity: 1)
        show("a", for: .seconds(30), in: &policy)
        show("b", for: .seconds(1), in: &policy)
        #expect(show("c", for: .seconds(1), in: &policy).evicted == ["b"])
        #expect(policy.protected == ["a"])
    }

    @Test func severalVisibleKeysKeepTheirOwnShowings() {
        var policy = policy()
        policy.setVisible(["claude", "shell"])
        clock.advance(.seconds(2))
        policy.setVisible(["claude"])
        clock.advance(.seconds(4))
        // claude has been visible for 6 s in one showing, shell for 2 s.
        policy.setVisible(["other"])
        #expect(policy.protected == ["claude"])
        #expect(policy.probation == ["shell"])
    }

    @Test func removeForgetsTheShowing() {
        var policy = policy()
        show("a", for: .seconds(30), in: &policy)
        policy.remove("a")
        // Shown again later: a new, quick showing.
        policy.setVisible(["a"])
        show("b", for: .seconds(1), in: &policy)
        #expect(policy.probation == ["a"] && policy.protected.isEmpty)
        #expect(policy.remove("a") == .hot)
        #expect(policy.hot.isEmpty)
    }
}
