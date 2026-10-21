import Darwin
import Dispatch
import Foundation
import os
import Synchronization

/// A child process on its own pseudo-terminal, with a background read loop.
///
/// Spike-local stand-in for `codd-holder`: no socket, no ring, just `forkpty`
/// plus non-blocking I/O on a private serial queue.
///
/// - Output is drained on `queue` in batches of up to 64 KiB and handed to
///   `onOutput`; the buffer is only valid during the call.
/// - Input is queued and written without blocking (PTY input capacity is about
///   1 KiB on Darwin); leftovers wait for `EVFILT_WRITE`.
/// - `onWrite` runs on `queue` after every successful `write(2)` (used for the
///   keyDown→PTY-write latency signpost).
/// - `onExit` runs on `queue` once, after the output the child wrote before
///   exiting has been delivered.
/// - `pauseReading()` / `resumeReading()` stop and restart draining (flow
///   control for engines that queue output, like Ghostty); while paused the
///   kernel buffer fills and the child blocks in `write(2)` (and in `exit`).
/// - Releasing the object before the exit was seen hangs up the child and
///   reaps it in the background (`DetachedReaper`); prefer `terminate()`.
///
/// Thread safety: every mutable property is confined to `queue`, which is why
/// the class is `@unchecked Sendable`.
public final class PTYProcess: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (UnsafeRawBufferPointer) -> Void
    public typealias WriteHandler = @Sendable (_ byteCount: Int) -> Void
    /// Receives the raw `waitpid` status.
    public typealias ExitHandler = @Sendable (_ status: Int32) -> Void

    static let readChunk = 64 * 1024

    public let pid: pid_t
    private let masterFD: Int32
    private let queue: DispatchQueue
    private let onOutput: OutputHandler
    private let onWrite: WriteHandler?
    private let onExit: ExitHandler

    private let readBuffer: UnsafeMutableRawPointer
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var writeSourceArmed = false
    private var processSource: (any DispatchSourceProcess)?
    private var pendingWrites: [Data] = []
    private var pendingOffset = 0
    private var exitStatus: Int32?
    private var readClosed = false
    /// The read source is suspended by `pauseReading()`.
    private var readPaused = false

    /// Spawns `spec` on a new PTY. The child is a session leader whose
    /// controlling terminal is the PTY slave; every fd >= 3 is closed before exec.
    public init(
        spec: PTYLaunchSpec,
        label: String = "pty",
        onOutput: @escaping OutputHandler,
        onWrite: WriteHandler? = nil,
        onExit: @escaping ExitHandler
    ) throws {
        guard spec.executable.hasPrefix("/") else {
            throw PTYError.invalidSpec("executable must be an absolute path")
        }
        guard !spec.arguments.isEmpty else {
            throw PTYError.invalidSpec("argv must contain argv[0]")
        }
        let (pid, master) = try ChildSpawner.forkExec(spec)
        self.pid = pid
        masterFD = master
        queue = DispatchQueue(label: "app.fancycodd.TermSpike.\(label).\(pid)", qos: .userInteractive)
        self.onOutput = onOutput
        self.onWrite = onWrite
        self.onExit = onExit
        readBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readChunk, alignment: 16)
        queue.sync { installSources() }
    }

    deinit {
        // Event handlers capture `self` weakly, so none holds a strong reference
        // while deinit runs, and nothing else can touch the queue-confined state.
        // The sources' cancel handlers own closing the fd and freeing the
        // buffer (`DescriptorCloser`), here or in closeReading().
        processSource?.cancel()
        if exitStatus == nil {
            // Released without terminate() or before the exit was seen: the
            // process source is gone, so nobody would ever waitpid() it.
            DetachedReaper.hangUpAndReap(pid)
        }
        guard !readClosed else { return }
        if let writeSource {
            if !writeSourceArmed { writeSource.resume() } // inactive or suspended
            writeSource.cancel()
        }
        // A suspended source never runs its cancel handler, which would leak the fd.
        if readPaused { readSource?.resume() }
        readSource?.cancel()
    }

    // MARK: - Public API

    /// Queues `data` for the child. Never blocks the caller.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            pendingWrites.append(data)
            flushWrites()
        }
    }

    /// Applies a new window size with `TIOCSWINSZ` (the kernel sends SIGWINCH
    /// to the foreground process group only when the size actually changes).
    public func resize(_ size: PTYWindowSize) {
        queue.async { [weak self] in
            guard let self, !readClosed else { return }
            var ws = winsize(
                ws_row: size.rows,
                ws_col: size.columns,
                ws_xpixel: size.pixelWidth,
                ws_ypixel: size.pixelHeight
            )
            _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        }
    }

    /// Stops draining the PTY until `resumeReading()`. Idempotent; output
    /// already handed to `onOutput` is unaffected. While paused the child
    /// blocks once the kernel buffer (a few KiB) is full, and also in
    /// `exit`: macOS drains a tty's output before the last close of the
    /// slave completes, so `onExit` waits until reading resumes (always
    /// after the output, as without a pause). Resume before hanging up a
    /// child, or its exit is never seen.
    public func pauseReading() {
        queue.async { [weak self] in
            guard let self, !readClosed, !readPaused else { return }
            readPaused = true
            readSource?.suspend()
        }
    }

    /// Restarts draining after `pauseReading()`. Idempotent.
    public func resumeReading() {
        queue.async { [weak self] in
            guard let self, readPaused else { return }
            readPaused = false
            if !readClosed { readSource?.resume() }
        }
    }

    /// Sends SIGHUP to the child's process group, then SIGKILL after `grace`
    /// seconds if it has not been reaped.
    public func terminate(grace: TimeInterval = 2) {
        queue.async { [weak self] in
            guard let self, exitStatus == nil else { return }
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            queue.asyncAfter(deadline: .now() + grace) { [weak self] in
                guard let self, exitStatus == nil else { return }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                reapChild(retries: 200)
            }
        }
    }

    // MARK: - Sources

    private func installSources() {
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)

        // Dispatch requires the fd to stay open until every source on it has
        // run its cancel handler, so the last of the two handlers closes it.
        let closer = DescriptorCloser(fd: masterFD, buffer: readBuffer, sources: 2)

        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in _ = self?.drainReadable() }
        read.setCancelHandler { closer.sourceCancelled() }
        readSource = read
        read.resume()

        let write = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        write.setEventHandler { [weak self] in self?.flushWrites() }
        write.setCancelHandler { closer.sourceCancelled() }
        writeSource = write // inactive until armed

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.reapChild(retries: 200) }
        processSource = process
        process.resume()
        // The child may already be gone before the kqueue filter was attached.
        queue.async { [weak self] in self?.reapChild(retries: 0) }
    }

    /// Reads what is available (up to one chunk) and hands it to `onOutput`.
    /// Returns the number of bytes delivered.
    private func drainReadable() -> Int {
        guard !readClosed else { return 0 }
        var total = 0
        var reachedEnd = false
        while total < Self.readChunk {
            let count = Darwin.read(masterFD, readBuffer + total, Self.readChunk - total)
            if count > 0 {
                total += count
                continue
            }
            if count == 0 {
                reachedEnd = true
                break
            }
            let code = errno
            if code == EINTR { continue }
            if code != EAGAIN { reachedEnd = true } // EIO once the slave side is closed
            break
        }
        if total > 0 {
            let id = Signposts.io.makeSignpostID()
            let state = Signposts.io.beginInterval(Signposts.readToFeed, id: id, "\(total) bytes")
            onOutput(UnsafeRawBufferPointer(start: readBuffer, count: total))
            Signposts.io.endInterval(Signposts.readToFeed, state)
        }
        if reachedEnd {
            closeReading()
        }
        return total
    }

    private func closeReading() {
        guard !readClosed else { return }
        readClosed = true
        pendingWrites.removeAll()
        pendingOffset = 0
        if let writeSource {
            if !writeSourceArmed { writeSource.resume() }
            writeSourceArmed = true
            writeSource.cancel()
        }
        if readPaused {
            // A suspended source never runs its cancel handler (fd leak).
            readPaused = false
            readSource?.resume()
        }
        readSource?.cancel() // the last cancel handler closes the fd
    }

    private func flushWrites() {
        guard !readClosed else { return }
        while let head = pendingWrites.first {
            let remaining = head.count - pendingOffset
            let written = head.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(masterFD, base + pendingOffset, remaining)
            }
            if written > 0 {
                onWrite?(written)
                if written == remaining {
                    pendingWrites.removeFirst()
                    pendingOffset = 0
                } else {
                    pendingOffset += written
                }
                continue
            }
            let code = errno
            if written < 0, code == EINTR { continue }
            if written < 0, code == EAGAIN {
                armWriteSource()
                return
            }
            // EIO / EBADF: the child side is gone; drop what is queued.
            pendingWrites.removeAll()
            pendingOffset = 0
            break
        }
        disarmWriteSource()
    }

    private func armWriteSource() {
        guard let writeSource, !writeSourceArmed else { return }
        writeSourceArmed = true
        writeSource.resume()
    }

    private func disarmWriteSource() {
        guard let writeSource, writeSourceArmed, !readClosed else { return }
        writeSourceArmed = false
        writeSource.suspend()
    }

    /// `NOTE_EXIT` can be delivered a moment before the child is reapable, and
    /// it fires only once, so after an exit event a `waitpid` that finds
    /// nothing yet is retried every 5 ms (`retries` times) instead of losing
    /// the exit.
    private func reapChild(retries: Int) {
        guard exitStatus == nil else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else {
            if result == 0, retries > 0 {
                queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                    self?.reapChild(retries: retries - 1)
                }
            }
            return
        }
        exitStatus = status
        processSource?.cancel()
        // The exit event and the last readable event race on this queue.
        // Deliver what the child wrote before exiting first, so consumers see
        // EXIT after the final OUTPUT (the holder protocol's order). Bounded:
        // a grandchild still holding the slave may keep writing.
        var rounds = 0
        while !readClosed, rounds < 16, drainReadable() == Self.readChunk {
            rounds += 1
        }
        onExit(status)
    }
}

/// Closes the PTY master and frees the read buffer after the last of
/// `sources` dispatch sources on that descriptor has been cancelled.
private final class DescriptorCloser: @unchecked Sendable {
    // Immutable after init; the buffer is touched only once, by the last caller.
    private let fd: Int32
    private let buffer: UnsafeMutableRawPointer
    private let remaining: Atomic<Int>

    init(fd: Int32, buffer: UnsafeMutableRawPointer, sources: Int) {
        self.fd = fd
        self.buffer = buffer
        remaining = Atomic(sources)
    }

    func sourceCancelled() {
        guard remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        close(fd)
        buffer.deallocate()
    }
}

/// Last-resort cleanup for a child whose `PTYProcess` was released before
/// its exit was seen: SIGHUP now, SIGKILL after `grace`, and a reap so no
/// zombie is left.
///
/// The reaper waits with `WNOWAIT` first, so the pid stays a zombie (and
/// cannot be reused) until the reaped flag is set under the lock the
/// SIGKILL timer also takes: the timer never signals a recycled pid.
enum DetachedReaper {
    private final class Flag: Sendable {
        let reaped = Mutex(false)
    }

    static func hangUpAndReap(_ pid: pid_t, grace: TimeInterval = 2) {
        let flag = Flag()
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
            flag.reaped.withLock { done in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                done = true
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            flag.reaped.withLock { done in
                guard !done else { return }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }
}

/// Exit status helpers for raw `waitpid` values (the C macros are not imported).
public enum WaitStatus {
    public static func describe(_ status: Int32) -> String {
        let signal = status & 0x7F
        if signal == 0 {
            return "exit \((status >> 8) & 0xFF)"
        }
        return "signal \(signal)"
    }

    public static func exitCode(_ status: Int32) -> UInt32 {
        let signal = status & 0x7F
        return signal == 0 ? UInt32((status >> 8) & 0xFF) : UInt32(128 + signal)
    }
}
