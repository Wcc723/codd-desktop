import Foundation

/// ISO 8601 dates as notes and state files carry them: `2026-10-14T18:20:11+08:00` (written in the
/// library's time zone, seconds precision), read leniently (fractions, `Z`, `+0800`, date only).
/// Hand-written instead of a formatter so it is `Sendable`, allocation-light and exact.
enum ISODate {
    static func format(_ date: Date, timeZone: TimeZone) -> String {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let offset = timeZone.secondsFromGMT(for: date)
        let local = seconds + offset
        let days = Int((Double(local) / 86_400).rounded(.down))
        var secOfDay = local - days * 86_400
        if secOfDay < 0 { secOfDay += 86_400 }
        let (y, m, d) = civil(fromDays: days)
        let hh = secOfDay / 3600, mm = (secOfDay % 3600) / 60, ss = secOfDay % 60
        var s = "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(hh, 2)):\(pad(mm, 2)):\(pad(ss, 2))"
        if offset == 0 {
            s += "Z"
        } else {
            let a = abs(offset)
            s += (offset < 0 ? "-" : "+") + pad(a / 3600, 2) + ":" + pad((a % 3600) / 60, 2)
        }
        return s
    }

    /// Parses `YYYY-MM-DD[THH:MM[:SS[.fff]]][Z|±HH:MM|±HHMM|±HH]`. A value without an offset is
    /// read in `timeZone`; a date alone is that day's local midnight.
    static func parse(_ text: String, timeZone: TimeZone) -> Date? {
        var u = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        if u.first == UInt8(ascii: "\""), u.last == UInt8(ascii: "\""), u.count >= 2 { u = Array(u[1..<(u.count - 1)]) }
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= u.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = u[i + k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += n
            return v
        }
        func take(_ c: Character) -> Bool {
            if i < u.count, u[i] == c.asciiValue! { i += 1; return true }
            return false
        }
        guard let y = digits(4), take("-"), let mo = digits(2), take("-"), let d = digits(2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var hh = 0, mm = 0, ss = 0
        var frac = 0.0
        var offset: Int?
        if i < u.count, u[i] == UInt8(ascii: "T") || u[i] == UInt8(ascii: "t") || u[i] == UInt8(ascii: " ") {
            i += 1
            guard let h = digits(2), take(":"), let mi = digits(2), h < 24, mi < 60 else { return nil }
            hh = h; mm = mi
            if take(":") {
                guard let s = digits(2), s <= 60 else { return nil }
                ss = min(s, 59)
                if take(".") || take(",") {
                    var scale = 0.1
                    while i < u.count, u[i] >= 48, u[i] <= 57 {
                        frac += Double(u[i] - 48) * scale
                        scale /= 10
                        i += 1
                    }
                }
            }
            if i < u.count {
                if u[i] == UInt8(ascii: "Z") || u[i] == UInt8(ascii: "z") {
                    i += 1
                    offset = 0
                } else if u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") {
                    let sign = u[i] == UInt8(ascii: "-") ? -1 : 1
                    i += 1
                    guard let oh = digits(2) else { return nil }
                    var om = 0
                    if take(":") {
                        guard let m2 = digits(2) else { return nil }
                        om = m2
                    } else if let m2 = digits(2) {
                        om = m2
                    }
                    offset = sign * (oh * 3600 + om * 60)
                }
            }
        }
        guard i == u.count else { return nil }
        let days = daysFromCivil(y, mo, d)
        let local = Double(days * 86_400 + hh * 3600 + mm * 60 + ss) + frac
        if let offset { return Date(timeIntervalSince1970: local - Double(offset)) }
        // No offset: interpret in the given zone (two passes settle DST edges).
        var guess = Date(timeIntervalSince1970: local - Double(timeZone.secondsFromGMT()))
        guess = Date(timeIntervalSince1970: local - Double(timeZone.secondsFromGMT(for: guess)))
        return guess
    }

    /// `yyyyMMdd-HHmmss-SSS` in UTC (history snapshot names).
    static func compactUTC(_ date: Date) -> String {
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = Int((Double(ms) / 1000).rounded(.down))
        let days = Int((Double(seconds) / 86_400).rounded(.down))
        let secOfDay = seconds - days * 86_400
        let (y, m, d) = civil(fromDays: days)
        return "\(pad(y, 4))\(pad(m, 2))\(pad(d, 2))-\(pad(secOfDay / 3600, 2))\(pad((secOfDay % 3600) / 60, 2))\(pad(secOfDay % 60, 2))-\(pad(ms - seconds * 1000, 3))"
    }

    static func parseCompactUTC(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[8] == UInt8(ascii: "-"), u[15] == UInt8(ascii: "-") else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for k in r {
                guard u[k] >= 48, u[k] <= 57 else { return nil }
                v = v * 10 + Int(u[k] - 48)
            }
            return v
        }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8), let h = num(9..<11), let mi = num(11..<13),
              let se = num(13..<15), let ms = num(16..<19) else { return nil }
        let days = daysFromCivil(y, mo, d)
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + mi * 60 + se) + Double(ms) / 1000)
    }

    private static func pad(_ v: Int, _ n: Int) -> String {
        let s = String(v)
        return s.count >= n ? s : String(repeating: "0", count: n - s.count) + s
    }

    // Howard Hinnant's civil-from-days algorithms (proleptic Gregorian).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

/// Local calendar helpers in an explicit time zone (no `Calendar.current` surprises in tests).
struct LocalCalendar: Sendable {
    let timeZone: TimeZone

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }

    func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    func date(year: Int, month: Int, day: Int) -> Date? {
        var dc = DateComponents()
        dc.year = year
        dc.month = month
        dc.day = day
        return calendar.date(from: dc)
    }

    /// `M/dd` (`9/24`, `9/01`).
    func monthDay(_ date: Date) -> String {
        let c = components(date)
        let d = c.day ?? 1
        return "\(c.month ?? 1)/\(d < 10 ? "0" : "")\(d)"
    }

    /// `M/d` (`10/15`), the quick-note title form.
    func shortMonthDay(_ date: Date) -> String {
        let c = components(date)
        return "\(c.month ?? 1)/\(c.day ?? 1)"
    }

    /// `yyyy-MM-dd HH:mm`.
    func dateTime(_ date: Date) -> String {
        let c = components(date)
        func p(_ v: Int?) -> String { let x = v ?? 0; return x < 10 ? "0\(x)" : "\(x)" }
        return "\(c.year ?? 0)-\(p(c.month))-\(p(c.day)) \(p(c.hour)):\(p(c.minute))"
    }

    /// `HH:mm`.
    func time(_ date: Date) -> String {
        let c = components(date)
        func p(_ v: Int?) -> String { let x = v ?? 0; return x < 10 ? "0\(x)" : "\(x)" }
        return "\(p(c.hour)):\(p(c.minute))"
    }

    /// `yyyy-MM-dd`.
    func day(_ date: Date) -> String {
        let c = components(date)
        func p(_ v: Int?) -> String { let x = v ?? 0; return x < 10 ? "0\(x)" : "\(x)" }
        return "\(c.year ?? 0)-\(p(c.month))-\(p(c.day))"
    }

    /// Whole days from `from` to `to` (floor of elapsed 24 h periods, never negative).
    static func days(from: Date, to: Date) -> Int {
        max(0, Int((to.timeIntervalSince(from) / 86_400).rounded(.down)))
    }
}
