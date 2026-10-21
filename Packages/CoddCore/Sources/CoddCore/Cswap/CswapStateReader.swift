import Darwin
import Foundation
import Synchronization

/// How trustworthy an account's cswap cache row is (D2).
public enum CswapUsageHealth: Sendable, Equatable, CustomStringConvertible {
    /// No row for this account (or the row belongs to another identity), no measurement yet.
    case none
    /// Measured at most ``freshness`` ago.
    case fresh
    /// Measured longer ago; nothing failed.
    case stale
    /// cswap's last fetches failed (`consecutiveFailures > 0`); its `lastError`, redacted (D31).
    case failing(String)
    /// cswap quarantined the account (`authDeadStrikes > 0`): only a re-login helps.
    case reloginRequired

    /// cswap polls every 3–10 minutes; older numbers are labelled stale.
    public static let freshness: TimeInterval = 15 * 60

    public var description: String {
        switch self {
        case .none: return "none"
        case .fresh: return "fresh"
        case .stale: return "stale"
        case .failing(let e): return "failing(\(e))"
        case .reloginRequired: return "reloginRequired"
        }
    }
}

/// One cswap-managed account as read from cswap's own state files (D2). There is deliberately no
/// e-mail and no `organizationName` (personal organizations are named after the e-mail, D31).
public struct CswapStateAccount: Sendable, Equatable, Identifiable {
    public var number: Int
    public var alias: String?
    public var isActive: Bool
    public var isDisabled: Bool
    /// D25 plan chip, `nil` when unknown.
    public var plan: String?
    /// cswap's `lastGood` measurement (pct = used %), identity-guarded like cswap's own reads.
    public var usage: CswapUsage?
    public var usageFetchedAt: Date?
    public var usageHealth: CswapUsageHealth
    /// `<root>/sessions/<n>-*` (a real directory, D12). Its name carries the e-mail slug: never
    /// log, dump or show it (D31); the descriptions of this type print `profile: yes|no` only.
    public var sessionProfile: URL?
    /// cswap's stale marker exists (either location): pinning is refused until `cswap run <n>`.
    public var sessionProfileStale: Bool
    /// `<profile>/settings.json` is a symlink to the Claude settings file; `nil` without a profile
    /// or without a settings URL to compare with.
    public var sessionProfileSharesSettings: Bool?
    /// An opaque token of the login this slot holds (``CswapStateReader/quotaIdentity(email:organization:)``,
    /// never the e-mail): `cswap swap` / `move` / `remove` keep slot numbers but change the login
    /// behind them, so the quota cache checks this before it trusts a number. nil when unknown
    /// (the D1 `cswap list` fallback, a slot without an e-mail string).
    public var identity: String?

    public var id: Int { number }

    public init(number: Int, alias: String? = nil, isActive: Bool = false, isDisabled: Bool = false, plan: String? = nil,
                usage: CswapUsage? = nil, usageFetchedAt: Date? = nil, usageHealth: CswapUsageHealth = .none,
                sessionProfile: URL? = nil, sessionProfileStale: Bool = false, sessionProfileSharesSettings: Bool? = nil,
                identity: String? = nil) {
        self.identity = identity
        self.number = number
        self.alias = alias
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.plan = plan
        self.usage = usage
        self.usageFetchedAt = usageFetchedAt
        self.usageHealth = usageHealth
        self.sessionProfile = sessionProfile
        self.sessionProfileStale = sessionProfileStale
        self.sessionProfileSharesSettings = sessionProfileSharesSettings
    }
}

extension CswapStateAccount: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        var parts = ["#\(number)"]
        if let alias { parts.append(EmailRedaction.redact(alias)) }
        if isActive { parts.append("active") }
        if isDisabled { parts.append("disabled") }
        parts.append("plan: \(plan ?? "-")")
        parts.append("usage: \(usage == nil ? "no" : "yes")")
        parts.append("health: \(usageHealth)")
        parts.append("profile: \(sessionProfile == nil ? "no" : "yes")")
        if sessionProfileStale { parts.append("stale") }
        if let shares = sessionProfileSharesSettings { parts.append("sharesSettings: \(shares)") }
        parts.append("identity: \(identity == nil ? "no" : "yes")")
        return "CswapStateAccount(\(parts.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }

    /// `dump` and the test runner's value printing go through this mirror: the profile path is
    /// replaced by `yes` / `no`.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "number": number,
            "alias": alias.map(EmailRedaction.redact) as Any,
            "isActive": isActive,
            "isDisabled": isDisabled,
            "plan": plan as Any,
            "usage": usage as Any,
            "usageFetchedAt": usageFetchedAt as Any,
            "usageHealth": usageHealth,
            "profile": sessionProfile == nil ? "no" : "yes",
            "sessionProfileStale": sessionProfileStale,
            "sessionProfileSharesSettings": sessionProfileSharesSettings as Any,
            "identity": identity == nil ? "no" : "yes",
        ], displayStyle: .struct)
    }
}

/// One read of cswap's state root.
public struct CswapStateSnapshot: Sendable, Equatable {
    /// Where the active account came from.
    public enum ActiveSource: Sendable, Equatable {
        /// The global login's `.claude.json` identity matched a managed account (cswap's own rule).
        case claudeJSON
        /// No usable `.claude.json` identity: cswap's last written `activeAccountNumber`.
        case sequenceFile
        /// Unknown, or the current login is not managed by cswap.
        case none
    }

    public var root: URL
    /// In `sequence.json` order (accounts missing from `sequence` follow, by number).
    public var accounts: [CswapStateAccount]
    public var activeAccountNumber: Int?
    public var activeSource: ActiveSource
    public var readAt: Date
    /// 繁體中文 lines for STATUS / Settings; never an e-mail or a path.
    public var warnings: [String]

    public init(root: URL, accounts: [CswapStateAccount], activeAccountNumber: Int?, activeSource: ActiveSource,
                readAt: Date, warnings: [String] = []) {
        self.root = root
        self.accounts = accounts
        self.activeAccountNumber = activeAccountNumber
        self.activeSource = activeSource
        self.readAt = readAt
        self.warnings = warnings
    }

    public var activeAccount: CswapStateAccount? { accounts.first(where: \.isActive) }

    public func account(_ number: Int) -> CswapStateAccount? { accounts.first { $0.number == number } }
}

extension CswapStateSnapshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let active = activeAccountNumber.map { "#\($0)" } ?? "-"
        return "CswapStateSnapshot(accounts: \(accounts.map(\.description)), active: \(active) via \(activeSource), "
            + "warnings: \(warnings.map(EmailRedaction.redact)))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "accounts": accounts,
            "activeAccountNumber": activeAccountNumber as Any,
            "activeSource": activeSource,
            "readAt": readAt,
            "warnings": warnings.map(EmailRedaction.redact),
        ], displayStyle: .struct)
    }
}

/// Why the state root could not be read. Payloads are short 繁體中文 reasons for the D1 line
/// `// 讀不到 cswap 狀態：<reason>`; they never contain a path or an e-mail.
public enum CswapStateError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case unreadable(String)
    case unsupported(String)

    public var reason: String {
        switch self {
        case .missing(let r), .unreadable(let r), .unsupported(let r): return r
        }
    }

    public var description: String {
        switch self {
        case .missing(let r): return "missing(\(r))"
        case .unreadable(let r): return "unreadable(\(r))"
        case .unsupported(let r): return "unsupported(\(r))"
        }
    }
}

/// D25 plan chip from `oauthAccount.organizationRateLimitTier` / `organizationType`.
public enum PlanLabel {
    public static func from(rateLimitTier: String?, organizationType: String?) -> String? {
        let fields = [rateLimitTier, organizationType].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        guard !fields.isEmpty else { return nil }
        if fields.contains(where: { $0.contains("max_20x") }) { return "MAX 20x" }
        if fields.contains(where: { $0.contains("max_5x") }) { return "MAX 5x" }
        let tokens = Set(fields.flatMap { field in
            field.split { c in !c.isLetter && !c.isNumber }.map(String.init)
        })
        if tokens.contains("enterprise") { return "ENT" }
        if tokens.contains("team") { return "TEAM" }
        if tokens.contains("max") { return "MAX" }
        if tokens.contains("pro") { return "PRO" }
        return nil
    }
}

/// Reads cswap 0.26's state root READ-ONLY (D2): `sequence.json`, `cache/usage.json` (schema 2),
/// `configs/.claude-config-<n>-<email>.json` (plan only) and the `sessions/<n>-*` profiles, plus
/// the global login's `.claude.json` identity. `credentials/` and the Keychain are never touched.
///
/// E-mails are read only to match identities, exactly as cswap does (`UsageStore._matches`,
/// `_find_account_slot`), and live only in local values of this file: no model field, no
/// warning, no error and no fingerprint key carries one (D31).
public struct CswapStateReader: Sendable {
    public static let maxSequenceBytes = 8 << 20
    public static let maxUsageBytes = 8 << 20
    public static let maxConfigBytes = 8 << 20
    /// `.claude.json` is about 0.5 MB on a busy machine; it grows with `projects`.
    public static let maxClaudeJSONBytes = 32 << 20
    /// The `.claude.json` members never needed for the identity, skipped without decoding.
    static let skippedClaudeJSONKeys: Set<String> = ["projects", "mcpServers"]

    public let root: URL
    public let claudeJSONCandidates: [URL]
    public let claudeSettingsURL: URL?
    private let cache = ReaderCache()

    /// - Parameters:
    ///   - root: cswap's state root (``standardRoot(home:)`` on the standard data root; a fake
    ///     root in tests and DEBUG runs, D3).
    ///   - claudeJSONCandidates: the global config file(s), first existing one wins
    ///     (``claudeJSONCandidates(claudeDir:)``).
    ///   - claudeSettingsURL: `<claudeDir>/settings.json`, to tell whether a profile shares it.
    public init(root: URL, claudeJSONCandidates: [URL], claudeSettingsURL: URL? = nil) {
        self.root = root
        self.claudeJSONCandidates = claudeJSONCandidates
        self.claudeSettingsURL = claudeSettingsURL
    }

    /// `~/.claude-swap-backup` (cswap's macOS root).
    public static func standardRoot(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude-swap-backup", isDirectory: true)
    }

    /// `<claudeDir>/.config.json` when it exists (legacy), else `<claudeDir>/../.claude.json`
    /// (claude_swap/paths.py `get_global_config_path`, which mirrors Claude Code).
    public static func claudeJSONCandidates(claudeDir: URL) -> [URL] {
        let legacy = claudeDir.appendingPathComponent(".config.json")
        if FileManager.default.fileExists(atPath: legacy.path) { return [legacy] }
        return [claudeDir.standardizedFileURL.deletingLastPathComponent().appendingPathComponent(".claude.json")]
    }

    // MARK: - Read

    /// Blocking; call off the main actor. Missing / torn files of the cache, the configs and
    /// `.claude.json` degrade (warnings, `nil` fields); only an unusable `sequence.json` throws.
    public func read(now: Date = Date()) throws(CswapStateError) -> CswapStateSnapshot {
        var warnings: [String] = []
        let sequence = try loadSequence()
        let usage = loadUsage(sequence.records, now: now, warnings: &warnings)

        var activeNumber: Int?
        var activeSource = CswapStateSnapshot.ActiveSource.none
        var activeIdentity: ClaudeIdentity?
        switch claudeJSONState() {
        case .identity(let identity):
            if let record = sequence.records.first(where: { $0.matchesSlot(identity) }) {
                activeNumber = record.number
                activeSource = .claudeJSON
                activeIdentity = identity
            } else if !sequence.records.isEmpty {
                warnings.append("目前的 Claude 登入不是 cswap 管理的帳號")
            }
        case .unreadable:
            warnings.append("讀不到目前登入（.claude.json），改用 cswap 記錄的使用中帳號")
            fallthrough
        case .missing, .noIdentity:
            if let n = sequence.activeNumber, sequence.records.contains(where: { $0.number == n }) {
                activeNumber = n
                activeSource = .sequenceFile
            }
        }

        let profiles = sessionProfiles(sequence.records, warnings: &warnings)
        let accounts = sequence.records.map { record -> CswapStateAccount in
            let row = usage[record.number]
            var plan: String?
            if record.number == activeNumber, let activeIdentity { plan = activeIdentity.plan }
            if plan == nil { plan = configPlan(record) }
            let profile = profiles[record.number]
            return CswapStateAccount(
                number: record.number, alias: record.alias, isActive: record.number == activeNumber,
                isDisabled: record.disabled, plan: plan, usage: row?.usage, usageFetchedAt: row?.fetchedAt,
                usageHealth: row?.health ?? .none, sessionProfile: profile,
                sessionProfileStale: profile.map(Self.isStale) ?? false,
                sessionProfileSharesSettings: profile.flatMap(sharesSettings),
                identity: record.email.map { Self.quotaIdentity(email: $0, organization: record.usageOrganization) })
        }
        var seen = Set<String>()
        return CswapStateSnapshot(root: root, accounts: accounts, activeAccountNumber: activeNumber, activeSource: activeSource,
                                  readAt: now, warnings: warnings.filter { seen.insert($0).inserted })
    }

    /// mtime + size of `sequence.json`, `cache/usage.json`, the `.claude.json` in use, each config
    /// backup and the `sessions` directory, to skip unchanged re-reads. Keys are fixed labels
    /// (`sequence`, `usage`, `claudeJSON`, `config-<n>`, `sessions`), never paths: config file
    /// names contain the e-mail (D31).
    public func fingerprint() -> [String: String] {
        var out: [String: String] = [
            "sequence": Self.stamp(root.appendingPathComponent("sequence.json").path),
            "usage": Self.stamp(root.appendingPathComponent("cache/usage.json").path),
            "sessions": Self.stamp(root.appendingPathComponent("sessions").path),
        ]
        if let (index, url) = claudeJSONInUse() {
            out["claudeJSON"] = "\(index):" + Self.stamp(url.path)
        } else {
            out["claudeJSON"] = "missing"
        }
        let configs = root.appendingPathComponent("configs")
        var byNumber: [Int: [String]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: configs.path)) ?? [] {
            guard let n = Self.configNumber(name) else { continue }
            byNumber[n, default: []].append(Self.stamp(configs.appendingPathComponent(name).path))
        }
        for (n, stamps) in byNumber { out["config-\(n)"] = stamps.sorted().joined(separator: ",") }
        return out
    }

    /// Dialog C step 2: the current global login compared with the managed accounts. Never
    /// returns the e-mail; `plan` comes from `.claude.json`.
    public func currentLogin() -> (existingAccount: Int?, plan: String?, loggedIn: Bool) {
        guard case .identity(let identity) = claudeJSONState() else { return (nil, nil, false) }
        let records = (try? loadSequence().records) ?? []
        return (records.first { $0.matchesSlot(identity) }?.number, identity.plan, true)
    }

    /// The persisted quota identity of a slot (quota.json, D7): 16 hex digits of a domain-separated
    /// FNV-1a 64 of e-mail and organization, the pair cswap's usage cache checks. It tells two
    /// logins apart; it is not the e-mail and never logged or shown.
    public static func quotaIdentity(email: String, organization: String) -> String {
        AccountKey.fnv1a64Hex("codd-quota-identity\u{0}" + email + "\u{0}" + organization)
    }

    /// An opaque token of the current login (a digest of its e-mail and organization, never the
    /// e-mail itself), nil when logged out: dialog C compares it before and after `claude /login`
    /// to see that the login changed, also between two logins cswap does not manage. Memory only.
    public func currentLoginToken() -> UInt64? {
        guard case .identity(let identity) = claudeJSONState() else { return nil }
        return identity.digest
    }

    // MARK: - sequence.json

    struct SequenceRecord {
        var number: Int
        /// `email` (missing → "", other types → nil: matches nothing).
        var email: String?
        /// `organizationUuid` as `_find_account_slot` compares it (missing → "", null → nil).
        var slotOrganization: String?
        /// `organizationUuid or ""` as the usage store's identities use it.
        var usageOrganization: String
        var alias: String?
        var disabled: Bool

        /// `_find_account_slot`: e-mail and organization equal the login's (compared as digests).
        func matchesSlot(_ identity: ClaudeIdentity) -> Bool {
            guard let email, let slotOrganization else { return false }
            return ClaudeIdentity.digest(email: email, organization: slotOrganization) == identity.digest
        }
    }

    struct Sequence {
        var records: [SequenceRecord]
        var activeNumber: Int?
    }

    func loadSequence() throws(CswapStateError) -> Sequence {
        let data: Data
        switch Self.readFile(root.appendingPathComponent("sequence.json"), max: Self.maxSequenceBytes) {
        case .missing: throw .missing("找不到 sequence.json")
        case .tooLarge: throw .unreadable("sequence.json 過大")
        case .unreadable: throw .unreadable("sequence.json 無法讀取")
        case .data(let d, _): data = d
        }
        guard let value = JSONValue.parse(data) else { throw .unreadable("sequence.json 不是有效的 JSON") }
        guard let object = value.objectValue else { throw .unsupported("sequence.json 格式不符") }
        var records: [Int: SequenceRecord] = [:]
        switch object["accounts"] {
        case nil, .null?:
            break
        case .object(let accounts)?:
            for (key, raw) in accounts {
                guard let n = Self.slotNumber(key), let a = raw.objectValue else { continue }
                let org = a["organizationUuid"]
                records[n] = SequenceRecord(
                    number: n,
                    email: a["email"] == nil ? "" : a["email"]?.stringValue,
                    slotOrganization: org == nil ? "" : org?.stringValue,
                    usageOrganization: org?.stringValue ?? "",
                    alias: JSText.nonBlankTrimmed(a["alias"]),
                    disabled: a["disabled"]?.isTruthy ?? false)
            }
        default:
            throw .unsupported("sequence.json 的 accounts 格式不符")
        }
        var ordered: [SequenceRecord] = []
        var placed = Set<Int>()
        for n in (object["sequence"]?.arrayValue ?? []).compactMap(\.exactIntegerValue) {
            if let r = records[n], placed.insert(n).inserted { ordered.append(r) }
        }
        ordered += records.keys.filter { !placed.contains($0) }.sorted().compactMap { records[$0] }
        return Sequence(records: ordered, activeNumber: object["activeAccountNumber"]?.exactIntegerValue)
    }

    // MARK: - cache/usage.json

    struct UsageRow {
        var usage: CswapUsage?
        var fetchedAt: Date?
        var health: CswapUsageHealth
    }

    static let supportedUsageSchema = 2

    func loadUsage(_ records: [SequenceRecord], now: Date, warnings: inout [String]) -> [Int: UsageRow] {
        let data: Data
        switch Self.readFile(root.appendingPathComponent("cache/usage.json"), max: Self.maxUsageBytes) {
        case .missing: return [:]
        case .tooLarge, .unreadable:
            warnings.append("cswap 用量快取（cache/usage.json）無法讀取")
            return [:]
        case .data(let d, _): data = d
        }
        guard let object = JSONValue.parse(data)?.objectValue else {
            warnings.append("cswap 用量快取（cache/usage.json）無法讀取")
            return [:]
        }
        guard let version = object["schemaVersion"]?.exactIntegerValue, version == Self.supportedUsageSchema else {
            let v = object["schemaVersion"]?.exactIntegerValue.map(String.init) ?? "（無）"
            warnings.append("cswap 用量快取版本 \(v) 不支援（需要 \(Self.supportedUsageSchema)），用量改由 statusline 提供")
            return [:]
        }
        guard let rows = object["accounts"]?.objectValue else { return [:] }
        var out: [Int: UsageRow] = [:]
        for record in records {
            guard let row = rows[String(record.number)]?.objectValue, Self.rowMatches(row, record) else { continue }
            out[record.number] = Self.usageRow(row, now: now)
        }
        return out
    }

    /// `UsageStore._matches`: the row's e-mail and organization equal the slot's identity, so a
    /// reused slot number never shows the previous account's numbers.
    static func rowMatches(_ row: [String: JSONValue], _ record: SequenceRecord) -> Bool {
        guard let email = row["email"]?.stringValue, let own = record.email, email == own else { return false }
        let org: String? = row["organizationUuid"] == nil ? "" : row["organizationUuid"]?.stringValue
        return org == record.usageOrganization
    }

    static func usageRow(_ row: [String: JSONValue], now: Date) -> UsageRow {
        var fetchedAt: Date?
        if let t = row["fetchedAt"]?.numberValue, t.isFinite, t > 0 { fetchedAt = Date(timeIntervalSince1970: t) }
        let usage = row["lastGood"].flatMap(decodeLastGood)
        let health: CswapUsageHealth
        if count(row["authDeadStrikes"]) > 0 {
            health = .reloginRequired
        } else if count(row["consecutiveFailures"]) > 0 {
            let error = JSText.cleanText(row["lastError"], max: 200).map(EmailRedaction.redact) ?? "unknown"
            health = .failing(error)
        } else if let fetchedAt {
            health = now.timeIntervalSince(fetchedAt) <= CswapUsageHealth.freshness ? .fresh : .stale
        } else {
            health = .none
        }
        return UsageRow(usage: usage, fetchedAt: fetchedAt, health: health)
    }

    /// `int(row.get(key) or 0)` for numbers.
    private static func count(_ v: JSONValue?) -> Int {
        guard let n = v?.numberValue, n.isFinite else { return 0 }
        return Int(max(-1e9, min(1e9, n.rounded(.towardZero))))
    }

    /// cswap's internal usage dict (`five_hour`, `seven_day`, `resets_at`, …) decoded with the
    /// tolerant `--json` models after renaming its snake_case keys.
    static func decodeLastGood(_ value: JSONValue) -> CswapUsage? {
        guard value.objectValue != nil, let data = try? camelCased(value).jsonData(),
              let usage = try? JSONDecoder().decode(CswapUsage.self, from: data) else { return nil }
        if usage.fiveHour == nil, usage.sevenDay == nil, usage.scoped.isEmpty, usage.spend == nil { return nil }
        return usage
    }

    private static let renamedKeys = ["five_hour": "fiveHour", "seven_day": "sevenDay", "resets_at": "resetsAt"]

    static func camelCased(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[renamedKeys[k] ?? k] = camelCased(v) }
            return .object(out)
        case .array(let a):
            return .array(a.map(camelCased))
        default:
            return value
        }
    }

    // MARK: - .claude.json

    /// The global login's identity. Only a digest of e-mail + organization is kept: this value
    /// is cached across reads, and e-mails must not outlive the read that matched them (D2).
    struct ClaudeIdentity: Equatable {
        var digest: UInt64
        var plan: String?

        static func digest(email: String, organization: String) -> UInt64 {
            AccountKey.fnv1a64(email + "\u{0}" + organization)
        }
    }

    enum ClaudeJSONState: Equatable {
        case missing
        case unreadable
        /// Readable, but no `oauthAccount.emailAddress` (logged out, or an API-key login).
        case noIdentity
        case identity(ClaudeIdentity)
    }

    /// The first candidate that exists, with its index.
    func claudeJSONInUse() -> (Int, URL)? {
        for (i, url) in claudeJSONCandidates.enumerated() {
            var st = stat()
            if stat(url.path, &st) == 0 { return (i, url) }
        }
        return nil
    }

    /// Cached by path + size + mtime: the file is large and Claude rewrites it often.
    func claudeJSONState() -> ClaudeJSONState {
        guard let (_, url) = claudeJSONInUse() else { return .missing }
        let path = url.path
        let key = Self.stamp(path)
        if let hit = cache.claudeJSON.withLock({ $0?.path == path && $0?.stamp == key ? $0?.state : nil }) { return hit }
        let state: ClaudeJSONState
        switch Self.readFile(url, max: Self.maxClaudeJSONBytes) {
        case .missing: return .missing
        case .tooLarge, .unreadable: state = .unreadable
        case .data(let data, _):
            if let object = JSONValue.parse(data, nullingTopLevelKeys: Self.skippedClaudeJSONKeys)?.objectValue {
                state = Self.identity(object["oauthAccount"]?.objectValue).map(ClaudeJSONState.identity) ?? .noIdentity
            } else {
                state = .unreadable
            }
        }
        cache.claudeJSON.withLock { $0 = CachedClaudeJSON(path: path, stamp: key, state: state) }
        return state
    }

    /// `_get_current_identity_triple`: a non-empty `emailAddress`, `organizationUuid or ""`.
    static func identity(_ oauth: [String: JSONValue]?) -> ClaudeIdentity? {
        guard let oauth, let email = oauth["emailAddress"]?.stringValue, !email.isEmpty else { return nil }
        return ClaudeIdentity(digest: ClaudeIdentity.digest(email: email, organization: oauth["organizationUuid"]?.stringValue ?? ""),
                              plan: plan(oauth))
    }

    static func plan(_ oauth: [String: JSONValue]?) -> String? {
        PlanLabel.from(rateLimitTier: oauth?["organizationRateLimitTier"]?.stringValue,
                       organizationType: oauth?["organizationType"]?.stringValue)
    }

    // MARK: - configs/

    /// The plan from the account's config backup (≤ 8 MiB, cached by path + size + mtime; the
    /// cache key is a digest, since the file name carries the e-mail).
    func configPlan(_ record: SequenceRecord) -> String? {
        guard let email = record.email, !email.isEmpty, !email.contains("/"), !email.contains("\0") else { return nil }
        let url = root.appendingPathComponent("configs").appendingPathComponent(".claude-config-\(record.number)-\(email).json")
        let path = AccountKey.fnv1a64(url.path)
        let key = Self.stamp(url.path)
        if let hit = cache.configs.withLock({ $0[path]?.stamp == key ? $0[path] : nil }) { return hit.plan }
        var plan: String?
        if case .data(let data, _) = Self.readFile(url, max: Self.maxConfigBytes),
           let object = JSONValue.parse(data, nullingTopLevelKeys: Self.skippedClaudeJSONKeys)?.objectValue {
            plan = Self.plan(object["oauthAccount"]?.objectValue)
        }
        cache.configs.withLock { $0[path] = CachedPlan(stamp: key, plan: plan) }
        return plan
    }

    /// `.claude-config-<n>-….json` → n.
    static func configNumber(_ name: String) -> Int? {
        let prefix = ".claude-config-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        return AccountKey.slotPrefix(name.dropFirst(prefix.count))
    }

    // MARK: - sessions/

    /// The profile of each account: the single real directory `sessions/<n>-*` (symlinks are
    /// ignored); with several, cswap's own name `<n>-<slugify(email)>` when present, else none.
    func sessionProfiles(_ records: [SequenceRecord], warnings: inout [String]) -> [Int: URL] {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        var candidates: [Int: [String]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            guard let n = AccountKey.slotPrefix(Substring(name)),
                  ReadOnlyFile.isRealDirectory(sessions.appendingPathComponent(name).path) else { continue }
            candidates[n, default: []].append(name)
        }
        var out: [Int: URL] = [:]
        for record in records {
            guard let names = candidates[record.number], !names.isEmpty else { continue }
            var chosen: String?
            if names.count == 1 {
                chosen = names[0]
            } else if let email = record.email, names.contains("\(record.number)-\(Self.slugify(email))") {
                chosen = "\(record.number)-\(Self.slugify(email))"
            } else {
                warnings.append("#\(record.number) 有多個 cswap session 設定目錄，無法判斷要用哪一個")
            }
            if let chosen { out[record.number] = sessions.appendingPathComponent(chosen, isDirectory: true) }
        }
        return out
    }

    /// claude_swap/session.py `slugify_email`.
    static func slugify(_ email: String) -> String {
        var out = String.UnicodeScalarView()
        for c in email.precomposedStringWithCanonicalMapping.unicodeScalars {
            let keep = c.isASCII && (c.properties.isAlphabetic || c.properties.numericType != nil || c == "." || c == "_" || c == "-")
            out.append(keep ? c : "_")
        }
        return String(out)
    }

    static let staleMarker = ".cswap-stale-credentials"

    /// session.py `is_session_stale`: the sibling marker `sessions/.<dir>.cswap-stale-credentials`
    /// or the legacy child `<dir>/.cswap-stale-credentials`.
    static func isStale(_ profile: URL) -> Bool {
        let sibling = profile.deletingLastPathComponent().appendingPathComponent(".\(profile.lastPathComponent)\(staleMarker)")
        let child = profile.appendingPathComponent(staleMarker)
        return [sibling, child].contains { url in
            var st = stat()
            return stat(url.path, &st) == 0
        }
    }

    /// `<profile>/settings.json` is a symlink resolving to ``claudeSettingsURL`` (cswap's
    /// SHARED_ITEMS link); a regular file, another target or no file → false.
    func sharesSettings(_ profile: URL) -> Bool? {
        guard let claudeSettingsURL else { return nil }
        let link = profile.appendingPathComponent("settings.json").path
        var st = stat()
        guard lstat(link, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return false }
        let resolvedLink = ReadOnlyFile.realPath(link) ?? Self.symlinkDestination(link)
        let target = ReadOnlyFile.realPath(claudeSettingsURL.path) ?? claudeSettingsURL.standardizedFileURL.path
        return resolvedLink == target
    }

    /// A dangling link's destination as an absolute, standardized path.
    static func symlinkDestination(_ link: String) -> String? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        let base = URL(fileURLWithPath: link).deletingLastPathComponent()
        let url = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : base.appendingPathComponent(dest)
        return url.standardizedFileURL.path
    }

    // MARK: - Files

    enum FileRead {
        case missing
        case tooLarge
        case unreadable
        case data(Data, ReadOnlyFile.Info)
    }

    static func readFile(_ url: URL, max: Int) -> FileRead {
        var st = stat()
        if stat(url.path, &st) != 0 { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        var tooLarge = false
        let read: (Data, ReadOnlyFile.Info)? = ReadOnlyFile.with(url.path) { fd, info in
            guard info.size <= Int64(max) else {
                tooLarge = true
                return nil
            }
            // Sized from fstat (not `max`: a 32 MiB buffer per read would be wasteful); one byte
            // more tells a file that grew while being read (then it parses as torn and the next
            // read retries).
            guard let bytes = ReadOnlyFile.read(fd, offset: 0, count: Int(info.size) + 1) else { return nil }
            guard bytes.count <= max else {
                tooLarge = true
                return nil
            }
            return (Data(bytes), info)
        }
        if let read { return .data(read.0, read.1) }
        return tooLarge ? .tooLarge : .unreadable
    }

    /// `size:mtime-ns`, or `missing`.
    static func stamp(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "missing" }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return "\(st.st_size):\(ns)"
    }

    /// A slot key: 1–4 ASCII digits (`sequence.json` keys are `str(int)`).
    static func slotNumber(_ key: String) -> Int? {
        let bytes = Array(key.utf8)
        guard (1...4).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(key)
    }
}

extension CswapStateReader: CustomStringConvertible, CustomReflectable {
    public var description: String { "CswapStateReader(root: \(root.path))" }

    /// The caches hold paths with e-mails: never reflected.
    public var customMirror: Mirror {
        Mirror(self, children: ["root": root, "claudeJSONCandidates": claudeJSONCandidates], displayStyle: .struct)
    }
}

/// Parsed `.claude.json` / config results, keyed by path + stamp. No e-mail is stored: identities
/// and config paths (whose names carry the e-mail) are kept as digests only; still never reflected.
final class ReaderCache: Sendable, CustomReflectable {
    let claudeJSON = Mutex<CachedClaudeJSON?>(nil)
    /// Keyed by a digest of the config file's path.
    let configs = Mutex<[UInt64: CachedPlan]>([:])

    var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct CachedClaudeJSON: Sendable {
    var path: String
    var stamp: String
    var state: CswapStateReader.ClaudeJSONState
}

struct CachedPlan: Sendable {
    var stamp: String
    var plan: String?
}

extension CswapStateReader.ClaudeJSONState: Sendable {}
extension CswapStateReader.ClaudeIdentity: Sendable {}
