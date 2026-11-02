import CoddHost
import Foundation

/// D36 host one-liner as values. FB (2026-11): the sidebar footer and the menu bar footer draw it
/// as three meters (`CPU ▬ 23%  MEM ▬ 59%  BAT ▬ 86%`, `HostMetersView`) instead of the text
/// `cpu 23% · mem 21/36G · bat 86%`, which stays as ``line`` (the state dump) and, spelled out,
/// as ``spoken`` (VoiceOver and the tooltip). No CPU before the sampler's second sample (it needs a
/// tick delta) and no battery on a Mac without one, as before.
struct HostMeters: Equatable, Sendable {
    struct Battery: Equatable, Sendable {
        var percent: Int
        var charging: Bool
        /// On AC power, charging or not (STATUS's `AC`).
        var onAC: Bool
    }

    /// Whole percent of all cores; nil until the second sample.
    var cpuPercent: Int?
    /// Whole gigabytes (`21/36G`) and the used share in whole percent (the meter's length).
    var memoryUsedGB: Int
    var memoryTotalGB: Int
    var memoryPercent: Int
    /// macOS's memory pressure: the meter's color, as STATUS's MEM card judges it.
    var memoryPressure: HostSample.Memory.Pressure
    var battery: Battery?

    init(cpuPercent: Int?, memoryUsedGB: Int, memoryTotalGB: Int, memoryPercent: Int,
         memoryPressure: HostSample.Memory.Pressure = .normal, battery: Battery?) {
        self.cpuPercent = cpuPercent
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
        self.memoryPercent = memoryPercent
        self.memoryPressure = memoryPressure
        self.battery = battery
    }

    /// Rounded once here, so two samples with the same visible numbers are equal (no redraw).
    init(sample: HostSample) {
        let gib = 1_073_741_824.0
        self.init(cpuPercent: sample.cpu.map { Int(max(0, min(100, $0.total)).rounded()) },
                  memoryUsedGB: Int((Double(sample.memory.used) / gib).rounded()),
                  memoryTotalGB: Int((Double(sample.memory.total) / gib).rounded()),
                  memoryPercent: Int((sample.memory.usedFraction * 100).rounded()), memoryPressure: sample.memory.pressure,
                  battery: sample.battery.map { Battery(percent: max(0, min(100, $0.percent)), charging: $0.charging, onAC: $0.onAC) })
    }

    /// `cpu 23% · mem 21/36G · bat 86%`: no `cpu` part before the second sample, no `bat` part
    /// without a battery.
    var line: String {
        var parts: [String] = []
        if let cpuPercent { parts.append("cpu \(cpuPercent)%") }
        parts.append("mem \(memoryUsedGB)/\(memoryTotalGB)G")
        if let battery { parts.append("bat \(battery.percent)%") }
        return parts.joined(separator: " · ")
    }

    /// The meters in their footer order.
    var meters: [HostMeter] {
        var list: [HostMeter] = []
        if let cpuPercent {
            list.append(HostMeter(kind: .cpu, label: "CPU", percent: cpuPercent, tone: HostLoad.cpu(percent: cpuPercent),
                                  spoken: "CPU \(cpuPercent)%"))
        }
        list.append(HostMeter(kind: .memory, label: "MEM", percent: memoryPercent, tone: HostLoad.memory(pressure: memoryPressure),
                              spoken: "記憶體 \(memoryUsedGB)/\(memoryTotalGB)G（\(memoryPercent)%）"))
        if let battery {
            // `BAT` on AC power too (STATUS's Bat card); the power state is in the words.
            let power = battery.charging ? "，充電中" : battery.onAC ? "，接上電源" : ""
            list.append(HostMeter(kind: .battery, label: "BAT", percent: battery.percent,
                                  tone: HostLoad.battery(percent: battery.percent, onAC: battery.onAC),
                                  spoken: "電池 \(battery.percent)%\(power)"))
        }
        return list
    }

    /// `主機 CPU 23%，記憶體 21/36G（59%），電池 86%，接上電源`, with the load word of a meter
    /// that is not normal (`偏高`, `過高`; memory `壓力偏高`, `壓力過高`; the battery `偏低`, `過低`):
    /// the bar's color as words.
    var spoken: String {
        "主機 " + meters.map { meter in meter.loadWord.map { "\(meter.spoken)，\($0)" } ?? meter.spoken }.joined(separator: "，")
    }
}

/// One footer meter: `CPU`, a bar filled to `percent` in `tone`, `23%`.
struct HostMeter: Equatable, Sendable {
    enum Kind: Sendable { case cpu, memory, battery }

    var kind: Kind
    /// `CPU`, `MEM`, `BAT`.
    var label: String
    /// 0...100: the bar and the value.
    var percent: Int
    var tone: QuotaTone
    /// The meter as words, without the load word.
    var spoken: String

    var valueText: String { "\(percent)%" }

    /// `偏高` / `過高` (CPU), `壓力偏高` / `壓力過高` (memory), `偏低` / `過低` (battery); nil while normal.
    var loadWord: String? {
        let word: String? = switch tone {
        case .warn: kind == .battery ? "偏低" : "偏高"
        case .crit: kind == .battery ? "過低" : "過高"
        case .ok, .muted: nil
        }
        return word.map { kind == .memory ? "壓力" + $0 : $0 }
    }
}

/// The footer meters' colors, in the quota bars' tones (ok success, warn amber, crit danger).
enum HostLoad {
    /// CPU: ok below 60 %, warn from 60 %, crit from 85 %.
    static func cpu(percent: Int) -> QuotaTone {
        if percent >= 85 { return .crit }
        if percent >= 60 { return .warn }
        return .ok
    }

    /// Memory: macOS's memory pressure, as STATUS's MEM card shows it (normal ok, warning warn,
    /// critical crit). The used share alone often sits at 60–85 % while the pressure is normal.
    static func memory(pressure: HostSample.Memory.Pressure) -> QuotaTone {
        switch pressure {
        case .normal: .ok
        case .warning: .warn
        case .critical: .crit
        }
    }

    /// Battery the other way round: crit at 20 % or less, warn at 40 % or less, else ok; on AC
    /// power it is always ok (it is charging or full, as STATUS's BAT card judges it).
    static func battery(percent: Int, onAC: Bool) -> QuotaTone {
        if onAC { return .ok }
        if percent <= 20 { return .crit }
        if percent <= 40 { return .warn }
        return .ok
    }
}
