import Foundation

/// `.codd/history/<note-id>/<yyyyMMdd-HHmmss-SSS>-<hash8>.md` snapshots of the whole file (D8).
/// The reason of a forced snapshot rides in an extended attribute, so the file names and the
/// folder stay exactly as §3.1 describes.
struct HistoryStore: Sendable {
    let root: URL
    let writer: AtomicWriter

    static let mergeWindow: TimeInterval = 5 * 60
    static let maxSnapshots = 200
    static let maxBytes = 2 * 1024 * 1024
    static let reasonAttribute = "com.codd.notes.snapshot-reason"

    func folder(_ id: NoteID) -> URL { root.appendingPathComponent(id.rawValue, isDirectory: true) }

    /// Newest first.
    func list(_ id: NoteID) -> [NoteSnapshotInfo] {
        let dir = folder(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [NoteSnapshotInfo] = []
        for name in names where name.hasSuffix(".md") {
            guard let at = ISODate.parseCompactUTC(String(name.prefix(19))) else { continue }
            let url = dir.appendingPathComponent(name)
            let bytes = FileFacts.info(url.path)?.size ?? 0
            out.append(NoteSnapshotInfo(id: name, takenAt: at, bytes: bytes, reason: FileFacts.xattr(Self.reasonAttribute, of: url)))
        }
        return out.sorted { $0.takenAt == $1.takenAt ? $0.id > $1.id : $0.takenAt > $1.takenAt }
    }

    /// Writes a snapshot of `data` unless it is over 2 MiB, identical to the newest snapshot, or
    /// (when not forced) the newest snapshot is younger than the 5-minute merge window.
    @discardableResult
    func take(_ id: NoteID, data: Data, reason: String?, force: Bool, now: Date) throws -> NoteSnapshotInfo? {
        guard data.count <= Self.maxBytes else { return nil }
        let existing = list(id)
        let hash8 = String(Hashing.sha256Hex(data).prefix(8))
        if let newest = existing.first {
            if newest.id.hasSuffix("-\(hash8).md") { return nil }
            if !force, now.timeIntervalSince(newest.takenAt) < Self.mergeWindow { return nil }
        }
        var stamp = now
        // Names sort by time: a snapshot taken in the same millisecond as the newest one (a forced
        // one right after a save, or a manual clock) is stamped 1 ms after it.
        if let newest = existing.first, stamp.timeIntervalSince(newest.takenAt) < 0.001 {
            stamp = newest.takenAt.addingTimeInterval(0.001)
        }
        var name = "\(ISODate.compactUTC(stamp))-\(hash8).md"
        while existing.contains(where: { $0.id == name }) {
            stamp = stamp.addingTimeInterval(0.001)
            name = "\(ISODate.compactUTC(stamp))-\(hash8).md"
        }
        let url = folder(id).appendingPathComponent(name)
        try writer.write(data, to: url, mode: 0o600)
        if let reason { FileFacts.setXattr(Self.reasonAttribute, reason, on: url) }
        if existing.count + 1 > Self.maxSnapshots {
            for old in existing.suffix(existing.count + 1 - Self.maxSnapshots) {
                try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(old.id))
            }
        }
        return NoteSnapshotInfo(id: name, takenAt: stamp, bytes: data.count, reason: reason)
    }

    func data(_ id: NoteID, snapshot: String) throws -> Data {
        guard !snapshot.contains("/"), snapshot.hasSuffix(".md") else { throw NotesError.io("沒有這個版本") }
        do {
            return try Data(contentsOf: folder(id).appendingPathComponent(snapshot))
        } catch {
            throw NotesError.io("沒有這個版本")
        }
    }

    /// D8 thinning: everything for 48 h, then the newest per hour for 14 days, the newest per day
    /// (local calendar) for 90 days, nothing older; at most 200. Returns how many were removed.
    func thin(_ id: NoteID, now: Date, calendar: LocalCalendar) -> Int {
        let all = list(id)
        var keep = Set<String>()
        var hours = Set<Int>()
        var days = Set<Date>()
        for s in all {
            let age = now.timeIntervalSince(s.takenAt)
            if age <= 48 * 3600 {
                keep.insert(s.id)
            } else if age <= 14 * 86_400 {
                let bucket = Int((s.takenAt.timeIntervalSince1970 / 3600).rounded(.down))
                if hours.insert(bucket).inserted { keep.insert(s.id) }
            } else if age <= 90 * 86_400 {
                if days.insert(calendar.startOfDay(s.takenAt)).inserted { keep.insert(s.id) }
            }
        }
        var removed = 0
        var kept = 0
        for s in all {
            if keep.contains(s.id), kept < Self.maxSnapshots {
                kept += 1
                continue
            }
            if (try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(s.id))) != nil { removed += 1 }
        }
        if list(id).isEmpty { try? FileManager.default.removeItem(at: folder(id)) }
        return removed
    }

    func noteIDs() -> [NoteID] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(NoteID.init(rawValue:))
    }
}
