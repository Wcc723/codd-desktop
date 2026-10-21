import Foundation

/// `cswap … --json` payloads, schema version 1 (claude-swap 0.26.0 `json_output.py`).
///
/// Decoding is tolerant: unknown keys are ignored, a field of the wrong type is `nil`, a broken
/// account row or window is skipped rather than failing the whole response. Account e-mail
/// addresses are deliberately NOT decoded (the UI never shows them; accounts are keyed by number).
public enum CswapSchema {
    public static let supportedVersion = 1
}

/// One `accounts[]` row of `cswap list --json` (also `active` of `status --json`).
public struct CswapAccount: Sendable, Equatable, Decodable {
    public var number: Int
    public var alias: String?
    public var organizationName: String?
    public var isOrganization: Bool
    public var active: Bool
    public var disabled: Bool
    public var usageStatus: CswapUsageStatus
    public var usage: CswapUsage?
    public var usageFetchedAt: Date?
    public var usageAgeSeconds: Double?
    /// Display-grade last known numbers when `usage` is `null`.
    public var lastGoodUsage: CswapUsage?
    public var lastGoodFetchedAt: Date?
    public var lastGoodAgeSeconds: Double?

    public init(number: Int, alias: String? = nil, organizationName: String? = nil, isOrganization: Bool = false,
                active: Bool = false, disabled: Bool = false, usageStatus: CswapUsageStatus = .ok,
                usage: CswapUsage? = nil, usageFetchedAt: Date? = nil, usageAgeSeconds: Double? = nil,
                lastGoodUsage: CswapUsage? = nil, lastGoodFetchedAt: Date? = nil, lastGoodAgeSeconds: Double? = nil) {
        self.number = number
        self.alias = alias
        self.organizationName = organizationName
        self.isOrganization = isOrganization
        self.active = active
        self.disabled = disabled
        self.usageStatus = usageStatus
        self.usage = usage
        self.usageFetchedAt = usageFetchedAt
        self.usageAgeSeconds = usageAgeSeconds
        self.lastGoodUsage = lastGoodUsage
        self.lastGoodFetchedAt = lastGoodFetchedAt
        self.lastGoodAgeSeconds = lastGoodAgeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case number, alias, organizationName, isOrganization, active, disabled, usageStatus, usage,
             usageFetchedAt, usageAgeSeconds, lastGoodUsage, lastGoodFetchedAt, lastGoodAgeSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let number = c.lenient(JSONValue.self, forKey: .number)?.exactIntegerValue else {
            throw DecodingError.dataCorruptedError(forKey: .number, in: c, debugDescription: "missing number")
        }
        self.number = number
        alias = JSText.nonBlankTrimmed(c.lenient(String.self, forKey: .alias))
        organizationName = c.lenient(String.self, forKey: .organizationName)
        isOrganization = c.lenient(Bool.self, forKey: .isOrganization) ?? false
        active = c.lenient(Bool.self, forKey: .active) ?? false
        disabled = c.lenient(Bool.self, forKey: .disabled) ?? false
        usageStatus = CswapUsageStatus(raw: c.lenient(String.self, forKey: .usageStatus))
        usage = c.lenient(CswapUsage.self, forKey: .usage)
        usageFetchedAt = FlexibleDate.decode(c, .usageFetchedAt)
        usageAgeSeconds = c.lenient(Double.self, forKey: .usageAgeSeconds)
        lastGoodUsage = c.lenient(CswapUsage.self, forKey: .lastGoodUsage)
        lastGoodFetchedAt = FlexibleDate.decode(c, .lastGoodFetchedAt)
        lastGoodAgeSeconds = c.lenient(Double.self, forKey: .lastGoodAgeSeconds)
    }

    /// `usage`, else `lastGoodUsage`.
    public var effectiveUsage: CswapUsage? { usage ?? lastGoodUsage }
    /// Fetch time of ``effectiveUsage``.
    public var effectiveUsageFetchedAt: Date? { usage != nil ? usageFetchedAt : lastGoodFetchedAt }
    /// Whether ``effectiveUsage`` is the last-good fallback.
    public var isUsingLastGoodUsage: Bool { usage == nil && lastGoodUsage != nil }
}

/// `cswap list --json`.
public struct CswapListResponse: Sendable, Equatable, Decodable {
    public var schemaVersion: Int
    public var activeAccountNumber: Int?
    public var accounts: [CswapAccount]
    /// Additive warning arrays, kept raw (their shape is not part of the documented contract).
    public var duplicateAccountWarnings: JSONValue?
    public var lockstepUsageWarnings: JSONValue?

    public init(schemaVersion: Int = CswapSchema.supportedVersion, activeAccountNumber: Int?, accounts: [CswapAccount]) {
        self.schemaVersion = schemaVersion
        self.activeAccountNumber = activeAccountNumber
        self.accounts = accounts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, activeAccountNumber, accounts, duplicateAccountWarnings, lockstepUsageWarnings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try CswapSchema.requireSupported(c.lenient(JSONValue.self, forKey: .schemaVersion))
        activeAccountNumber = c.lenient(JSONValue.self, forKey: .activeAccountNumber)?.exactIntegerValue
        accounts = c.lenient(LossyArray<CswapAccount>.self, forKey: .accounts)?.elements ?? []
        duplicateAccountWarnings = c.lenient(JSONValue.self, forKey: .duplicateAccountWarnings)
        lockstepUsageWarnings = c.lenient(JSONValue.self, forKey: .lockstepUsageWarnings)
    }

    /// The active account: the row flagged `active`, else the one numbered `activeAccountNumber`.
    public var activeAccount: CswapAccount? {
        accounts.first(where: \.active) ?? accounts.first { $0.number == activeAccountNumber }
    }
}

/// `cswap status --json`.
public struct CswapStatusResponse: Sendable, Equatable, Decodable {
    public var schemaVersion: Int
    public var active: CswapAccount?
    public var totalManagedAccounts: Int?

    enum CodingKeys: String, CodingKey { case schemaVersion, active, totalManagedAccounts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try CswapSchema.requireSupported(c.lenient(JSONValue.self, forKey: .schemaVersion))
        active = c.lenient(CswapAccount.self, forKey: .active)
        totalManagedAccounts = c.lenient(JSONValue.self, forKey: .totalManagedAccounts)?.exactIntegerValue
    }
}

/// `cswap switch <n> --json`.
public struct CswapSwitchResponse: Sendable, Equatable, Decodable {
    public var schemaVersion: Int
    public var switched: Bool
    public var fromNumber: Int?
    public var toNumber: Int?
    public var strategy: String?
    /// `switched`, `already-active`, …
    public var reason: String?
    public var message: String?
    public var warnings: [String]

    enum CodingKeys: String, CodingKey { case schemaVersion, switched, from, to, strategy, reason, message, warnings }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try CswapSchema.requireSupported(c.lenient(JSONValue.self, forKey: .schemaVersion))
        switched = c.lenient(Bool.self, forKey: .switched) ?? false
        fromNumber = c.lenient(JSONValue.self, forKey: .from)?["number"]?.exactIntegerValue
        toNumber = c.lenient(JSONValue.self, forKey: .to)?["number"]?.exactIntegerValue
        strategy = c.lenient(String.self, forKey: .strategy)
        reason = c.lenient(String.self, forKey: .reason)
        message = c.lenient(String.self, forKey: .message)
        warnings = (c.lenient([JSONValue].self, forKey: .warnings) ?? []).compactMap(\.stringValue)
    }
}

/// `{"schemaVersion":1,"error":{"type","message"}}` (exit status 1).
public struct CswapErrorEnvelope: Sendable, Equatable {
    public var type: String
    public var message: String

    /// Parses an error envelope from cswap stdout, if that is what it is.
    public static func parse(_ data: Data) -> CswapErrorEnvelope? {
        guard let error = JSONValue.parse(data)?["error"], let type = JSText.nonBlankTrimmed(error["type"]) else {
            return nil
        }
        return CswapErrorEnvelope(type: type, message: error["message"]?.stringValue ?? "")
    }
}

extension CswapSchema {
    static func requireSupported(_ raw: JSONValue?) throws -> Int {
        guard let v = raw?.exactIntegerValue else { throw CswapError.unsupportedSchema(nil) }
        guard v == supportedVersion else { throw CswapError.unsupportedSchema(v) }
        return v
    }
}
