import Foundation
import Synchronization

/// One Recent row of the tree (`files/recent.json`, §3.4).
public struct RecentFile: Sendable, Equatable, Codable {
    /// Absolute path of the file.
    public var path: String
    /// Absolute path of the project root it was opened in.
    public var root: String
    public var openedAt: Date
    /// `user` (opened in the tree, ⌘P, a path) or `note` (opened from a note's LOCAL FILES).
    public var source: String

    public init(path: String, root: String, openedAt: Date, source: String) {
        self.path = path
        self.root = root
        self.openedAt = openedAt
        self.source = source
    }
}

/// The recently opened files (≤ ``maxItems``, newest first; an entry not opened for
/// ``expiry`` drops). Every change is written at once (atomic, 0600). Thread-safe; the file I/O
/// is synchronous, so call it off the main actor.
public final class RecentFilesStore: Sendable {
    public static let maxItems = 20
    public static let expiry: TimeInterval = 30 * 24 * 3600

    public let file: URL
    private let clock: @Sendable () -> Date
    private let state: Mutex<State>

    private struct State {
        var items: [RecentFile]?
        var readOnly = false
    }

    public init(file: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.clock = clock
        state = Mutex(State())
    }

    /// The live entries, newest first.
    public func load() -> [RecentFile] {
        state.withLock { state in
            Self.live(items(&state), now: clock())
        }
    }

    public func record(_ path: URL, root: URL, source: String, at: Date) {
        state.withLock { state in
            var list = items(&state).filter { $0.path != path.path }
            list.insert(RecentFile(path: path.path, root: root.path, openedAt: at, source: source), at: 0)
            list = Self.live(list, now: max(at, clock()))
            commit(list, into: &state)
        }
    }

    public func remove(_ path: URL) {
        state.withLock { state in
            let list = items(&state)
            let kept = list.filter { $0.path != path.path }
            guard kept.count != list.count else { return }
            commit(kept, into: &state)
        }
    }

    private func items(_ state: inout State) -> [RecentFile] {
        if let items = state.items { return items }
        let loaded = StoreFile<RecentFile>(url: file).load(now: clock())
        state.items = loaded.items
        state.readOnly = loaded.readOnly
        return loaded.items
    }

    private func commit(_ list: [RecentFile], into state: inout State) {
        state.items = list
        guard !state.readOnly else { return }
        try? StoreFile<RecentFile>(url: file).save(list)
    }

    private static func live(_ items: [RecentFile], now: Date) -> [RecentFile] {
        let sorted = items.sorted { $0.openedAt > $1.openedAt }
        var seen = Set<String>()
        return Array(sorted.filter { now.timeIntervalSince($0.openedAt) <= expiry && seen.insert($0.path).inserted }.prefix(maxItems))
    }
}
