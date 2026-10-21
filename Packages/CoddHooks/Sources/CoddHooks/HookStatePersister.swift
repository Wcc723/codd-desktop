import CoddCore
import Foundation

/// Writes each session's ``HookSessionState`` to `<dataRoot>/hooks/<session-id>.json` (0600, dir
/// 0700), coalescing writes per session for ``debounce``, and reads them back at registration.
///
/// The files exist so a relaunched CODD shows a running session's state (WAITING, BUSY, …) before
/// its next hook arrives. They are a cache, written with an atomic rename but no disk flush (see
/// ``FileIO/writeAtomically(_:to:mode:durable:)``). All file work happens on a private serial
/// queue; ``load(_:)`` and ``flush()`` wait for it.
final class HookStatePersister: @unchecked Sendable {
    static let maxFileBytes = 256 * 1024

    let directory: URL
    let debounce: Duration
    private let queue = DispatchQueue(label: "app.codd.hooks.persist", qos: .utility)
    // Queue-confined.
    private var pending: [UUID: HookSessionState] = [:]
    private var scheduled = false
    private var directoryReady = false
    private(set) var writeCount = 0
    private(set) var lastError: String?

    init(directory: URL, debounce: Duration) {
        self.directory = directory
        self.debounce = debounce
    }

    func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false)
    }

    func schedule(_ id: UUID, _ state: HookSessionState) {
        queue.async {
            self.pending[id] = state
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + RegistryWatcher.dispatchInterval(self.debounce)) {
                self.writePending()
            }
        }
    }

    /// The newest state for `id`: a not-yet-written one, else the file (`nil` when absent or not
    /// decodable).
    func load(_ id: UUID) -> HookSessionState? {
        queue.sync {
            if let state = pending[id] { return state }
            guard let data = try? FileIO.read(fileURL(id), limit: Self.maxFileBytes) else { return nil }
            return try? JSONDecoder().decode(HookSessionState.self, from: data)
        }
    }

    /// Writes everything pending now (app quit, tests).
    func flush() {
        queue.sync { writePending() }
    }

    /// Forgets `id` and deletes its file.
    func remove(_ id: UUID) {
        queue.async {
            self.pending[id] = nil
            unlink(self.fileURL(id).path)
        }
    }

    /// Deletes the files of sessions not in `keeping` (sessions deleted while CODD was not running).
    func prune(keeping: Set<UUID>) {
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? []
            for name in names where name.hasSuffix(".json") {
                guard let id = UUID(uuidString: String(name.dropLast(5))), name == "\(id.uuidString.lowercased()).json",
                      !keeping.contains(id) else { continue }
                self.pending[id] = nil
                unlink(self.directory.appendingPathComponent(name).path)
            }
        }
    }

    func statistics() -> (writes: Int, lastError: String?) {
        queue.sync { (writeCount, lastError) }
    }

    private func writePending() {
        scheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        if !directoryReady {
            do {
                try FileIO.ensureDirectory(directory)
                directoryReady = true
            } catch {
                lastError = error.description
                return
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (id, state) in batch {
            do {
                let data = try encoder.encode(state)
                try FileIO.writeAtomically(data, to: fileURL(id), durable: false)
                writeCount += 1
            } catch let failure as FileIO.Failure {
                lastError = failure.description
                directoryReady = false // recreate it if it was deleted underneath us
            } catch {
                lastError = String(describing: error)
            }
        }
    }
}
