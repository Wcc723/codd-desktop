import Dispatch
import Foundation
import Synchronization

/// One file a CODD session's Edit / Write / MultiEdit / NotebookEdit named (D26).
public struct AITouch: Sendable, Equatable, Codable {
    /// Absolute path (relative payload paths resolved against the payload `cwd` by the caller).
    public var path: String
    /// The CODD session id (uuid).
    public var session: String
    /// `Edit`, `Write`, `MultiEdit`, `NotebookEdit`.
    public var tool: String
    public var at: Date

    public init(path: String, session: String, tool: String, at: Date) {
        self.path = path
        self.session = session
        self.tool = tool
        self.at = at
    }
}

/// The AI-touched files (`files/ai-touches.json`, §3.4): kept ``retention`` (7 days), at most
/// ``maxItems`` (the newest win). Reads are served from memory; writes are debounced
/// (``saveDelay`` after the last `record`) and atomic, so a burst of PostToolUse hooks costs one
/// write. ``flush()`` writes now (app quit, tests). Thread-safe.
public final class AITouchLog: Sendable {
    public static let retention: TimeInterval = 7 * 24 * 3600
    public static let maxItems = 2_000

    public let file: URL
    public let saveDelay: Duration
    private let clock: @Sendable () -> Date
    private let state: Mutex<State>
    /// Held while a snapshot is taken and written, so writes land in order.
    private let writing = Mutex(0)
    private let queue = DispatchQueue(label: "codd.files.ai-touches")

    private struct State {
        var items: [AITouch]?
        var readOnly = false
        var generation = 0
        var dirty = false
    }

    public init(file: URL, clock: @escaping @Sendable () -> Date, saveDelay: Duration = .seconds(1)) {
        self.file = file
        self.clock = clock
        self.saveDelay = saveDelay
        state = Mutex(State())
    }

    public func record(_ touches: [AITouch]) {
        guard !touches.isEmpty else { return }
        let generation: Int = state.withLock { state in
            var list = items(&state)
            list.append(contentsOf: touches)
            state.items = Self.trimmed(list, now: clock())
            state.dirty = true
            state.generation += 1
            return state.generation
        }
        let c = saveDelay.components
        queue.asyncAfter(deadline: .now() + TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18) { [weak self] in
            self?.saveIfCurrent(generation)
        }
    }

    /// Touches of files under `root` (nil: everywhere) at or after `since`, newest first. Either
    /// spelling matches (``spellings(of:)``): a hook names `/private/var/…` where the app's URLs
    /// say `/var/…`.
    public func touches(under root: URL?, since: Date) -> [AITouch] {
        let prefixes = root.map { Self.spellings(of: $0.path) } ?? []
        return state.withLock { state in
            items(&state).filter { touch in
                touch.at >= since && (prefixes.isEmpty || Self.lexicalSpellings(of: touch.path).contains { path in
                    prefixes.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
                })
            }
        }.sorted { $0.at > $1.at }
    }

    /// The newest touch of `path` (absolute, either spelling).
    public func latest(for path: String) -> AITouch? {
        let keys = Self.spellings(of: path)
        return state.withLock { state in
            items(&state).filter { !keys.isDisjoint(with: Self.lexicalSpellings(of: $0.path)) }.max { $0.at < $1.at }
        }
    }

    /// Every spelling of `path` worth comparing: as given, standardized and with symlinks
    /// resolved (Foundation drops a leading `/private` on both), the real path (`realpath(3)`
    /// keeps it), and the ``lexicalSpellings(of:)`` of each.
    static func spellings(of path: String) -> Set<String> {
        let url = URL(fileURLWithPath: path)
        var paths = [path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        if let real = realpath(path, nil) {
            paths.append(String(cString: real))
            free(real)
        }
        return paths.reduce(into: Set<String>()) { $0.formUnion(lexicalSpellings(of: $1)) }
    }

    /// `path` without a trailing slash, with and without `/private` before `/var`, `/tmp` and
    /// `/etc` (macOS's firmlinks). No file system call: cheap enough for every logged touch.
    static func lexicalSpellings(of path: String) -> Set<String> {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        var result: Set<String> = [trimmed]
        for top in ["/var", "/tmp", "/etc"] {
            if trimmed == "/private" + top || trimmed.hasPrefix("/private" + top + "/") {
                result.insert(String(trimmed.dropFirst("/private".count)))
            } else if trimmed == top || trimmed.hasPrefix(top + "/") {
                result.insert("/private" + trimmed)
            }
        }
        return result
    }

    /// Writes pending changes now.
    public func flush() {
        writing.withLock { _ in
            let snapshot: [AITouch]? = state.withLock { state in
                guard state.dirty, !state.readOnly else { return nil }
                state.dirty = false
                return state.items
            }
            if let snapshot { try? StoreFile<AITouch>(url: file).save(snapshot) }
        }
    }

    private func saveIfCurrent(_ generation: Int) {
        let current = state.withLock { $0.generation == generation }
        if current { flush() }
    }

    private func items(_ state: inout State) -> [AITouch] {
        if let items = state.items { return items }
        let loaded = StoreFile<AITouch>(url: file).load(now: clock())
        let trimmed = Self.trimmed(loaded.items, now: clock())
        state.items = trimmed
        state.readOnly = loaded.readOnly
        return trimmed
    }

    /// Within the retention, oldest first, at most `maxItems` (the newest kept).
    private static func trimmed(_ items: [AITouch], now: Date) -> [AITouch] {
        let live = items.filter { now.timeIntervalSince($0.at) <= retention }.sorted { $0.at < $1.at }
        return Array(live.suffix(maxItems))
    }

}
