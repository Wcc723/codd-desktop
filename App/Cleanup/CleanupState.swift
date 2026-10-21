import CoddCore
import Foundation

/// `<dataRoot>/cleanup.json` (§3.4): what the Cleanup page and the retention engine remember
/// across launches: `保留 30 天` of sessions and files, the digest's last showing, and the D30
/// first-run grace (`retention.firstRunAt`, written by the first retention run on a data root).
///
/// `{"v":1,"sessions":{"<uuid>":{"keepUntil":"<ISO>"}},"files":{"<abs path>":{"keepUntil":"<ISO>"}},`
/// `"digest":{"lastShownAt":"<ISO>","lastCount":15},"retention":{"firstRunAt":"<ISO>","lastRunAt":"<ISO>"}}`
/// Dates are UTC seconds with `Z`; reading also takes fractional seconds and offsets.
struct CleanupState: Equatable, Sendable {
    struct Keep: Equatable, Sendable {
        var keepUntil: Date?
    }

    struct Digest: Equatable, Sendable {
        var lastShownAt: Date?
        var lastCount: Int?
    }

    struct Retention: Equatable, Sendable {
        var firstRunAt: Date?
        var lastRunAt: Date?
    }

    static let version = 1

    /// Lowercase session UUID → keep.
    var sessions: [String: Keep] = [:]
    /// Absolute path (an unused note image, a Recent entry) → keep.
    var files: [String: Keep] = [:]
    var digest = Digest()
    var retention = Retention()

    /// `保留 30 天` of a session (or of an archived session's ring) is still running at `now`.
    func sessionKept(_ id: String, now: Date) -> Date? {
        sessions[id.lowercased()]?.keepUntil.flatMap { $0 > now ? $0 : nil }
    }

    func fileKept(_ path: String, now: Date) -> Bool {
        (files[path]?.keepUntil).map { $0 > now } ?? false
    }

    /// Drops keeps that ran out (the file stays small).
    mutating func expire(now: Date) {
        sessions = sessions.filter { ($0.value.keepUntil ?? .distantPast) > now }
        files = files.filter { ($0.value.keepUntil ?? .distantPast) > now }
    }

    // MARK: JSON

    static func decode(_ data: Data) -> (state: CleanupState, version: Int)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let version = (object["v"] as? NSNumber)?.intValue ?? 1
        var state = CleanupState()
        func keeps(_ value: Any?) -> [String: Keep] {
            guard let dict = value as? [String: Any] else { return [:] }
            var out: [String: Keep] = [:]
            for (key, entry) in dict {
                guard let entry = entry as? [String: Any] else { continue }
                out[key] = Keep(keepUntil: date(entry["keepUntil"]))
            }
            return out
        }
        state.sessions = keeps(object["sessions"]).reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        state.files = keeps(object["files"])
        if let digest = object["digest"] as? [String: Any] {
            state.digest = Digest(lastShownAt: date(digest["lastShownAt"]), lastCount: (digest["lastCount"] as? NSNumber)?.intValue)
        }
        if let retention = object["retention"] as? [String: Any] {
            state.retention = Retention(firstRunAt: date(retention["firstRunAt"]), lastRunAt: date(retention["lastRunAt"]))
        }
        return (state, version)
    }

    func encoded() throws -> Data {
        func keeps(_ dict: [String: Keep]) -> [String: Any] {
            dict.reduce(into: [:]) { out, entry in
                out[entry.key] = ["keepUntil": entry.value.keepUntil.map { Self.isoString($0) as Any } ?? NSNull()]
            }
        }
        var digestObject: [String: Any] = [:]
        if let at = digest.lastShownAt { digestObject["lastShownAt"] = Self.isoString(at) }
        if let count = digest.lastCount { digestObject["lastCount"] = count }
        var retentionObject: [String: Any] = [:]
        if let at = retention.firstRunAt { retentionObject["firstRunAt"] = Self.isoString(at) }
        if let at = retention.lastRunAt { retentionObject["lastRunAt"] = Self.isoString(at) }
        let object: [String: Any] = ["v": Self.version, "sessions": keeps(sessions), "files": keeps(files), "digest": digestObject,
                                     "retention": retentionObject]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return RealModeOptions.isoDate(text)
    }

    /// `2026-10-18T01:02:03Z`.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// Reads and writes `cleanup.json` (0600, atomic). A file that does not parse is moved aside to
/// `cleanup.json.corrupt-<ms>` and started over; a file of a newer `v` is used but never written
/// (a newer CODD owns it). Main actor: the file is a few hundred bytes, written after a run or an
/// action.
@MainActor
final class CleanupStateStore {
    let url: URL
    private(set) var state = CleanupState()
    /// A newer CODD wrote the file: keep its values in memory, never overwrite it.
    private(set) var isReadOnly = false
    /// The last write failure (the dump), nil after a good write.
    private(set) var writeProblem: String?
    /// `load()` ran.
    private(set) var isLoaded = false
    private let log: @Sendable (String) -> Void

    static let fileName = "cleanup.json"

    init(dataRoot: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        url = dataRoot.appendingPathComponent(Self.fileName)
        self.log = log
    }

    /// Loads the file (a missing file is an empty state).
    func load() {
        isLoaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = CleanupState.decode(data) else {
            let aside = url.path + ".corrupt-\(Int(Date().timeIntervalSince1970 * 1000))"
            try? FileManager.default.moveItem(atPath: url.path, toPath: aside)
            log("cleanup state corrupt moved=\((aside as NSString).lastPathComponent)")
            state = CleanupState()
            return
        }
        state = decoded.state
        isReadOnly = decoded.version > CleanupState.version
        if isReadOnly { log("cleanup state v=\(decoded.version) is newer: read only") }
    }

    /// Applies `edit` and writes the file (unless read only).
    func update(_ edit: (inout CleanupState) -> Void) {
        var next = state
        edit(&next)
        guard next != state else { return }
        state = next
        save()
    }

    private func save() {
        guard !isReadOnly else { return }
        do {
            try AtomicFile.write(try state.encoded(), to: url, permissions: 0o600)
            writeProblem = nil
        } catch {
            writeProblem = "\(error)"
            log("cleanup state write failed: \(error)")
        }
    }
}
