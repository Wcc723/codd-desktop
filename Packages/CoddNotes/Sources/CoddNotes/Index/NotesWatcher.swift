import CoreServices
import Foundation

/// FSEvents on the notes root (D7): file-level events, recursive, 200 ms latency (the coalescing
/// window). Delivered on its own serial queue and forwarded as batches into an `AsyncStream`
/// that the library consumes in order, so events never overtake each other on the way into the
/// actor.
final class NotesWatcher: @unchecked Sendable {
    struct Event: Sendable {
        var path: String
        var flags: FSEventStreamEventFlags

        var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
        var mustRescan: Bool {
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped) != 0
        }
        var rootChanged: Bool { flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
    }

    private let queue = DispatchQueue(label: "codd.notes.watcher")
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<[Event]>.Continuation
    let batches: AsyncStream<[Event]>

    init() {
        (batches, continuation) = AsyncStream.makeStream(of: [Event].self, bufferingPolicy: .unbounded)
    }

    /// Starts watching `root` (a realpath). False when FSEvents refused the stream.
    func start(root: String, latency: Double = 0.2) -> Bool {
        stop()
        let box = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<NotesWatcher>.fromOpaque(info).release()
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<NotesWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for k in 0..<count {
                guard let p = array[k] as? String else { continue }
                events.append(Event(path: p, flags: flags[k]))
            }
            me.continuation.yield(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            box.release()
            return false
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    func finish() {
        stop()
        continuation.finish()
    }
}
