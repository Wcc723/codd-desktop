import Darwin
import Dispatch
import Foundation

public enum FileWatchEvent: Sendable, Equatable {
    /// The contents changed: written in place, or replaced (atomic rename onto the path, a
    /// delete followed by a new file at the path).
    case modified
    /// The file is gone (unlinked) and nothing is at the path now.
    case deleted
    /// The file was moved away and nothing is at the path now.
    case renamed
    /// Only metadata changed (mode, flags, times).
    case attributes
}

/// Watches one open file with a `DispatchSource` vnode source (D25): write, extend, delete,
/// rename, attrib, link, revoke.
///
/// The source follows the inode, so after an atomic replace (a new inode renamed onto the path,
/// which every careful editor and Claude's Write do) or a delete + recreate the watch reopens the
/// path; while nothing is at the path it watches the parent folder for the file to come back.
/// Events within 100 ms are coalesced into one: the file's state at the end of the window decides
/// (`deleted` / `renamed` when the path is empty, else `modified` when the contents may have changed,
/// else `attributes`). `events` is meant for one consumer.
public final class FileWatch: Sendable {
    public let url: URL
    public let events: AsyncStream<FileWatchEvent>
    private let core: Core

    public init(url: URL, coalescing: Duration = .milliseconds(100)) {
        self.url = url
        let (stream, continuation) = AsyncStream.makeStream(of: FileWatchEvent.self, bufferingPolicy: .unbounded)
        events = stream
        core = Core(path: url.path, continuation: continuation, coalescing: coalescing)
        core.start()
    }

    deinit { core.cancel() }

    /// Stops watching and finishes `events`. Idempotent.
    public func cancel() { core.cancel() }

    /// All state lives on `queue` (sources fire there; `start` / `cancel` hop onto it).
    private final class Core: @unchecked Sendable {
        private let path: String
        private let folder: String
        private let continuation: AsyncStream<FileWatchEvent>.Continuation
        private let coalescing: Duration
        private let queue = DispatchQueue(label: "codd.files.filewatch")
        private var fileSource: (any DispatchSourceFileSystemObject)?
        private var folderSource: (any DispatchSourceFileSystemObject)?
        private var pendingContent = false
        private var pendingAttributes = false
        private var pendingGone: FileWatchEvent?
        private var flushScheduled = false
        private var cancelled = false

        init(path: String, continuation: AsyncStream<FileWatchEvent>.Continuation, coalescing: Duration) {
            self.path = path
            self.folder = (path as NSString).deletingLastPathComponent
            self.continuation = continuation
            self.coalescing = coalescing
        }

        func start() {
            queue.async { [self] in
                if !armFile() { armFolder() }
            }
        }

        func cancel() {
            queue.async { [self] in
                guard !cancelled else { return }
                cancelled = true
                fileSource?.cancel()
                fileSource = nil
                folderSource?.cancel()
                folderSource = nil
                continuation.finish()
            }
        }

        /// Opens the path and watches its inode; false when nothing is there.
        @discardableResult
        private func armFile() -> Bool {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, let mask = self.fileSource?.data else { return }
                self.fileEvent(mask)
            }
            source.setCancelHandler { close(fd) }
            fileSource = source
            source.activate()
            return true
        }

        /// Watches the parent folder until something appears at the path again.
        private func armFolder() {
            guard folderSource == nil else { return }
            let fd = open(folder, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.folderEvent() }
            source.setCancelHandler { close(fd) }
            folderSource = source
            source.activate()
        }

        private func fileEvent(_ mask: DispatchSource.FileSystemEvent) {
            guard !cancelled else { return }
            if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
                fileSource?.cancel()
                fileSource = nil
                if armFile() {
                    // Replaced: a new inode is at the path.
                    pendingContent = true
                    pendingGone = nil
                } else {
                    pendingGone = mask.contains(.rename) ? .renamed : .deleted
                    armFolder()
                }
            } else {
                if mask.contains(.write) || mask.contains(.extend) { pendingContent = true }
                if mask.contains(.attrib) || mask.contains(.link) { pendingAttributes = true }
            }
            scheduleFlush()
        }

        private func folderEvent() {
            guard !cancelled, fileSource == nil else { return }
            guard armFile() else { return }
            folderSource?.cancel()
            folderSource = nil
            pendingContent = true
            pendingGone = nil
            scheduleFlush()
        }

        private func scheduleFlush() {
            guard !flushScheduled else { return }
            flushScheduled = true
            let c = coalescing.components
            queue.asyncAfter(deadline: .now() + TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18) { [self] in flush() }
        }

        private func flush() {
            flushScheduled = false
            guard !cancelled else { return }
            let event: FileWatchEvent?
            if fileSource == nil, let gone = pendingGone {
                event = gone
            } else if pendingContent {
                event = .modified
            } else if pendingAttributes {
                event = .attributes
            } else {
                event = nil
            }
            pendingContent = false
            pendingAttributes = false
            pendingGone = nil
            if let event { continuation.yield(event) }
        }
    }
}
