import Foundation

/// Ids and file names (D3). Ids are short and readable for `codd://note/<id>` (`rwd-punch-k7x2`);
/// file names are set once at creation and never renamed, so pasted paths stay valid.
public enum NoteNaming {
    static let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// Up to two ASCII words from the title, then from the tags (lowercased, `[a-z0-9]+`, deduped,
    /// ≤ 20 characters, else `note`) + `-` + 4 random base36 characters. `taken` sees every candidate
    /// (the index and the tombstones), so a purged note's id is never handed out again.
    public static func makeID(title: String, tags: [String], taken: (NoteID) -> Bool) -> NoteID {
        var rng = SystemRandomNumberGenerator()
        return makeID(title: title, tags: tags, taken: taken, using: &rng)
    }

    public static func makeID(title: String, tags: [String], taken: (NoteID) -> Bool,
                              using rng: inout some RandomNumberGenerator) -> NoteID {
        makeID(prefix: idPrefix(title: title, tags: tags), taken: taken, using: &rng)
    }

    /// `<prefix>-xxxx` for a caller-chosen prefix (`cleanup-1015`); an invalid prefix becomes `note`.
    public static func makeID(prefix rawPrefix: String, taken: (NoteID) -> Bool) -> NoteID {
        var rng = SystemRandomNumberGenerator()
        return makeID(prefix: rawPrefix, taken: taken, using: &rng)
    }

    static func makeID(prefix rawPrefix: String, taken: (NoteID) -> Bool, using rng: inout some RandomNumberGenerator) -> NoteID {
        let prefix = rawPrefix.count <= 30 && NoteID(rawValue: rawPrefix) != nil ? rawPrefix : "note"
        while true {
            for _ in 0..<64 {
                var s = prefix + "-"
                for _ in 0..<4 { s.append(base36[Int.random(in: 0..<36, using: &rng)]) }
                if let id = NoteID(rawValue: s), !taken(id) { return id }
            }
            // 64 misses in a row means the 4-character space of this prefix is nearly full: widen.
            for _ in 0..<64 {
                var s = prefix + "-"
                for _ in 0..<8 { s.append(base36[Int.random(in: 0..<36, using: &rng)]) }
                if let id = NoteID(rawValue: s), !taken(id) { return id }
            }
        }
    }

    static func idPrefix(title: String, tags: [String]) -> String {
        var words: [String] = []
        for source in [title] + tags {
            for w in asciiWords(source) where !words.contains(w) {
                words.append(w)
            }
        }
        var prefix = ""
        for w in words.prefix(2) {
            let candidate = prefix.isEmpty ? w : prefix + "-" + w
            if candidate.count <= 20 {
                prefix = candidate
            } else if prefix.isEmpty {
                prefix = String(w.prefix(20))
            }
        }
        return prefix.isEmpty ? "note" : prefix
    }

    /// The `[a-z0-9]+` runs of the NFKC-lowercased text (full-width `ＲＷＤ` counts as `rwd`).
    static func asciiWords(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var out: [String] = []
        var current = ""
        for u in folded.unicodeScalars {
            if (u >= "a" && u <= "z") || (u >= "0" && u <= "9") {
                current.unicodeScalars.append(u)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `YYYY-MM-DD-<slug>.md` (NFC): the title with CJK kept, ASCII lowercased, whitespace and
    /// punctuation → `-` (collapsed, ≤ 48 graphemes, else `note`); `-2`, `-3` … when `taken`.
    public static func fileName(title: String, date: Date, timeZone: TimeZone, taken: (String) -> Bool) -> String {
        let day = LocalCalendar(timeZone: timeZone).day(date)
        let base = "\(day)-\(slug(title))"
        var name = base + ".md"
        var n = 2
        while taken(name) {
            name = "\(base)-\(n).md"
            n += 1
        }
        return name
    }

    static func slug(_ title: String) -> String {
        var out = ""
        var lastHyphen = true
        for ch in title.precomposedStringWithCanonicalMapping {
            let keep = ch.unicodeScalars.allSatisfy { u in
                let p = u.properties
                return p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark
                    || p.generalCategory == .spacingMark
            }
            if keep {
                out += ch.isASCII ? ch.lowercased() : String(ch)
                lastHyphen = false
            } else if !lastHyphen {
                out += "-"
                lastHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 48 {
            out = String(out.prefix(48))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "note" : out
    }

    /// The id of a file without a usable `id:` (no frontmatter, or one CODD cannot parse): the
    /// file name's ASCII words (≤ 20 characters, else `note`) + 4 hex of a hash of its relative
    /// path, so it is the same at every rebuild.
    static func derivedID(relativePath: String) -> NoteID {
        let name = (relativePath as NSString).lastPathComponent
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        var prefix = ""
        for w in asciiWords(stem) {
            let candidate = prefix.isEmpty ? w : prefix + "-" + w
            if candidate.count > 20 { break }
            prefix = candidate
        }
        if prefix.isEmpty { prefix = "note" }
        let hash = Hashing.sha256Hex(relativePath.precomposedStringWithCanonicalMapping)
        return NoteID(rawValue: "\(prefix)-\(hash.prefix(4))") ?? NoteID(rawValue: "note-\(hash.prefix(4))")!
    }
}
