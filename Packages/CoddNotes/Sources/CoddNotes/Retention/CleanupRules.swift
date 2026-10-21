import Foundation

/// §3.4 long-note rule: H2 / H3 sections whose heading starts with a date.
enum DatedSections {
    /// Every H2 / H3 section (outside code blocks) of `body` whose heading starts with
    /// `2026-09-03`, `2026/09/03`, `9/03`, `09/03` or `9/3`. A date without a year takes the year of
    /// `now`, or the year before when that would lie in the future.
    static func sections(in body: String, now: Date, calendar: LocalCalendar) -> [NoteSection] {
        let lines = BodyLines.split(body)
        var headings: [(line: Int, level: Int, text: String)] = []
        var fence: Fence?
        for (k, l) in lines.enumerated() {
            if let f = fence {
                if f.closes(l.text) { fence = nil }
                continue
            }
            if let f = Fence(opening: l.text) {
                fence = f
                continue
            }
            if let (level, text) = heading(l.text) { headings.append((k, level, text)) }
        }
        let ns = body as NSString
        var out: [NoteSection] = []
        for (n, h) in headings.enumerated() where h.level == 2 || h.level == 3 {
            guard let date = leadingDate(h.text, now: now, calendar: calendar) else { continue }
            var endLine = lines.count
            for later in headings[(n + 1)...] where later.level <= h.level {
                endLine = later.line
                break
            }
            let start = lines[h.line].offset
            let end = endLine < lines.count ? lines[endLine].offset : ns.length
            let range = NSRange(location: start, length: max(0, end - start))
            out.append(NoteSection(heading: h.text, date: date, range: range, text: ns.substring(with: range)))
        }
        return out
    }

    static func heading(_ line: String) -> (Int, String)? {
        var t = Substring(line)
        var indent = 0
        while t.first == " ", indent < 3 {
            t.removeFirst()
            indent += 1
        }
        var level = 0
        while t.first == "#", level < 7 {
            t.removeFirst()
            level += 1
        }
        guard (1...6).contains(level), t.isEmpty || t.first == " " || t.first == "\t" else { return nil }
        var text = t.trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: " #+$", options: .regularExpression) { text.removeSubrange(r) }
        return (level, text)
    }

    static func leadingDate(_ text: String, now: Date, calendar: LocalCalendar) -> Date? {
        let u = Array(text.utf8)
        var i = 0
        func number(max: Int) -> (Int, Int)? {
            var v = 0, n = 0
            while i < u.count, n < max, u[i] >= 48, u[i] <= 57 {
                v = v * 10 + Int(u[i] - 48)
                i += 1
                n += 1
            }
            return n == 0 ? nil : (v, n)
        }
        guard let (a, an) = number(max: 4) else { return nil }
        guard i < u.count, u[i] == UInt8(ascii: "-") || u[i] == UInt8(ascii: "/") else { return nil }
        let sep = u[i]
        i += 1
        guard let (b, _) = number(max: 2) else { return nil }
        var year: Int?
        var month: Int
        var day: Int
        if an == 4 {
            guard i < u.count, u[i] == sep else { return nil }
            i += 1
            guard let (c, _) = number(max: 2) else { return nil }
            year = a
            month = b
            day = c
        } else {
            guard sep == UInt8(ascii: "/") else { return nil }
            month = a
            day = b
        }
        // The date must end the token (`9/03 會議`, `2026-09-03：…`), not run into more digits.
        if i < u.count, u[i] >= 48, u[i] <= 57 { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        if let year { return calendar.date(year: year, month: month, day: day) }
        let thisYear = calendar.components(now).year ?? 2026
        guard let d = calendar.date(year: thisYear, month: month, day: day) else { return nil }
        if d > now.addingTimeInterval(86_400) { return calendar.date(year: thisYear - 1, month: month, day: day) }
        return d
    }
}

/// Near-duplicate detection (§3.4): trigram Jaccard ≥ 0.80. Candidate pairs come from MinHash
/// with LSH banding (16 bands × 4 rows), so a notebook of a few thousand notes is not compared
/// pairwise; every candidate pair is then measured exactly.
enum Similarity {
    static let hashes = 64
    static let bands = 16

    static func trigrams(_ text: String) -> Set<UInt64> {
        // Collapse whitespace so reflowed text still matches.
        var scalars: [UInt32] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        var lastSpace = true
        for u in SearchFold.fold(text).unicodeScalars {
            if u.properties.isWhitespace {
                if !lastSpace { scalars.append(32) }
                lastSpace = true
            } else {
                scalars.append(u.value)
                lastSpace = false
            }
        }
        var out = Set<UInt64>()
        guard scalars.count >= 3 else { return out }
        out.reserveCapacity(scalars.count)
        for k in 0..<(scalars.count - 2) {
            out.insert(UInt64(scalars[k]) << 42 ^ UInt64(scalars[k + 1]) << 21 ^ UInt64(scalars[k + 2]))
        }
        return out
    }

    static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let (small, large) = a.count < b.count ? (a, b) : (b, a)
        var inter = 0
        for x in small where large.contains(x) { inter += 1 }
        return Double(inter) / Double(a.count + b.count - inter)
    }

    static func mix(_ x: UInt64, _ seed: UInt64) -> UInt64 {
        var z = x &+ seed &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func signature(_ set: Set<UInt64>) -> [UInt64] {
        var sig = [UInt64](repeating: .max, count: hashes)
        for x in set {
            for k in 0..<hashes {
                let h = mix(x, UInt64(k + 1))
                if h < sig[k] { sig[k] = h }
            }
        }
        return sig
    }

    /// Pairs (i, j), i < j, whose Jaccard is ≥ `threshold`, with the value.
    static func pairs(_ sets: [Set<UInt64>], threshold: Double) -> [(Int, Int, Double)] {
        let sigs = sets.map(signature)
        let rows = hashes / bands
        var candidates = Set<Int>()
        for b in 0..<bands {
            var buckets: [[UInt64]: [Int]] = [:]
            for (i, sig) in sigs.enumerated() where !sets[i].isEmpty {
                buckets[Array(sig[(b * rows)..<((b + 1) * rows)]), default: []].append(i)
            }
            for members in buckets.values where members.count > 1 {
                for x in 0..<members.count {
                    for y in (x + 1)..<members.count { candidates.insert(members[x] << 32 | members[y]) }
                }
            }
        }
        var out: [(Int, Int, Double)] = []
        for c in candidates {
            let i = c >> 32, j = c & 0xFFFF_FFFF
            // Jaccard ≥ t needs the smaller set to be at least t of the larger.
            let (s1, s2) = (sets[i].count, sets[j].count)
            guard Double(min(s1, s2)) >= threshold * Double(max(s1, s2)) else { continue }
            let jac = jaccard(sets[i], sets[j])
            if jac >= threshold { out.append((min(i, j), max(i, j), jac)) }
        }
        return out.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
    }

    /// A short label for the other note in `近似重複（與<label> 82% 相同）`: the part of its title
    /// that differs from this note's (`keynote 第 3 章大綱` vs `keynote 第 2 章大綱` → `第 3 章`),
    /// or the whole title in 「」 when the titles share no useful affix.
    static func differenceLabel(mine: String, other: String) -> String {
        let a = Array(mine), b = Array(other)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        guard p > 0 || s > 0, p + s < b.count else { return "「\(other)」" }
        // Widen to whole words: back to the previous blank, keeping a one-character lead (`第`).
        var start = p
        while start > 0, b[start - 1] != " " { start -= 1 }
        if start == p, start > 0 {
            // Already at a word start: keep the preceding short word (`第 3`).
            var w = start - 1
            while w > 0, b[w - 1] == " " { w -= 1 }
            var ws = w
            while ws > 0, b[ws - 1] != " " { ws -= 1 }
            if w - ws <= 1 { start = ws }
        }
        var end = b.count - s
        // Keep the first character of the shared tail when it is a counter / unit (`章`).
        if end < b.count, b[end] == " ", end + 1 < b.count { end += 2 } else if end < b.count, b[end] != " " { end += 1 }
        end = min(end, b.count)
        let label = String(b[start..<end]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count < other.count else { return "「\(other)」" }
        return label
    }
}
