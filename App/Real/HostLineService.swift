import CoddHost
import Foundation

/// D36: the host one-liner of the sidebar footer and the menu bar footer (`cpu 23% · mem 21/36G ·
/// bat 86%`), sampled with CoddHost every 30 s off the main actor while the main window or the
/// menu bar popover is visible, and not at all otherwise. The CPU figure needs two samples (a tick
/// delta): until the second one the line shows memory and battery only.
@MainActor
final class HostLineService {
    private let sampler: HostSampler
    private let interval: Duration
    private let publish: @MainActor (String) -> Void
    private var task: Task<Void, Never>?
    private(set) var line: String?
    /// Who needs the line (the main window, the popover).
    private var demand: Set<String> = []

    static let defaultInterval: Duration = .seconds(30)

    init(sampler: HostSampler = HostSampler(), interval: Duration = HostLineService.defaultInterval,
         publish: @escaping @MainActor (String) -> Void) {
        self.sampler = sampler
        self.interval = interval
        self.publish = publish
    }

    var isSampling: Bool { task != nil }

    /// `who` (`window`, `popover`) is visible or not; sampling runs while anyone is.
    func setVisible(_ visible: Bool, for who: String) {
        if visible { demand.insert(who) } else { demand.remove(who) }
        if demand.isEmpty {
            task?.cancel()
            task = nil
        } else if task == nil {
            start()
        }
    }

    private func start() {
        let sampler = self.sampler
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { sampler.sample() }.value
                guard !Task.isCancelled, let self else { return }
                let text = Self.line(sample)
                if text != self.line {
                    self.line = text
                    self.publish(text)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        demand.removeAll()
    }

    /// `cpu 23% · mem 21/36G · bat 86%`: whole gigabytes, no `bat` part without a battery, no
    /// `cpu` part before the second sample.
    nonisolated static func line(_ sample: HostSample) -> String {
        var parts: [String] = []
        if let cpu = sample.cpu { parts.append("cpu \(Int(cpu.total.rounded()))%") }
        let gib = 1_073_741_824.0
        let used = Int((Double(sample.memory.used) / gib).rounded())
        let total = Int((Double(sample.memory.total) / gib).rounded())
        parts.append("mem \(used)/\(total)G")
        if let battery = sample.battery { parts.append("bat \(battery.percent)%") }
        return parts.joined(separator: " · ")
    }
}
