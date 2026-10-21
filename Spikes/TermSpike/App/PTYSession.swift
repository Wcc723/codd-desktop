import Foundation
import Synchronization
import TermSpikeKit

/// Joins one engine to one child process on a PTY:
/// PTY read queue → `feeder` (never the main thread), engine output → PTY
/// write, engine resize → `TIOCSWINSZ`, and every PTY write ends a pending
/// keyDown→ptyWrite latency interval.
///
/// Flow control: engines that queue output (Ghostty) pause the PTY read loop
/// while more than `backlogHighWater` bytes wait to be parsed, the way the
/// holder pauses for a slow client (docs/ARCHITECTURE.md), so a flood such as
/// `cat` of a large file never builds an unbounded queue in the app. The
/// water marks are small so a keystroke echo never waits behind more than a
/// few milliseconds of parsing.
///
/// Note: probe replies the engine writes also end a pending interval (FIFO);
/// the header numbers are only meaningful while typing, not while a program
/// is querying the terminal.
@MainActor
final class PTYSession {
    /// Diagnostic knob: `SPIKE_BACKLOG_KIB=high,low` overrides the marks
    /// (`SPIKE_BACKLOG_KIB=0` turns flow control off, for comparison).
    nonisolated static let backlogMarks: (high: Int, low: Int)? = {
        guard let value = ProcessInfo.processInfo.environment["SPIKE_BACKLOG_KIB"] else {
            return (1 << 20, 256 << 10)
        }
        let parts = value.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[1] < parts[0], parts[1] >= 0 else { return nil }
        return (parts[0] << 10, parts[1] << 10)
    }()
    nonisolated static var backlogHighWater: Int { backlogMarks?.high ?? Int.max }
    nonisolated static var backlogLowWater: Int { backlogMarks?.low ?? Int.max - 1 }

    let process: PTYProcess
    let commandLine: String
    private let host: any TerminalEngineHost
    private let gate: OutputGate

    /// - Parameter onExit: called on the main actor with the raw wait status.
    init(
        host: any TerminalEngineHost,
        command: String,
        termProgram: String?,
        tracker: KeyLatencyTracker,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        let (term, extra) = host.childTerminal()
        let environment = ChildEnvironment.build(
            parent: ProcessInfo.processInfo.environment,
            term: term,
            termProgram: termProgram,
            extra: extra
        )
        let (executable, arguments) = CommandLineSpec.loginShell(command: command)
        let spec = PTYLaunchSpec(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            size: host.io.currentSize ?? .fallback
        )
        // Route the engine's output before the child exists: a reply produced
        // between the spawn and this init returning would otherwise be lost.
        let target = PTYWriteTarget()
        host.io.setOutput { data in target.write(data) }
        host.io.setResize { size in target.resize(size) }
        let feeder = host.feeder
        let gate = OutputGate()
        let process: PTYProcess
        do {
            process = try PTYProcess(
                spec: spec,
                label: host.kind.rawValue,
                onOutput: { buffer in
                    if gate.isOpen { feeder.feed(buffer) }
                },
                onWrite: { _ in tracker.ptyWritten() },
                onExit: { status in
                    Task { @MainActor in onExit(status) }
                }
            )
        } catch {
            host.io.setOutput(nil)
            host.io.setResize(nil)
            throw error
        }
        target.attach(process)
        host.setBacklogHandler(highWater: Self.backlogHighWater, lowWater: Self.backlogLowWater) { backlogged in
            if backlogged { process.pauseReading() } else { process.resumeReading() }
        }
        self.process = process
        self.host = host
        self.gate = gate
        commandLine = command
    }

    /// Writes bytes as if typed (used by the Cmd+V image shim).
    func sendRaw(_ bytes: [UInt8]) {
        process.write(Data(bytes))
    }

    /// Detaches the engine and hangs up the child. The process object stays
    /// alive until its exit is reaped (see `EnginePane`). Output the dying
    /// child still prints is dropped, so it cannot land on the screen of the
    /// next session started in the same engine (at most one chunk that is
    /// already being fed can still get through).
    func detachAndTerminate() {
        gate.close()
        host.setBacklogHandler(highWater: Self.backlogHighWater, lowWater: Self.backlogLowWater, nil)
        host.io.setOutput(nil)
        host.io.setResize(nil)
        // Reading must not stay paused, or the hangup is never read and the
        // descriptor stays open until the process object is released.
        process.resumeReading()
        process.terminate()
    }
}

/// Lets the PTY read queue stop feeding an engine without a lock.
final class OutputGate: Sendable {
    private let open = Atomic<Bool>(true)

    var isOpen: Bool { open.load(ordering: .acquiring) }

    func close() {
        open.store(false, ordering: .releasing)
    }
}

/// Engine output and resizes for a PTY that is still being spawned: held
/// until `attach`, then forwarded.
final class PTYWriteTarget: Sendable {
    private struct State {
        var process: PTYProcess?
        var pending: [Data] = []
        var size: PTYWindowSize?
    }

    private let state = Mutex(State())

    func write(_ data: Data) {
        let process: PTYProcess? = state.withLock { state in
            if state.process == nil { state.pending.append(data) }
            return state.process
        }
        process?.write(data)
    }

    func resize(_ size: PTYWindowSize) {
        let process: PTYProcess? = state.withLock { state in
            if state.process == nil { state.size = size }
            return state.process
        }
        process?.resize(size)
    }

    /// Flushes under the lock (`PTYProcess.write` only enqueues), so held
    /// bytes stay ahead of every write that sees the process afterwards.
    func attach(_ process: PTYProcess) {
        state.withLock { state in
            state.process = process
            if let size = state.size { process.resize(size) }
            for data in state.pending { process.write(data) }
            state.pending = []
            state.size = nil
        }
    }
}
