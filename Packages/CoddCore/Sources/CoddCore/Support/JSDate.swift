import Foundation

/// JavaScript-compatible timestamp helpers.
///
/// JS `Date` values are integer milliseconds since the epoch. The ported logic stores timestamps
/// as `toISOString()` strings and compares them with `Date.parse`, so these helpers work on
/// integer milliseconds to avoid floating-point drift.
public enum JSDate {
    /// Largest |time value| ECMAScript accepts (±100,000,000 days).
    static let maxTimeValue: Int64 = 8_640_000_000_000_000

    /// Milliseconds since the epoch for a `Date`, rounded to the nearest millisecond.
    public static func milliseconds(_ date: Date) -> Int64 {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        guard ms.isFinite else { return 0 }
        return Int64(min(max(ms, -Double(maxTimeValue)), Double(maxTimeValue)))
    }

    /// A `Date` for integer epoch milliseconds (exact round trip with ``milliseconds(_:)``).
    public static func date(milliseconds ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// `new Date(date).toISOString()`, e.g. `2026-10-15T02:42:00.000Z`.
    /// Dates outside the JS range are clamped to it.
    public static func isoString(_ date: Date) -> String {
        format(milliseconds: min(max(milliseconds(date), -maxTimeValue), maxTimeValue))
    }

    /// `new Date(ms).toISOString()` for integer milliseconds (`nil` when out of the JS range).
    public static func isoString(milliseconds ms: Int64) -> String? {
        abs(ms) <= maxTimeValue ? format(milliseconds: ms) : nil
    }

    private static func format(milliseconds ms: Int64) -> String {
        let (days, msOfDay) = floorDivMod(ms, 86_400_000)
        let (y, m, d) = civil(fromDays: days)
        let hh = msOfDay / 3_600_000
        let mm = (msOfDay / 60_000) % 60
        let ss = (msOfDay / 1000) % 60
        let mmm = msOfDay % 1000
        let year: String
        if (0...9999).contains(y) {
            year = pad(y, 4)
        } else {
            year = (y < 0 ? "-" : "+") + pad(abs(y), 6)
        }
        return "\(year)-\(pad(m, 2))-\(pad(d, 2))T\(pad(hh, 2)):\(pad(mm, 2)):\(pad(ss, 2)).\(pad(mmm, 3))Z"
    }

    /// `Date.parse(s)` restricted to the ECMAScript date-time string format
    /// (`YYYY[-MM[-DD]][THH:mm[:ss[.fraction]]][Z|±HH:mm]`, expanded `±YYYYYY` years, any number of
    /// fraction digits). Date-only forms are UTC; date-time forms without an offset are local time,
    /// as in ECMAScript. Returns integer milliseconds, or `nil` for anything else.
    ///
    /// Intentional gap: V8 also accepts legacy formats (`"Thu Oct 15 2026"`, `"2026/10/15"`); those
    /// yield `nil` here. None of the ported data sources produce them.
    public static func parse(_ s: String, timeZone: TimeZone = .current) -> Int64? {
        var p = Scanner(Array(s.utf8))
        guard let year = p.year(), let ms = p.dateTimeRest(year: year, timeZone: timeZone), p.atEnd else {
            return nil
        }
        return abs(ms) <= maxTimeValue ? ms : nil
    }

    /// `Date` for an ISO string accepted by ``parse(_:timeZone:)``.
    public static func date(fromISO s: String?) -> Date? {
        guard let s, let ms = parse(s) else { return nil }
        return date(milliseconds: ms)
    }

    /// session-insights.js `toIso(v)`: ISO string / epoch seconds / epoch milliseconds → ISO string.
    /// Numbers must be finite and > 0; values > 1e12 are milliseconds, others seconds. Fractional
    /// milliseconds are truncated (ECMAScript TimeClip).
    public static func toISO(_ value: JSONValue?) -> String? {
        timestamp(value).flatMap { isoString(milliseconds: $0) }
    }

    /// The millisecond value behind ``toISO(_:)``.
    public static func timestamp(_ value: JSONValue?) -> Int64? {
        switch value {
        case .number(let n)? where n.isFinite && n > 0:
            let msDouble = n > 1e12 ? n : n * 1000
            guard msDouble <= Double(maxTimeValue) else { return nil }
            return Int64(msDouble.rounded(.towardZero))
        case .string(let s)? where !JSText.trim(s).isEmpty:
            return parse(s)
        default:
            return nil
        }
    }

    // MARK: - Calendar math (proleptic Gregorian, H. Hinnant's algorithms)

    static func days(fromCivil y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }

    private static func floorDivMod(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        let q = a / b, r = a % b
        return r < 0 ? (q - 1, r + b) : (q, r)
    }

    private static func pad(_ v: Int64, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func daysInMonth(_ y: Int64, _ m: Int64) -> Int64 {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Minimal byte scanner for the ECMAScript date-time string format.
    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        var atEnd: Bool { i == b.count }

        mutating func eat(_ c: UInt8) -> Bool {
            guard i < b.count, b[i] == c else { return false }
            i += 1
            return true
        }

        mutating func digits(_ n: Int) -> Int64? {
            guard i + n <= b.count else { return nil }
            var v: Int64 = 0
            for k in 0..<n {
                let c = b[i + k]
                guard (0x30...0x39).contains(c) else { return nil }
                v = v * 10 + Int64(c - 0x30)
            }
            i += n
            return v
        }

        mutating func year() -> Int64? {
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
                let negative = b[i] == 0x2D
                i += 1
                guard let y = digits(6), !(negative && y == 0) else { return nil }
                return negative ? -y : y
            }
            return digits(4)
        }

        mutating func dateTimeRest(year: Int64, timeZone: TimeZone) -> Int64? {
            var month: Int64 = 1, day: Int64 = 1
            if eat(0x2D) {
                guard let m = digits(2), (1...12).contains(m) else { return nil }
                month = m
                if eat(0x2D) {
                    guard let d = digits(2), d >= 1, d <= JSDate.daysInMonth(year, m) else { return nil }
                    day = d
                }
            }
            let dayMs = JSDate.days(fromCivil: year, month, day) * 86_400_000
            guard eat(0x54) else { return atEnd ? dayMs : nil } // date-only: UTC
            guard let hh = digits(2), eat(0x3A), let mm = digits(2) else { return nil }
            var ss: Int64 = 0, frac: Int64 = 0
            if eat(0x3A) {
                guard let s = digits(2) else { return nil }
                ss = s
                if eat(0x2E) {
                    var count = 0
                    var value: Int64 = 0
                    while i < b.count, (0x30...0x39).contains(b[i]) {
                        if count < 3 { value = value * 10 + Int64(b[i] - 0x30) }
                        count += 1
                        i += 1
                    }
                    guard count > 0 else { return nil }
                    if count < 3 { for _ in 0..<(3 - count) { value *= 10 } }
                    frac = value
                }
            }
            guard hh < 24 || (hh == 24 && mm == 0 && ss == 0 && frac == 0), mm < 60, ss < 60 else { return nil }
            let local = dayMs + ((hh * 60 + mm) * 60 + ss) * 1000 + frac
            if eat(0x5A) { return local }
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
                let sign: Int64 = b[i] == 0x2B ? 1 : -1
                i += 1
                guard let oh = digits(2), eat(0x3A), let om = digits(2), oh < 24, om < 60 else { return nil }
                return local - sign * (oh * 60 + om) * 60_000
            }
            // No offset on a date-time form: local time (ECMAScript rule).
            let approx = JSDate.date(milliseconds: local)
            let offset = Int64(timeZone.secondsFromGMT(for: approx)) * 1000
            return local - offset
        }
    }
}
