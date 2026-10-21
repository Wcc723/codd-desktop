// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.

import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void
    typealias Tick = @Sendable (ghostty_surface_t) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated,
    )
    private let write: Write
    /// CODD: parses reconstructed history with replies suppressed.
    private let replay: Write
    private let processExit: ProcessExit
    private let tick: Tick

    private var surface: ghostty_surface_t?
    /// Prevents the caller from freeing a surface while a C operation uses it.
    private var activeOperations = 0
    /// Host output in arrival order, not yet handed to a surface. Each entry
    /// is consumed by whichever surface is attached when the output queue
    /// reaches it, so output queued behind a slow parse survives a surface
    /// rebuild, and output received while no surface is attached waits for
    /// the next one. The host's transport does not pause while a view
    /// (re)builds its surface — a reattach replay that lands in that gap used
    /// to be dropped, leaving the restored session showing only whatever the
    /// shell printed afterwards.
    private var operations = InMemoryTerminalPendingOperations()
    /// Bound on the bytes kept while no surface is attached: oldest bytes go
    /// first, matching what a terminal scrollback would have forgotten anyway.
    /// The next surface sees exactly this many; meanwhile up to twice as many
    /// are held, so a flood trims once per limit's worth of bytes instead of
    /// moving the whole buffer for every chunk.
    private static let pendingWriteByteLimit = 1 << 20
    /// Set when detached output went past the limit and the trim to exactly
    /// the limit is still owed to the next surface.
    private var pendingTrimOwed = false
    /// Parsing on the output queue pushes titles, pwd and command marks into
    /// ghostty's 64-slot app mailbox, which only `ghostty_app_tick` drains,
    /// and this package ticks on the main thread alone. A main-thread caller
    /// that blocks on the queue outright therefore waits forever on a write
    /// that is itself waiting for the tick, so the main thread waits in
    /// slices and ticks between them.
    private static let mainThreadPollInterval: TimeInterval = 0.01
    /// A drain block is in the output queue. One block works through the
    /// backlog instead of one block per `receive`: a flood of small writes
    /// queued a block per write, and the blocks outlived the bytes.
    private var isDrainScheduled = false
    /// Operations one drain block hands over before it yields the queue, so
    /// a `waitForPendingOutput` barrier is not starved by a live flood.
    private static let drainBatchLimit = 64
    private var backlogObserver: BacklogObserver?
    private var isBacklogged = false
    /// CODD: bumped whenever the observer is replaced; what was delivered to an older one no
    /// longer counts.
    private var backlogEpoch = 0
    /// CODD: serializes backlog handler calls (recursive: a handler may call back into the
    /// session). Each transition is decided under `condition` but delivered after it is released,
    /// on whichever thread crossed the mark; two crossings racing to the handler could arrive in
    /// the wrong order, and a host that applied a stale `true` last stayed paused with nothing
    /// queued, waiting for a `false` that never came. So a delivery hands over the state current
    /// when it runs, never one already handed over.
    private let backlogDelivery = NSRecursiveLock()
    /// CODD: guarded by `backlogDelivery`.
    private var deliveredBacklog = false
    private var deliveredEpoch = 0

    /// CODD: a new surface starts at libghostty's default 800×600 px grid, and the view's real size
    /// reaches the terminal only after the IO thread's 25 ms resize coalescing. Output parsed in
    /// that window (typically a whole reattach replay) is laid out for the wrong width: absolute
    /// cursor moves clamp, an alternate-screen TUI comes out garbled. So after a surface attaches,
    /// output waits until the IO thread reports the grid the coordinator sized the surface to
    /// (`expectGrid`), or until `sizeGateTimeout` passes.
    private enum SizeGate {
        case open
        case waiting(expected: GridSize?)
    }

    struct GridSize: Equatable {
        var columns: UInt16
        var rows: UInt16
    }

    private var sizeGate = SizeGate.open
    /// Retires the timers of a gate that a newer surface replaced.
    private var sizeGateGeneration = 0
    /// The last grid the IO thread reported for the current surface.
    private var lastReportedGrid: GridSize?
    private var sizeGateTimeoutHandler: (@Sendable () -> Void)?
    private static let sizeGateTimeout: TimeInterval = 0.25
    /// The IO thread reports a grid right before it takes the terminal-state mutex to apply it;
    /// the first write waits this long so it lands after the resize.
    private static let sizeGateSettle: TimeInterval = 0.004

    struct BacklogObserver {
        let highWater: Int
        let lowWater: Int
        let handler: @Sendable (Bool) -> Void
    }

    init(
        write: @escaping Write,
        replay: @escaping Write,
        processExit: @escaping ProcessExit,
        tick: @escaping Tick,
    ) {
        self.write = write
        self.replay = replay
        self.processExit = processExit
        self.tick = tick
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        let previous = self.surface
        self.surface = nil
        waitForActiveOperations(ticking: previous)
        self.surface = surface
        // Drains scheduled while detached ran without consuming anything, so
        // give every waiting operation a drain of its own.
        if surface != nil {
            if pendingTrimOwed {
                pendingTrimOwed = false
                operations.trimWrites(toLimit: Self.pendingWriteByteLimit)
            }
            // CODD: drains start once the surface has its real grid (see `SizeGate`).
            closeSizeGate()
        }
        let backlogChange = takeBacklogChange()
        condition.unlock()
        backlogChange?()
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        surface = nil
        waitForActiveOperations(ticking: expectedSurface)
        condition.unlock()
        return true
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    func enqueueWrite(_ data: Data) {
        condition.lock()
        if surface == nil {
            operations.appendCoalescing(data)
            if operations.writeByteCount > Self.pendingWriteByteLimit {
                pendingTrimOwed = true
                if operations.writeByteCount > 2 * Self.pendingWriteByteLimit {
                    operations.trimWrites(toLimit: Self.pendingWriteByteLimit)
                }
            }
        } else {
            operations.append(.write(data))
            scheduleDrain()
        }
        let backlogChange = takeBacklogChange()
        condition.unlock()
        backlogChange?()
    }

    /// CODD: an ordered replay of reconstructed history. It waits in the same queue as live
    /// writes, so it is parsed after every write enqueued before it and before every write
    /// enqueued after it. Unlike a detached write it is neither coalesced nor trimmed.
    func enqueueReplay(_ data: Data) {
        condition.lock()
        operations.append(.replay(data))
        if surface != nil {
            scheduleDrain()
        }
        let backlogChange = takeBacklogChange()
        condition.unlock()
        backlogChange?()
    }

    /// Bytes received and not yet handed to a surface (CODD: replays included).
    var pendingByteCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return operations.pendingByteCount
    }

    func setBacklogObserver(_ observer: BacklogObserver?) {
        // CODD: under the delivery lock, so the observer being replaced has finished its last call
        // when this returns and is never called again.
        backlogDelivery.lock()
        defer { backlogDelivery.unlock() }
        condition.lock()
        backlogObserver = observer
        backlogEpoch &+= 1
        isBacklogged = false
        let backlogChange = takeBacklogChange()
        condition.unlock()
        backlogChange?()
    }

    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64,
    ) {
        condition.lock()
        defer { condition.unlock() }
        operations.append(.processExit(
            exitCode: exitCode,
            runtimeMilliseconds: runtimeMilliseconds,
        ))
        if surface != nil {
            scheduleDrain()
        }
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result,
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    /// Returns false when output is still waiting for a surface to attach:
    /// that output is parsed only once the next surface attaches.
    ///
    /// A drain block hands over at most `drainBatchLimit` operations, so one
    /// barrier can land between two batches of earlier output; the wait goes
    /// round until everything appended before it has left the queue. The
    /// operation that left last did so in a block ahead of the barrier, so
    /// its write has finished too.
    @discardableResult
    func waitForPendingOutput() -> Bool {
        condition.lock()
        let target = operations.appendedSequence
        condition.unlock()
        while true {
            waitForOutputQueueBarrier()
            condition.lock()
            let attached = surface != nil
            let done = operations.retiredSequence >= target
            let empty = operations.isEmpty
            let gated = isSizeGateClosed
            condition.unlock()
            if !attached {
                return empty
            }
            if done {
                return true
            }
            if gated {
                // CODD: at most `sizeGateTimeout`; keep the app ticking on the main thread.
                if Thread.isMainThread {
                    tickCurrentSurface()
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }

    private func waitForOutputQueueBarrier() {
        if Thread.isMainThread {
            let drained = DispatchSemaphore(value: 0)
            outputQueue.async { drained.signal() }
            while drained.wait(timeout: .now() + Self.mainThreadPollInterval) == .timedOut {
                tickCurrentSurface()
            }
        } else {
            outputQueue.sync {}
        }
    }

    /// Ticks outside the lock and without counting an operation: the tick can
    /// deliver a close, and a host that tears the surface down from that
    /// callback re-enters `clearSurface` on this thread. Teardown is
    /// main-actor work, so the pointer stays valid across a main-thread tick.
    private func tickCurrentSurface() {
        condition.lock()
        let current = surface
        condition.unlock()
        if let current {
            tick(current)
        }
    }

    // MARK: - CODD: size gate

    /// Called by the session when the timeout opens the gate without a matching report.
    func setSizeGateTimeoutHandler(_ handler: (@Sendable () -> Void)?) {
        condition.lock()
        sizeGateTimeoutHandler = handler
        condition.unlock()
    }

    /// The grid the coordinator sized the current surface to (main thread, right after
    /// `ghostty_surface_set_size`). Opens the gate if the IO thread already reported it.
    func expectGrid(columns: UInt16, rows: UInt16) {
        condition.lock()
        defer { condition.unlock() }
        guard case .waiting = sizeGate else { return }
        let expected = GridSize(columns: columns, rows: rows)
        if lastReportedGrid == expected {
            openSizeGate(after: Self.sizeGateSettle)
        } else {
            sizeGate = .waiting(expected: expected)
        }
    }

    /// A grid the IO thread reported (it is about to apply it). Returns whether the host should
    /// hear about it: not while the gate waits for a different grid, so the default size a new
    /// surface starts at never reaches the PTY.
    func noteResize(columns: UInt16, rows: UInt16) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let grid = GridSize(columns: columns, rows: rows)
        lastReportedGrid = grid
        guard case let .waiting(expected) = sizeGate else { return true }
        guard let expected, expected == grid else { return false }
        openSizeGate(after: Self.sizeGateSettle)
        return true
    }

    private var isSizeGateClosed: Bool {
        if case .waiting = sizeGate { return true }
        return false
    }

    /// Called with the lock held.
    private func closeSizeGate() {
        sizeGateGeneration &+= 1
        sizeGate = .waiting(expected: nil)
        lastReportedGrid = nil
        let generation = sizeGateGeneration
        outputQueue.asyncAfter(deadline: .now() + Self.sizeGateTimeout) { [self] in
            condition.lock()
            guard generation == sizeGateGeneration, isSizeGateClosed else {
                condition.unlock()
                return
            }
            openSizeGateNow()
            let handler = sizeGateTimeoutHandler
            condition.unlock()
            handler?()
        }
    }

    /// Called with the lock held.
    private func openSizeGate(after delay: TimeInterval) {
        let generation = sizeGateGeneration
        // Stays closed until then; a second matching report only re-arms the same opening.
        outputQueue.asyncAfter(deadline: .now() + delay) { [self] in
            condition.lock()
            if generation == sizeGateGeneration, isSizeGateClosed {
                openSizeGateNow()
            }
            condition.unlock()
        }
    }

    /// Called with the lock held.
    private func openSizeGateNow() {
        sizeGate = .open
        if surface != nil, !operations.isEmpty {
            scheduleDrain()
        }
    }

    /// Called with the lock held. Each operation goes to the surface
    /// attached when the drain reaches it; a drain that finds no surface
    /// stops, and `setSurface` schedules the next one.
    private func scheduleDrain() {
        guard !isDrainScheduled else { return }
        isDrainScheduled = true
        outputQueue.async { [self] in drain() }
    }

    private func drain() {
        for _ in 0 ..< Self.drainBatchLimit {
            guard drainOne() else { return }
        }
        condition.lock()
        isDrainScheduled = false
        if surface != nil, !isSizeGateClosed, !operations.isEmpty {
            scheduleDrain()
        }
        condition.unlock()
    }

    /// False once nothing is left to hand over, with the drain unscheduled.
    private func drainOne() -> Bool {
        condition.lock()
        // CODD: a closed size gate stops the drain like a missing surface; opening it reschedules.
        guard let surface, !isSizeGateClosed, let operation = operations.popFirst() else {
            isDrainScheduled = false
            condition.unlock()
            return false
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        switch operation {
        case let .write(data):
            write(surface, data)
        case let .replay(data):
            replay(surface, data)
        case let .processExit(exitCode, runtimeMilliseconds):
            processExit(surface, exitCode, runtimeMilliseconds)
        }
        return true
    }

    /// Called with the lock held; the caller runs the result after unlocking,
    /// so a handler may call back into the session.
    private func takeBacklogChange() -> (() -> Void)? {
        guard let backlogObserver else { return nil }
        // CODD: replays count too; a reattach streams up to a whole ring through them.
        let bytes = operations.pendingByteCount
        let backlogged: Bool = if isBacklogged {
            bytes > backlogObserver.lowWater
        } else {
            bytes >= backlogObserver.highWater
        }
        guard backlogged != isBacklogged else { return nil }
        isBacklogged = backlogged
        // CODD: delivers whatever is current by then (see `backlogDelivery`).
        return { [self] in deliverBacklogState() }
    }

    /// CODD: hands the observer the current backlog state if it has not been handed over yet.
    /// Called without `condition` held.
    private func deliverBacklogState() {
        backlogDelivery.lock()
        defer { backlogDelivery.unlock() }
        condition.lock()
        let observer = backlogObserver
        let backlogged = isBacklogged
        let epoch = backlogEpoch
        condition.unlock()
        guard let observer else { return }
        if deliveredEpoch != epoch {
            deliveredEpoch = epoch
            deliveredBacklog = false
        }
        guard backlogged != deliveredBacklog else { return }
        deliveredBacklog = backlogged
        observer.handler(backlogged)
    }

    private func finishOperation() {
        condition.lock()
        activeOperations -= 1
        if activeOperations == 0 {
            condition.broadcast()
        }
        let backlogChange = takeBacklogChange()
        condition.unlock()
        backlogChange?()
    }

    /// Called with the lock held. `previous` is the surface the in-flight
    /// operations use; the caller frees it only after this returns.
    private func waitForActiveOperations(ticking previous: ghostty_surface_t?) {
        while activeOperations > 0 {
            guard Thread.isMainThread, let previous else {
                condition.wait()
                continue
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.mainThreadPollInterval))
            guard activeOperations > 0 else { return }
            condition.unlock()
            tick(previous)
            condition.lock()
        }
    }
}
