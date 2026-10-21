import Darwin

/// File-descriptor helpers. Every descriptor CODD creates is FD_CLOEXEC.
public enum Descriptor {
    public static func setCloseOnExec(_ fd: Int32) throws(SystemError) {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { throw .current("fcntl(F_GETFD)") }
        if flags & FD_CLOEXEC == 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0 {
            throw .current("fcntl(F_SETFD)")
        }
    }

    public static func setNonBlocking(_ fd: Int32) throws(SystemError) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw .current("fcntl(F_GETFL)") }
        if flags & O_NONBLOCK == 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            throw .current("fcntl(F_SETFL)")
        }
    }

    public static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    /// close(2) ignoring errors (EINTR on close must not be retried on Darwin).
    public static func closeQuietly(_ fd: Int32) {
        if fd >= 0 { _ = close(fd) }
    }

    /// Writes everything, waiting with poll(2) when the descriptor is non-blocking and full.
    public static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws(SystemError) {
        guard var pointer = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let written = write(fd, pointer, remaining)
            if written > 0 {
                pointer += written
                remaining -= written
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 1000)
            } else {
                throw .current("write")
            }
        }
    }

    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws(SystemError) {
        // withUnsafeBytes is rethrows (untyped), so carry the typed error out as a value.
        let failure = bytes.withUnsafeBytes { buffer -> SystemError? in
            do throws(SystemError) {
                try writeAll(fd, buffer)
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
    }

    public static func writeAll(_ fd: Int32, _ text: String) throws(SystemError) {
        try writeAll(fd, Array(text.utf8))
    }
}
