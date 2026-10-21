import Darwin
import Dispatch
import Foundation
import Synchronization

/// Reads a ``HostSample`` on demand. One instance per consumer that wants its own CPU delta
/// window (the CPU figure is "since this sampler's previous sample").
///
/// `sample()` is blocking and cheap (about 0.1 ms on an M-series Mac: processor ticks, VM
/// statistics, a few sysctls, one statfs, one powerd query) and never throws: anything
/// unreadable comes back as nil or 0. The first sample of an instance also does the slow
/// important-usage disk lookup (about 20 ms, more while other lookups are in flight). Call it off
/// the main actor (M3 D26: every 5 s while STATUS is shown; D36: every 30 s for the footer line).
public final class HostSampler: Sendable {
    private struct Ticks {
        var user, system, idle, nice: UInt32
    }

    private struct State {
        var previous: Ticks?
        var lastCPU: HostSample.CPU?
        /// `importantUsage - available` from the last slow lookup, and when it was taken (uptime ns).
        var purgeable: (at: UInt64, bytes: Int64)?
        var purgeableLookupRunning = false
        var purgeableLookups = 0
    }

    /// Cached once: `mach_host_self()` adds a send-right reference per call, so calling it every
    /// sample would leak references (one per sampler instance is kept for its lifetime).
    private let host: mach_port_t
    private let pageSize: UInt64
    private let memorySize: UInt64
    private let cores: Int
    private let diskPath: String
    private let importantUsageRefreshNanoseconds: UInt64
    private let pressureLevel: Sysctl?
    private let swapUsage: Sysctl?
    private let bootTime: Sysctl?
    private let state = Mutex(State())

    /// - Parameters:
    ///   - diskPath: any path on the volume the DISK card describes (default: home).
    ///   - importantUsageRefresh: how often the volume's important-usage capacity is looked up
    ///     again. That lookup asks the cache-delete service for purgeable space and costs 7 to
    ///     25 ms, so it runs at most once per interval and, after the first sample, in the
    ///     background; in between, the purgeable share from the last lookup is added to the cheap
    ///     free-space figure.
    public init(diskPath: String = NSHomeDirectory(), importantUsageRefresh: Duration = .seconds(60)) {
        host = mach_host_self()
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : UInt64(getpagesize())
        memorySize = Sysctl("hw.memsize")?.readInteger().map { UInt64(max(0, $0)) } ?? 0
        cores = Sysctl("hw.logicalcpu")?.readInteger().map { Int($0) } ?? ProcessInfo.processInfo.activeProcessorCount
        self.diskPath = diskPath
        let (seconds, attoseconds) = importantUsageRefresh.components
        importantUsageRefreshNanoseconds = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
        pressureLevel = Sysctl("kern.memorystatus_vm_pressure_level")
        swapUsage = Sysctl("vm.swapusage")
        bootTime = Sysctl("kern.boottime")
    }

    public func sample(now: Date = Date()) -> HostSample {
        HostSample(
            at: now,
            cpu: cpu(),
            memory: memory(),
            disk: disk(),
            swap: swap(),
            battery: PowerSource.internalBattery(),
            bootedAt: bootedAt(fallback: now),
            hostName: Self.hostName())
    }

    /// Physical footprint (what Activity Monitor calls Memory, and jetsam judges by) and resident
    /// size of a process; nil when the process is gone or not ours to inspect.
    public static func footprint(pid: pid_t = getpid()) -> (physFootprint: UInt64, resident: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_resident_size)
    }

    // MARK: - CPU

    private func cpu() -> HostSample.CPU? {
        guard let ticks = readTicks() else { return state.withLock { $0.lastCPU } }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != 3 { loads = [0, 0, 0] }
        let cores = self.cores
        return state.withLock { state -> HostSample.CPU? in
            defer { state.previous = ticks }
            guard let previous = state.previous else { return nil }
            // Tick counters are 32-bit and wrap; wrapping subtraction keeps the delta right.
            let user = Double(ticks.user &- previous.user) + Double(ticks.nice &- previous.nice)
            let system = Double(ticks.system &- previous.system)
            let all = user + system + Double(ticks.idle &- previous.idle)
            // Two samples inside one tick: keep the previous figure instead of dividing by zero.
            guard all > 0 else { return state.lastCPU }
            let userPercent = user / all * 100, systemPercent = system / all * 100
            let cpu = HostSample.CPU(
                user: userPercent, system: systemPercent, total: min(100, userPercent + systemPercent),
                load1: loads[0], load5: loads[1], load15: loads[2], cores: cores)
            state.lastCPU = cpu
            return cpu
        }
    }

    /// The host's load ticks (what `host_cpu_load_info` reports), summed from the per-processor
    /// counters. Not `host_statistics(HOST_CPU_LOAD_INFO)`: for non-Apple processes XNU answers
    /// that from a system-wide cache after 2 to 10 calls per second (any third-party process's
    /// calls count), so two close samples can see identical ticks. `host_processor_info` is
    /// not rate limited and costs about 20 µs.
    private func readTicks() -> Ticks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        guard cpuCount > 0, Int(infoCount) >= Int(cpuCount) * states else { return nil }
        var ticks = Ticks(user: 0, system: 0, idle: 0, nice: 0)
        // Wrapping sums: each processor's counter wraps on its own, and the delta of the wrapped
        // sums still equals the sum of the deltas (mod 2^32).
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            ticks.user &+= UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            ticks.system &+= UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            ticks.idle &+= UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            ticks.nice &+= UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        }
        return ticks
    }

    // MARK: - Memory

    /// `host_statistics64(HOST_VM_INFO64)`. It shares the rate limit described at `readTicks()`,
    /// so a figure can be up to a second old; that is fine for 5 s and 30 s sampling.
    private func memory() -> HostSample.Memory {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let pressure = Self.pressure(level: pressureLevel?.readInteger())
        guard rc == KERN_SUCCESS else {
            return HostSample.Memory(total: memorySize, used: 0, app: 0, wired: 0, compressed: 0, pressure: pressure)
        }
        // Activity Monitor's "App Memory": anonymous pages minus the purgeable ones.
        let internalPages = UInt64(vm.internal_page_count)
        let appPages = internalPages - min(UInt64(vm.purgeable_count), internalPages)
        let app = appPages * pageSize
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        // Clamp so the stacked meter never overflows even if counters race each other.
        let total = memorySize
        let used = total > 0 ? min(total, app + wired + compressed) : app + wired + compressed
        return HostSample.Memory(total: total, used: used, app: min(app, used), wired: min(wired, used),
                                 compressed: min(compressed, used), pressure: pressure)
    }

    static func pressure(level: Int64?) -> HostSample.Memory.Pressure {
        switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }

    // MARK: - Disk

    /// Total and free space are cheap (one statfs); the purgeable share comes from the last
    /// important-usage lookup. The first sample looks up inline, so the first DISK figure already
    /// counts purgeable space and does not jump on the next one; later lookups run on a utility
    /// queue when the last one is older than `importantUsageRefresh`, one at a time.
    private func disk() -> HostSample.Disk? {
        let uptime = DispatchTime.now().uptimeNanoseconds
        let refresh = importantUsageRefreshNanoseconds
        let (cached, lookUpInBackground) = state.withLock { s -> (Int64?, Bool) in
            guard let last = s.purgeable else { return (nil, false) }
            guard uptime &- last.at >= refresh, !s.purgeableLookupRunning else { return (last.bytes, false) }
            s.purgeableLookupRunning = true
            return (last.bytes, true)
        }
        if lookUpInBackground {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.lookUpPurgeable() }
        }
        let purgeable = cached ?? lookUpPurgeable()
        // A fresh URL every time: URL caches resource values per instance.
        let url = URL(fileURLWithPath: diskPath, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]),
              let total = values.volumeTotalCapacity.map(Int64.init), total > 0 else { return nil }
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let available = min(total, max(0, free + purgeable))
        return HostSample.Disk(volumeName: values.volumeLocalizedName ?? "", total: UInt64(total), available: UInt64(available))
    }

    /// The slow part: `importantUsage - free` (purgeable space macOS would free for the user).
    /// No answer counts as no purgeable space until the next lookup.
    @discardableResult
    private func lookUpPurgeable() -> Int64 {
        let url = URL(fileURLWithPath: diskPath, isDirectory: true)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let bytes = values?.volumeAvailableCapacityForImportantUsage.map { $0 > 0 ? $0 - free : 0 } ?? 0
        let at = DispatchTime.now().uptimeNanoseconds
        state.withLock { s in
            s.purgeable = (at, bytes)
            s.purgeableLookupRunning = false
            s.purgeableLookups += 1
        }
        return bytes
    }

    /// Important-usage lookups done so far (tests).
    var purgeableLookupCount: Int { state.withLock { $0.purgeableLookups } }

    // MARK: - Swap, boot, name

    private func swap() -> HostSample.Swap {
        var usage = xsw_usage()
        guard swapUsage?.read(into: &usage) == true else { return HostSample.Swap(total: 0, used: 0) }
        return HostSample.Swap(total: usage.xsu_total, used: min(usage.xsu_used, usage.xsu_total))
    }

    private func bootedAt(fallback now: Date) -> Date {
        var boot = timeval()
        guard bootTime?.read(into: &boot) == true, boot.tv_sec > 0 else {
            return now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    /// `gethostname` (no DNS lookup, unlike `ProcessInfo.hostName`, which can block) without
    /// the Bonjour `.local` suffix.
    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "localhost" }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return trimmedHostName(name)
    }

    static func trimmedHostName(_ name: String) -> String {
        var trimmed = name
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        if trimmed.lowercased().hasSuffix(".local") { trimmed.removeLast(".local".count) }
        return trimmed.isEmpty ? "localhost" : trimmed
    }
}
