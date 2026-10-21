import Dispatch
import Synchronization

/// How long a block waits for the main thread, sampled once a second (M3 D26: the CODD APP card's
/// `event loop p99 3ms`).
///
/// A timer on a utility queue notes when it fired and posts a block to the main queue; the block
/// records how long it waited. A main thread busy for 50 ms shows up as delays up to 50 ms, a
/// stall of several seconds as one delay per second of the stall. Only the last `capacity` (300,
/// five minutes) delays are kept, in a fixed ring, so the probe costs one tiny block a second.
///
/// The clock is uptime (`DispatchTime`), which stops while the Mac sleeps, so sleep never counts
/// as latency. `start()` / `stop()` are idempotent; delays survive a stop (the card keeps its last
/// figure while STATUS is paused) until ``reset()``.
public final class MainThreadLatencyProbe: Sendable {
    /// Runs a block on the thread being measured (the main queue unless a test injects another).
    public typealias Post = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct State {
        var timer: (any DispatchSourceTimer)?
        /// Bumped by `stop()`, so blocks still queued from before the stop are not recorded.
        var generation: UInt64 = 0
        var delays: [UInt64]
        var nextSlot = 0
    }

    public let interval: DispatchTimeInterval
    public let capacity: Int
    private let timerQueue: DispatchQueue
    private let post: Post
    private let clock: @Sendable () -> UInt64
    private let state: Mutex<State>

    /// 1 Hz, last 300 delays, measuring the main queue.
    public convenience init() {
        self.init(interval: .seconds(1))
    }

    /// - Parameters:
    ///   - interval: time between probes.
    ///   - capacity: delays kept for the percentile (at least 1).
    ///   - timerQueue: where the timer fires; a private utility queue by default.
    ///   - post: enqueues the measuring block on the measured thread.
    ///   - clock: monotonic nanoseconds.
    public init(interval: DispatchTimeInterval,
                capacity: Int = 300,
                timerQueue: DispatchQueue = DispatchQueue(label: "codd.host.latency-probe", qos: .utility),
                post: @escaping Post = { DispatchQueue.main.async(execute: $0) },
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.interval = interval
        self.capacity = max(1, capacity)
        self.timerQueue = timerQueue
        self.post = post
        self.clock = clock
        var delays: [UInt64] = []
        delays.reserveCapacity(self.capacity)
        state = Mutex(State(delays: delays))
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
    }

    public func start() {
        state.withLock { s in
            guard s.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            // 10 % leeway lets the system coalesce the wakeup; the delay is measured from the
            // moment the timer actually fired, so leeway never inflates it.
            timer.schedule(deadline: .now() + interval, repeating: interval,
                           leeway: .nanoseconds(Int(min(Self.nanoseconds(interval) / 10, UInt64(Int.max)))))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            s.timer = timer
        }
    }

    public func stop() {
        state.withLock { s in
            guard let timer = s.timer else { return }
            timer.cancel()
            s.timer = nil
            s.generation &+= 1
        }
    }

    public var isRunning: Bool { state.withLock { $0.timer != nil } }

    /// Delays currently kept (at most `capacity`).
    public var sampleCount: Int { state.withLock { $0.delays.count } }

    /// 99th percentile (nearest rank) of the kept delays; nil before 10 delays were recorded, so
    /// the card shows `—` for the first ten seconds instead of a meaningless figure.
    public var p99Milliseconds: Double? { percentileMilliseconds(99) }

    /// Nearest-rank percentile (`percent` in 0 ... 100) of the kept delays; nil below 10 delays.
    public func percentileMilliseconds(_ percent: Double) -> Double? {
        var sorted = state.withLock { $0.delays }
        guard sorted.count >= 10 else { return nil }
        sorted.sort()
        let rank = Int((Double(sorted.count) * min(100, max(0, percent)) / 100).rounded(.up)) - 1
        return Double(sorted[min(max(rank, 0), sorted.count - 1)]) / 1_000_000
    }

    /// Drops every kept delay.
    public func reset() {
        state.withLock { s in
            s.delays.removeAll(keepingCapacity: true)
            s.nextSlot = 0
        }
    }

    // MARK: - Internals (the timer handler; tests drive it directly with a fake clock)

    func tick() {
        let generation = state.withLock { $0.generation }
        let firedAt = clock()
        post { [weak self] in
            guard let self else { return }
            let now = self.clock()
            self.record(nanoseconds: now >= firedAt ? now - firedAt : 0, generation: generation)
        }
    }

    func record(nanoseconds: UInt64, generation: UInt64? = nil) {
        state.withLock { s in
            if let generation, generation != s.generation { return }
            if s.delays.count < capacity {
                s.delays.append(nanoseconds)
            } else {
                s.delays[s.nextSlot] = nanoseconds
                s.nextSlot = (s.nextSlot + 1) % capacity
            }
        }
    }

    static func nanoseconds(_ interval: DispatchTimeInterval) -> UInt64 {
        switch interval {
        case .seconds(let n): UInt64(max(0, n)) * 1_000_000_000
        case .milliseconds(let n): UInt64(max(0, n)) * 1_000_000
        case .microseconds(let n): UInt64(max(0, n)) * 1_000
        case .nanoseconds(let n): UInt64(max(0, n))
        case .never: 0
        @unknown default: 1_000_000_000
        }
    }
}
