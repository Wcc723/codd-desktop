import CoddHookClient
import Foundation

/// One quota window of a status-line report (Claude Code's `rate_limits.five_hour` / `seven_day`).
public struct StatusLineWindow: Sendable, Equatable {
    /// 0…100 (Claude sends one decimal, already clamped to 100).
    public var usedPercent: Double
    /// `nil` when absent or unreadable; the used value is still meaningful without it.
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// A `POST /statusline` from `codd-statusline` (M3 D9), as the app's quota pipeline consumes it.
///
/// Body: `{"v":1,"session_id":<Claude session id>|null,"config_key":"default"|"cswap-3"|"cfg-<16 hex>",
/// "rate_limits":<Claude's value verbatim>|null}`. The CLI forwards `rate_limits` unparsed, so all
/// tolerance lives here: a window counts only with a finite numeric `used_percentage`, and
/// `resets_at` may be epoch seconds (what Claude sends), epoch milliseconds or an ISO 8601 string
/// (what CODD web's script also accepted).
public struct StatusLineReport: Sendable, Equatable {
    /// `X-CODD-Session`: the CODD session that ran the status line; `nil` from the global one.
    public var sessionID: UUID?
    /// The body's `session_id` (Claude's own id), when it is a non-empty string of at most 256 bytes.
    public var claudeSessionId: String?
    /// The account key (D6) when it has one of the three shapes, else ``invalidConfigKey``.
    public var configKey: String
    public var fiveHour: StatusLineWindow?
    public var sevenDay: StatusLineWindow?
    /// `rate_limits` was an object. Claude omits it entirely until a window is known, so `false`
    /// means "no quota information in this run", not "quota unknown for good".
    public var hadRateLimits: Bool
    /// When the request was complete, from the server's clock.
    public var receivedAt: Date

    public static let invalidConfigKey = "invalid"

    public init(sessionID: UUID?, claudeSessionId: String?, configKey: String, fiveHour: StatusLineWindow?,
                sevenDay: StatusLineWindow?, hadRateLimits: Bool, receivedAt: Date) {
        self.sessionID = sessionID
        self.claudeSessionId = claudeSessionId
        self.configKey = configKey
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.hadRateLimits = hadRateLimits
        self.receivedAt = receivedAt
    }

    /// Decodes a report body; `nil` when it is not one valid JSON object (nested at most 64 deep)
    /// or its `v` is present and not `1`. Everything else degrades per field: an invalid key
    /// becomes ``invalidConfigKey``, a window without a usable `used_percentage` is `nil`, an
    /// unreadable `resets_at` is `nil`, a `rate_limits` that is not an object (or `null`) means
    /// ``hadRateLimits`` `false`.
    public static func decode(body: [UInt8], sessionID: UUID?, receivedAt: Date) -> StatusLineReport? {
        guard let m = JSONScan.members(body) else { return nil }
        if let v = m["v"], JSONScan.integer(body, v) != 1 { return nil }
        let claudeSessionId = m["session_id"].flatMap { JSONScan.string(body, $0) }
            .flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
        let configKey = m["config_key"].flatMap { JSONScan.string(body, $0) }.flatMap { isValidConfigKey($0) ? $0 : nil }
            ?? invalidConfigKey
        var fiveHour: StatusLineWindow?
        var sevenDay: StatusLineWindow?
        var hadRateLimits = false
        if let span = m["rate_limits"], let limits = JSONScan.members(body, in: span) {
            hadRateLimits = true
            fiveHour = limits["five_hour"].flatMap { window(body, $0) }
            sevenDay = limits["seven_day"].flatMap { window(body, $0) }
        }
        return StatusLineReport(sessionID: sessionID, claudeSessionId: claudeSessionId, configKey: configKey,
                                fiveHour: fiveHour, sevenDay: sevenDay, hadRateLimits: hadRateLimits, receivedAt: receivedAt)
    }

    /// `^(default|cswap-[0-9]{1,4}|cfg-[0-9a-f]{16})$`.
    public static func isValidConfigKey(_ key: String) -> Bool {
        let b = Array(key.utf8)
        if key == "default" { return true }
        func digits(_ s: ArraySlice<UInt8>) -> Bool { s.allSatisfy { (0x30...0x39).contains($0) } }
        if b.starts(with: Array("cswap-".utf8)) {
            let rest = b.dropFirst(6)
            return (1...4).contains(rest.count) && digits(rest)
        }
        if b.starts(with: Array("cfg-".utf8)) {
            let rest = b.dropFirst(4)
            return rest.count == 16 && rest.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        }
        return false
    }

    static func window(_ body: [UInt8], _ span: Range<Int>) -> StatusLineWindow? {
        guard let w = JSONScan.members(body, in: span),
              let used = w["used_percentage"].flatMap({ JSONScan.number(body, $0) }) else { return nil }
        return StatusLineWindow(usedPercent: min(100, max(0, used)), resetsAt: w["resets_at"].flatMap { resetDate(body, $0) })
    }

    /// Epoch seconds, epoch milliseconds (above 1e12, i.e. after 2001 in milliseconds; seconds only
    /// get there in the year 33658) or ISO 8601 with a time zone. Zero, negative and implausibly
    /// far values (past the year 5138) are unreadable.
    static func resetDate(_ body: [UInt8], _ span: Range<Int>) -> Date? {
        if let n = JSONScan.number(body, span) {
            let seconds = n > 1e12 ? n / 1000 : n
            guard seconds > 0, seconds < 1e11 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let s = JSONScan.string(body, span), !s.isEmpty, s.utf8.count <= 64 else { return nil }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
}
