import CoreServices
import Dispatch
import Foundation

/// Watches a project folder recursively with FSEvents (file-level events), for the tree and the
/// git badges (D24: the app re-reads git status on changes, debounced). Each batch FSEvents
/// delivers (after `latency` seconds) becomes one `changes` element: the root-relative paths that
/// changed, deduplicated, in arrival order ("" = the root itself). `.git/` changes are included
/// (a commit or checkout changes the badges). `changes` is meant for one consumer.
public final class DirectoryWatcher: Sendable {
    public let root: URL
    public let changes: AsyncStream<[String]>
    private let core: Core

    public init(root: URL, latency: Double = 0.3) {
        self.root = root
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self, bufferingPolicy: .unbounded)
        changes = stream
        core = Core(root: root, continuation: continuation)
        core.start(latency: latency)
    }

    deinit { core.cancel() }

    /// Stops the stream and finishes `changes`. Idempotent.
    public func cancel() { core.cancel() }

    /// The FSEvents stream; created, started and torn down on `queue` (FSEvents calls back there).
    final class Core: @unchecked Sendable {
        private let continuation: AsyncStream<[String]>.Continuation
        /// Both spellings of the root: as given and with symlinks resolved (FSEvents reports real
        /// paths, e.g. `/private/var/…` for `/var/…`).
        private let prefixes: [String]
        private let watchedPath: String
        private let queue = DispatchQueue(label: "codd.files.fsevents")
        private var stream: FSEventStreamRef?
        private var cancelled = false

        init(root: URL, continuation: AsyncStream<[String]>.Continuation) {
            self.continuation = continuation
            let given = root.standardizedFileURL.path
            let real = root.resolvingSymlinksInPath().path
            let resolved = realpath(given, nil).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? real
            watchedPath = resolved
            prefixes = Array(Set([given, real, resolved])).sorted { $0.count > $1.count }
        }

        func start(latency: Double) {
            queue.async { [self] in
                guard !cancelled else { return }
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                   retain: { info in
                                                       guard let info else { return nil }
                                                       _ = Unmanaged<Core>.fromOpaque(info).retain()
                                                       return UnsafeRawPointer(info)
                                                   },
                                                   release: { info in
                                                       guard let info else { return }
                                                       Unmanaged<Core>.fromOpaque(info).release()
                                                   },
                                                   copyDescription: nil)
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
                guard let created = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, [watchedPath] as CFArray,
                                                        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
                else { return }
                FSEventStreamSetDispatchQueue(created, queue)
                FSEventStreamStart(created)
                stream = created
            }
        }

        func cancel() {
            queue.async { [self] in
                guard !cancelled else { return }
                cancelled = true
                if let stream {
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                }
                stream = nil
                continuation.finish()
            }
        }

        private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let core = Unmanaged<Core>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var batch: [String] = []
            var seen = Set<String>()
            for index in 0..<min(count, array.count) {
                guard let path = array[index] as? String, let relative = core.relative(path) else { continue }
                if seen.insert(relative).inserted { batch.append(relative) }
            }
            core.deliver(batch)
        }

        private func deliver(_ batch: [String]) {
            guard !cancelled, !batch.isEmpty else { return }
            continuation.yield(batch)
        }

        func relative(_ path: String) -> String? {
            for prefix in prefixes {
                if path == prefix { return "" }
                if path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count + 1)) }
            }
            return nil
        }
    }
}
