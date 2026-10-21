import Foundation

/// Claude Code's own files that CODD reads, never writes: the live session registry
/// (`sessions/<pid>.json`), the transcript folders (`projects/<sanitized cwd>/`, their modification
/// time is the "last used" of a project) and `.claude.json` (its `projects` keys are the folders
/// Claude has run in). `-codd-claude-dir` points tests at a temp directory instead of `~/.claude`.
struct ClaudeDirectory: Sendable, Equatable {
    /// `~/.claude` by default.
    let path: String

    init(path: String) {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        self.path = normalized
    }

    static var standard: ClaudeDirectory { ClaudeDirectory(path: NSHomeDirectory() + "/.claude") }

    /// `<dir>/sessions` (RegistryWatcher).
    var registryURL: URL { URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("sessions", isDirectory: true) }
    var transcriptsPath: String { path + "/projects" }

    /// `.claude.json` sits next to `~/.claude` (`<dir>/../.claude.json`); with `CLAUDE_CONFIG_DIR`
    /// it lives inside the directory instead. The first existing one is read.
    var configFileCandidates: [String] {
        let parent = (path as NSString).deletingLastPathComponent
        return [parent + "/.claude.json", path + "/.claude.json"]
    }
}

/// A folder Claude has been used in (new-session sheet, home view).
struct RecentProject: Sendable, Equatable, Hashable {
    var path: String
    var lastUsed: Date?

    var name: String { HolderSessionStore.projectName(cwd: path) }
}

/// Reads the `projects` keys of `.claude.json`, newest first by the modification time of their
/// transcript folder. Blocking file I/O: call it off the main actor.
enum RecentProjectsReader {
    /// `.claude.json` holds per-project history and can grow; anything bigger is not read.
    static let maxFileBytes = 64 << 20
    static let maxProjects = 200

    static func read(_ directory: ClaudeDirectory, fileManager: FileManager = .default) -> [RecentProject] {
        guard let file = directory.configFileCandidates.first(where: { fileManager.fileExists(atPath: $0) }),
              let attributes = try? fileManager.attributesOfItem(atPath: file),
              let size = attributes[.size] as? Int, size <= maxFileBytes,
              let data = fileManager.contents(atPath: file) else { return [] }
        return parse(data, transcriptsPath: directory.transcriptsPath, fileManager: fileManager)
    }

    /// The projects in `data` (a `.claude.json`) that still exist as folders.
    static func parse(_ data: Data, transcriptsPath: String, fileManager: FileManager = .default) -> [RecentProject] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any] else { return [] }
        var out: [RecentProject] = []
        for path in projects.keys where isListable(path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let transcripts = transcriptsPath + "/" + transcriptFolderName(for: path)
            let modified = (try? fileManager.attributesOfItem(atPath: transcripts))?[.modificationDate] as? Date
            out.append(RecentProject(path: path, lastUsed: modified))
        }
        return sorted(out).prefix(maxProjects).map { $0 }
    }

    /// Most recently used first; folders without a transcript folder last, by path.
    static func sorted(_ projects: [RecentProject]) -> [RecentProject] {
        projects.sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.path < rhs.path
            }
        }
    }

    /// Absolute and not a worktree Claude created for an agent (SPEC Onboarding: hidden by default).
    static func isListable(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("/.claude-worktrees/")
    }

    /// Claude's transcript folder name for a cwd: every UTF-16 unit outside `[A-Za-z0-9]` becomes
    /// `-` (JavaScript `path.replace(/[^a-zA-Z0-9]/g, '-')`).
    static func transcriptFolderName(for path: String) -> String {
        String(decoding: path.utf16.map { unit -> UInt8 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: UInt8(unit)
            default: 0x2D
            }
        }, as: UTF8.self)
    }
}
