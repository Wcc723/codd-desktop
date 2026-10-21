import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// A fresh directory under $TMPDIR, removed on deinit. Short names keep socket paths < 104 bytes.
final class TemporaryDirectory {
    let path: String

    init() throws {
        var base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        while base.hasSuffix("/") { base.removeLast() }
        var template = Array("\(base)/cht.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw SystemError.current("mkdtemp") }
        path = String(cString: created)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Locates the executables built next to the test bundle (both the classic SwiftPM layout and the
/// Swift Build `out/Products/Debug` layout put them in the bundle's parent directory).
/// Override with CODD_HOLDER_PRODUCTS (e.g. a release build directory).
enum TestBinaries {
    static let productsDirectory: String = {
        if let override = ProcessInfo.processInfo.environment["CODD_HOLDER_PRODUCTS"] { return override }
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return "." }
        var path = String(cString: name)
        // …/Debug/CoddHolderTests.xctest/Contents/MacOS/CoddHolderTests → …/Debug
        for _ in 0..<4 { path = PosixFile.directoryName(path) }
        return path
    }()

    static var holder: String { PosixFile.join(productsDirectory, "codd-holder") }
    static var ctl: String { PosixFile.join(productsDirectory, "codd-holderctl") }
    static var helper: String { PosixFile.join(productsDirectory, "codd-holder-testhelper") }
}

/// Minimal, predictable child environment.
let testEnvironment = [
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "TERM=xterm-256color",
    "LANG=en_US.UTF-8",
    "LC_CTYPE=UTF-8",
    "PS1=$ ",
    "HOME=\(ProcessInfo.processInfo.environment["HOME"] ?? "/tmp")",
]

/// One holder process in its own temporary root.
final class TestSession {
    let root: TemporaryDirectory
    let sessionDirectory: String
    let socketPath: String
    let logPath: String
    let pid: pid_t
    private var reaped = false

    /// - Parameters:
    ///   - extraInheritedDescriptor: passed to the holder as fd 9 WITHOUT close-on-exec (fd hygiene test).
    ///   - softFileLimit: start the holder with this RLIMIT_NOFILE soft limit (launchd's 256).
    ///   - holderExecutable: run this holder binary (e.g. an installed copy) instead of the built one.
    ///   - flowControlLimit: `--flow-limit` (the backpressure threshold is min(limit, ring / 2)).
    init(
        _ argv: [String], cols: UInt16 = 80, rows: UInt16 = 24, ringSize: Int? = nil, lingerMilliseconds: Int? = 2000,
        environment: [String] = testEnvironment, cwd: String = "/tmp", extraInheritedDescriptor: Int32? = nil,
        softFileLimit: Int? = nil, holderExecutable: String = TestBinaries.holder, flowControlLimit: Int? = nil
    ) throws {
        root = try TemporaryDirectory()
        sessionDirectory = root.path + "/sessions/s"
        socketPath = root.path + "/run/s.sock"
        logPath = root.path + "/holder.log"
        let envFile = root.path + "/env"
        var envBytes: [UInt8] = []
        for entry in environment { envBytes += Array(entry.utf8) + [0] }
        try PosixFile.writeAtomically(envFile, envBytes)
        let launch = HolderLaunch(
            holderExecutable: holderExecutable, session: "test-session", sessionDirectory: sessionDirectory,
            socketPath: socketPath, cols: cols, rows: rows, cwd: cwd, ringSize: ringSize, envFile: envFile,
            exitLingerMilliseconds: lingerMilliseconds, logPath: logPath, flowControlLimit: flowControlLimit, argv: argv)
        let stderrPath = root.path + "/holder.stderr"
        if let extraInheritedDescriptor {
            pid = try spawnInheriting(arguments: launch.arguments, descriptor: extraInheritedDescriptor, as: 9)
        } else if let softFileLimit {
            let wrapper = ["/bin/sh", "-c", "ulimit -Sn \(softFileLimit) && exec \"$0\" \"$@\""]
            pid = try HolderSpawner.spawn(executable: "/bin/sh", arguments: wrapper + launch.arguments, stderrPath: stderrPath)
        } else {
            pid = try HolderSpawner.spawn(launch, stderrPath: stderrPath)
        }
        guard HolderSpawner.waitForSocket(socketPath, timeoutMilliseconds: 10_000, pid: pid) else {
            let log = (try? String(contentsOfFile: root.path + "/holder.stderr", encoding: .utf8)) ?? ""
            throw TestFailure("holder did not open its socket: \(log)")
        }
    }

    deinit {
        stop()
    }

    func connect(takeover: Bool = false, client: String = "tests") throws -> (HolderConnection, Welcome) {
        let connection = try HolderConnection(socketPath: socketPath)
        let welcome = try connection.handshake(client: client, takeover: takeover)
        return (connection, welcome)
    }

    /// Connect + ATTACH.
    func attach(from offset: UInt64 = 0, takeover: Bool = false) throws -> (HolderConnection, Welcome) {
        let (connection, welcome) = try connect(takeover: takeover)
        try connection.send(.attach(fromOffset: offset))
        return (connection, welcome)
    }

    var meta: HolderMeta? { SessionDirectory.readMeta(directory: sessionDirectory) }

    var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    var isRunning: Bool { !reaped && !HolderSpawner.hasExited(pid) }

    /// Waits for the holder to exit on its own; returns its wait status or nil on timeout.
    func waitForExit(timeoutMilliseconds: Int) -> Int32? {
        let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        while Clock.monotonicNanoseconds() < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                return status
            }
            Clock.sleep(milliseconds: 5)
        }
        return nil
    }

    /// SIGTERM, then SIGKILL; always reaps.
    func stop() {
        guard !reaped else { return }
        kill(pid, SIGTERM)
        if waitForExit(timeoutMilliseconds: 5000) == nil {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            reaped = true
        }
    }
}

/// posix_spawn like HolderSpawner, but hands `descriptor` to the child as `target` without FD_CLOEXEC.
func spawnInheriting(arguments: [String], descriptor: Int32, as target: Int32) throws -> pid_t {
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, descriptor, target)
    let argv = CStringArray(arguments)
    let envp = CStringArray(ProcessQueries.environment())
    var pid: pid_t = 0
    let status = argv.withUnsafePointer { argvPointer in
        envp.withUnsafePointer { envPointer in
            posix_spawn(&pid, arguments[0], &actions, &attributes,
                        UnsafeMutablePointer(mutating: argvPointer), UnsafeMutablePointer(mutating: envPointer))
        }
    }
    guard status == 0 else { throw SystemError("posix_spawn", code: status) }
    return pid
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Everything a client received, with OUTPUT contiguity checking.
struct StreamCapture {
    /// Keep only the last `byteLimit` bytes (floods); nil keeps everything.
    var byteLimit: Int?
    var totalBytes = 0
    var bytes: [UInt8] = []
    var firstOffset: UInt64?
    var nextOffset: UInt64?
    var titles: [String] = []
    var cwds: [String] = []
    var bells = 0
    var gaps: [(from: UInt64, to: UInt64)] = []
    var exit: ExitInfo?
    var errors: [ErrorInfo] = []
    var pongs: [UInt64] = []
    /// OUTPUT frames whose offset did not continue the previous one without a GAP in between.
    var discontinuities = 0
    var outputFrames = 0

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Cheap check of the last bytes received (for floods, where `text` would be rebuilt per frame).
    func tailContains(_ marker: String, within count: Int = 256) -> Bool {
        String(decoding: bytes.suffix(count), as: UTF8.self).contains(marker)
    }

    init(byteLimit: Int? = nil) {
        self.byteLimit = byteLimit
    }

    mutating func absorb(_ message: Message) {
        switch message {
        case .output(let offset, let chunk):
            if firstOffset == nil { firstOffset = offset }
            if let nextOffset, nextOffset != offset { discontinuities += 1 }
            nextOffset = offset + UInt64(chunk.count)
            bytes += chunk
            totalBytes += chunk.count
            if let byteLimit, bytes.count > byteLimit * 2 { bytes.removeFirst(bytes.count - byteLimit) }
            outputFrames += 1
        case .gap(let from, let to):
            gaps.append((from, to))
            if let nextOffset, nextOffset != from { discontinuities += 1 }
            nextOffset = to
        case .title(let title): titles.append(title)
        case .cwd(let cwd): cwds.append(cwd)
        case .bell: bells += 1
        case .exit(let info): exit = info
        case .error(let info): errors.append(info)
        case .pong(let token): pongs.append(token)
        default: break
        }
    }
}

extension HolderConnection {
    /// Receives until `done(capture)` or the timeout; returns whether the condition was met.
    @discardableResult
    func collect(
        into capture: inout StreamCapture, timeoutMilliseconds: Int = 10_000, until done: (StreamCapture) -> Bool
    ) throws -> Bool {
        let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        if done(capture) { return true }
        while Clock.monotonicNanoseconds() < deadline {
            let remaining = Int((deadline - Clock.monotonicNanoseconds()) / 1_000_000)
            guard let message = try receive(timeoutMilliseconds: max(remaining, 1)) else { continue }
            capture.absorb(message)
            if done(capture) { return true }
        }
        return done(capture)
    }

    /// Sends PING and waits for the matching PONG (everything received meanwhile goes to `capture`).
    func roundTrip(token: UInt64, into capture: inout StreamCapture) throws {
        try send(.ping(token: token))
        let ok = try collect(into: &capture) { $0.pongs.contains(token) }
        if !ok { throw TestFailure("no PONG \(token)") }
    }
}

/// FNV-1a, for comparing large payloads in failure messages without dumping them.
func fnv1a(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0100_0000_01B3
    }
    return hash
}

/// Parent pid of `pid` via sysctl KERN_PROC_PID.
func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Runs a command and returns its stdout (tests only).
func runCommand(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Deterministic PRNG for reproducible test payloads.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
