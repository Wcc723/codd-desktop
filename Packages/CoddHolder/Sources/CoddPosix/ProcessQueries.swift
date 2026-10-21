import CCoddShim
import Darwin

/// How a child process ended.
public struct ProcessTermination: Sendable, Equatable {
    /// Exit code, or the signal number when `signaled`.
    public var status: Int32
    public var signaled: Bool

    public init(status: Int32, signaled: Bool) {
        self.status = status
        self.signaled = signaled
    }

    /// Decodes a waitpid status; `nil` for stop/continue notifications.
    public init?(waitStatus: Int32) {
        var value: Int32 = 0
        var signaled: Int32 = 0
        guard codd_decode_wait_status(waitStatus, &value, &signaled) == 1 else { return nil }
        self.status = value
        self.signaled = signaled != 0
    }
}

/// Process-level queries (sysctl, libproc, dyld) without Foundation.
public enum ProcessQueries {
    /// `kern.bootsessionuuid`, which changes on every boot.
    public static func bootSessionUUID() -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Absolute path of the running executable.
    public static func executablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard codd_executable_path(&buffer, UInt32(buffer.count)) == 0 else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if realpath(buffer, &resolved) != nil {
            return String(decoding: resolved.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Executable path of another process (`proc_pidpath`).
    public static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = codd_process_path(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Pids of all processes on the system (proc_listpids), unordered.
    public static func allProcessIDs() -> [pid_t] {
        var capacity = max(Int(codd_list_pids(nil, 0)), 256) + 64
        while capacity <= 1 << 20 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(codd_list_pids(&buffer, Int32(capacity)))
            guard count >= 0 else { return [] }
            if count < capacity { return buffer.prefix(count).filter { $0 > 0 } }
            capacity *= 2  // the table grew between the size query and the call
        }
        return []
    }

    /// True while `pid` exists (including zombies) and we may signal it.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The current process environment as "KEY=VALUE" strings.
    public static func environment() -> [String] {
        var result: [String] = []
        guard var cursor = codd_environ() else { return result }
        while let entry = cursor.pointee {
            result.append(String(cString: entry))
            cursor += 1
        }
        return result
    }

    /// Highest open descriptor of this process (libproc), or -1.
    public static func highestOpenDescriptor() -> Int32 {
        codd_highest_open_fd()
    }
}

/// NULL-terminated C string vector (argv / envp) owning its strdup'ed storage.
public final class CStringArray {
    public private(set) var pointers: [UnsafeMutablePointer<CChar>?]

    public init(_ strings: [String]) {
        pointers = strings.map { strdup($0) }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers { free(pointer) }
    }

    /// Runs `body` with a `char *const *` view; the storage stays valid for the duration of the call.
    /// The pointer is never nil in practice (the array always holds the terminating nil).
    public func withUnsafePointer<R>(_ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) throws -> R) rethrows -> R {
        try pointers.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }
}
