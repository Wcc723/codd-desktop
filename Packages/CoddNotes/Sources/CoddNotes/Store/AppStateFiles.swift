import Foundation

/// Shared rules of the `.codd/` JSON files (plan §3.4): 0600, atomic, tolerant (a corrupt file is
/// moved aside to `<name>.corrupt-<ms>` and started over), a newer `v` is read-only.
enum StateFileIO {
    enum Loaded {
        case missing
        case object([String: Any])
        /// A newer format: use what can be read, never write it.
        case newer([String: Any])
        case corrupt
    }

    static func load(_ url: URL, version: Int, clock: Date, log: (String) -> Void) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(clock.timeIntervalSince1970 * 1000))")
            try? FileManager.default.moveItem(at: url, to: aside)
            log("notes state file corrupt name=\(url.lastPathComponent) moved=\(aside.lastPathComponent)")
            return .corrupt
        }
        if let v = obj["v"] as? Int, v > version { return .newer(obj) }
        return .object(obj)
    }
}

/// `.codd/state.json`: per-note app state that is not derivable from the files (D4).
struct NoteAppState: Sendable, Equatable {
    var lastOpenedAt: Date?
    var openCount: Int = 0
    var lastUserActivityAt: Date?
    var keepUntil: Date?
}

struct StateStore {
    let url: URL
    let timeZone: TimeZone
    private(set) var notes: [NoteID: NoteAppState] = [:]
    private(set) var readOnly = false
    private(set) var dirty = false

    init(url: URL, timeZone: TimeZone) {
        self.url = url
        self.timeZone = timeZone
    }

    mutating func load(clock: Date, log: (String) -> Void) {
        notes = [:]
        let obj: [String: Any]
        switch StateFileIO.load(url, version: 1, clock: clock, log: log) {
        case .missing, .corrupt: return
        case .object(let o): obj = o
        case .newer(let o):
            obj = o
            readOnly = true
        }
        guard let map = obj["notes"] as? [String: Any] else { return }
        for (key, value) in map {
            guard let id = NoteID(rawValue: key), let d = value as? [String: Any] else { continue }
            func date(_ k: String) -> Date? { (d[k] as? String).flatMap { ISODate.parse($0, timeZone: timeZone) } }
            notes[id] = NoteAppState(lastOpenedAt: date("lastOpenedAt"), openCount: (d["openCount"] as? Int) ?? 0,
                                     lastUserActivityAt: date("lastUserActivityAt"), keepUntil: date("keepUntil"))
        }
    }

    subscript(id: NoteID) -> NoteAppState {
        get { notes[id] ?? NoteAppState() }
        set {
            notes[id] = newValue
            dirty = true
        }
    }

    mutating func remove(_ id: NoteID) {
        if notes.removeValue(forKey: id) != nil { dirty = true }
    }

    /// The §3.4 text, keys in a stable order.
    func serialized() -> String {
        var out = "{\"v\":1,\"notes\":{"
        for (k, id) in notes.keys.sorted().enumerated() {
            let s = notes[id]!
            if k > 0 { out += "," }
            func d(_ date: Date?) -> String { date.map { JSONText.quoted(ISODate.format($0, timeZone: timeZone)) } ?? "null" }
            out += JSONText.quoted(id.rawValue)
            out += ":{\"lastOpenedAt\":\(d(s.lastOpenedAt)),\"openCount\":\(s.openCount),\"lastUserActivityAt\":\(d(s.lastUserActivityAt)),\"keepUntil\":\(d(s.keepUntil))}"
        }
        return out + "}}\n"
    }

    mutating func flush(writer: AtomicWriter) throws {
        guard dirty, !readOnly else { return }
        try writer.write(Data(serialized().utf8), to: url, mode: 0o600)
        dirty = false
    }
}

/// `.codd/activity.jsonl`: AI activity per note (D20), append-only, compacted at open.
struct ActivityLog {
    let url: URL
    let timeZone: TimeZone
    private(set) var byNote: [NoteID: [NoteActivityEvent]] = [:]

    static let keepLines = 5000
    static let keepDays = 90.0

    init(url: URL, timeZone: TimeZone) {
        self.url = url
        self.timeZone = timeZone
    }

    /// Reads the log, keeps the newest 5,000 lines of the last 90 days and rewrites it when it dropped any.
    mutating func load(now: Date, writer: AtomicWriter, log: (String) -> Void) {
        byNote = [:]
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        var events: [NoteActivityEvent] = []
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            if let e = decode(String(line)) { events.append(e) }
        }
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86_400)
        var kept = events.filter { $0.at >= cutoff }
        kept.sort { $0.at < $1.at }
        if kept.count > Self.keepLines { kept.removeFirst(kept.count - Self.keepLines) }
        for e in kept { byNote[e.note, default: []].append(e) }
        if kept.count != lines {
            let body = kept.map(encode).joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
            do {
                try writer.write(Data(body.utf8), to: url, mode: 0o600)
                log("notes activity compacted kept=\(kept.count) dropped=\(lines - kept.count)")
            } catch {
                log("notes activity compaction failed: \(error)")
            }
        }
    }

    mutating func append(_ e: NoteActivityEvent) {
        byNote[e.note, default: []].append(e)
        let line = Data((encode(e) + "\n").utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }

    mutating func remove(_ id: NoteID) {
        byNote.removeValue(forKey: id)
    }

    func events(of id: NoteID, limit: Int) -> [NoteActivityEvent] {
        Array((byNote[id] ?? []).reversed().prefix(max(0, limit)))
    }

    /// The newest AI read-like event (read / expand / url) of a note.
    func lastRead(of id: NoteID) -> NoteActivityEvent? {
        byNote[id]?.last { ["read", "expand", "url"].contains($0.action) }
    }

    func sessions(thatRead id: NoteID) -> Set<String> {
        Set((byNote[id] ?? []).compactMap { ["read", "expand", "url"].contains($0.action) ? $0.session : nil })
    }

    func encode(_ e: NoteActivityEvent) -> String {
        func s(_ v: String?) -> String { v.map(JSONText.quoted) ?? "null" }
        return "{\"v\":1,\"at\":\(JSONText.quoted(ISODate.format(e.at, timeZone: timeZone))),\"note\":\(JSONText.quoted(e.note.rawValue)),\"action\":\(JSONText.quoted(e.action)),\"client\":\(s(e.client)),\"session\":\(s(e.session)),\"sessionTitle\":\(s(e.sessionTitle)),\"via\":\(JSONText.quoted(e.via))}"
    }

    func decode(_ line: String) -> NoteActivityEvent? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let atText = d["at"] as? String, let at = ISODate.parse(atText, timeZone: timeZone),
              let noteText = d["note"] as? String, let note = NoteID(rawValue: noteText), let action = d["action"] as? String
        else { return nil }
        return NoteActivityEvent(at: at, note: note, action: action, client: d["client"] as? String,
                                 session: (d["session"] as? String)?.lowercased(), sessionTitle: d["sessionTitle"] as? String,
                                 via: (d["via"] as? String) ?? "mcp")
    }
}

/// `.codd/tombstones.json`: purged notes, so `codd://` refs answer 已刪除 (D29).
struct TombstoneStore {
    let url: URL
    let timeZone: TimeZone
    private(set) var items: [Tombstone] = []
    private(set) var readOnly = false

    init(url: URL, timeZone: TimeZone) {
        self.url = url
        self.timeZone = timeZone
    }

    mutating func load(clock: Date, log: (String) -> Void) {
        items = []
        let obj: [String: Any]
        switch StateFileIO.load(url, version: 1, clock: clock, log: log) {
        case .missing, .corrupt: return
        case .object(let o): obj = o
        case .newer(let o):
            obj = o
            readOnly = true
        }
        for d in (obj["items"] as? [[String: Any]]) ?? [] {
            guard let idText = d["id"] as? String, let id = NoteID(rawValue: idText),
                  let t = (d["trashedAt"] as? String).flatMap({ ISODate.parse($0, timeZone: timeZone) }),
                  let p = (d["purgedAt"] as? String).flatMap({ ISODate.parse($0, timeZone: timeZone) }) else { continue }
            items.append(Tombstone(id: id, title: (d["title"] as? String) ?? "", trashedAt: t, purgedAt: p))
        }
    }

    func tombstone(_ id: NoteID) -> Tombstone? { items.last { $0.id == id } }

    func contains(_ id: NoteID) -> Bool { items.contains { $0.id == id } }

    mutating func add(_ t: Tombstone) {
        items.removeAll { $0.id == t.id }
        items.append(t)
    }

    /// Drops tombstones older than `days` after their purge; nil keeps them forever.
    mutating func expire(days: Int?, now: Date) -> Bool {
        guard let days else { return false }
        let before = items.count
        items.removeAll { $0.purgedAt.addingTimeInterval(Double(days) * 86_400) <= now }
        return items.count != before
    }

    func serialized() -> String {
        var out = "{\"v\":1,\"items\":["
        for (k, t) in items.enumerated() {
            if k > 0 { out += "," }
            out += "{\"id\":\(JSONText.quoted(t.id.rawValue)),\"title\":\(JSONText.quoted(t.title)),\"trashedAt\":\(JSONText.quoted(ISODate.format(t.trashedAt, timeZone: timeZone))),\"purgedAt\":\(JSONText.quoted(ISODate.format(t.purgedAt, timeZone: timeZone)))}"
        }
        return out + "]}\n"
    }

    func flush(writer: AtomicWriter) throws {
        guard !readOnly else { return }
        try writer.write(Data(serialized().utf8), to: url, mode: 0o600)
    }
}
