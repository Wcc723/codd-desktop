/// Writes JSON the way the wire contract promises: UTF-8, `/` never escaped (URIs like
/// `codd://note/<id>` and paths stay readable), non-ASCII text (CJK) as raw UTF-8, members in the
/// order they were built, numbers as their stored text. Only `"`, `\` and C0 controls are escaped.
enum JSONWriter {
    static func compact(_ value: JSON) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(value, into: &out, indent: nil, level: 0)
        return out
    }

    /// Two-space indentation, `"key": value`, empty containers as `{}` / `[]`. Used for the golden
    /// fixture files and the README examples, never on the wire.
    static func pretty(_ value: JSON) -> String {
        var out: [UInt8] = []
        write(value, into: &out, indent: 2, level: 0)
        return String(decoding: out, as: UTF8.self)
    }

    private static func write(_ value: JSON, into out: inout [UInt8], indent: Int?, level: Int) {
        switch value {
        case .null: out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        case .bool(true): out.append(contentsOf: [0x74, 0x72, 0x75, 0x65])
        case .bool(false): out.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65])
        case .number(let n): out.append(contentsOf: n.text.utf8)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            guard !items.isEmpty else { out.append(contentsOf: [0x5B, 0x5D]); return }
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x2C) }
                newline(&out, indent: indent, level: level + 1)
                write(item, into: &out, indent: indent, level: level + 1)
            }
            newline(&out, indent: indent, level: level)
            out.append(0x5D)
        case .object(let object):
            guard !object.isEmpty else { out.append(contentsOf: [0x7B, 0x7D]); return }
            out.append(0x7B)
            for (i, member) in object.members.enumerated() {
                if i > 0 { out.append(0x2C) }
                newline(&out, indent: indent, level: level + 1)
                writeString(member.key, into: &out)
                out.append(0x3A)
                if indent != nil { out.append(0x20) }
                write(member.value, into: &out, indent: indent, level: level + 1)
            }
            newline(&out, indent: indent, level: level)
            out.append(0x7D)
        }
    }

    private static func newline(_ out: inout [UInt8], indent: Int?, level: Int) {
        guard let indent else { return }
        out.append(0x0A)
        out.append(contentsOf: repeatElement(0x20, count: indent * level))
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    /// Copies runs that need no escape in bulk: a 4 MB base64 image is one run.
    static func writeString(_ string: String, into out: inout [UInt8]) {
        var string = string
        string.makeContiguousUTF8()
        out.append(0x22)
        // Always non-nil after makeContiguousUTF8().
        _ = string.utf8.withContiguousStorageIfAvailable { bytes in
            var runStart = 0
            var i = 0
            while i < bytes.count {
                // Skip eight clean bytes at a time (the Debug app writes MBs of base64 here).
                if i + 8 <= bytes.count,
                   !needsEscape(UnsafeRawBufferPointer(bytes).loadUnaligned(fromByteOffset: i, as: UInt64.self))
                {
                    i += 8
                    continue
                }
                let b = bytes[i]
                i += 1
                guard b == 0x22 || b == 0x5C || b < 0x20 else { continue }
                let at = i - 1
                if runStart < at { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<at])) }
                runStart = i
                out.append(0x5C)
                switch b {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x0A: out.append(0x6E)
                case 0x0D: out.append(0x72)
                case 0x09: out.append(0x74)
                case 0x08: out.append(0x62)
                case 0x0C: out.append(0x66)
                default:
                    out.append(contentsOf: [0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0x0F)]])
                }
            }
            if runStart < bytes.count {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<bytes.count]))
            }
        }
        out.append(0x22)
    }

    /// True when any of the eight bytes is `"`, `\` or below 0x20 (exact, no false negatives;
    /// the classic "has zero byte" / "has byte less than" bit tricks). Bytes ≥ 0x80 (UTF-8
    /// continuation and lead bytes) never match.
    @inline(__always)
    static func needsEscape(_ word: UInt64) -> Bool {
        let ones: UInt64 = 0x0101_0101_0101_0101
        let highs: UInt64 = 0x8080_8080_8080_8080
        func hasZeroByte(_ v: UInt64) -> Bool { (v &- ones) & ~v & highs != 0 }
        let below20 = (word &- ones &* 0x20) & ~word & highs != 0
        return below20 || hasZeroByte(word ^ (ones &* 0x22)) || hasZeroByte(word ^ (ones &* 0x5C))
    }
}
