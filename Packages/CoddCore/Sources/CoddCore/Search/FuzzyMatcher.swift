import Foundation

/// A highlighted run in UTF-16 units of the ORIGINAL candidate (`NSRange`-compatible).
public struct TextSpan: Sendable, Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// A candidate that matched: higher `score` ranks first; `spans` are merged, ascending runs.
public struct FuzzyMatch: Sendable, Equatable {
    public var score: Int
    public var spans: [TextSpan]

    public init(score: Int, spans: [TextSpan]) {
        self.score = score
        self.spans = spans
    }
}

/// The ⌘K quick switch matcher (D14): titles, project names and actions mixing CJK and Latin.
///
/// Characters are compared after case, width and diacritic folding (`ＲＷＤ` = `rwd`, `é` = `e`).
/// Folding may change lengths (`ß` → `ss`), so each folded character remembers the UTF-16 range of
/// the original character it came from and spans are always reported in the original string.
///
/// Ranking, by tier: the whole candidate starts with the query > the query occurs at a word start
/// (after whitespace or `- _ . / ·`, or at a CJK↔Latin boundary) > the query occurs elsewhere >
/// the query's characters occur in order (fewer gaps and longer runs better, word starts get a
/// bonus). Within the contiguous tiers a shorter candidate (then an earlier hit) wins; among
/// subsequences the alignment quality decides first, then the length.
public enum FuzzyMatcher {
    /// Tier multiplier: every tier outranks every score of the tiers below it.
    static let tierScale = 10_000_000
    static let prefixTier = 4, wordStartTier = 3, substringTier = 2, subsequenceTier = 1

    // Subsequence quality (per matched character, per run, per gap).
    static let matchPoints = 10
    static let wordStartBonus = 12
    static let consecutiveBonus = 8
    /// Extra per character already in the run (capped), so one run of three beats two of two.
    static let runBonus = 2
    static let runBonusCap = 4
    static let gapPenalty = 4
    /// Skipped characters cost one point each, at most this many per gap.
    static let gapLengthCap = 3
    static let leadingCap = 5

    /// `nil` when the query's characters do not all occur in order. Leading and trailing query
    /// whitespace is ignored; an empty query matches everything with score 0 and no spans.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let q = folded(JSText.trim(query)).map(\.char)
        guard !q.isEmpty else { return FuzzyMatch(score: 0, spans: []) }
        let units = folded(candidate)
        guard units.count >= q.count, isSubsequence(q, of: units) else { return nil }
        let length = min(units.count, 999)

        if units.starts(with: q, by: { $1 == $0.char }) {
            return FuzzyMatch(score: tierScale * prefixTier + 5_000_000 - length * 1000,
                              spans: spans(Array(0..<q.count), in: units))
        }
        var firstHit: Int?
        var wordHit: Int?
        for start in 0...(units.count - q.count) where units[start].char == q[0] {
            var k = 1
            while k < q.count, units[start + k].char == q[k] { k += 1 }
            guard k == q.count else { continue }
            if firstHit == nil { firstHit = start }
            if units[start].wordStart { wordHit = start; break }
        }
        if let start = wordHit ?? firstHit {
            let tier = wordHit != nil ? wordStartTier : substringTier
            return FuzzyMatch(score: tierScale * tier + 5_000_000 - length * 1000 - min(start, 999),
                              spans: spans(Array(start..<(start + q.count)), in: units))
        }
        guard let (quality, positions) = bestSubsequence(q, in: units) else { return nil }
        let inner = max(0, min(tierScale - 1, 5_000_000 + quality * 1000 - length))
        return FuzzyMatch(score: tierScale * subsequenceTier + inner, spans: spans(positions, in: units))
    }

    // MARK: - Folding

    struct Unit {
        var char: Character
        /// UTF-16 range of the original character this folded character came from.
        var location: Int
        var length: Int
        var wordStart: Bool
    }

    /// One unit per folded character; an original character that folds to several (`ß`) gives
    /// several units sharing its range, only the first of which can be a word start.
    static func folded(_ s: String) -> [Unit] {
        var out: [Unit] = []
        out.reserveCapacity(s.utf16.count)
        var offset = 0
        var previous: Character?
        for ch in s {
            let length = ch.utf16.count
            let start = isWordStart(ch, after: previous)
            var first = true
            for f in fold(ch) {
                out.append(Unit(char: f, location: offset, length: length, wordStart: first && start))
                first = false
            }
            offset += length
            previous = ch
        }
        return out
    }

    private static let foldOptions: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]

    /// ASCII and CJK ideographs / kana / hangul syllables fold to themselves (fast path); every
    /// other character goes through Foundation's folding.
    static func fold(_ ch: Character) -> [Character] {
        if let ascii = ch.asciiValue {
            return [(0x41...0x5A).contains(ascii) ? Character(Unicode.Scalar(ascii + 0x20)) : ch]
        }
        if ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first, isCJKIdentity(s) { return [ch] }
        let f = String(ch).folding(options: foldOptions, locale: nil)
        return f.isEmpty ? [ch] : Array(f)
    }

    private static func isCJKIdentity(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3041...0x3096, 0x30A1...0x30FA, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0x20000...0x2FA1F: true
        default: false
        }
    }

    static func isCJK(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        switch s.value {
        case 0x2E80...0x2FDF, 0x3040...0x30FF, 0x3100...0x312F, 0x3190...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// Latin letters and digits (ASCII and their full-width forms, accented Latin letters).
    static func isLatin(_ ch: Character) -> Bool {
        if let a = ch.asciiValue { return (0x30...0x39).contains(a) || (0x41...0x5A).contains(a) || (0x61...0x7A).contains(a) }
        guard let s = ch.unicodeScalars.first else { return false }
        switch s.value {
        case 0xC0...0x24F, 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return ch.isLetter || ch.isNumber
        default: return false
        }
    }

    static let separators: Set<Character> = ["-", "_", ".", "/", "·", "・"]

    static func isWordStart(_ ch: Character, after previous: Character?) -> Bool {
        guard let previous else { return true }
        if ch.isWhitespace || separators.contains(ch) { return false }
        if previous.isWhitespace || separators.contains(previous) { return true }
        return (isCJK(previous) && isLatin(ch)) || (isLatin(previous) && isCJK(ch))
    }

    // MARK: - Matching

    private static func isSubsequence(_ q: [Character], of units: [Unit]) -> Bool {
        var i = 0
        for u in units where u.char == q[i] {
            i += 1
            if i == q.count { return true }
        }
        return false
    }

    /// Best alignment by dynamic programming (query × candidate, O(n·m)): `best[i][j]` is the best
    /// quality with query character `i` matched at unit `j`. A gap costs ``gapPenalty`` plus one per
    /// skipped unit (capped), so the best predecessor beyond the cap is a running maximum. The run
    /// bonus follows the run length of the chosen predecessor (a heuristic, not part of the optimum).
    static func bestSubsequence(_ q: [Character], in units: [Unit]) -> (Int, [Int])? {
        let n = units.count, m = q.count
        let none = Int.min / 4
        var best = [Int](repeating: none, count: m * n)
        var from = [Int](repeating: -1, count: m * n)
        var run = [Int](repeating: 1, count: m * n)
        func points(_ j: Int) -> Int { matchPoints + (units[j].wordStart ? wordStartBonus : 0) }
        for j in 0..<n where units[j].char == q[0] {
            best[j] = points(j) - min(j, leadingCap)
        }
        if m > 1 {
            for i in 1..<m {
                let row = i * n, prev = (i - 1) * n
                // Running max of best[prev + k] for k <= j - 2 - gapLengthCap (gap at the cap).
                var farBest = none, farIndex = -1
                for j in i..<n {
                    let farK = j - 2 - gapLengthCap
                    if farK >= 0, best[prev + farK] > farBest { farBest = best[prev + farK]; farIndex = farK }
                    guard units[j].char == q[i] else { continue }
                    var value = none, source = -1
                    if best[prev + j - 1] > none {
                        value = best[prev + j - 1] + consecutiveBonus + runBonus * min(run[prev + j - 1] - 1, runBonusCap)
                        source = j - 1
                    }
                    for gap in 1...gapLengthCap {
                        let k = j - 1 - gap
                        guard k >= 0, best[prev + k] > none else { continue }
                        let v = best[prev + k] - gapPenalty - gap
                        if v > value { value = v; source = k }
                    }
                    if farIndex >= 0, farBest > none {
                        let v = farBest - gapPenalty - gapLengthCap
                        if v > value { value = v; source = farIndex }
                    }
                    guard source >= 0 else { continue }
                    best[row + j] = value + points(j)
                    from[row + j] = source
                    run[row + j] = source == j - 1 ? run[prev + j - 1] + 1 : 1
                }
            }
        }
        let last = (m - 1) * n
        var end = -1, quality = none
        for j in 0..<n where best[last + j] > quality { quality = best[last + j]; end = j }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = from[i * n + j]
        }
        return (quality, positions)
    }

    /// Merged runs of the original characters behind the matched units.
    static func spans(_ positions: [Int], in units: [Unit]) -> [TextSpan] {
        var out: [TextSpan] = []
        for p in positions {
            let u = units[p]
            if let last = out.last, u.location <= last.location + last.length {
                let end = max(last.location + last.length, u.location + u.length)
                out[out.count - 1].length = end - last.location
            } else {
                out.append(TextSpan(location: u.location, length: u.length))
            }
        }
        return out
    }
}
