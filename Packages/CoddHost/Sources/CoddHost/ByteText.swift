/// Compact byte counts as the STATUS artboard writes them: `21.4G`, `412G`, `1T`, `412MB`, `0B`.
///
/// Rules (base 1024):
/// 1. The unit is the largest one in which the value is at least 1: `B`, `KB`, `MB`, `G`, `T`,
///    `P`, `E`. Below a gigabyte the unit keeps its `B` (`412MB`, the CODD app RSS card); from a
///    gigabyte up it is one letter (`21.4/36G`, `412G free`, `1T`), exactly as the artboard.
/// 2. Below 100 the value is rounded to one decimal, and the decimal is dropped when it is `.0`
///    (`1.2G`, `21.4G`, `36G`, `1T`). From 100 up it is rounded to a whole number (`412G`).
/// 3. When rounding reaches 1024 the next unit is used instead (`1023.97MB` is `1G`, never
///    `1024MB`).
/// 4. Plain bytes are always whole (`0B`, `512B`).
///
/// No locale: the decimal separator is always `.` and there is no grouping, so the text is
/// stable in tests, the state dump and every UI language.
public enum ByteText {
    private static let units = ["B", "KB", "MB", "G", "T", "P", "E"]

    public static func short(_ bytes: UInt64) -> String {
        guard bytes >= 1024 else { return "\(bytes)B" }
        var unit = 0
        var value = Double(bytes)
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        var text = render(value)
        if text.rounded >= 1024, unit < units.count - 1 {
            unit += 1
            text = render(value / 1024)
        }
        return text.digits + units[unit]
    }

    private static func render(_ value: Double) -> (digits: String, rounded: Double) {
        if value < 100 {
            let tenths = Int((value * 10).rounded())
            if tenths % 10 == 0 { return ("\(tenths / 10)", Double(tenths) / 10) }
            return ("\(tenths / 10).\(tenths % 10)", Double(tenths) / 10)
        }
        let whole = value.rounded()
        return ("\(Int(whole))", whole)
    }
}
