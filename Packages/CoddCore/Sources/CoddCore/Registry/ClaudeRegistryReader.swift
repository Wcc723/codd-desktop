import Darwin
import Foundation

/// One `<digits>.json` file of a registry directory (``ClaudeRegistryReader/readFiles(directory:)``).
public struct ClaudeRegistryFile: Sendable, Equatable {
    /// The file name, e.g. `48211.json`.
    public var name: String
    /// `nil` when the file is unreadable, not a regular file, too large or not a JSON object.
    public var entry: ClaudeRegistryEntry?

    public init(name: String, entry: ClaudeRegistryEntry?) {
        self.name = name
        self.entry = entry
    }
}

/// Reads a Claude Code session registry directory (`<CLAUDE_CONFIG_DIR>/sessions`).
///
/// Mirrors session-insights.js `_loadRegistry`: only files named `<digits>.json` are read (so the
/// `<pid>.<hash>.key` secrets are never opened), at most ``maxFiles`` of them, and unreadable or
/// non-object files are skipped. Files are visited in ascending pid order for determinism (the
/// original uses `readdir` order).
public struct ClaudeRegistryReader: Sendable {
    public static let maxFiles = 500
    /// Registry files are tiny; anything larger is not a registry file.
    public static let maxFileBytes = 256 * 1024

    public init() {}

    /// The default registry directory for a config dir (`~/.claude` when `nil`).
    public static func directory(configDir: String?, home: String = NSHomeDirectory()) -> URL {
        let base = configDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        return base.appendingPathComponent("sessions", isDirectory: true)
    }

    /// All decodable entries in `directory` (empty when it does not exist). Synchronous file I/O
    /// (about 60 µs per file in release builds): call it off the main actor.
    public func read(directory: URL) -> [ClaudeRegistryEntry] {
        readFiles(directory: directory).compactMap(\.entry)
    }

    /// The same files as ``read(directory:)`` (same filter, order and limit), but each with its
    /// name, and with `entry == nil` for a file that could not be read or decoded. Claude may
    /// rewrite a registry file in place, so a reader can catch it half written; a watcher uses
    /// the name to keep the previous good entry for such a file instead of dropping the session.
    public func readFiles(directory: URL) -> [ClaudeRegistryFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter(Self.isRegistryFileName).sorted(by: Self.numericOrder).prefix(Self.maxFiles)
        return files.map { name in
            let data = Self.readSmallFile(directory.appendingPathComponent(name, isDirectory: false))
            return ClaudeRegistryFile(name: name, entry: data.flatMap(ClaudeRegistryEntry.init(data:)))
        }
    }

    /// `/^\d+\.json$/` (ASCII digits only).
    public static func isRegistryFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.utf8.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// Orders `<digits>.json` names by numeric value without converting (names may exceed `Int`).
    static func numericOrder(_ a: String, _ b: String) -> Bool {
        let x = a.drop(while: { $0 == "0" }), y = b.drop(while: { $0 == "0" })
        return x.count != y.count ? x.count < y.count : x < y
    }

    /// The entries whose process is still running (``ProcessLivenessChecking``: pid exists and its
    /// start time matches `procStart`). Claude removes its file on a clean exit, but a crash leaves
    /// it behind, and its pid may since belong to another process; such entries must not reach
    /// ``ActivityMerger`` (CODD web does not filter them). Entries without a pid are dropped.
    public static func liveEntries(
        _ entries: [ClaudeRegistryEntry], liveness: any ProcessLivenessChecking = DarwinProcessLiveness()
    ) -> [ClaudeRegistryEntry] {
        entries.filter { e in e.pid.map { liveness.isAlive(pid: $0, procStart: e.procStart) } ?? false }
    }

    /// session-insights.js `_registryMatch`: the first entry whose `pid` equals `pid`, or whose
    /// `sessionId` equals `sessionId`. Pass entries of several registry directories concatenated in
    /// priority order (`~/.claude` first, then the session's own config dir).
    public static func match(
        _ entries: [ClaudeRegistryEntry], pid: Int?, sessionId: String?
    ) -> ClaudeRegistryEntry? {
        entries.first { e in
            (pid != nil && e.pid == pid) || (sessionId != nil && e.sessionId == sessionId)
        }
    }

    /// Reads a regular file of at most ``maxFileBytes``. `O_NONBLOCK` keeps a FIFO named
    /// `<digits>.json` from blocking the open (a plain open would hang the reader forever),
    /// `O_CLOEXEC` keeps the fd out of concurrently spawned children, and anything that is not a
    /// regular file is skipped.
    static func readSmallFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxFileBytes else { return nil }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxFileBytes {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: chunk.prefix(n))
            } else if n < 0, errno == EINTR {
                continue
            } else if n == 0 {
                return data
            } else {
                return nil
            }
        }
        return nil // grew past the limit while being read
    }
}
