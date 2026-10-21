import Darwin

/// A sysctl name resolved to its MIB once, so repeated reads skip the name lookup (one syscall
/// each instead of two) and allocate nothing.
struct Sysctl: Sendable {
    let name: String
    private let mib: [Int32]

    /// nil when this kernel does not know `name`.
    init?(_ name: String) {
        var buffer = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var count = buffer.count
        guard sysctlnametomib(name, &buffer, &count) == 0, count > 0 else { return nil }
        self.name = name
        mib = Array(buffer.prefix(count))
    }

    /// Reads a fixed-size value; false when the call fails or the kernel returns a different size
    /// than `T` (then `value` must not be used).
    func read<T: BitwiseCopyable>(into value: inout T) -> Bool {
        var size = MemoryLayout<T>.size
        let rc = mib.withUnsafeBufferPointer { m in
            withUnsafeMutablePointer(to: &value) { p in
                // sysctl(3) takes a mutable MIB pointer but never writes through it.
                sysctl(UnsafeMutablePointer(mutating: m.baseAddress), u_int(m.count), p, &size, nil, 0)
            }
        }
        return rc == 0 && size == MemoryLayout<T>.size
    }

    /// Integer sysctls are 4 or 8 bytes depending on the name; this accepts either.
    func readInteger() -> Int64? {
        var wide: Int64 = 0
        var size = MemoryLayout<Int64>.size
        let rc = mib.withUnsafeBufferPointer { m in
            withUnsafeMutablePointer(to: &wide) { p in
                sysctl(UnsafeMutablePointer(mutating: m.baseAddress), u_int(m.count), p, &size, nil, 0)
            }
        }
        guard rc == 0 else { return nil }
        switch size {
        case 8: return wide
        case 4: return Int64(Int32(truncatingIfNeeded: wide))   // little-endian: the low half holds the value
        default: return nil
        }
    }
}
