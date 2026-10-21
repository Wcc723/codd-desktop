import Foundation

/// Locations under the CODD data root (docs/ARCHITECTURE.md, "Session directory"):
/// `sessions/<session-uuid>/` (meta.json + ring, written by the holder), `run/<hex>.sock`,
/// `layout.json` (sidebar tree), `panes.json` (tabs), `config.json` + `hooks/` (CoddHooks),
/// `bin/` (installed holder copies), `cache/` (DERIVED data only, see ``cacheURL``).
struct CoddDataRoot: Sendable, Equatable {
    let path: String

    /// `sun_path` holds 104 bytes including the terminating NUL.
    static let maxSocketPathBytes = 103

    init(path: String) {
        // Normalized (`$TMPDIR` ends in `/`, so `$TMPDIR/x` has `//`) so meta.json paths and
        // prefix checks never differ by a slash.
        var normalized = path
        while normalized.contains("//") { normalized = normalized.replacingOccurrences(of: "//", with: "/") }
        if normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        self.path = normalized
    }

    /// `~/Library/Application Support/CODD`.
    static var standard: CoddDataRoot {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        return CoddDataRoot(path: support.appendingPathComponent("CODD", isDirectory: true).path)
    }

    var sessionsPath: String { path + "/sessions" }
    var runPath: String { path + "/run" }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// Groups, projects and sessions (CoddCore `LayoutStore`).
    var layoutURL: URL { url.appendingPathComponent("layout.json", isDirectory: false) }
    /// DERIVED data only (user decision 2026-10-18): files CODD rebuilds when they are missing
    /// (the notes index, burned-in annotated images). 0700 and excluded from Time Machine; an
    /// update may delete the whole folder. User data never goes here.
    var cacheURL: URL { url.appendingPathComponent("cache", isDirectory: true) }

    func sessionDirectory(_ sessionID: String) -> String { sessionsPath + "/" + sessionID }

    /// `run/<hex>.sock`: the first 8 hex digits of the session id, lengthened only if another
    /// socket file already uses that name. Nil when the path would not fit in `sun_path`.
    func socketPath(for sessionID: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let hex = sessionID.lowercased().filter(\.isHexDigit)
        guard hex.count >= 8 else { return nil }
        for length in stride(from: 8, through: hex.count, by: 4) {
            let candidate = runPath + "/" + hex.prefix(length) + ".sock"
            guard candidate.utf8.count <= Self.maxSocketPathBytes else { return nil }
            if !exists(candidate) { return candidate }
        }
        return nil
    }

    /// Creates the root, `sessions/` and `run/` (mode 0700) and excludes `sessions/` from Time
    /// Machine. Blocking file I/O: call it off the main actor.
    func prepare() throws {
        let manager = FileManager.default
        for dir in [path, sessionsPath, runPath] {
            try manager.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        var sessions = URL(fileURLWithPath: sessionsPath, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? sessions.setResourceValues(values)
    }
}
