import Foundation

/// `usageStatus` values (`json_output.py` `usage_fields`). Unknown values are preserved.
public enum CswapUsageStatus: Sendable, Hashable {
    case ok
    case tokenExpired
    case apiKey
    case keychainUnavailable
    case reloginRequired
    case foreignCredential
    case noCredentials
    case unavailable
    case other(String)

    public init(raw: String?) {
        switch raw {
        case "ok"?: self = .ok
        case "token_expired"?: self = .tokenExpired
        case "api_key"?: self = .apiKey
        case "keychain_unavailable"?: self = .keychainUnavailable
        case "relogin_required"?: self = .reloginRequired
        case "foreign_credential"?: self = .foreignCredential
        case "no_credentials"?: self = .noCredentials
        case "unavailable"?, nil: self = .unavailable
        case .some(let s): self = .other(s)
        }
    }

    /// Whether the account's (possibly last-good) numbers are trustworthy enough to switch to it:
    /// the data is fresh (`ok`) or merely stale (`unavailable` = fetch failed, `token_expired` =
    /// refresh deferred and retried automatically). Accounts that need the user (re-login, no
    /// credentials, foreign credential, API key, locked keychain) are never switch targets.
    public var allowsAutoSwitchTarget: Bool {
        switch self {
        case .ok, .unavailable, .tokenExpired: return true
        default: return false
        }
    }
}

/// One usage window (`fiveHour`, `sevenDay`, or a scoped per-model window).
public struct CswapWindow: Sendable, Equatable, Decodable {
    /// Percent USED (0–100, may exceed 100 on overage).
    public var pct: Double
    public var resetsAt: Date?
    /// cswap's human countdown (`"4d 10h"`), recomputed at serialization time.
    public var countdown: String?
    /// cswap's reset clock (`"Oct 19 20:00"`).
    public var clock: String?
    // Weekly pace fields (seven-day and scoped windows only).
    public var expectedPct: Double?
    public var aheadOfPace: Bool?
    public var projectedExhaustionAt: Date?
    public var willLastToReset: Bool?

    public init(pct: Double, resetsAt: Date? = nil, countdown: String? = nil, clock: String? = nil,
                expectedPct: Double? = nil, aheadOfPace: Bool? = nil, projectedExhaustionAt: Date? = nil,
                willLastToReset: Bool? = nil) {
        self.pct = pct
        self.resetsAt = resetsAt
        self.countdown = countdown
        self.clock = clock
        self.expectedPct = expectedPct
        self.aheadOfPace = aheadOfPace
        self.projectedExhaustionAt = projectedExhaustionAt
        self.willLastToReset = willLastToReset
    }

    /// `100 − used`, clamped to 0…100 and rounded to 0.1 (as CODD web displays it).
    public var remainingPercent: Double { QuotaMath.remaining(usedPercent: pct) }

    enum CodingKeys: String, CodingKey {
        case pct, resetsAt, countdown, clock, expectedPct, aheadOfPace, projectedExhaustionAt, willLastToReset
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let pct = c.lenient(Double.self, forKey: .pct), pct.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .pct, in: c, debugDescription: "missing pct")
        }
        self.pct = pct
        resetsAt = FlexibleDate.decode(c, .resetsAt)
        countdown = c.lenient(String.self, forKey: .countdown)
        clock = c.lenient(String.self, forKey: .clock)
        expectedPct = c.lenient(Double.self, forKey: .expectedPct)
        aheadOfPace = c.lenient(Bool.self, forKey: .aheadOfPace)
        projectedExhaustionAt = FlexibleDate.decode(c, .projectedExhaustionAt)
        willLastToReset = c.lenient(Bool.self, forKey: .willLastToReset)
    }
}

/// A per-model weekly window (`scoped[]`, e.g. "Fable").
public struct CswapScopedWindow: Sendable, Equatable, Decodable {
    public var name: String
    public var window: CswapWindow

    public init(name: String, window: CswapWindow) {
        self.name = name
        self.window = window
    }

    enum CodingKeys: String, CodingKey { case name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = JSText.nonBlankTrimmed(c.lenient(String.self, forKey: .name)) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "missing name")
        }
        self.name = name
        window = try CswapWindow(from: decoder)
    }
}

/// Pay-as-you-go extra usage (`spend`), already in currency units (cswap divides cents by 100).
public struct CswapSpend: Sendable, Equatable, Decodable {
    public var used: Double?
    public var limit: Double?
    public var pct: Double?
    public var currency: String?
    public var resetsAt: Date?
    public var countdown: String?
    public var clock: String?

    enum CodingKeys: String, CodingKey { case used, limit, pct, currency, resetsAt, countdown, clock }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        used = c.lenient(Double.self, forKey: .used)
        limit = c.lenient(Double.self, forKey: .limit)
        pct = c.lenient(Double.self, forKey: .pct)
        currency = c.lenient(String.self, forKey: .currency)
        resetsAt = FlexibleDate.decode(c, .resetsAt)
        countdown = c.lenient(String.self, forKey: .countdown)
        clock = c.lenient(String.self, forKey: .clock)
    }
}

/// `usage` / `lastGoodUsage`. Every window may be absent (the API does not always send them).
public struct CswapUsage: Sendable, Equatable, Decodable {
    public var fiveHour: CswapWindow?
    public var sevenDay: CswapWindow?
    public var scoped: [CswapScopedWindow]
    public var spend: CswapSpend?

    public init(fiveHour: CswapWindow? = nil, sevenDay: CswapWindow? = nil,
                scoped: [CswapScopedWindow] = [], spend: CswapSpend? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
        self.spend = spend
    }

    enum CodingKeys: String, CodingKey { case fiveHour, sevenDay, scoped, spend }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = c.lenient(CswapWindow.self, forKey: .fiveHour)
        sevenDay = c.lenient(CswapWindow.self, forKey: .sevenDay)
        scoped = c.lenient(LossyArray<CswapScopedWindow>.self, forKey: .scoped)?.elements ?? []
        spend = c.lenient(CswapSpend.self, forKey: .spend)
    }
}

/// Tolerant date decoding: ISO 8601 strings (any fraction digits, `Z` or offset) or epoch
/// seconds / milliseconds (session-insights `toIso` rule).
enum FlexibleDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        JSDate.timestamp(c.lenient(JSONValue.self, forKey: key)).map(JSDate.date(milliseconds:))
    }
}
