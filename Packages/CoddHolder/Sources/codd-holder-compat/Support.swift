import Darwin
import Dispatch
import Synchronization

/// Monotonic time and polling. Deliberately its own small copy (not CoddPosix): the target depends
/// only on the client modules it checks.
enum Monotonic {
    static func milliseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000
    }

    /// Polls `condition` every 5 ms until it holds or `deadline` (monotonic milliseconds) passed.
    static func poll(until deadline: UInt64, _ condition: () -> Bool) -> Bool {
        while milliseconds() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    static func poll(timeoutMilliseconds: Int, _ condition: () -> Bool) -> Bool {
        poll(until: milliseconds() + UInt64(max(0, timeoutMilliseconds)), condition)
    }
}

/// A failed check: `detail` goes on the `COMPAT … FAIL` line.
struct CheckFailure: Error {
    var detail: String

    init(_ detail: String) {
        self.detail = detail
    }
}

/// Byte searches and printable excerpts for check details.
enum Bytes {
    static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var index = max(0, start)
        while index <= last {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    static func contains(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Bool {
        firstIndex(of: needle, in: haystack, from: start) != nil
    }

    /// The last `limit` bytes, quoted, with ESC as `\e`, CR / LF as `\r` / `\n` and other bytes
    /// outside printable ASCII as `\xHH`, so a detail stays on one line.
    static func excerpt<C: Collection>(_ bytes: C, limit: Int = 160) -> String where C.Element == UInt8 {
        var text = bytes.count > limit ? "\"..." : "\""
        for byte in bytes.suffix(limit) {
            switch byte {
            case 0x1B: text += "\\e"
            case 0x0D: text += "\\r"
            case 0x0A: text += "\\n"
            case UInt8(ascii: "\""): text += "\\\""
            case UInt8(ascii: "\\"): text += "\\\\"
            case 0x20..<0x7F: text.append(Character(Unicode.Scalar(byte)))
            default:
                let hex = String(byte, radix: 16)
                text += "\\x" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return text + "\""
    }
}

/// stdout / stderr through write(2): unbuffered, so every result line is out before a crash or
/// an abort, and no C `stdout` global (not concurrency-safe in Swift 6).
enum Report {
    static func line(_ text: String) {
        write(fd: 1, text + "\n")
    }

    static func error(_ text: String) {
        write(fd: 2, text)
    }

    /// One line: control characters (from error descriptions) become spaces.
    static func singleLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar)
        }
        return String(scalars)
    }

    private static func write(fd: Int32, _ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                bytes = bytes.dropFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

/// Small file helpers on plain descriptors.
enum Files {
    static func write(_ path: String, _ bytes: [UInt8]) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var rest = bytes[...]
        while !rest.isEmpty {
            let written = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                rest = rest.dropFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// The first `maxBytes` of a file (empty when it cannot be read).
    static func head(_ path: String, maxBytes: Int = 4096) -> [UInt8] {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return count > 0 ? Array(buffer.prefix(count)) : []
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && Int(info.st_mode) & 0o170000 == 0o040000
    }

    static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

/// `waitpid` status as text.
func describeWaitStatus(_ status: Int32) -> String {
    let signal = status & 0x7F
    if signal == 0 { return "exit \((status >> 8) & 0xFF)" }
    return signal == 0x7F ? "stopped" : "signal \(signal)"
}

/// What the signal and watchdog handlers must end when the run is cut short: the holder this run
/// spawned (SETSID, so it would outlive us) and its child's process group.
final class Emergency: Sendable {
    static let shared = Emergency()

    let holderPid = Atomic<Int32>(0)
    let childPid = Atomic<Int32>(0)

    /// SIGINT / SIGTERM / SIGHUP and a watchdog for the whole run end the processes and exit 1.
    /// Keep the returned sources alive for the run.
    func install(label: String, watchdogSeconds: Int) -> [any DispatchSourceProtocol] {
        var sources: [any DispatchSourceProtocol] = []
        for signo in [SIGINT, SIGTERM, SIGHUP] {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
            source.setEventHandler { self.abort(label: label, reason: "interrupted by signal \(signo)") }
            source.resume()
            sources.append(source)
        }
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .seconds(watchdogSeconds))
        watchdog.setEventHandler { self.abort(label: label, reason: "watchdog: the run took longer than \(watchdogSeconds) s") }
        watchdog.resume()
        sources.append(watchdog)
        return sources
    }

    func abort(label: String, reason: String) -> Never {
        let holder = holderPid.load(ordering: .acquiring)
        let child = childPid.load(ordering: .acquiring)
        if holder > 0 { kill(holder, SIGKILL) }
        if child > 0 { kill(-child, SIGKILL) }
        Report.line("COMPAT \(label) abort FAIL \(reason); holder and child killed")
        exit(1)
    }
}
