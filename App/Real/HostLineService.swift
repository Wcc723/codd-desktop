import CoddHost
import Foundation

/// D36: the host one-liner of the sidebar footer and the menu bar footer (the CPU / MEM / BAT
/// meters, ``HostMeters``), sampled with CoddHost every 30 s off the main actor while the main
/// window or the menu bar popover is visible, and not at all otherwise. The CPU figure needs two
/// samples (a tick delta): until the second one there are memory and battery only.
@MainActor
final class HostLineService {
    private let sampler: HostSampler
    private let interval: Duration
    private let publish: @MainActor (HostMeters) -> Void
    private var task: Task<Void, Never>?
    private(set) var meters: HostMeters?
    /// Who needs the line (the main window, the popover).
    private var demand: Set<String> = []

    static let defaultInterval: Duration = .seconds(30)

    init(sampler: HostSampler = HostSampler(), interval: Duration = HostLineService.defaultInterval,
         publish: @escaping @MainActor (HostMeters) -> Void) {
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
                let meters = HostMeters(sample: sample)
                if meters != self.meters {
                    self.meters = meters
                    self.publish(meters)
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

    /// `cpu 23% · mem 21/36G · bat 86%`, the plain text form (``HostMeters/line``).
    nonisolated static func line(_ sample: HostSample) -> String { HostMeters(sample: sample).line }
}
