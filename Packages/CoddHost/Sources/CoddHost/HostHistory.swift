import Foundation

/// The last `capacity` samples' CPU and memory figures, oldest first, for the CPU / MEM
/// sparklines (M3 D26: 120 samples at 5 s = the artboard's 10 minutes). Only the two numbers
/// per sample are kept, so a full history is a few kilobytes.
public struct HostHistory: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var at: Date
        /// nil for a sample without a CPU figure (a sampler's first sample).
        public var cpuTotal: Double?
        public var memoryUsedFraction: Double
    }

    public let capacity: Int
    public private(set) var points: [Point] = []

    /// A capacity below 1 is treated as 1.
    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
        points.reserveCapacity(self.capacity)
    }

    public mutating func append(_ s: HostSample) {
        if points.count >= capacity { points.removeFirst(points.count - capacity + 1) }
        points.append(Point(at: s.at, cpuTotal: s.cpu?.total, memoryUsedFraction: s.memory.usedFraction))
    }

    public mutating func removeAll() {
        points.removeAll(keepingCapacity: true)
    }

    public var count: Int { points.count }
    public var isEmpty: Bool { points.isEmpty }

    /// CPU total percent, oldest first. Samples without a CPU figure are skipped, so this can be
    /// one shorter than ``memoryUsedFraction`` right after the sampler was created.
    public var cpuTotal: [Double] { points.compactMap(\.cpuTotal) }

    /// `used / total` in 0 ... 1, oldest first, one per sample.
    public var memoryUsedFraction: [Double] { points.map(\.memoryUsedFraction) }

    /// Highest CPU total in the window (the artboard's `peak 38%`); nil before any CPU figure.
    public var cpuPeak: Double? { points.lazy.compactMap(\.cpuTotal).max() }
}
