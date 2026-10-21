import CoddPosix
import Darwin

/// Diagnostic log: `--log <path>` (append) or stderr (which is /dev/null when spawned by the app).
final class HolderLog {
    private let fd: Int32
    private let ownsDescriptor: Bool

    init(path: String?) {
        if let path {
            let opened = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            fd = opened >= 0 ? opened : 2
            ownsDescriptor = opened >= 0
        } else {
            fd = 2
            ownsDescriptor = false
        }
    }

    deinit {
        if ownsDescriptor { Descriptor.closeQuietly(fd) }
    }

    func info(_ message: String) {
        let line = "\(Clock.wallMilliseconds()) codd-holder[\(getpid())] \(message)\n"
        try? Descriptor.writeAll(fd, line)
    }
}
