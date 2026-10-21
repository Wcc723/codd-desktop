/// The account key a status-line report carries (M3 D6), computed from `CLAUDE_CONFIG_DIR`.
///
/// The key must identify the login without revealing it: cswap's session profiles are named
/// `<n>-<e-mail slug>`, so only the number is kept, and any other directory is reduced to a hash.
/// CoddCore's `AccountKey.from(claudeConfigDir:home:)` implements the same table for the app side
/// (pinned sessions and known profiles are matched by recomputing it), so the two must stay equal;
/// both packages test the same rows.
///
/// | `CLAUDE_CONFIG_DIR` | Key |
/// |---|---|
/// | unset or empty | `default` |
/// | `<home>/.claude`, trailing slashes ignored | `default` |
/// | `…/.claude-swap-backup/sessions/<n>-…` (1–4 digits, then `-`) | `cswap-<n>` (no leading zeros) |
/// | anything else | `cfg-` + 16 lowercase hex of FNV-1a 64 over the UTF-8 bytes of the path as given |
public enum StatusLineAccountKey {
    public static let defaultKey = "default"

    public static func from(claudeConfigDir: String?, home: String?) -> String {
        guard let dir = claudeConfigDir, !dir.isEmpty else { return defaultKey }
        if let home {
            // Exactly CoddCore's rule (even for HOME=/, where this gives "//.claude").
            let claudeDir = trimmingTrailingSlashes(home) + "/.claude"
            if trimmingTrailingSlashes(dir) == claudeDir { return defaultKey }
        }
        let components = dir.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
        if components.count >= 3,
           components[components.count - 2].elementsEqual("sessions".utf8),
           components[components.count - 3].elementsEqual(".claude-swap-backup".utf8),
           let number = slotNumber(components[components.count - 1]) {
            return "cswap-\(number)"
        }
        return "cfg-" + hex16(fnv1a64(dir.utf8))
    }

    /// `^([0-9]{1,4})-` → the number.
    static func slotNumber(_ name: Substring.UTF8View) -> Int? {
        var value = 0
        var count = 0
        for c in name {
            if c == UInt8(ascii: "-") { return count > 0 ? value : nil }
            guard ASCII.isDigit(c), count < 4 else { return nil }
            value = value * 10 + Int(c - 0x30)
            count += 1
        }
        return nil
    }

    /// FNV-1a 64 (offset basis 0xcbf29ce484222325, prime 0x100000001b3).
    public static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func hex16(_ value: UInt64) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0x30, count: 16)
        var v = value
        for i in stride(from: 15, through: 0, by: -1) {
            out[i] = digits[Int(v & 0xF)]
            v >>= 4
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func trimmingTrailingSlashes(_ s: String) -> String {
        var bytes = Array(s.utf8)
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Standard base64 (RFC 4648 §4) decoding without Foundation, for `--chain-b64` and
/// `CODD_STATUSLINE_CHAIN`. Padding may be omitted; any other deviation (characters outside the
/// alphabet, whitespace, misplaced `=`, a length that cannot be base64) is refused.
public enum Base64 {
    public static func decode(_ text: String) -> [UInt8]? {
        var bytes = Array(text.utf8)
        var padding = 0
        while bytes.last == UInt8(ascii: "=") {
            bytes.removeLast()
            padding += 1
        }
        guard padding <= 2 else { return nil }
        if padding > 0 { guard (bytes.count + padding) % 4 == 0 else { return nil } }
        guard bytes.count % 4 != 1 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        for c in bytes {
            guard let v = value(c) else { return nil }
            accumulator = accumulator << 6 | UInt32(v)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    static func value(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x41...0x5A: return c - 0x41
        case 0x61...0x7A: return c - 0x61 + 26
        case 0x30...0x39: return c - 0x30 + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}
