import Synchronization

/// Percentile summary of a set of latency samples, in milliseconds.
public struct LatencySummary: Sendable, Codable, Equatable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var max: Double
    public var mean: Double

    public static let empty = LatencySummary(count: 0, p50: 0, p95: 0, p99: 0, max: 0, mean: 0)

    /// Builds a summary with nearest-rank percentiles.
    public init(samples: [Double]) {
        guard !samples.isEmpty else {
            self = .empty
            return
        }
        let sorted = samples.sorted()
        func rank(_ p: Double) -> Double {
            let index = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, index))]
        }
        count = sorted.count
        p50 = rank(0.50)
        p95 = rank(0.95)
        p99 = rank(0.99)
        max = sorted[sorted.count - 1]
        mean = sorted.reduce(0, +) / Double(sorted.count)
    }

    public init(count: Int, p50: Double, p95: Double, p99: Double, max: Double, mean: Double) {
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.max = max
        self.mean = mean
    }

    /// Compact single-line rendering, e.g. `p50 0.12 / p95 0.30 / p99 0.41 ms (n=57)`.
    public var compact: String {
        guard count > 0 else { return "n=0" }
        return "p50 \(Self.fmt(p50)) / p95 \(Self.fmt(p95)) / p99 \(Self.fmt(p99)) / max \(Self.fmt(max)) ms (n=\(count))"
    }

    static func fmt(_ value: Double) -> String {
        let scaled = (value * 1000).rounded() / 1000
        return String(scaled)
    }
}

/// Thread-safe bounded store of latency samples (milliseconds).
public final class LatencyRecorder: Sendable {
    private let samples: Mutex<[Double]>
    private let capacity: Int

    public init(capacity: Int = 20_000) {
        self.capacity = capacity
        samples = Mutex([])
    }

    public func record(_ milliseconds: Double) {
        samples.withLock { storage in
            if storage.count >= capacity {
                storage.removeFirst(storage.count - capacity + 1)
            }
            storage.append(milliseconds)
        }
    }

    public func reset() {
        samples.withLock { $0.removeAll(keepingCapacity: true) }
    }

    public func summary() -> LatencySummary {
        LatencySummary(samples: samples.withLock { $0 })
    }
}
