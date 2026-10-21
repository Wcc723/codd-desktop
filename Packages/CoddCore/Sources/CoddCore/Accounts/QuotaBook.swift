import Foundation

/// Where a quota number came from (D1).
public enum QuotaSource: String, Sendable, Codable {
    /// A `codd-statusline` report (Claude Code's own `rate_limits`).
    case statusline
    /// cswap's cache file `cache/usage.json` (or, on explicit request only, `cswap list --json`).
    case cswap
}

/// Which login a quota entry belongs to. JSON key `"3"` / `"default"` (quota.json, §3).
public enum QuotaAccountRef: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A cswap account number.
    case number(Int)
    /// The global login when there are no cswap accounts at all (the D4 pseudo account).
    case defaultLogin

    public var key: String {
        switch self {
        case .number(let n): return String(n)
        case .defaultLogin: return "default"
        }
    }

    public init?(key: String) {
        if key == "default" {
            self = .defaultLogin
        } else if let n = CswapStateReader.slotNumber(key) {
            self = .number(n)
        } else {
            return nil
        }
    }

    public var description: String { key }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard let ref = QuotaAccountRef(key: try c.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "account key")
        }
        self = ref
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

/// One window with its provenance (D7).
public struct SourcedWindow: Sendable, Equatable, Codable {
    public var window: QuotaWindow
    public var source: QuotaSource
    /// When the number was measured (status-line receipt, cswap `fetchedAt`).
    public var capturedAt: Date

    public init(window: QuotaWindow, source: QuotaSource, capturedAt: Date) {
        self.window = window
        self.source = source
        self.capturedAt = capturedAt
    }

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let w = SourcedWindow(json: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "window"))
        }
        self = w
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    /// `{"usedPercent":9,"resetsAt":"…","source":"statusline","capturedAt":"…"}`.
    init?(json v: JSONValue) {
        guard let used = QuotaJSON.finite(v["usedPercent"]), let source = v["source"]?.stringValue.flatMap(QuotaSource.init),
              let captured = QuotaJSON.date(v["capturedAt"]) else { return nil }
        self.init(window: QuotaWindow(usedPercent: used, resetsAt: QuotaJSON.date(v["resetsAt"])), source: source, capturedAt: captured)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "usedPercent": .number(window.usedPercent), "source": .string(source.rawValue), "capturedAt": QuotaJSON.json(capturedAt),
        ]
        if let r = window.resetsAt { o["resetsAt"] = QuotaJSON.json(r) }
        return .object(o)
    }
}

/// Everything known about one login's quota.
public struct QuotaEntry: Sendable, Equatable, Codable {
    public var fiveHour: SourcedWindow?
    public var weekly: SourcedWindow?
    /// Per-model weekly windows (`Fable`); cswap only (the status line has none).
    public var scoped: [NamedQuotaWindow]
    public var scopedCapturedAt: Date?
    /// cswap's pace of ``weekly`` when that window is cswap's (D7); otherwise computed on demand
    /// (``QuotaBook/pace(for:now:)``).
    public var pace: WeeklyPaceInfo?
    /// The login these numbers belong to (``CswapStateAccount/identity``): a slot number alone is
    /// not an account, since `cswap swap` / `move` / `remove` hand it to another login.
    public var identity: String?

    public init(fiveHour: SourcedWindow? = nil, weekly: SourcedWindow? = nil, scoped: [NamedQuotaWindow] = [],
                scopedCapturedAt: Date? = nil, pace: WeeklyPaceInfo? = nil, identity: String? = nil) {
        self.identity = identity
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.scoped = scoped
        self.scopedCapturedAt = scopedCapturedAt
        self.pace = pace
    }

    /// The source and capture time of the newest window: the account's label and age
    /// (`statusline · 12s 前`, `cswap cache · 3m 前`, D7). On a tie the status line wins.
    public var newest: (source: QuotaSource, at: Date)? {
        var candidates: [(source: QuotaSource, at: Date)] = [fiveHour, weekly].compactMap { $0.map { ($0.source, $0.capturedAt) } }
        if let scopedCapturedAt, !scoped.isEmpty { candidates.append((.cswap, scopedCapturedAt)) }
        return candidates.max { a, b in
            a.at != b.at ? a.at < b.at : (a.source == .cswap && b.source == .statusline)
        }
    }

    public var isEmpty: Bool { fiveHour == nil && weekly == nil && scoped.isEmpty }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    /// Tolerant: a broken window or scoped row is skipped.
    init(json v: JSONValue) {
        self.init(
            fiveHour: v["fiveHour"].flatMap(SourcedWindow.init(json:)),
            weekly: v["weekly"].flatMap(SourcedWindow.init(json:)),
            scoped: (v["scoped"]?.arrayValue ?? []).compactMap { row in
                guard let name = JSText.nonBlankTrimmed(row["name"]), let used = QuotaJSON.finite(row["usedPercent"]) else { return nil }
                return NamedQuotaWindow(name: name, window: QuotaWindow(usedPercent: used, resetsAt: QuotaJSON.date(row["resetsAt"])))
            },
            scopedCapturedAt: QuotaJSON.date(v["scopedCapturedAt"]),
            pace: v["pace"].flatMap(WeeklyPaceInfo.init(json:)),
            identity: JSText.nonBlankTrimmed(v["identity"]))
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let fiveHour { o["fiveHour"] = fiveHour.json }
        if let weekly { o["weekly"] = weekly.json }
        if !scoped.isEmpty {
            o["scoped"] = .array(scoped.map { s in
                var row: [String: JSONValue] = ["name": .string(s.name), "usedPercent": .number(s.window.usedPercent)]
                if let r = s.window.resetsAt { row["resetsAt"] = QuotaJSON.json(r) }
                return .object(row)
            })
        }
        if let scopedCapturedAt { o["scopedCapturedAt"] = QuotaJSON.json(scopedCapturedAt) }
        if let pace { o["pace"] = pace.json }
        if let identity { o["identity"] = .string(identity) }
        return .object(o)
    }
}

/// One measurement to merge into the book.
public struct QuotaObservation: Sendable, Equatable {
    public var account: QuotaAccountRef
    public var fiveHour: QuotaWindow?
    public var weekly: QuotaWindow?
    public var scoped: [NamedQuotaWindow]
    /// cswap's pace fields of the weekly window, when present.
    public var pace: WeeklyPaceInfo?
    public var source: QuotaSource
    public var capturedAt: Date
    /// The login of ``account`` when it was measured (nil: unknown).
    public var identity: String?

    public init(account: QuotaAccountRef, fiveHour: QuotaWindow?, weekly: QuotaWindow?, scoped: [NamedQuotaWindow] = [],
                pace: WeeklyPaceInfo? = nil, source: QuotaSource, capturedAt: Date, identity: String? = nil) {
        self.identity = identity
        self.account = account
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.scoped = scoped
        self.pace = pace
        self.source = source
        self.capturedAt = capturedAt
    }

    /// An account's cswap cache row: `lastGood` (pct = used %), `resets_at`, `fetchedAt` as the
    /// capture time; `nil` without a measurement.
    public static func fromCswap(_ a: CswapStateAccount) -> QuotaObservation? {
        guard let usage = a.usage, let fetchedAt = a.usageFetchedAt else { return nil }
        return QuotaObservation(
            account: .number(a.number), fiveHour: usage.fiveHour.map(QuotaWindow.init), weekly: usage.sevenDay.map(QuotaWindow.init),
            scoped: usage.scoped.map { NamedQuotaWindow(name: $0.name, window: QuotaWindow($0.window)) },
            pace: usage.sevenDay.flatMap(WeeklyPaceInfo.init(cswap:)), source: .cswap, capturedAt: fetchedAt,
            identity: a.identity)
    }

    /// A status-line report already attributed to `account` (``QuotaAttribution``), whose slot
    /// holds the login `identity` now.
    public static func fromStatusLine(account: QuotaAccountRef, fiveHour: QuotaWindow?, weekly: QuotaWindow?,
                                      capturedAt: Date, identity: String? = nil) -> QuotaObservation {
        QuotaObservation(account: account, fiveHour: fiveHour, weekly: weekly, source: .statusline, capturedAt: capturedAt,
                         identity: identity)
    }
}

/// The quota cache behind every account surface (D7), persisted as `quota.json` by ``QuotaStore``.
///
/// Merge rules, per window: a window is replaced only by a strictly newer capture, whatever its
/// source; a window missing from an observation never erases a known one (Claude drops a window
/// after its reset, and `QuotaWindow.status(at:)` already shows a passed reset as 100 %); scoped
/// windows come from cswap only. An observation of another login than the entry's starts the
/// entry over, and ``reconcile(slots:)`` keeps entries on the slot that holds their login.
public struct QuotaBook: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public private(set) var entries: [QuotaAccountRef: QuotaEntry]
    /// The last automatic switch (quota.json `autoSwitch.lastAt`, D37), so a relaunch keeps the
    /// cooldown.
    public var lastAutoSwitchAt: Date?

    public init(entries: [QuotaAccountRef: QuotaEntry] = [:], lastAutoSwitchAt: Date? = nil) {
        self.entries = entries
        self.lastAutoSwitchAt = lastAutoSwitchAt
    }

    public func entry(_ ref: QuotaAccountRef) -> QuotaEntry? { entries[ref] }

    /// Merges `o` (D7). Returns whether anything changed.
    @discardableResult
    public mutating func ingest(_ o: QuotaObservation) -> Bool {
        let before = entries[o.account] ?? QuotaEntry()
        var e = before
        if let identity = o.identity {
            // The slot holds another login now: its old numbers are not this login's.
            if let known = e.identity, known != identity { e = QuotaEntry() }
            e.identity = identity
        }
        if let w = o.fiveHour, e.fiveHour.map({ o.capturedAt > $0.capturedAt }) ?? true {
            e.fiveHour = SourcedWindow(window: w, source: o.source, capturedAt: o.capturedAt)
        }
        if let w = o.weekly, e.weekly.map({ o.capturedAt > $0.capturedAt }) ?? true {
            e.weekly = SourcedWindow(window: w, source: o.source, capturedAt: o.capturedAt)
            // cswap's pace belongs to cswap's window; a status-line window gets a computed one.
            e.pace = o.source == .cswap ? o.pace : nil
        }
        if o.source == .cswap, !o.scoped.isEmpty, e.scopedCapturedAt.map({ o.capturedAt > $0 }) ?? true {
            e.scoped = o.scoped
            e.scopedCapturedAt = o.capturedAt
        }
        guard e != before else { return false }
        entries[o.account] = e
        return true
    }

    /// Forgets an account (removed from cswap). Returns whether it was known.
    @discardableResult
    public mutating func remove(_ ref: QuotaAccountRef) -> Bool {
        entries.removeValue(forKey: ref) != nil
    }

    /// Lines the book up with cswap's current slots (`slots`: number → the login it holds, nil
    /// when unknown). An entry follows its login to the slot that holds it now (`cswap swap` /
    /// `move`), is dropped once no slot holds it (`cswap remove`, a slot reused by another login)
    /// and, without an identity (a cache written before identities), is dropped where the slot's
    /// login is known: it cannot be told apart from another login's numbers, and cswap's cache
    /// and the next report refill it. Where a slot's login is unknown (the D1 list) entries stay.
    /// The D4 entry stays only while cswap has no account at all. Returns whether anything changed.
    @discardableResult
    public mutating func reconcile(slots: [Int: String?]) -> Bool {
        var slotOf: [String: Int] = [:]
        for (number, identity) in slots {
            if let identity { slotOf[identity] = number }
        }
        var next: [QuotaAccountRef: QuotaEntry] = [:]
        var stayed = Set<Int>()
        func place(_ entry: QuotaEntry, at number: Int, preferred: Bool) {
            let ref = QuotaAccountRef.number(number)
            if let other = next[ref] {
                // Two entries for one login (cannot happen with cswap's one-slot-per-login rule):
                // the one already on the slot wins, else the newer one.
                if stayed.contains(number) && !preferred { return }
                if !preferred, (other.newest?.at ?? .distantPast) >= (entry.newest?.at ?? .distantPast) { return }
            }
            if preferred { stayed.insert(number) }
            next[ref] = entry
        }
        for (ref, entry) in entries {
            guard case .number(let number) = ref else {
                if slots.isEmpty { next[ref] = entry }
                continue
            }
            let slotIdentity: String?? = slots[number]
            if let identity = entry.identity {
                if let target = slotOf[identity] {
                    place(entry, at: target, preferred: target == number)
                } else if case .some(.none) = slotIdentity {
                    place(entry, at: number, preferred: true)
                }
            } else if case .some(.none) = slotIdentity {
                place(entry, at: number, preferred: true)
            }
        }
        guard next != entries else { return false }
        entries = next
        return true
    }

    /// Whether the entry for `number` may be read as the login `identity` holds there now: the
    /// identities agree, or either is unknown on a slot whose login is unknown.
    public func entry(_ number: Int, matching identity: String?) -> QuotaEntry? {
        guard let entry = entries[.number(number)] else { return nil }
        switch (entry.identity, identity) {
        case let (known?, current?): return known == current ? entry : nil
        case (nil, _?): return nil
        default: return entry
        }
    }

    /// The weekly pace: cswap's when the weekly window is cswap's and it sent one, else
    /// ``WeeklyPaceCalculator`` on the window and its capture time. `nil` once the weekly reset has
    /// passed at `now` (the window rolled over).
    public func pace(for ref: QuotaAccountRef, now: Date) -> WeeklyPaceInfo? {
        guard let weekly = entries[ref]?.weekly, let resetsAt = weekly.window.resetsAt, now <= resetsAt else { return nil }
        if weekly.source == .cswap, let pace = entries[ref]?.pace { return pace }
        return WeeklyPaceCalculator.compute(usedPercent: weekly.window.usedPercent, resetsAt: resetsAt, measuredAt: weekly.capturedAt)
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    /// Tolerant: unknown keys are ignored, a bad entry is skipped.
    public init(json v: JSONValue) {
        var entries: [QuotaAccountRef: QuotaEntry] = [:]
        for (key, value) in v["accounts"]?.objectValue ?? [:] {
            guard let ref = QuotaAccountRef(key: key), value.objectValue != nil else { continue }
            let entry = QuotaEntry(json: value)
            if !entry.isEmpty { entries[ref] = entry }
        }
        self.init(entries: entries, lastAutoSwitchAt: QuotaJSON.date(v["autoSwitch"]?["lastAt"]))
    }

    /// `{"v":1,"accounts":{"3":{…},"default":{…}},"autoSwitch":{"lastAt":"…"}}` (§3).
    public var json: JSONValue {
        var accounts: [String: JSONValue] = [:]
        for (ref, entry) in entries { accounts[ref.key] = entry.json }
        var o: [String: JSONValue] = ["v": .number(Double(Self.currentVersion)), "accounts": .object(accounts)]
        if let lastAutoSwitchAt { o["autoSwitch"] = .object(["lastAt": QuotaJSON.json(lastAutoSwitchAt)]) }
        return .object(o)
    }
}

/// quota.json value helpers: dates as JS ISO strings (millisecond precision), read back from ISO
/// or epoch numbers.
enum QuotaJSON {
    static func date(_ v: JSONValue?) -> Date? {
        JSDate.timestamp(v).map(JSDate.date(milliseconds:))
    }

    static func json(_ d: Date) -> JSONValue {
        .string(JSDate.isoString(d))
    }

    static func finite(_ v: JSONValue?) -> Double? {
        guard let n = v?.numberValue, n.isFinite else { return nil }
        return n
    }
}
