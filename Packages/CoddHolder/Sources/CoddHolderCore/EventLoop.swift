import CoddPosix
import Darwin

/// Thin kqueue wrapper for the holder's single-threaded loop.
///
/// Every registration carries a `tag` in `udata`. Connections get unique, never-reused tags, so an
/// event that is still in the current batch for a descriptor that was closed (and whose number was
/// reused by a new accept) is recognized as stale and dropped.
final class EventLoop {
    let queue: Int32

    static let filterRead = Int16(EVFILT_READ)
    static let filterWrite = Int16(EVFILT_WRITE)
    static let filterTimer = Int16(EVFILT_TIMER)
    static let filterProcess = Int16(EVFILT_PROC)
    static let filterSignal = Int16(EVFILT_SIGNAL)
    static let filterVnode = Int16(EVFILT_VNODE)

    init() throws(SystemError) {
        queue = kqueue()
        guard queue >= 0 else { throw .current("kqueue") }
        try Descriptor.setCloseOnExec(queue)
    }

    deinit {
        Descriptor.closeQuietly(queue)
    }

    // MARK: - Registration

    private func apply(ident: UInt, filter: Int16, flags: Int32, fflags: UInt32 = 0, data: Int = 0, tag: UInt) throws(SystemError) {
        var change = kevent(
            ident: ident, filter: filter, flags: UInt16(truncatingIfNeeded: flags), fflags: fflags, data: data,
            udata: UnsafeMutableRawPointer(bitPattern: tag))
        if kevent(queue, &change, 1, nil, 0, nil) < 0 {
            throw .current("kevent(filter \(filter), ident \(ident))")
        }
    }

    func addRead(_ fd: Int32, tag: UInt, enabled: Bool = true) throws(SystemError) {
        try apply(ident: UInt(fd), filter: Self.filterRead, flags: EV_ADD | (enabled ? EV_ENABLE : EV_DISABLE), tag: tag)
    }

    func setReadEnabled(_ fd: Int32, tag: UInt, _ enabled: Bool) {
        try? apply(ident: UInt(fd), filter: Self.filterRead, flags: enabled ? EV_ENABLE : EV_DISABLE, tag: tag)
    }

    func addWrite(_ fd: Int32, tag: UInt, enabled: Bool) throws(SystemError) {
        try apply(ident: UInt(fd), filter: Self.filterWrite, flags: EV_ADD | (enabled ? EV_ENABLE : EV_DISABLE), tag: tag)
    }

    func setWriteEnabled(_ fd: Int32, tag: UInt, _ enabled: Bool) {
        try? apply(ident: UInt(fd), filter: Self.filterWrite, flags: enabled ? EV_ENABLE : EV_DISABLE, tag: tag)
    }

    /// Removes read and write registrations of `fd` (closing the fd also removes them).
    func removeDescriptor(_ fd: Int32) {
        try? apply(ident: UInt(fd), filter: Self.filterRead, flags: EV_DELETE, tag: 0)
        try? apply(ident: UInt(fd), filter: Self.filterWrite, flags: EV_DELETE, tag: 0)
    }

    /// Arms (or re-arms) timer `id` to fire after `nanoseconds`. Critical timers ask the kernel for
    /// minimal coalescing (submit and repaint deadlines are user-visible).
    func setTimer(_ id: UInt, nanoseconds: UInt64, repeating: Bool = false, critical: Bool = false) {
        var fflags = UInt32(NOTE_NSECONDS)
        if critical { fflags |= UInt32(NOTE_CRITICAL) }
        let flags = EV_ADD | EV_ENABLE | (repeating ? 0 : EV_ONESHOT)
        let delay = Int(clamping: max(nanoseconds, 1))
        try? apply(ident: id, filter: Self.filterTimer, flags: flags, fflags: fflags, data: delay, tag: id)
    }

    func cancelTimer(_ id: UInt) {
        try? apply(ident: id, filter: Self.filterTimer, flags: EV_DELETE, tag: id)
    }

    /// Process exit notification. Throws ESRCH if the process is already gone.
    func watchProcessExit(_ pid: pid_t, tag: UInt) throws(SystemError) {
        try apply(ident: UInt(pid), filter: Self.filterProcess, flags: EV_ADD | EV_ONESHOT, fflags: NOTE_EXIT, tag: tag)
    }

    /// Delivers `signal` as an event; the caller must also ignore it (SIG_IGN) so it does not kill us.
    func watchSignal(_ signal: Int32, tag: UInt) throws(SystemError) {
        try apply(ident: UInt(signal), filter: Self.filterSignal, flags: EV_ADD, tag: tag)
    }

    func watchVnode(_ fd: Int32, tag: UInt) throws(SystemError) {
        let fflags = UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)
        try apply(ident: UInt(fd), filter: Self.filterVnode, flags: EV_ADD | EV_CLEAR, fflags: fflags, tag: tag)
    }

    // MARK: - Waiting

    /// Blocks until at least one event is ready (or the timeout passes) and returns the count.
    func wait(into events: inout [kevent], timeoutNanoseconds: UInt64? = nil) -> Int {
        let capacity = Int32(events.count)
        let count: Int32 = events.withUnsafeMutableBufferPointer { buffer in
            if let timeoutNanoseconds {
                var timeout = timespec(
                    tv_sec: Int(timeoutNanoseconds / 1_000_000_000), tv_nsec: Int(timeoutNanoseconds % 1_000_000_000))
                return kevent(queue, nil, 0, buffer.baseAddress, capacity, &timeout)
            }
            return kevent(queue, nil, 0, buffer.baseAddress, capacity, nil)
        }
        return count < 0 ? 0 : Int(count)
    }
}

extension kevent {
    /// The registration tag stored in `udata`.
    var tag: UInt { UInt(bitPattern: udata) }
}
