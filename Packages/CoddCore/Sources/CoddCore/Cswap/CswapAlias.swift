import Foundation

/// D34: cswap's alias rule, checked before CODD runs `cswap alias` / `cswap add --alias`, so an
/// alias cswap would refuse never reaches it (and its error text, which echoes the input, never
/// has to be shown).
public enum CswapAlias {
    /// The inline hint shown next to an invalid alias.
    public static let hint = "別名只能用英文小寫、數字與 - _ .（cswap 規則）"

    /// Exact port of claude_swap/models.py `normalize_alias` (0.26): Python `str.strip()`, then
    /// `lower()`, then non-empty, not purely digits, no leading `-`, and `^[a-z0-9_.-]+$`.
    /// Returns the normalized alias, or `nil` when cswap would raise `ValueError`.
    public static func normalize(_ name: String) -> String? {
        let normalized = pythonStrip(name).lowercased()
        guard !normalized.isEmpty else { return nil }
        let bytes = Array(normalized.utf8)
        guard bytes.allSatisfy(isAllowed) else { return nil }
        // After the ASCII check `isdigit()` reduces to ASCII digits.
        if bytes.allSatisfy({ (0x30...0x39).contains($0) }) { return nil }
        if bytes.first == UInt8(ascii: "-") { return nil }
        return normalized
    }

    private static func isAllowed(_ b: UInt8) -> Bool {
        (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == UInt8(ascii: "_") || b == UInt8(ascii: ".")
            || b == UInt8(ascii: "-")
    }

    /// Python's `str.strip()` set (`str.isspace()`), which differs from ECMAScript's `trim`
    /// (it includes U+001C–U+001F and U+0085, not U+FEFF).
    static func pythonStrip(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isPythonSpace($0) }),
              let last = scalars.lastIndex(where: { !isPythonSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    static func isPythonSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}
