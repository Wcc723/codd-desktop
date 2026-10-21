import CoreServices
import Foundation

/// FSEvents on one directory tree (file-level events), coalesced: the first change schedules
/// `onChange` `latency` later on the main actor and every change until then joins it. A
/// directory that does not exist yet is retried every `retry` (cswap creates its state root on
/// its first `add`); a moved or deleted root is watched again once it is back.
///
/// It never reads a file and never logs a path: cswap's state root holds files whose names carry
/// e-mails (D31), and only "something changed" leaves this type.
final class FileEventWatcher: @unchecked Sendable {
    private let path: String
    private let latency: Duration
    private let retry: Duration
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: CoddIdentity.label("file-events"), qos: .utility)

    // Queue-confined.
    private var stream: FSEventStreamRef?
    private var running = false
    private var scheduled = false
    private var generation = 0

    init(path: String, latency: Duration = .milliseconds(300), retry: Duration = .seconds(5),
         onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.latency = latency
        self.retry = retry
        self.onChange = onChange
    }

    deinit {
        // Invalidated on the queue it delivers to; the relay already lets go of this watcher.
        let box = StreamBox(stream: stream)
        queue.async {
            guard let stream = box.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private struct StreamBox: @unchecked Sendable {
        var stream: FSEventStreamRef?
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.arm(generation: self.generation)
        }
    }

    func stop() {
        queue.sync {
            self.running = false
            self.generation += 1
            self.stopStream()
        }
    }

    // MARK: Queue

    private func arm(generation gen: Int) {
        guard running, gen == generation else { return }
        if startStreamIfPresent() { return }
        queue.asyncAfter(deadline: .now() + Self.interval(retry)) { [weak self] in
            guard let self, self.running, gen == self.generation, self.stream == nil else { return }
            if self.startStreamIfPresent() {
                self.changed() // it appeared: whatever is there is new
            } else {
                self.arm(generation: gen)
            }
        }
    }

    private func startStreamIfPresent() -> Bool {
        if stream != nil { return true }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        // The stream owns a relay that refers to this watcher weakly: an event delivered after the
        // watcher went away finds nothing instead of a dangling pointer.
        let relay = Relay()
        relay.watcher = self
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(relay).toOpaque(), retain: nil,
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<Relay>.fromOpaque(info).release()
                                           }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info, let watcher = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue().watcher else { return }
            var rootChanged = false
            for i in 0..<count where flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootChanged = true }
            watcher.eventsArrived(rootChanged: rootChanged)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return false }
        // Callbacks run on `queue`, which owns every mutable property.
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func eventsArrived(rootChanged: Bool) {
        guard running else { return }
        if rootChanged {
            stopStream()
            arm(generation: generation)
        }
        changed()
    }

    private func changed() {
        guard running, !scheduled else { return }
        scheduled = true
        let gen = generation
        queue.asyncAfter(deadline: .now() + Self.interval(latency)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.scheduled = false
            let onChange = self.onChange
            Task { @MainActor in onChange() }
        }
    }

    /// The FSEvents context object (retained by the stream, released when it is released).
    private final class Relay: @unchecked Sendable {
        weak var watcher: FileEventWatcher?
    }

    private static func interval(_ d: Duration) -> DispatchTimeInterval {
        let c = d.components
        return .nanoseconds(Int(c.seconds) * 1_000_000_000 + Int(c.attoseconds / 1_000_000_000))
    }
}
