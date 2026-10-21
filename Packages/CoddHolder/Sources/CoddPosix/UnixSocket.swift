import Darwin

/// AF_UNIX stream socket helpers. All sockets are FD_CLOEXEC and SO_NOSIGPIPE.
public enum UnixSocket {
    /// Kernel limit for `sun_path` including the terminating NUL.
    public static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    public static func address(path: String) throws(SystemError) -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < maxPathLength else { throw SystemError("socket path", code: ENAMETOOLONG) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// New stream socket with FD_CLOEXEC and SO_NOSIGPIPE.
    public static func makeStreamSocket() throws(SystemError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .current("socket") }
        do {
            try Descriptor.setCloseOnExec(fd)
            try setOption(fd, SO_NOSIGPIPE, 1)
        } catch {
            Descriptor.closeQuietly(fd)
            throw error
        }
        return fd
    }

    public static func setOption(_ fd: Int32, _ option: Int32, _ value: Int32) throws(SystemError) {
        var value = value
        if setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            throw .current("setsockopt(\(option))")
        }
    }

    /// Sets SO_SNDBUF / SO_RCVBUF, ignoring failures (the defaults of 8 KiB are only slower).
    public static func setBufferSizes(_ fd: Int32, send: Int32?, receive: Int32?) {
        if let send { try? setOption(fd, SO_SNDBUF, send) }
        if let receive { try? setOption(fd, SO_RCVBUF, receive) }
    }

    /// Blocking connect. The returned descriptor is blocking, FD_CLOEXEC, SO_NOSIGPIPE.
    public static func connect(path: String) throws(SystemError) -> Int32 {
        var address = try address(path: path)
        let fd = try makeStreamSocket()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = SystemError.current("connect(\(path))")
            Descriptor.closeQuietly(fd)
            throw error
        }
        return fd
    }

    /// bind + listen on `path` with mode 0600.
    public static func listen(path: String, backlog: Int32 = 16) throws(SystemError) -> Int32 {
        let fd = try bind(path: path)
        do {
            try listen(fd, backlog: backlog)
        } catch {
            Descriptor.closeQuietly(fd)
            unlink(path)
            throw error
        }
        return fd
    }

    /// Binds a new stream socket to `path` with mode 0600 (umask 077 while binding, then chmod) without
    /// listening yet: connects are refused until `listen(_:backlog:)`, which lets the holder claim
    /// the path early but accept clients only once its meta.json exists.
    ///
    /// The umask is process-wide: only call this from a single-threaded process (the holder). A
    /// multi-threaded caller would briefly change the mode of files other threads create.
    public static func bind(path: String) throws(SystemError) -> Int32 {
        var address = try address(path: path)
        let fd = try makeStreamSocket()
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno
        umask(previousMask)
        guard bound == 0 else {
            Descriptor.closeQuietly(fd)
            throw SystemError("bind(\(path))", code: bindErrno)
        }
        guard chmod(path, 0o600) == 0 else {
            let error = SystemError.current("chmod(\(path))")
            Descriptor.closeQuietly(fd)
            unlink(path)
            throw error
        }
        return fd
    }

    public static func listen(_ fd: Int32, backlog: Int32 = 16) throws(SystemError) {
        guard Darwin.listen(fd, backlog) == 0 else { throw .current("listen") }
    }

    /// True if something accepts connections on `path` right now.
    public static func isLive(path: String) -> Bool {
        guard let fd = try? connect(path: path) else { return false }
        Descriptor.closeQuietly(fd)
        return true
    }

    /// Effective uid of the peer of a connected AF_UNIX socket.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Pid of the peer process (LOCAL_PEERPID).
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
    }
}
