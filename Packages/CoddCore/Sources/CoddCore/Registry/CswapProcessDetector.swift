import Darwin
import Foundation

/// cswap's own background tools that may switch accounts behind CODD's back (D13).
public struct CswapBackgroundTools: Sendable, Equatable {
    /// `cswap menubar` (its own auto-switch lives there).
    public var menubar: Bool
    /// `cswap auto` (polls the usage API and switches).
    public var auto: Bool

    public init(menubar: Bool = false, auto: Bool = false) {
        self.menubar = menubar
        self.auto = auto
    }

    public var any: Bool { menubar || auto }
}

/// Finds running `cswap menubar` / `cswap auto` processes of the current user, so Settings and
/// STATUS can warn `! cswap menubar 也在執行，兩邊可能同時切換` (D13).
///
/// Argument vectors can hold secrets (tokens passed on command lines), so ``scan()`` looks at
/// them only long enough to classify and never logs, returns or keeps one.
public enum CswapProcessDetector {
    /// Upper bounds of one scan: processes listed, argument areas read, bytes per area.
    static let maxProcesses = 8192
    static let maxInspected = 512
    static let maxArgumentBytes = 1 << 20

    /// Pure: each element is one process's argv. A process counts when one of its tokens names
    /// cswap (`cswap`, `claude-swap` as a basename, the `claude_swap` package or a path inside it)
    /// and the first non-option token after it is `menubar` or `auto`. Arguments are also split
    /// at whitespace, so `sh -c "cswap menubar"` counts too.
    public static func classify(arguments: [[String]]) -> CswapBackgroundTools {
        var out = CswapBackgroundTools()
        for argv in arguments {
            let tokens = argv.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            guard let i = tokens.firstIndex(where: namesCswap) else { continue }
            guard let sub = tokens[(i + 1)...].first(where: { !$0.hasPrefix("-") }) else { continue }
            switch sub {
            case "menubar": out.menubar = true
            case "auto": out.auto = true
            default: break
            }
        }
        return out
    }

    static func namesCswap(_ token: String) -> Bool {
        let base = token.split(separator: "/").last.map(String.init) ?? token
        if base == "cswap" || base == "claude-swap" || base == "claude_swap" { return true }
        return token.contains("/claude_swap/") || token.contains("/claude-swap/bin/cswap")
    }

    /// `sysctl KERN_PROC_ALL`, then `KERN_PROCARGS2` for this user's processes whose short name
    /// looks like an interpreter or cswap itself. Blocking (a few ms); never throws: anything
    /// unreadable is skipped.
    public static func scan() -> CswapBackgroundTools {
        let uid = getuid()
        var found = CswapBackgroundTools()
        var buffer = [UInt8](repeating: 0, count: argumentBufferSize())
        var inspected = 0
        for proc in allProcesses() where proc.kp_eproc.e_ucred.cr_uid == uid {
            guard inspected < maxInspected else { break }
            let pid = proc.kp_proc.p_pid
            guard pid > 0, pid != getpid(), isCandidate(shortName(proc)) else { continue }
            inspected += 1
            guard let argv = arguments(pid: pid, buffer: &buffer) else { continue }
            let c = classify(arguments: [argv])
            found.menubar = found.menubar || c.menubar
            found.auto = found.auto || c.auto
            if found.menubar, found.auto { break }
        }
        return found
    }

    /// `p_comm` (16 bytes): python, cswap or a shell that may have exec'd it.
    static func isCandidate(_ comm: String) -> Bool {
        let c = comm.lowercased()
        return c.contains("python") || c.contains("cswap") || c.contains("claude-swap") || c.contains("claude_swap")
    }

    private static func shortName(_ proc: kinfo_proc) -> String {
        var comm = proc.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // Room for processes started between the two calls.
            let count = min(maxProcesses, size / stride + 64)
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            var bytes = count * stride
            let rc = procs.withUnsafeMutableBytes { raw in sysctl(&mib, u_int(mib.count), raw.baseAddress, &bytes, nil, 0) }
            if rc == 0 { return Array(procs.prefix(bytes / stride)) }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    private static func argumentBufferSize() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &argmax, &size, nil, 0) == 0, argmax > 0 else { return 256 << 10 }
        return min(maxArgumentBytes, Int(argmax))
    }

    /// The argv of `pid` from `KERN_PROCARGS2` (`argc`, exec path, padding, argv…, env…); the
    /// environment part is never decoded.
    private static func arguments(pid: pid_t, buffer: inout [UInt8]) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let rc = buffer.withUnsafeMutableBytes { raw in sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0) }
        guard rc == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 } // exec path
        while i < size, buffer[i] == 0 { i += 1 } // padding
        var out: [String] = []
        while out.count < Int(argc), i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            out.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return out.isEmpty ? nil : out
    }
}
