import Foundation

/// cswap 0.26's alias rule (`claude_swap/models.py` `normalize_alias`, M3-PLAN D34), repeated here
/// because this package may not depend on CoddCore (whose `CswapAlias` is the same table).
/// Checking client side keeps an invalid alias from ever reaching `cswap add --alias`.
public enum DialogAliasRule {
    /// The inline hint shown under an invalid alias (D34, exact copy).
    public static let hint = "別名只能用英文小寫、數字與 - _ .（cswap 規則）"

    /// Trimmed and lowercased like Python's `strip().lower()`; nil when cswap would refuse it:
    /// empty, purely digits (reserved for slot numbers), starting with `-` (read as a flag), or
    /// any character outside `[a-z0-9_.-]`. CJK aliases such as `工作室` are refused.
    public static func normalize(_ alias: String) -> String? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let scalars = normalized.unicodeScalars
        guard scalars.allSatisfy(isAllowed) else { return nil }
        if scalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) { return nil }
        if normalized.hasPrefix("-") { return nil }
        return normalized
    }

    /// `^[a-z0-9_.-]$` for one scalar (ASCII only, like the Python regex).
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x61 ... 0x7A, 0x30 ... 0x39: true      // a-z 0-9
        case 0x5F, 0x2E, 0x2D: true                  // _ . -
        default: false
        }
    }
}
