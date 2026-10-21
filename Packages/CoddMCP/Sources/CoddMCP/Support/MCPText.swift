import Foundation

/// Dates in tool output, formatted by hand from calendar components (no shared DateFormatter
/// across concurrent requests, no locale surprises).
struct MCPDateText: Sendable {
    let calendar: Calendar

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func pad(_ value: Int?, _ width: Int = 2) -> String {
        let text = String(value ?? 0)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    /// RFC 3339 with the zone's offset, like the note frontmatter: `2026-10-15T10:05:44+08:00`
    /// (`Z` for UTC).
    func iso(_ date: Date) -> String {
        let c = parts(date)
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let zone: String
        if offset == 0 {
            zone = "Z"
        } else {
            let minutes = abs(offset) / 60
            zone = (offset < 0 ? "-" : "+") + Self.pad(minutes / 60) + ":" + Self.pad(minutes % 60)
        }
        return Self.pad(c.year, 4) + "-" + Self.pad(c.month) + "-" + Self.pad(c.day) + "T"
            + Self.pad(c.hour) + ":" + Self.pad(c.minute) + ":" + Self.pad(c.second) + zone
    }

    /// `2026-11-14`.
    func day(_ date: Date) -> String {
        let c = parts(date)
        return Self.pad(c.year, 4) + "-" + Self.pad(c.month) + "-" + Self.pad(c.day)
    }

    /// `10/15 10:05` in the current year, `2025/10/15 10:05` otherwise (the artboards' `9/24`).
    func short(_ date: Date, now: Date) -> String {
        let c = parts(date)
        let time = Self.pad(c.hour) + ":" + Self.pad(c.minute)
        let monthDay = "\(c.month ?? 0)/\(c.day ?? 0)"
        if calendar.component(.year, from: now) == c.year { return monthDay + " " + time }
        return "\(c.year ?? 0)/" + monthDay + " " + time
    }
}

enum MCPText {
    /// At most `limit` characters, with `…` when cut (refs and queries echoed in messages).
    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// Newlines and tabs folded to single spaces: one result per line in list output. Between two
    /// non-ASCII characters (CJK text wrapped across lines) nothing is inserted, as Chinese text
    /// has no spaces between words.
    static func oneLine(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isNewline || character == "\t" {
                while out.last == " " { out.removeLast() }
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                if character == " " { continue }  // indentation of the next line
                let joinsCJK = !character.isASCII && out.last.map { !$0.isASCII } == true
                if !joinsCJK { out.append(" ") }
                pendingSpace = false
            }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
