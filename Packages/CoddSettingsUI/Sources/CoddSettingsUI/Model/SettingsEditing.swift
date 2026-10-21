import CoddPreferences
import Foundation

/// cswap 0.26's alias rule (`claude_swap/models.py` `normalize_alias`, M3 D34): Python's
/// `strip()`, lowercased, only `a-z 0-9 _ . -`, not all digits, not starting with `-`. The same
/// port as CoddCore's `CswapAlias` (this package has no CoddCore dependency); the two must stay
/// identical.
public enum AliasRule {
    public static let hint = "別名只能用英文小寫、數字與 - _ .（cswap 規則）"

    /// The alias cswap would store, or nil when cswap refuses it.
    public static func normalize(_ raw: String) -> String? {
        let value = pythonStrip(raw).lowercased()
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.allSatisfy(isAllowed) else { return nil }
        guard !bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return value
    }

    private static func isAllowed(_ b: UInt8) -> Bool {
        (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == UInt8(ascii: "_") || b == UInt8(ascii: ".")
            || b == UInt8(ascii: "-")
    }

    /// Python's `str.strip()` set (`str.isspace()`), not Foundation's white space.
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

/// `HH:mm` for 勿擾時段: `7:30` is accepted as `07:30`; hours 0–23, minutes 0–59.
public enum ClockTime {
    public static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    public static let invalidHint = "時間格式為 HH:mm（00:00–23:59）"
}

/// Numeric fields that take digits only (自動切換冷卻, MCP port).
public enum DigitsField {
    /// The digits of `raw` (anything else typed is dropped as you type).
    public static func filter(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))
    }

    /// The committed value clamped into `range`; nil for an empty field (the old value stays).
    public static func commit(_ raw: String, range: ClosedRange<Int>) -> Int? {
        let digits = filter(raw)
        guard !digits.isEmpty else { return nil }
        // Ten digits or more is out of any range here; avoid Int overflow on paste.
        guard digits.count < 10, let value = Int(digits) else { return range.upperBound }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Labels of the select options, in the artboard's order (`CoddPreferences` option arrays).
enum OptionLabels {
    static func seconds(_ value: Int) -> String { "\(value) 秒" }

    static func stale(_ value: Int?) -> String {
        switch value {
        case nil: "永不"
        case 1800: "30 分鐘"
        case let seconds?: seconds % 3600 == 0 ? "\(seconds / 3600) 小時" : "\(seconds / 60) 分鐘"
        }
    }

    static func days(_ value: Int?, never: String = "永不") -> String {
        value.map { "\($0) 天" } ?? never
    }

    static func uiFontSize(_ value: Int) -> String {
        value == CoddPreferences.Appearance().uiFontSize ? "\(value) px（預設）" : "\(value) px"
    }

    static func condition(_ value: CoddPreferences.NotifyCondition) -> String {
        switch value {
        case .always: "一律通知"
        case .unfocusedOnly: "僅在未聚焦時"
        }
    }

    static func reduceMotion(_ value: CoddPreferences.ReduceMotion) -> String {
        switch value {
        case .system: "跟隨系統"
        case .on: "開啟"
        case .off: "關閉"
        }
    }

    static func language(_ value: CoddPreferences.Language) -> String {
        switch value {
        case .zhHant: "繁體中文"
        case .english: "English"
        case .system: "跟隨系統"
        }
    }
}

/// Search matching: case, width (`ＣＲＴ` = `CRT`) and diacritic insensitive; runs of white space
/// count as one space.
public enum SettingsSearch {
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether `haystack` contains `query` (an empty query matches nothing).
    public static func matches(_ haystack: String, query: String) -> Bool {
        let needle = fold(query)
        guard !needle.isEmpty else { return false }
        return fold(haystack).contains(needle)
    }
}
