/// Activity state stored in a hook state record (`state` in the v2 hook file).
///
/// `busy`, `waiting`, `idle` and `ended` come from status-writer.js. `error` and `compacting` are
/// produced only by the ``HookDialect/desktop`` dialect (see ``HookReducer``).
public enum HookActivityState: String, Sendable, Codable, CaseIterable {
    case busy
    case waiting
    case idle
    case ended
    /// Desktop extension: the turn failed (StopFailure).
    case error
    /// Desktop extension: context compaction in progress (PreCompact … PostCompact).
    case compacting
}

/// Why a session is waiting for the user (SPEC §3: permission | question | plan | other).
public enum WaitingReason: String, Sendable, Codable, CaseIterable {
    case permission
    case question
    case plan
    /// Only from the registry (`waitingFor` = `dialog open`, `goal proposal`, or unrecognised).
    case other

    /// Sidebar NEEDS-YOU abbreviation (SPEC §3).
    public var shortLabel: String {
        switch self {
        case .permission: return "PERM"
        case .question: return "ASK"
        case .plan: return "PLAN"
        case .other: return "WAIT"
        }
    }

    /// Header chip label, e.g. `◆ WAITING · PERMISSION`.
    public var label: String {
        switch self {
        case .permission: return "PERMISSION"
        case .question: return "QUESTION"
        case .plan: return "PLAN"
        case .other: return "OTHER"
        }
    }
}

/// StopFailure `error` values (https://code.claude.com/docs/en/hooks, StopFailure input).
/// Unrecognised values decode as ``unknown``.
public enum HookErrorKind: String, Sendable, CaseIterable {
    case rateLimit = "rate_limit"
    case overloaded
    case authenticationFailed = "authentication_failed"
    case oauthOrgNotAllowed = "oauth_org_not_allowed"
    case accountOnHold = "account_on_hold"
    case billingError = "billing_error"
    case invalidRequest = "invalid_request"
    case modelNotFound = "model_not_found"
    case serverError = "server_error"
    case maxOutputTokens = "max_output_tokens"
    case cloudCredentialError = "cloud_credential_error"
    case unknown

    /// Lenient mapping from the raw hook value.
    public init(hookValue: String?) {
        self = hookValue.flatMap(HookErrorKind.init(rawValue:)) ?? .unknown
    }

    /// Header chip label (SPEC §3 shows `OVERLOADED`, `RATE LIMIT`, `AUTH`; the rest are proposals).
    public var label: String {
        switch self {
        case .rateLimit: return "RATE LIMIT"
        case .overloaded: return "OVERLOADED"
        case .authenticationFailed, .oauthOrgNotAllowed, .cloudCredentialError: return "AUTH"
        case .accountOnHold: return "ACCOUNT HOLD"
        case .billingError: return "BILLING"
        case .invalidRequest: return "INVALID REQUEST"
        case .modelNotFound: return "MODEL NOT FOUND"
        case .serverError: return "SERVER ERROR"
        case .maxOutputTokens: return "MAX TOKENS"
        case .unknown: return "UNKNOWN"
        }
    }
}

extension HookErrorKind: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = HookErrorKind(hookValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
