import CoddCore
import CoreServices
import Foundation

/// The live entries of the watched registry directories, in priority order (directory order, then
/// pid order), ready for ``ActivityMerger/merge(context:hook:registry:)``.
public struct RegistrySnapshot: Sendable, Equatable {
    public var entries: [ClaudeRegistryEntry]

    public init(entries: [ClaudeRegistryEntry]) {
        self.entries = entries
    }
}

/// Watches Claude Code's session registry (`~/.claude/sessions/<pid>.json`, plus the `sessions`
/// directory of every extra `CLAUDE_CONFIG_DIR`) and emits a ``RegistrySnapshot`` whenever the set
/// of live entries changes.
///
/// - FSEvents with file-level events, because Claude may rewrite a file in place (which a kqueue
///   watch on the directory would not see).
/// - Coalescing: the first change schedules a read ``Configuration/debounce`` later and every change
///   until then joins it, so a burst costs one read, latency stays bounded, and reads happen at
///   most 10 times a second at the default 100 ms.
/// - Partial writes: a file that fails to decode keeps its previous good entry (and a re-read is
///   scheduled), so a session does not flicker out while Claude is mid-write. A file that never
///   decoded is simply absent.
/// - A missing directory (Claude never run with that config dir yet, or deleted) is polled every
///   ``Configuration/missingDirectoryRetry`` until it appears; FSEvents' root watch notices when a
///   watched directory goes away.
/// - Liveness (pid + `procStart`) is re-checked every ``Configuration/livenessRecheck`` without
///   reading files, because a crashed Claude leaves its file behind and no event fires.
///
/// All work happens on one private serial queue (hence `@unchecked Sendable`); file reads go
/// through CoddCore's tolerant ``ClaudeRegistryReader``.
public final class RegistryWatcher: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Registry directories in priority order (`~/.claude/sessions` first).
        public var directories: [URL]
        public var debounce: Duration
        public var missingDirectoryRetry: Duration
        /// `nil` disables the periodic liveness re-check.
        public var livenessRecheck: Duration?
        /// Re-reads after a file failed to decode, before giving up until the next event.
        public var maxPartialWriteRetries: Int

        public init(directories: [URL] = [ClaudeRegistryReader.directory(configDir: nil)],
                    debounce: Duration = .milliseconds(100), missingDirectoryRetry: Duration = .seconds(2),
                    livenessRecheck: Duration? = .seconds(5), maxPartialWriteRetries: Int = 10) {
            self.directories = directories
            self.debounce = debounce
            self.missingDirectoryRetry = missingDirectoryRetry
            self.livenessRecheck = livenessRecheck
            self.maxPartialWriteRetries = maxPartialWriteRetries
        }
    }

    /// Snapshots, the first one right after ``start()``. Single consumer; only the newest is kept
    /// when the consumer lags (each snapshot is complete).
    public let snapshots: AsyncStream<RegistrySnapshot>
    private let continuation: AsyncStream<RegistrySnapshot>.Continuation
    private let queue = DispatchQueue(label: "app.codd.hooks.registry", qos: .utility)
    private let reader: ClaudeRegistryReader
    private let liveness: any ProcessLivenessChecking

    // Queue-confined.
    private var configuration: Configuration
    /// Keyed by ``Self/key(_:)``: URL equality is not stable for a directory (a URL built while the
    /// directory is missing has no trailing slash; one built once it exists may have one).
    private var watches: [String: DirectoryWatch] = [:]
    private var running = false
    private var readScheduled = false
    private var partialRetries = 0
    private var lastEmitted: [ClaudeRegistryEntry]?
    private var generation = 0
    /// Total directory reads (tests assert coalescing with it).
    private var readCount = 0

    public init(configuration: Configuration = Configuration(),
                liveness: any ProcessLivenessChecking = DarwinProcessLiveness(),
                reader: ClaudeRegistryReader = ClaudeRegistryReader()) {
        self.configuration = configuration
        self.liveness = liveness
        self.reader = reader
        (snapshots, continuation) = AsyncStream.makeStream(of: RegistrySnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        // FSEvents streams must be invalidated on the queue they deliver to; the block keeps the
        // watches (the streams' callback context) alive until then.
        let watches = self.watches
        queue.async {
            for watch in watches.values { watch.invalidate() }
        }
        continuation.finish()
    }

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.syncWatches()
            self.readNow()
            self.scheduleLivenessRecheck(generation: self.generation)
        }
    }

    /// Stops watching; ``snapshots`` stays open for a later ``start()``.
    public func stop() {
        queue.sync {
            self.running = false
            self.generation += 1
            for watch in self.watches.values { watch.invalidate() }
            self.watches.removeAll()
            self.readScheduled = false
        }
    }

    /// Stops and ends ``snapshots``.
    public func finish() {
        stop()
        continuation.finish()
    }

    /// Replaces the watched directories (for example when an account with its own
    /// `CLAUDE_CONFIG_DIR` is added) and re-reads.
    public func setDirectories(_ directories: [URL]) {
        queue.async {
            self.configuration.directories = directories
            guard self.running else { return }
            self.syncWatches()
            self.readNow()
        }
    }

    /// Forces a read now (for example after the app wakes from sleep).
    public func refresh() {
        queue.async {
            guard self.running else { return }
            self.readNow()
        }
    }

    /// Number of directory read passes so far.
    public func readPasses() -> Int {
        queue.sync { readCount }
    }

    // MARK: - Queue

    /// A stable identity for a directory: the standardized path without a trailing slash.
    static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private var orderedKeys: [String] {
        var seen = Set<String>()
        return configuration.directories.map(Self.key).filter { seen.insert($0).inserted }
    }

    private func syncWatches() {
        let wanted = Set(orderedKeys)
        for (key, watch) in watches where !wanted.contains(key) {
            watch.invalidate()
            watches[key] = nil
        }
        for key in orderedKeys where watches[key] == nil {
            let watch = DirectoryWatch(path: key, queue: queue) { [weak self] kind in
                self?.directoryChanged(key, kind)
            }
            watches[key] = watch
            arm(watch)
        }
    }

    /// Starts the FSEvents stream when the directory exists, else polls for it.
    private func arm(_ watch: DirectoryWatch) {
        guard running else { return }
        if watch.startIfPresent() { return }
        let gen = generation
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(configuration.missingDirectoryRetry)) { [weak self, weak watch] in
            guard let self, let watch, self.running, gen == self.generation, self.watches[watch.path] === watch else { return }
            if watch.isStreaming { return }
            if watch.startIfPresent() {
                self.readNow() // it appeared: pick up whatever is already there
            } else {
                self.arm(watch)
            }
        }
    }

    private func directoryChanged(_ key: String, _ kind: DirectoryWatch.Change) {
        guard running else { return }
        switch kind {
        case .contents:
            scheduleRead()
        case .rootChanged:
            // The directory itself was moved or deleted: drop the stream and wait for it again.
            if let watch = watches[key] {
                watch.stopStream()
                arm(watch)
            }
            scheduleRead()
        }
    }

    private func scheduleRead() {
        guard running, !readScheduled else { return }
        readScheduled = true
        let gen = generation
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(configuration.debounce)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.readScheduled = false
            self.readNow()
        }
    }

    private func readNow() {
        guard running else { return }
        readCount += 1
        var sawPartial = false
        for key in orderedKeys {
            guard let watch = watches[key] else { continue }
            let files = reader.readFiles(directory: URL(fileURLWithPath: key, isDirectory: true))
            var next: [String: ClaudeRegistryEntry] = [:]
            for file in files {
                if let entry = file.entry {
                    next[file.name] = entry
                } else {
                    sawPartial = true
                    if let previous = watch.lastGood[file.name] { next[file.name] = previous }
                }
            }
            watch.lastGood = next
            watch.order = files.map(\.name).filter { next[$0] != nil }
        }
        if sawPartial, partialRetries < configuration.maxPartialWriteRetries {
            partialRetries += 1
            scheduleRead()
        } else if !sawPartial {
            partialRetries = 0
        }
        emitIfChanged()
    }

    private func emitIfChanged() {
        var entries: [ClaudeRegistryEntry] = []
        for key in orderedKeys {
            guard let watch = watches[key] else { continue }
            entries += watch.order.compactMap { watch.lastGood[$0] }
        }
        let live = ClaudeRegistryReader.liveEntries(entries, liveness: liveness)
        guard live != lastEmitted else { return }
        lastEmitted = live
        continuation.yield(RegistrySnapshot(entries: live))
    }

    private func scheduleLivenessRecheck(generation gen: Int) {
        guard let interval = configuration.livenessRecheck else { return }
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(interval)) { [weak self] in
            guard let self, self.running, gen == self.generation else { return }
            self.emitIfChanged()
            self.scheduleLivenessRecheck(generation: gen)
        }
    }

    static func dispatchInterval(_ d: Duration) -> DispatchTimeInterval {
        let c = d.components
        return .nanoseconds(Int(c.seconds) * 1_000_000_000 + Int(c.attoseconds / 1_000_000_000))
    }
}

/// One directory's FSEvents stream and last good entries. Confined to the watcher queue.
final class DirectoryWatch: @unchecked Sendable {
    enum Change {
        case contents
        case rootChanged
    }

    let path: String
    let queue: DispatchQueue
    let onChange: (Change) -> Void
    var lastGood: [String: ClaudeRegistryEntry] = [:]
    /// File names of ``lastGood`` in reader order.
    var order: [String] = []
    private var stream: FSEventStreamRef?

    init(path: String, queue: DispatchQueue, onChange: @escaping (Change) -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    var isStreaming: Bool { stream != nil }

    /// Creates the stream when the directory exists. `true` when streaming.
    func startIfPresent() -> Bool {
        if stream != nil { return true }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, _, flagsPointer, _ in
            guard let info else { return }
            let watch = Unmanaged<DirectoryWatch>.fromOpaque(info).takeUnretainedValue()
            var rootChanged = false
            for i in 0..<count where flagsPointer[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
            }
            watch.onChange(rootChanged ? .rootChanged : .contents)
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03, flags) else { return false }
        // Callbacks run on the watcher queue, the same queue that owns this object.
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stopStream() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    /// Stops the stream and forgets the entries (the directory is no longer watched).
    func invalidate() {
        stopStream()
        lastGood.removeAll()
        order.removeAll()
    }

    deinit {
        stopStream()
    }
}
