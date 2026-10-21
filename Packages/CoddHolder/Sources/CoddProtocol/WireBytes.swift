/// Big-endian integer helpers used by the frame codec (all multi-byte wire integers are big-endian).
public enum WireBytes {
    @inlinable
    public static func append(_ value: UInt8, to out: inout [UInt8]) {
        out.append(value)
    }

    @inlinable
    public static func append(_ value: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    @inlinable
    public static func append(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    @inlinable
    public static func append(_ value: UInt64, to out: inout [UInt8]) {
        append(UInt32(truncatingIfNeeded: value >> 32), to: &out)
        append(UInt32(truncatingIfNeeded: value), to: &out)
    }

    @inlinable
    public static func readUInt16<C: RandomAccessCollection>(_ bytes: C, at index: C.Index) -> UInt16
    where C.Element == UInt8 {
        let second = bytes.index(after: index)
        return UInt16(bytes[index]) << 8 | UInt16(bytes[second])
    }

    @inlinable
    public static func readUInt32<C: RandomAccessCollection>(_ bytes: C, at index: C.Index) -> UInt32
    where C.Element == UInt8 {
        var value: UInt32 = 0
        var position = index
        for _ in 0..<4 {
            value = value << 8 | UInt32(bytes[position])
            position = bytes.index(after: position)
        }
        return value
    }

    @inlinable
    public static func readUInt64<C: RandomAccessCollection>(_ bytes: C, at index: C.Index) -> UInt64
    where C.Element == UInt8 {
        var value: UInt64 = 0
        var position = index
        for _ in 0..<8 {
            value = value << 8 | UInt64(bytes[position])
            position = bytes.index(after: position)
        }
        return value
    }
}
