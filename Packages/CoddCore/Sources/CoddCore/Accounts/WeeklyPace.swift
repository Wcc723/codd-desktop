import Foundation

/// Weekly pace of one window (SPEC §5 「1w 用量超前預期 · 預估 10/17 18:00 用完」).
public struct WeeklyPaceInfo: Sendable, Equatable, Codable {
    /// Used more than the elapsed share of the week by at least the threshold (15 points).
    public var aheadOfPace: Bool
    /// Linear projection of when usage reaches 100 %; `nil` without a measurable rate.
    public var projectedExhaustionAt: Date?
    /// The "on schedule" used % at the measurement (cswap `expectedPct`); `nil` when unknown.
    public var expectedPercent: Double?
    /// Usage stays under 100 % through the reset at the current rate; `nil` when unknown.
    public var willLastToReset: Bool?

    public init(aheadOfPace: Bool, projectedExhaustionAt: Date? = nil, expectedPercent: Double? = nil, willLastToReset: Bool? = nil) {
        self.aheadOfPace = aheadOfPace
        self.projectedExhaustionAt = projectedExhaustionAt
        self.expectedPercent = expectedPercent
        self.willLastToReset = willLastToReset
    }

    /// cswap's `--json` pace fields of a weekly window, when it sent them.
    public init?(cswap w: CswapWindow) {
        guard let ahead = w.aheadOfPace else { return nil }
        self.init(aheadOfPace: ahead, projectedExhaustionAt: w.projectedExhaustionAt, expectedPercent: w.expectedPct,
                  willLastToReset: w.willLastToReset)
    }

    // quota.json shape (§3): dates as ISO strings, absent fields omitted.
    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let info = WeeklyPaceInfo(json: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "pace"))
        }
        self = info
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    init?(json v: JSONValue) {
        guard let ahead = v["aheadOfPace"]?.boolValue else { return nil }
        self.init(aheadOfPace: ahead, projectedExhaustionAt: QuotaJSON.date(v["projectedExhaustionAt"]),
                  expectedPercent: QuotaJSON.finite(v["expectedPercent"]), willLastToReset: v["willLastToReset"]?.boolValue)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["aheadOfPace": .bool(aheadOfPace)]
        if let projectedExhaustionAt { o["projectedExhaustionAt"] = QuotaJSON.json(projectedExhaustionAt) }
        if let expectedPercent { o["expectedPercent"] = .number(expectedPercent) }
        if let willLastToReset { o["willLastToReset"] = .bool(willLastToReset) }
        return .object(o)
    }
}

/// Exact port of claude_swap/pace.py (0.26): `compute_pace`, `projected_exhaustion_ts` and
/// `will_last_to_reset`, so a status-line weekly window gets the same pace cswap would compute.
///
/// The window start is derived by rolling `resetsAt` by whole periods until it lands at or before
/// the measurement (Python's floored `%`), so a stale or far-future reset still works.
public enum WeeklyPaceCalculator {
    public static let period: TimeInterval = 7 * 86_400
    public static let suppressAfterReset: TimeInterval = 24 * 3600
    public static let aheadThreshold: Double = 15

    /// `nil` when the input is unusable or within `suppressAfterReset` of the window start (right
    /// after a reset almost any usage reads as far ahead).
    public static func compute(usedPercent: Double, resetsAt: Date, measuredAt: Date, period: TimeInterval = 604_800,
                               suppressAfterReset: TimeInterval = 86_400, aheadThreshold: Double = 15) -> WeeklyPaceInfo? {
        guard usedPercent.isFinite, period > 0 else { return nil }
        let delta = resetsAt.timeIntervalSince1970 - measuredAt.timeIntervalSince1970
        guard delta.isFinite else { return nil }
        var remaining = delta.truncatingRemainder(dividingBy: period)
        if remaining < 0 { remaining += period }
        let elapsed = remaining == 0 ? 0 : period - remaining
        if elapsed < suppressAfterReset { return nil }

        let expected = min(100, (elapsed / period) * 100)
        let ahead = (usedPercent - expected) >= aheadThreshold

        var projected: Date?
        if elapsed > 0, usedPercent > 0 {
            let rate = usedPercent / elapsed
            if rate > 0 {
                let left = 100 - usedPercent
                projected = left <= 0 ? measuredAt : measuredAt.addingTimeInterval(left / rate)
            }
        }

        let willLast: Bool?
        if usedPercent <= 0 {
            willLast = true
        } else if elapsed <= 0 {
            willLast = nil
        } else {
            let rate = usedPercent / elapsed
            willLast = rate > 0 ? usedPercent + rate * (period - elapsed) <= 100 : nil
        }
        return WeeklyPaceInfo(aheadOfPace: ahead, projectedExhaustionAt: projected, expectedPercent: expected,
                              willLastToReset: willLast)
    }
}
