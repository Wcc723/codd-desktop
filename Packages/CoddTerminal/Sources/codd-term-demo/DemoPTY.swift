import Darwin
import Dispatch
import Foundation
import Synchronization

/// A child process on its own pseudo-terminal: the demo's stand-in for `codd-holder` (no socket,
/// no ring). Output is drained on a private serial queue in chunks of up to 64 KiB; input is queued
/// and written without blocking; the exit is reported once, after the last output.
final class DemoPTY: @unchecked Sendable {
    // Mutable state below is confined to `queue`.
    let pid: pid_t
    private let master: Int32
    private let queue: DispatchQueue
    private let onOutput: @Sendable (UnsafeRawBufferPointer) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var writeArmed = false
    private var processSource: (any DispatchSourceProcess)?
    private var pending: [UInt8] = []
    private var closed = false
    private var paused = false
    private var exited = false

    init(
        argv: [String], environment: [String: String], directory: String, size: winsize,
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let (pid, master) = try Self.spawn(argv: argv, environment: environment, directory: directory, size: size)
        self.pid = pid
        self.master = master
        self.onOutput = onOutput
        self.onExit = onExit
        queue = DispatchQueue(label: "codd-term-demo.pty.\(pid)", qos: .userInteractive)
        queue.sync { installSources() }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            pending += bytes
            flush()
        }
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        queue.async { [self] in
            guard !closed else { return }
            var size = winsize(
                ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
                ws_xpixel: UInt16(clamping: pixelWidth), ws_ypixel: UInt16(clamping: pixelHeight)
            )
            _ = ioctl(master, TIOCSWINSZ, &size)
        }
    }

    /// Flow control: stop draining while the terminal has too much unparsed output queued.
    func setReadingPaused(_ pause: Bool) {
        queue.async { [self] in
            guard !closed, pause != paused else { return }
            paused = pause
            if pause { readSource?.suspend() } else { readSource?.resume() }
        }
    }

    /// SIGHUP to the process group, SIGKILL after a grace period.
    func terminate() {
        queue.async { [self] in
            guard !exited else { return }
            if paused {
                paused = false
                readSource?.resume()
            }
            kill(-pid, SIGHUP)
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                guard !exited else { return }
                kill(-pid, SIGKILL)
            }
        }
    }

    private func installSources() {
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let closer = Closer(fd: master, buffer: buffer, sources: 2)
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self] in _ = self?.drain() }
        read.setCancelHandler { closer.done() }
        read.resume()
        readSource = read

        let write = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
        write.setEventHandler { [weak self] in self?.flush() }
        write.setCancelHandler { closer.done() }
        writeSource = write

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.reap(retries: 200) }
        process.resume()
        processSource = process
        queue.async { [weak self] in self?.reap(retries: 0) }
    }

    private func drain() -> Int {
        guard !closed else { return 0 }
        var total = 0
        var ended = false
        while total < 64 * 1024 {
            let count = Darwin.read(master, buffer + total, 64 * 1024 - total)
            if count > 0 {
                total += count
                continue
            }
            let code = errno
            if count < 0, code == EINTR { continue }
            // 0 = EOF; EIO once the slave side is closed. EAGAIN = drained for now.
            if count == 0 || code != EAGAIN { ended = true }
            break
        }
        if total > 0 { onOutput(UnsafeRawBufferPointer(start: buffer, count: total)) }
        if ended { closeDescriptor() }
        return total
    }

    private func flush() {
        guard !closed else { return }
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                if !writeArmed {
                    writeArmed = true
                    writeSource?.resume()
                }
                return
            }
            pending = []
        }
        if writeArmed {
            writeArmed = false
            writeSource?.suspend()
        }
    }

    private func closeDescriptor() {
        guard !closed else { return }
        closed = true
        pending = []
        if !writeArmed { writeSource?.resume() }
        writeSource?.cancel()
        if paused { readSource?.resume() }
        readSource?.cancel()
    }

    /// NOTE_EXIT can arrive a moment before the child is reapable; retry every 5 ms.
    private func reap(retries: Int) {
        guard !exited else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else {
            if result == 0, retries > 0 {
                queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                    self?.reap(retries: retries - 1)
                }
            }
            return
        }
        exited = true
        processSource?.cancel()
        var rounds = 0
        while !closed, rounds < 16, drain() == 64 * 1024 { rounds += 1 }
        onExit(status)
    }

    /// `forkpty` + `execve`, with every allocation done before the fork (the child may only make
    /// async-signal-safe calls).
    private static func spawn(argv: [String], environment: [String: String], directory: String, size: winsize)
        throws -> (pid_t, Int32)
    {
        let cArgv = CStrings(argv)
        let cEnv = CStrings(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            cArgv.free()
            cEnv.free()
        }
        guard let path = strdup(argv[0]), let cwd = strdup(directory) else { throw POSIXError(.ENOMEM) }
        defer {
            free(path)
            free(cwd)
        }
        var size = size
        var attributes = termios()
        var probeMaster: Int32 = -1
        var probeSlave: Int32 = -1
        if openpty(&probeMaster, &probeSlave, nil, nil, nil) == 0 {
            _ = tcgetattr(probeSlave, &attributes)
            close(probeMaster)
            close(probeSlave)
        }
        attributes.c_iflag |= tcflag_t(IUTF8)
        var limit = rlimit()
        let maxFD: Int32 = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int32(clamping: min(limit.rlim_cur, 16384)) : 4096
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)

        var master: Int32 = -1
        let pid = forkpty(&master, nil, &attributes, &size)
        if pid < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            var signal: Int32 = 1
            while signal < NSIG {
                if signal != SIGKILL, signal != SIGSTOP { _ = sigaction(signal, &defaultAction, nil) }
                signal += 1
            }
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            _ = chdir(cwd)
            var fd: Int32 = 3
            while fd < maxFD {
                _ = close(fd)
                fd += 1
            }
            _ = execve(path, cArgv.pointer, cEnv.pointer)
            _exit(127)
        }
        return (pid, master)
    }
}

/// A NULL-terminated `char *[]` that owns its strings.
private struct CStrings {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[strings.count] = nil
    }

    func free() {
        for index in 0 ..< count { Darwin.free(pointer[index]) }
        pointer.deallocate()
    }
}

/// Closes the descriptor and frees the read buffer after the last of `sources` dispatch sources on
/// it was cancelled (dispatch needs the descriptor open until every source on it is gone).
/// `@unchecked`: the buffer pointer is touched once, by the last caller.
private final class Closer: @unchecked Sendable {
    private let fd: Int32
    private let buffer: UnsafeMutableRawPointer
    private let remaining: Atomic<Int>

    init(fd: Int32, buffer: UnsafeMutableRawPointer, sources: Int) {
        self.fd = fd
        self.buffer = buffer
        remaining = Atomic(sources)
    }

    func done() {
        guard remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        close(fd)
        buffer.deallocate()
    }
}
