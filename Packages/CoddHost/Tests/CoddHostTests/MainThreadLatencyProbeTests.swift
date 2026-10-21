import Dispatch
import Foundation
import Synchronization
import Testing
@testable import CoddHost

@Suite("MainThreadLatencyProbe")
struct MainThreadLatencyProbeTests {
    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    static func wait(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A probe whose "main queue" runs blocks synchronously after advancing a fake clock by
    /// `delayMilliseconds`: every tick records exactly that delay.
    static func fakeProbe(delayMilliseconds: UInt64, capacity: Int = 300) -> MainThreadLatencyProbe {
        let now = Mutex<UInt64>(1_000_000_000)
        return MainThreadLatencyProbe(
            interval: .seconds(1), capacity: capacity,
            post: { block in
                now.withLock { $0 += delayMilliseconds * 1_000_000 }
                block()
            },
            clock: { now.withLock { $0 } })
    }

    @Test func defaultsAreOneHertzAndThreeHundredSamples() {
        let probe = MainThreadLatencyProbe()
        #expect(probe.interval == .seconds(1))
        #expect(probe.capacity == 300)
        #expect(!probe.isRunning)
        #expect(probe.p99Milliseconds == nil)
    }

    @Test func p99IsNilBeforeTenSamples() {
        let probe = Self.fakeProbe(delayMilliseconds: 50)
        for _ in 0..<9 { probe.tick() }
        #expect(probe.sampleCount == 9)
        #expect(probe.p99Milliseconds == nil)
        probe.tick()
        #expect(probe.p99Milliseconds == 50)
    }

    @Test func injectedFiftyMillisecondMainQueueDelayWithAFakeClock() {
        let probe = Self.fakeProbe(delayMilliseconds: 50)
        for _ in 0..<40 { probe.tick() }
        #expect(probe.p99Milliseconds == 50)
        #expect(probe.percentileMilliseconds(50) == 50)
    }

    @Test func nearestRankPercentiles() {
        let probe = Self.fakeProbe(delayMilliseconds: 0)
        for ms in (1...100).reversed() { probe.record(nanoseconds: UInt64(ms) * 1_000_000) }
        #expect(probe.p99Milliseconds == 99)
        #expect(probe.percentileMilliseconds(50) == 50)
        #expect(probe.percentileMilliseconds(100) == 100)
        #expect(probe.percentileMilliseconds(0) == 1)
        #expect(probe.percentileMilliseconds(250) == 100)
    }

    @Test func keepsOnlyTheLastCapacityDelays() {
        let probe = Self.fakeProbe(delayMilliseconds: 0)
        for _ in 0..<100 { probe.record(nanoseconds: 9_000_000_000) }   // an old 9 s stall
        for _ in 0..<300 { probe.record(nanoseconds: 2_000_000) }
        #expect(probe.sampleCount == 300)
        #expect(probe.p99Milliseconds == 2)
        // Nearest rank over 300: the 297th smallest. Three slow delays are under 1 %, four are not.
        for _ in 0..<3 { probe.record(nanoseconds: 700_000_000) }
        #expect(probe.sampleCount == 300)
        #expect(probe.p99Milliseconds == 2)
        probe.record(nanoseconds: 700_000_000)
        #expect(probe.p99Milliseconds == 700)
        probe.reset()
        #expect(probe.sampleCount == 0)
        #expect(probe.p99Milliseconds == nil)
    }

    @Test func startAndStopAreIdempotent() {
        let probe = MainThreadLatencyProbe(interval: .seconds(60))
        probe.stop()
        #expect(!probe.isRunning)
        probe.start()
        probe.start()
        #expect(probe.isRunning)
        probe.stop()
        probe.stop()
        #expect(!probe.isRunning)
        probe.start()
        #expect(probe.isRunning)
        probe.stop()
    }

    @Test func blocksQueuedBeforeStopAreNotRecorded() {
        let pending = Mutex<[@Sendable () -> Void]>([])
        let probe = MainThreadLatencyProbe(interval: .seconds(60), post: { block in pending.withLock { $0.append(block) } })
        probe.start()
        for _ in 0..<12 { probe.tick() }
        probe.stop()
        for block in pending.withLock({ $0 }) { block() }
        #expect(probe.sampleCount == 0)
        // After a restart new blocks count again; delays from before a stop are kept.
        pending.withLock { $0.removeAll() }
        probe.start()
        for _ in 0..<10 { probe.tick() }
        for block in pending.withLock({ $0 }) { block() }
        #expect(probe.sampleCount == 10)
        probe.stop()
        #expect(probe.sampleCount == 10)
    }

    /// The real timer, with a stand-in main queue that runs every block 50 ms late.
    @Test func timerWithAnInjectedFiftyMillisecondDelay() async {
        let late = DispatchQueue(label: "codd.host.test.late-main")
        let probe = MainThreadLatencyProbe(
            interval: .milliseconds(10),
            post: { block in late.asyncAfter(deadline: .now() + .milliseconds(50), execute: block) })
        probe.start()
        #expect(await Self.wait { probe.sampleCount >= 30 })
        probe.stop()
        let p99 = probe.p99Milliseconds ?? -1, p50 = probe.percentileMilliseconds(50) ?? -1
        print(String(format: "MEASURE probe with injected 50 ms delay: p50 %.1f ms, p99 %.1f ms over %d", p50, p99, probe.sampleCount))
        #expect(p50 >= 49)
        #expect(p99 >= 50 && p99 < 1_000)
    }

    /// The default probe on the real main queue: a main actor blocked 60 ms at a time shows up.
    @MainActor
    @Test func realMainQueueBlockedSixtyMilliseconds() async {
        let probe = MainThreadLatencyProbe(interval: .milliseconds(10), timerQueue: DispatchQueue(label: "codd.host.test.timer", qos: .utility))
        probe.start()
        // Idle first: the main queue answers quickly.
        _ = await Self.wait { probe.sampleCount >= 10 }
        for _ in 0..<12 {
            usleep(60_000)   // block the main thread
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(300))   // let the queued blocks drain
        probe.stop()
        let p99 = probe.p99Milliseconds ?? -1
        print(String(format: "MEASURE probe on the real main queue blocked 60 ms: p99 %.1f ms over %d", p99, probe.sampleCount))
        #expect(p99 >= 40)
        #expect(p99 < 1_000)
    }

    struct WeakProbe: Sendable {
        weak var value: MainThreadLatencyProbe?
    }

    /// The running timer holds the probe weakly, so dropping the probe stops it.
    @Test func probeDoesNotOutliveItsOwner() async {
        let ref: WeakProbe = {
            let probe = MainThreadLatencyProbe(interval: .milliseconds(10))
            probe.start()
            return WeakProbe(value: probe)
        }()
        #expect(await Self.wait(timeout: .seconds(1)) { ref.value == nil })
    }
}
