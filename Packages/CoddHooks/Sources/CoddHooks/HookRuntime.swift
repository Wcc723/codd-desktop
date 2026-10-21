import CoddCore
import Foundation
import Synchronization

/// The hook pipeline as one object: config.json → ``HookServer`` and ``RegistryWatcher`` → pumped
/// into a ``SessionStateEngine`` whose ``SessionStateEngine/updates`` the UI consumes.
///
/// In M1 the app hosts this (degraded mode); `coddd` takes it over later with the same parts.
/// Register restored sessions on ``engine`` before ``start()`` where possible; hooks that arrive
/// earlier are buffered by the engine anyway.
public final class HookRuntime: Sendable {
    public let config: HookConfig
    public let server: HookServer
    public let watcher: RegistryWatcher
    public let engine: SessionStateEngine
    private let pumps = Mutex<[Task<Void, Never>]>([])

    public init(config: HookConfig, dataRoot: URL,
                registryDirectories: [URL] = [ClaudeRegistryReader.directory(configDir: nil)],
                clock: any HookClock = SystemHookClock(),
                liveness: any ProcessLivenessChecking = DarwinProcessLiveness()) {
        self.config = config
        server = HookServer(configuration: .init(config: config), clock: clock)
        watcher = RegistryWatcher(configuration: .init(directories: registryDirectories), liveness: liveness)
        engine = SessionStateEngine(configuration: .init(dataRoot: dataRoot), clock: clock)
    }

    /// Loads or creates `<dataRoot>/config.json` and builds the runtime (nothing is started).
    public static func make(dataRoot: URL, registryDirectories: [URL] = [ClaudeRegistryReader.directory(configDir: nil)])
        throws(HookConfigError) -> (HookRuntime, HookConfigLoad) {
        let load = try HookConfigStore(dataRoot: dataRoot).loadOrCreate()
        return (HookRuntime(config: load.config, dataRoot: dataRoot, registryDirectories: registryDirectories), load)
    }

    /// Starts the pumps (once), the registry watcher and the server. A busy port throws
    /// ``HookServerError/portInUse(_:)``; the watcher and engine keep working without hooks
    /// (registry-only states), and ``startServer()`` can be retried.
    @discardableResult
    public func start() async throws(HookServerError) -> UInt16 {
        pumps.withLock { tasks in
            guard tasks.isEmpty else { return }
            let engine = engine
            let events = server.events
            let snapshots = watcher.snapshots
            tasks.append(Task.detached(priority: .userInitiated) {
                for await event in events { await engine.ingest(event) }
            })
            tasks.append(Task.detached(priority: .utility) {
                for await snapshot in snapshots { await engine.ingestRegistry(snapshot) }
            })
        }
        watcher.start()
        return try await startServer()
    }

    /// Starts (or retries) only the HTTP endpoint.
    @discardableResult
    public func startServer() async throws(HookServerError) -> UInt16 {
        try await server.start()
    }

    /// Stops the server and the watcher and writes pending hook records. The pumps stay alive
    /// (cancelling an `AsyncStream` consumer would end the stream for good), so ``start()`` works
    /// again later.
    public func stop() async {
        await server.stop()
        watcher.stop()
        await engine.flush()
    }

    /// Stops everything and ends all streams (app termination).
    public func finish() async {
        await server.finish()
        watcher.finish()
        await engine.finish()
        let tasks = pumps.withLock { t in
            defer { t.removeAll() }
            return t
        }
        for task in tasks { await task.value }
    }
}
