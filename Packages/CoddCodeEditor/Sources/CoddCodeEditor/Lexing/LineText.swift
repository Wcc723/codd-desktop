import Foundation

/// ASCII code units the lexers compare against (UTF-16, like `NSString` and `NSRange`).
enum A {
    static let tab: UInt16 = 0x09
    static let lf: UInt16 = 0x0A
    static let cr: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let bang: UInt16 = 0x21
    static let dquote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let percent: UInt16 = 0x25
    static let amp: UInt16 = 0x26
    static let squote: UInt16 = 0x27
    static let lparen: UInt16 = 0x28
    static let rparen: UInt16 = 0x29
    static let star: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let comma: UInt16 = 0x2C
    static let minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let lt: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let gt: UInt16 = 0x3E
    static let question: UInt16 = 0x3F
    static let at: UInt16 = 0x40
    static let lbracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let rbracket: UInt16 = 0x5D
    static let caret: UInt16 = 0x5E
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lbrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C
    static let rbrace: UInt16 = 0x7D
    static let tilde: UInt16 = 0x7E

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) static func isHex(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
    @inline(__always) static func isAsciiLetter(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
    @inline(__always) static func isSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C || c == 0x0B || c == 0xA0 || c == 0x3000
    }
    /// Letters, `_`, and any non-ASCII unit except spaces (identifiers may be 中文 in JS / Swift / Python).
    @inline(__always) static func isIdentStart(_ c: UInt16) -> Bool {
        isAsciiLetter(c) || c == 0x5F || (c >= 0x80 && c != 0xA0 && c != 0x3000 && c != 0x2028 && c != 0x2029)
    }
    @inline(__always) static func isIdentPart(_ c: UInt16) -> Bool {
        isIdentStart(c) || isDigit(c)
    }
    /// Lowercase an ASCII letter (other units unchanged).
    @inline(__always) static func lower(_ c: UInt16) -> UInt16 {
        (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c
    }
}

/// One line's UTF-16 code units (no line terminator) with the scanning helpers every lexer uses.
/// Out-of-range reads return 0, so look-ahead never needs a bounds check.
struct LineText {
    let units: UnsafeBufferPointer<UInt16>

    var count: Int { units.count }

    @inline(__always) subscript(_ i: Int) -> UInt16 {
        i >= 0 && i < units.count ? units[i] : 0
    }

    /// `ascii` (ASCII only) at `i`.
    func has(_ ascii: StaticString, at i: Int) -> Bool {
        let n = ascii.utf8CodeUnitCount
        guard i >= 0, i + n <= units.count else { return false }
        let p = ascii.utf8Start
        for k in 0 ..< n where units[i + k] != UInt16(p[k]) { return false }
        return true
    }

    /// `ascii` (lowercase ASCII) at `i`, ignoring the case of the line.
    func hasIgnoringCase(_ ascii: StaticString, at i: Int) -> Bool {
        let n = ascii.utf8CodeUnitCount
        guard i >= 0, i + n <= units.count else { return false }
        let p = ascii.utf8Start
        for k in 0 ..< n where A.lower(units[i + k]) != UInt16(p[k]) { return false }
        return true
    }

    /// The first index ≥ `from` where `ascii` starts, before `end`.
    func find(_ ascii: StaticString, from: Int, end: Int? = nil, ignoringCase: Bool = false) -> Int? {
        let limit = min(end ?? units.count, units.count)
        let n = ascii.utf8CodeUnitCount
        guard n > 0 else { return from }
        var i = max(0, from)
        let first = UInt16(ascii.utf8Start[0])
        while i + n <= limit {
            let c = ignoringCase ? A.lower(units[i]) : units[i]
            if c == first, ignoringCase ? hasIgnoringCase(ascii, at: i) : has(ascii, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// The first index ≥ `from` holding `unit`, before `end`.
    func find(unit: UInt16, from: Int, end: Int? = nil) -> Int? {
        let limit = min(end ?? units.count, units.count)
        var i = max(0, from)
        while i < limit {
            if units[i] == unit { return i }
            i += 1
        }
        return nil
    }

    @inline(__always) func skipSpaces(_ from: Int, end: Int? = nil) -> Int {
        let limit = min(end ?? units.count, units.count)
        var i = from
        while i < limit, A.isSpace(units[i]) { i += 1 }
        return i
    }

    /// End of an identifier starting at `from` (`extra` admits more characters, e.g. `-` in CSS).
    @inline(__always) func identEnd(_ from: Int, end: Int? = nil, extra: UInt16 = 0, extra2: UInt16 = 0) -> Int {
        let limit = min(end ?? units.count, units.count)
        var i = from
        while i < limit {
            let c = units[i]
            if A.isIdentPart(c) || (extra != 0 && c == extra) || (extra2 != 0 && c == extra2) { i += 1 } else { break }
        }
        return i
    }

    func text(_ start: Int, _ end: Int) -> String {
        guard end > start else { return "" }
        return String(utf16CodeUnits: units.baseAddress! + start, count: end - start)
    }

    /// The first non-space index (the line's indentation width in units).
    var indent: Int { skipSpaces(0) }

    /// Only spaces.
    var isBlank: Bool { skipSpaces(0) >= units.count }

    /// Scans a quoted string from the opening quote at `start`; returns the index after the
    /// closing quote, or nil when the line ends first. `escapes`: backslash escapes the next unit.
    func stringEnd(_ start: Int, quote: UInt16, end: Int? = nil, escapes: Bool = true) -> Int? {
        let limit = min(end ?? units.count, units.count)
        var i = start + 1
        while i < limit {
            let c = units[i]
            if escapes, c == A.backslash { i += 2; continue }
            if c == quote { return i + 1 }
            i += 1
        }
        return nil
    }

    /// Scans a number starting at `start` (decimal, `0x` / `0b` / `0o`, `_` separators, fraction,
    /// exponent, alphanumeric suffix such as `n`, `u32`, `f`, `px`). Stops before `..` (ranges).
    func numberEnd(_ start: Int, end: Int? = nil) -> Int {
        let limit = min(end ?? units.count, units.count)
        var i = start
        let prefix = A.lower(self[i + 1])
        if self[i] == A.zero, prefix == 0x78 || prefix == 0x62 || prefix == 0x6F {
            i += 2
            while i < limit, A.isHex(units[i]) || units[i] == A.underscore { i += 1 }
        } else {
            while i < limit, A.isDigit(units[i]) || units[i] == A.underscore { i += 1 }
            if i < limit, units[i] == A.dot, A.isDigit(self[i + 1]) {
                i += 1
                while i < limit, A.isDigit(units[i]) || units[i] == A.underscore { i += 1 }
            }
            if i < limit, units[i] == 0x65 || units[i] == 0x45,
               A.isDigit(self[i + 1]) || ((self[i + 1] == A.plus || self[i + 1] == A.minus) && A.isDigit(self[i + 2])) {
                i += 2
                while i < limit, A.isDigit(units[i]) { i += 1 }
            }
        }
        while i < limit, A.isAsciiLetter(units[i]) || A.isDigit(units[i]) || units[i] == A.underscore { i += 1 }
        return i
    }
}
