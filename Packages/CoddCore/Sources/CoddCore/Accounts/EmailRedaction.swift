import Foundation

/// D31: cswap output carries account e-mails in many places (switch `message` / `warnings`, `add`'s
/// stdout, personal `organizationName`s, error texts). Every string that comes from cswap passes
/// through ``redact(_:)`` before it is logged, dumped or shown.
///
/// A hand-written scanner rather than a regex: it never backtracks, needs no shared regex object
/// across concurrency domains, and errs on the side of redacting too much (letters of any script
/// count as e-mail characters, so CJK text glued to an address is redacted with it).
public enum EmailRedaction {
    public static let placeholder = "•••@•••"

    /// `text` with every e-mail-like token (`local@domain.tld`, also the percent-encoded `%40`
    /// form) replaced by ``placeholder``.
    public static func redact(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let found = ranges(in: scalars)
        guard !found.isEmpty else { return text }
        var out = String.UnicodeScalarView()
        var i = 0
        for r in found {
            out.append(contentsOf: scalars[i..<r.lowerBound])
            out.append(contentsOf: placeholder.unicodeScalars)
            i = r.upperBound
        }
        out.append(contentsOf: scalars[i...])
        return String(out)
    }

    /// Whether `text` contains an e-mail-like token.
    public static func containsEmail(_ text: String) -> Bool {
        !ranges(in: Array(text.unicodeScalars)).isEmpty
    }

    /// Scalar ranges of the e-mail-like tokens, in order, non-overlapping.
    static func ranges(in s: [Unicode.Scalar]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        var floor = 0 // a token never reaches back into the previous one
        while i < s.count {
            let atLength: Int
            if s[i] == "@" {
                atLength = 1
            } else if s[i] == "%", i + 2 < s.count, s[i + 1] == "4", s[i + 2] == "0" {
                atLength = 3
            } else {
                i += 1
                continue
            }
            var start = i
            while start > floor, isLocal(s[start - 1]) { start -= 1 }
            var end = i + atLength
            while end < s.count, isDomain(s[end]) { end += 1 }
            // A sentence-final "." or a trailing "-" is not part of the domain.
            while end > i + atLength, s[end - 1] == "." || s[end - 1] == "-" { end -= 1 }
            if start < i, isDomainName(s[(i + atLength)..<end]) {
                out.append(start..<end)
                floor = end
                i = end
            } else {
                i += atLength
            }
        }
        return out
    }

    /// `label(.label)+` whose last label is at least two letters.
    private static func isDomainName(_ d: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let first = d.first, first != ".", first != "-" else { return false }
        let labels = d.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty), let tld = labels.last else { return false }
        return tld.count >= 2 && tld.allSatisfy { $0.properties.isAlphabetic }
    }

    private static func isLocal(_ c: Unicode.Scalar) -> Bool {
        isWordScalar(c) || c == "." || c == "_" || c == "%" || c == "+" || c == "-"
    }

    private static func isDomain(_ c: Unicode.Scalar) -> Bool {
        isWordScalar(c) || c == "." || c == "-"
    }

    private static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII {
            let v = c.value
            return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
        }
        return c.properties.isAlphabetic || c.properties.numericType != nil
    }
}
