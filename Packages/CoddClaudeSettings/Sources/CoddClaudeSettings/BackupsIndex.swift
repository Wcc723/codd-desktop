import Darwin
import Foundation
import Synchronization

/// `<dataRoot>/claude-settings-backups.json` (M3 D10): `{"v":1,"backups":[{name, reason, at,
/// settingsPath}]}`, newest last, the newest 200 kept, 0600, written atomically. The App's
/// `ClaudeSettingsService` writes the settings.json entries in the same format; the
/// `~/.claude.json` installer writes its own (`mcp-register` / `mcp-remove`) here.
///
/// M5 D14: an index a newer CODD wrote (`v` > 1) is read as far as its entries decode and never
/// written (the backup file next to `~/.claude.json` is still made, only its index entry is
/// skipped); a missing or non-integer `v` still reads as a foreign file (the launch preflight
/// moves such a file aside before anything appends to it).
enum BackupsIndex {
    static let limit = 200
    static let currentVersion = 1
    /// One writer at a time inside this process (the App's own writer is a separate queue).
    private static let writing = Mutex(())

    /// Appends one entry; returns the reason it could not be written (nil on success).
    static func record(_ index: URL, name: String, reason: String, at date: Date, settingsPath: String) -> String? {
        writing.withLock { _ -> String? in
            let existing = object(index)
            if let version = existing?["v"] as? Int, version > currentVersion {
                return "\(index.lastPathComponent) is v\(version) (a newer CODD): entry not written"
            }
            var entries = entries(in: existing)
            entries.append(["name": name, "reason": reason, "at": isoString(date), "settingsPath": abbreviate(settingsPath)])
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["v": 1, "backups": entries],
                                                      options: [.prettyPrinted, .sortedKeys])
                return write(data, to: index)
            } catch {
                return "encode: \((error as NSError).localizedDescription)"
            }
        }
    }

    /// The entries (newest last); an unreadable or foreign file reads as empty, like the App. A
    /// newer index keeps the entries that are objects.
    static func read(_ index: URL) -> [[String: Any]] {
        entries(in: object(index))
    }

    /// The index's integer `v`, nil when the file is missing, unreadable or foreign.
    static func version(_ index: URL) -> Int? {
        object(index)?["v"] as? Int
    }

    private static func entries(in object: [String: Any]?) -> [[String: Any]] {
        guard let object, let version = object["v"] as? Int, version >= currentVersion else { return [] }
        if version == currentVersion { return object["backups"] as? [[String: Any]] ?? [] }
        return (object["backups"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func object(_ index: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: index), data.count <= 4 << 20 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `new Date().toISOString()`: UTC with milliseconds (`2026-10-17T02:42:10.000Z`), as the
    /// App's entries carry.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// `~/…` for a path inside the home folder.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Temp file (0600, its own name so it never shares the App writer's temp) + rename.
    private static func write(_ data: Data, to url: URL) -> String? {
        let directory = url.deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return "mkdir: \((error as NSError).localizedDescription)"
        }
        let temp = "\(directory)/.\(url.lastPathComponent).codd-mcp-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).tmp"
        guard FileManager.default.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return "create: could not write the temp file"
        }
        guard rename(temp, url.path) == 0 else {
            let code = errno
            unlink(temp)
            return SettingsFS.errnoText("rename", code)
        }
        return nil
    }
}
