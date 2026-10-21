import Foundation
import Testing
@testable import CoddHost

@Suite("HostHistory")
struct HostHistoryTests {
    static let gib: UInt64 = 1 << 30

    static func sample(_ second: Int, cpu: Double?, usedGiB: UInt64, totalGiB: UInt64 = 36) -> HostSample {
        HostSample(
            at: Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(second)),
            cpu: cpu.map { HostSample.CPU(user: $0 * 0.7, system: $0 * 0.3, total: $0, load1: 1, load5: 1, load15: 1, cores: 12) },
            memory: HostSample.Memory(total: totalGiB * gib, used: usedGiB * gib, app: usedGiB * gib, wired: 0, compressed: 0, pressure: .normal),
            disk: nil, swap: HostSample.Swap(total: 0, used: 0), battery: nil,
            bootedAt: Date(timeIntervalSince1970: 1_789_000_000), hostName: "studio-mbp")
    }

    @Test func defaultCapacityIsTenMinutesAtFiveSeconds() {
        #expect(HostHistory().capacity == 120)
        #expect(HostHistory(capacity: 0).capacity == 1)
        #expect(HostHistory(capacity: -5).capacity == 1)
    }

    @Test func emptyHistory() {
        let history = HostHistory()
        #expect(history.isEmpty)
        #expect(history.cpuTotal.isEmpty)
        #expect(history.memoryUsedFraction.isEmpty)
        #expect(history.cpuPeak == nil)
    }

    @Test func keepsTheNewestCapacitySamplesOldestFirst() {
        var history = HostHistory(capacity: 3)
        for i in 1...5 { history.append(Self.sample(i, cpu: Double(i * 10), usedGiB: UInt64(i))) }
        #expect(history.count == 3)
        #expect(history.cpuTotal == [30, 40, 50])
        let times: [TimeInterval] = [1_790_000_003, 1_790_000_004, 1_790_000_005]
        #expect(history.points.map(\.at.timeIntervalSince1970) == times)
        let expected: [Double] = [3, 4, 5].map { $0 / 36 }
        #expect(history.memoryUsedFraction == expected)
        #expect(history.cpuPeak == 50)
    }

    @Test func fullDefaultHistoryStaysBounded() {
        var history = HostHistory()
        for i in 0..<1_000 { history.append(Self.sample(i, cpu: Double(i % 100), usedGiB: 10)) }
        #expect(history.count == 120)
        #expect(history.cpuTotal.first == Double(880 % 100))
        #expect(history.cpuTotal.last == 99)
    }

    @Test func samplesWithoutCPUAreSkippedInTheCPUSeriesOnly() {
        var history = HostHistory(capacity: 10)
        history.append(Self.sample(0, cpu: nil, usedGiB: 9))
        #expect(history.cpuPeak == nil)
        #expect(history.cpuTotal.isEmpty)
        history.append(Self.sample(5, cpu: 38, usedGiB: 18))
        history.append(Self.sample(10, cpu: 23, usedGiB: 36))
        #expect(history.cpuTotal == [38, 23])
        #expect(history.memoryUsedFraction == [0.25, 0.5, 1])
        #expect(history.cpuPeak == 38)
    }

    @Test func peakFollowsTheWindow() {
        var history = HostHistory(capacity: 2)
        history.append(Self.sample(0, cpu: 90, usedGiB: 1))
        history.append(Self.sample(1, cpu: 10, usedGiB: 1))
        #expect(history.cpuPeak == 90)
        history.append(Self.sample(2, cpu: 20, usedGiB: 1))
        #expect(history.cpuPeak == 20)
    }

    @Test func memoryFractionIsZeroWithoutATotal() {
        var history = HostHistory()
        history.append(Self.sample(0, cpu: 1, usedGiB: 4, totalGiB: 0))
        #expect(history.memoryUsedFraction == [0])
    }

    @Test func equalityAndRemoveAll() {
        var a = HostHistory(capacity: 4), b = HostHistory(capacity: 4)
        for i in 0..<6 { a.append(Self.sample(i, cpu: 1, usedGiB: 1)) }
        for i in 2..<6 { b.append(Self.sample(i, cpu: 1, usedGiB: 1)) }
        #expect(a == b)
        a.removeAll()
        #expect(a.isEmpty && a.capacity == 4)
        #expect(a == HostHistory(capacity: 4))
    }

    @Test func liveSamplesFeedTheHistory() async throws {
        let sampler = HostSampler()
        var history = HostHistory(capacity: 3)
        history.append(sampler.sample())
        try await Task.sleep(for: .milliseconds(200))
        history.append(sampler.sample())
        #expect(history.count == 2)
        #expect(history.cpuTotal.count == 1)
        #expect(history.memoryUsedFraction.allSatisfy { $0 > 0 && $0 <= 1 })
    }
}
