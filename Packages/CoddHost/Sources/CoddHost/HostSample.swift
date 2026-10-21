import Foundation

/// One reading of the Mac CODD runs on, for the STATUS HOST cards and the footer host line.
/// Plain values only, so the UI packages and the state dump can take it as is. All byte counts are
/// bytes; all percentages are 0 ... 100.
public struct HostSample: Sendable, Equatable {
    /// Share of all logical CPUs since the previous sample (host tick deltas), plus load averages.
    public struct CPU: Sendable, Equatable {
        /// User + nice time, percent of all cores.
        public var user: Double
        public var system: Double
        /// `user + system`; the STATUS card's big number ("user + sys").
        public var total: Double
        public var load1, load5, load15: Double
        public var cores: Int

        public init(user: Double, system: Double, total: Double, load1: Double, load5: Double, load15: Double, cores: Int) {
            self.user = user
            self.system = system
            self.total = total
            self.load1 = load1
            self.load5 = load5
            self.load15 = load15
            self.cores = cores
        }
    }

    /// Activity Monitor's breakdown: `used = app + wired + compressed`.
    public struct Memory: Sendable, Equatable {
        /// `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical).
        public enum Pressure: String, Sendable {
            case normal, warning, critical
        }

        /// `hw.memsize`.
        public var total, used, app, wired, compressed: UInt64
        public var pressure: Pressure

        public init(total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, pressure: Pressure) {
            self.total = total
            self.used = used
            self.app = app
            self.wired = wired
            self.compressed = compressed
            self.pressure = pressure
        }

        /// `used / total` in 0 ... 1 (0 when total is unknown).
        public var usedFraction: Double { HostSample.fraction(used, of: total) }
    }

    /// The volume holding the sampler's `diskPath` (the home volume by default).
    public struct Disk: Sendable, Equatable {
        public var volumeName: String
        public var total: UInt64
        /// Capacity for important usage: free space plus what macOS would purge for the user,
        /// which is what Finder shows as available.
        public var available: UInt64

        public init(volumeName: String, total: UInt64, available: UInt64) {
            self.volumeName = volumeName
            self.total = total
            self.available = available
        }

        public var used: UInt64 { total > available ? total - available : 0 }
        /// `used / total` in 0 ... 1 (the card's `已用 59%`).
        public var usedFraction: Double { HostSample.fraction(used, of: total) }
    }

    /// `vm.swapusage`. macOS grows the swap file on demand, so `total` changes over time.
    public struct Swap: Sendable, Equatable {
        public var total: UInt64
        public var used: UInt64

        public init(total: UInt64, used: UInt64) {
            self.total = total
            self.used = used
        }

        public var usedFraction: Double { HostSample.fraction(used, of: total) }
    }

    /// The internal battery (IOPowerSources).
    public struct Battery: Sendable, Equatable {
        public var percent: Int
        public var charging: Bool
        /// Drawing from AC power (the card's `AC` / `接上電源`), charging or not.
        public var onAC: Bool

        public init(percent: Int, charging: Bool, onAC: Bool) {
            self.percent = percent
            self.charging = charging
            self.onAC = onAC
        }
    }

    public var at: Date
    /// nil on a sampler's first sample: CPU usage needs a delta between two tick counts.
    public var cpu: CPU?
    public var memory: Memory
    /// nil when the volume cannot be read (path gone, permissions).
    public var disk: Disk?
    public var swap: Swap
    /// nil without an internal battery (desktop Macs): the BAT card is hidden.
    public var battery: Battery?
    /// `kern.boottime`.
    public var bootedAt: Date
    /// The host name without the `.local` suffix (`studio-mbp`).
    public var hostName: String

    public init(at: Date, cpu: CPU?, memory: Memory, disk: Disk?, swap: Swap, battery: Battery?, bootedAt: Date, hostName: String) {
        self.at = at
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.swap = swap
        self.battery = battery
        self.bootedAt = bootedAt
        self.hostName = hostName
    }

    /// Time since boot at the moment of the sample (the UPTIME card).
    public var uptime: TimeInterval { max(0, at.timeIntervalSince(bootedAt)) }

    static func fraction(_ part: UInt64, of whole: UInt64) -> Double {
        guard whole > 0 else { return 0 }
        return min(1, Double(part) / Double(whole))
    }
}
