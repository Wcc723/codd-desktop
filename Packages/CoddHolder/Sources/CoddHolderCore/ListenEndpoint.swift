import CoddPosix
import Darwin

/// The holder's listening socket: mode 0600 in a 0700 directory, FD_CLOEXEC, non-blocking.
///
/// Remembers the socket file's identity so the holder can tell when the path disappeared (cleanup
/// tools, a deleted run directory) and re-bind.
final class ListenEndpoint {
    let path: String
    let directory: String
    private(set) var fd: Int32 = -1
    private var identity: FileIdentity?

    /// Socket buffer sizes for accepted connections (the AF_UNIX defaults are 8 KiB).
    static let sendBufferBytes: Int32 = 1 << 20
    static let receiveBufferBytes: Int32 = 256 << 10

    /// Binds `path` (claiming it; fails if a live holder owns it) without accepting yet.
    init(path: String) throws(SystemError) {
        self.path = path
        self.directory = PosixFile.directoryName(path)
        try bind(listening: false)
    }

    deinit {
        Descriptor.closeQuietly(fd)
    }

    /// Starts accepting connections on the bound socket.
    func startListening() throws(SystemError) {
        try UnixSocket.listen(fd, backlog: 16)
    }

    /// (Re)creates the directory and binds. A path that still accepts connections belongs to a live
    /// holder and is never stolen; a dead socket file is replaced.
    func bind(listening: Bool = true) throws(SystemError) {
        try PosixFile.ensurePrivateDirectory(directory)
        if PosixFile.exists(path) {
            if UnixSocket.isLive(path: path) {
                throw SystemError("socket \(path) is in use by another holder", code: EADDRINUSE)
            }
            unlink(path)
        }
        let socket = try UnixSocket.bind(path: path)
        do {
            try Descriptor.setNonBlocking(socket)
            if listening { try UnixSocket.listen(socket, backlog: 16) }
        } catch {
            Descriptor.closeQuietly(socket)
            unlink(path)
            throw error
        }
        Descriptor.closeQuietly(fd)
        fd = socket
        identity = PosixFile.identity(path)
    }

    /// True when the socket path no longer exists.
    var isPathMissing: Bool { !PosixFile.exists(path) }

    /// Accepts one pending connection, configured for the holder (non-blocking, CLOEXEC, NOSIGPIPE,
    /// larger buffers). Returns nil when nothing is pending. On EMFILE / ENFILE XNU drops the pending
    /// connection (verified: the listener does not stay readable), so returning nil cannot spin the loop.
    func accept() -> Int32? {
        while true {
            let connection = Darwin.accept(fd, nil, nil)
            if connection >= 0 {
                do {
                    try Descriptor.setCloseOnExec(connection)
                    try Descriptor.setNonBlocking(connection)
                    try UnixSocket.setOption(connection, SO_NOSIGPIPE, 1)
                } catch {
                    Descriptor.closeQuietly(connection)
                    continue
                }
                UnixSocket.setBufferSizes(connection, send: Self.sendBufferBytes, receive: Self.receiveBufferBytes)
                return connection
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// Opens the directory for EVFILT_VNODE (O_EVTONLY does not block unmounts).
    func openDirectoryForEvents() -> Int32? {
        let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
        return descriptor >= 0 ? descriptor : nil
    }

    /// Closes the listener and removes the socket file if it is still ours.
    func shutdown() {
        if let identity, PosixFile.identity(path) == identity {
            unlink(path)
        }
        Descriptor.closeQuietly(fd)
        fd = -1
    }
}
