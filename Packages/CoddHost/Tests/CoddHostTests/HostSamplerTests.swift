import Darwin
import Foundation
import Testing
@testable import CoddHost

/// Live readings on the Mac running the tests: only ranges and internal consistency are checked,
/// never a particular machine's numbers.
@Suite("HostSampler")
struct HostSamplerTests {
    @Test func firstSampleHasNoCPUAndSecondOneSecondLaterHasSaneCPU() async throws {
        let sampler = HostSampler()
        let first = sampler.sample()
        #expect(first.cpu == nil)
        try await Task.sleep(for: .seconds(1))
        let second = sampler.sample()
        let cpu = try #require(second.cpu)
        #expect(cpu.total >= 0 && cpu.total <= 100)
        #expect(cpu.user >= 0 && cpu.system >= 0)
        #expect(abs(cpu.user + cpu.system - cpu.total) < 0.001)
        #expect(cpu.cores == Int(Sysctl("hw.logicalcpu")?.readInteger() ?? -1))
        #expect(cpu.cores > 0)
        #expect(cpu.load1 >= 0 && cpu.load5 >= 0 && cpu.load15 >= 0)
    }

    @Test func memoryBreakdownFitsTotal() {
        let memory = HostSampler().sample().memory
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.total > 0)
        #expect(memory.used <= memory.total)
        #expect(memory.app + memory.wired + memory.compressed <= memory.total)
        #expect(memory.used == memory.app + memory.wired + memory.compressed)
        #expect(memory.used > 0 && memory.wired > 0)
        #expect(memory.usedFraction > 0 && memory.usedFraction <= 1)
    }

    @Test func swapDiskBootAndName() {
        let now = Date()
        let s = HostSampler().sample(now: now)
        #expect(s.at == now)
        #expect(s.swap.used <= s.swap.total)
        let disk = s.disk
        #expect(disk != nil)
        if let disk {
            #expect(disk.total > 0)
            #expect(disk.available <= disk.total)
            #expect(!disk.volumeName.isEmpty)
            #expect(disk.used + disk.available == disk.total)
        }
        #expect(s.bootedAt < now)
        #expect(now.timeIntervalSince(s.bootedAt) < 365 * 86_400)
        #expect(s.uptime > 0)
        #expect(!s.hostName.isEmpty)
        #expect(!s.hostName.lowercased().hasSuffix(".local"))
        if let battery = s.battery {
            #expect((0...100).contains(battery.percent))
            if battery.charging { #expect(battery.onAC) }
        }
    }

    @Test func diskFollowsThePathAndMissingPathsGiveNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codd-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try #require(HostSampler(diskPath: dir.path).sample().disk)
        #expect(disk.total > 0 && disk.available <= disk.total)
        #expect(HostSampler(diskPath: dir.appendingPathComponent("missing/deeper").path).sample().disk == nil)
    }

    /// The cached purgeable share keeps the cheap samples close to a full important-usage lookup.
    @Test func cachedImportantUsageMatchesAFreshLookup() throws {
        let home = NSHomeDirectory()
        let cached = HostSampler(diskPath: home)
        _ = cached.sample()
        let fromCache = try #require(cached.sample().disk)
        let fresh = try #require(HostSampler(diskPath: home, importantUsageRefresh: .zero).sample().disk)
        let values = try URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let free = UInt64(try #require(values.volumeAvailableCapacity))
        #expect(fromCache.total == fresh.total)
        #expect(fromCache.volumeName == fresh.volumeName)
        let drift = fromCache.available > fresh.available ? fromCache.available - fresh.available : fresh.available - fromCache.available
        #expect(drift < 4 << 30, "cached \(fromCache.available) vs fresh \(fresh.available)")
        // Important-usage capacity counts purgeable space, so it is never far below plain free space.
        #expect(fresh.available + (1 << 30) >= free)
    }

    /// After the first (inline) lookup, a stale purgeable figure is refreshed in the background,
    /// one lookup at a time, and samples keep answering from the cache meanwhile.
    @Test func staleImportantUsageIsRefreshedInTheBackground() async throws {
        let sampler = HostSampler(importantUsageRefresh: .milliseconds(1))
        _ = sampler.sample()
        #expect(sampler.purgeableLookupCount == 1)
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<5 { #expect(sampler.sample().disk != nil) }
        #expect(await MainThreadLatencyProbeTests.wait { sampler.purgeableLookupCount == 2 })
        let quiet = HostSampler()
        for _ in 0..<5 { _ = quiet.sample() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(quiet.purgeableLookupCount == 1)
    }

    @Test func footprintOfThisProcessAndOfAMissingOne() throws {
        let mine = try #require(HostSampler.footprint())
        #expect(mine.physFootprint > 0)
        #expect(mine.resident > 0)
        // A child that has exited and been reaped: its pid is free, so there is nothing to read.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(HostSampler.footprint(pid: child.processIdentifier) == nil)
    }

    @Test(arguments: [(Int64?.none, HostSample.Memory.Pressure.normal), (1, .normal), (2, .warning), (4, .critical), (3, .normal)])
    func pressureLevels(level: Int64?, expected: HostSample.Memory.Pressure) {
        #expect(HostSampler.pressure(level: level) == expected)
    }

    @Test(arguments: [("studio-mbp.local", "studio-mbp"), ("studio-mbp.local.", "studio-mbp"), ("Studio.LOCAL", "Studio"),
                      ("build.example.com", "build.example.com"), ("", "localhost"), (".local", "localhost"), ("mac", "mac")])
    func hostNameTrimming(raw: String, expected: String) {
        #expect(HostSampler.trimmedHostName(raw) == expected)
    }

    @Test func concurrentSamplingIsSafe() async {
        let sampler = HostSampler()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var ok = true
                    for _ in 0..<20 {
                        let s = sampler.sample()
                        if let cpu = s.cpu, !(0...100).contains(cpu.total) { ok = false }
                    }
                    return ok
                }
            }
            for await ok in group { #expect(ok) }
        }
    }

    /// Contract: `sample()` median < 2 ms. Prints the measured figures for the report. The first
    /// sample includes the inline important-usage lookup; later ones never wait for it.
    @Test func sampleCostMedianUnderTwoMilliseconds() {
        let sampler = HostSampler()
        let coldStart = DispatchTime.now().uptimeNanoseconds
        _ = sampler.sample()
        let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
        var costs: [Double] = []
        costs.reserveCapacity(50)
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = sampler.sample()
            costs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        costs.sort()
        let median = (costs[24] + costs[25]) / 2
        print(String(format: "MEASURE HostSampler.sample(): first %.3f ms; then median %.3f ms, p90 %.3f ms, max %.3f ms over 50",
                     cold, median, costs[44], costs[49]))
        #expect(median < 2)
    }

    /// Prints one live sample in the artboard's terms (for the M3 report; never asserted).
    @Test func printsALiveSample() async throws {
        let sampler = HostSampler()
        _ = sampler.sample()
        try await Task.sleep(for: .seconds(1))
        let s = sampler.sample()
        let cpu = s.cpu.map { String(format: "%.0f%% (user %.1f + sys %.1f) · load %.2f · %d cores", $0.total, $0.user, $0.system, $0.load1, $0.cores) } ?? "—"
        let m = s.memory
        let disk = s.disk.map { "\(ByteText.short($0.available)) free / \(ByteText.short($0.total)) · 已用 \(Int(($0.usedFraction * 100).rounded()))% · \($0.volumeName)" } ?? "—"
        let bat = s.battery.map { "\($0.percent)% charging=\($0.charging) onAC=\($0.onAC)" } ?? "none"
        let app = HostSampler.footprint().map { "footprint \(ByteText.short($0.physFootprint)) resident \(ByteText.short($0.resident))" } ?? "—"
        print("SAMPLE host \(s.hostName) · cpu \(cpu)")
        print("SAMPLE mem \(ByteText.short(m.used))/\(ByteText.short(m.total)) app \(ByteText.short(m.app)) wired \(ByteText.short(m.wired)) compressed \(ByteText.short(m.compressed)) pressure \(m.pressure.rawValue)")
        print("SAMPLE disk \(disk) · swap \(ByteText.short(s.swap.used)) / \(ByteText.short(s.swap.total)) · bat \(bat)")
        print("SAMPLE booted \(s.bootedAt) uptime \(Int(s.uptime / 3600))h · test process \(app)")
    }
}
