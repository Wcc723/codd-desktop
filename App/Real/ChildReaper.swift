import Darwin
import Dispatch

/// Reaps the holders this app run spawned. The app is their parent until it quits (launchd
/// adopts them afterwards), so without this every holder that exits while the app runs stays a
/// zombie until the app quits.
///
/// Every mutable property is confined to `queue`, which is why the class is `@unchecked Sendable`.
final class ChildReaper: @unchecked Sendable {
    static let shared = ChildReaper()

    private let queue = DispatchQueue(label: CoddIdentity.label("child-reaper"), qos: .utility)
    private var sources: [pid_t: DispatchSourceProcess] = [:]

    /// The kernel can report an exit a moment before the child is reapable, and it reports it
    /// only once: retry `waitpid` this many times, this far apart.
    private static let retryCount = 50
    private static let retryDelay = DispatchTimeInterval.milliseconds(20)

    /// Watches `pid` (a direct child of this process) and reaps it when it exits.
    /// `onExit` receives the raw wait status, on the reaper's queue.
    func watch(_ pid: pid_t, onExit: (@Sendable (Int32) -> Void)? = nil) {
        queue.async { [self] in
            guard sources[pid] == nil else { return }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [self] in reap(pid, attempt: 0, onExit: onExit) }
            sources[pid] = source
            source.resume()
            // An exit before the source was registered produces no event: probe once now.
            reap(pid, attempt: nil, onExit: onExit)
        }
    }

    /// `attempt == nil` is the registration probe (no retries while the child still runs).
    private func reap(_ pid: pid_t, attempt: Int?, onExit: (@Sendable (Int32) -> Void)?) {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno == ECHILD) {
            sources.removeValue(forKey: pid)?.cancel()
            if result == pid { onExit?(status) }
            return
        }
        if result < 0 && errno == EINTR {
            reap(pid, attempt: attempt, onExit: onExit)
            return
        }
        guard let attempt, attempt < Self.retryCount else { return }
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
            reap(pid, attempt: attempt + 1, onExit: onExit)
        }
    }
}
