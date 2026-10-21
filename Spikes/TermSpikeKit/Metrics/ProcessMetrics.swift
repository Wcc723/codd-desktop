import Darwin

/// Memory and thread usage of the current process.
public struct ProcessMemory: Sendable, Codable, Equatable {
    /// Resident set size (`mach_task_basic_info.resident_size`).
    public var residentBytes: UInt64
    /// Physical footprint (`task_vm_info.phys_footprint`): what Activity Monitor
    /// shows as "Memory" and what memory pressure is judged by. Includes
    /// IOSurface / GPU memory attributed to the process.
    public var footprintBytes: UInt64
    /// Number of Mach threads in the task.
    public var threads: Int

    public init(residentBytes: UInt64, footprintBytes: UInt64, threads: Int) {
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.threads = threads
    }

    public var residentMiB: Double { Double(residentBytes) / 1_048_576 }
    public var footprintMiB: Double { Double(footprintBytes) / 1_048_576 }
}

public enum ProcessMetrics {
    /// Samples the current task. Fields that cannot be read are reported as 0.
    public static func current() -> ProcessMemory {
        ProcessMemory(
            residentBytes: residentBytes(),
            footprintBytes: footprintBytes(),
            threads: threadCount()
        )
    }

    /// User + system CPU time this process has used, in seconds (all threads).
    public static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// CPU use between two readings as a percentage of one core.
    public static func cpuPercent(cpuSeconds: Double, wallNanos: UInt64) -> Double {
        guard wallNanos > 0 else { return 0 }
        return max(0, cpuSeconds) / (Double(wallNanos) / 1_000_000_000) * 100
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
            return 0
        }
        for index in 0 ..< Int(count) {
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        let size = vm_size_t(MemoryLayout<thread_act_t>.stride * Int(count))
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        return Int(count)
    }
}
