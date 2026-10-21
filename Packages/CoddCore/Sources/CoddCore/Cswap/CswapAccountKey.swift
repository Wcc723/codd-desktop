import Foundation

/// D6: which login a status-line report belongs to, computed by `codd-statusline` from the
/// `CLAUDE_CONFIG_DIR` it runs under. The CLI (C2, no Foundation) implements the same table; both
/// are tested with the same rows.
///
/// A path outside the two known shapes is hashed (FNV-1a 64) rather than carried as is: cswap
/// profile directory names contain an e-mail slug, and the key travels in every report (D31).
public enum AccountKey: Sendable, Hashable, CustomStringConvertible {
    /// `CLAUDE_CONFIG_DIR` unset, empty or `~/.claude`: the global login.
    case `default`
    /// A cswap session profile `…/.claude-swap-backup/sessions/<n>-…`.
    case cswap(Int)
    /// Anything else: the whole raw value `cfg-<16 lowercase hex>`.
    case other(String)

    /// `default`, `cswap-<n>` (1–4 digits) or `cfg-<16 lowercase hex>`; anything else is `nil`.
    public init?(rawValue: String) {
        if rawValue == "default" {
            self = .default
        } else if rawValue.hasPrefix("cswap-") {
            let digits = rawValue.utf8.dropFirst(6)
            guard (1...4).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }),
                  let n = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
            self = .cswap(n)
        } else if rawValue.hasPrefix("cfg-") {
            let hex = rawValue.utf8.dropFirst(4)
            guard hex.count == 16, hex.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
            self = .other(rawValue)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .default: return "default"
        case .cswap(let n): return "cswap-\(n)"
        case .other(let raw): return raw
        }
    }

    public var description: String { rawValue }

    /// The D6 table:
    /// - `nil`, empty, or `<home>/.claude` (trailing slashes ignored on both) → ``default``;
    /// - a last component matching `^[0-9]{1,4}-` whose parent is `sessions` and grandparent
    ///   `.claude-swap-backup` → ``cswap(_:)``;
    /// - anything else → `cfg-` + FNV-1a 64 of the path's UTF-8 bytes exactly as given.
    public static func from(claudeConfigDir: String?, home: String) -> AccountKey {
        guard let dir = claudeConfigDir, !dir.isEmpty else { return .default }
        let trimmed = stripTrailingSlashes(dir)
        if trimmed == stripTrailingSlashes(home) + "/.claude" { return .default }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 3, parts[parts.count - 2] == "sessions", parts[parts.count - 3] == ".claude-swap-backup",
           let n = slotPrefix(parts[parts.count - 1]) {
            return .cswap(n)
        }
        return .other("cfg-" + fnv1a64Hex(dir))
    }

    /// D6: the `.other` key of each account's session profile path → its number, so a report from
    /// a pinned session started on a non-standard root (where the path is not `…/.claude-swap-backup/…`)
    /// is still attributed. The key is computed from `sessionProfile.path`, the exact string CODD
    /// passes as `CLAUDE_CONFIG_DIR` (``LaunchRequest/claudeConfigDir``).
    public static func profileKeys(_ accounts: [CswapStateAccount], home: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for account in accounts {
            guard let profile = account.sessionProfile,
                  case .other(let raw) = from(claudeConfigDir: profile.path, home: home) else { continue }
            out[raw] = account.number
        }
        return out
    }

    /// `1…4` leading ASCII digits followed by `-`.
    static func slotPrefix(_ component: Substring) -> Int? {
        let bytes = Array(component.utf8)
        var count = 0
        while count < bytes.count, (0x30...0x39).contains(bytes[count]) { count += 1 }
        guard (1...4).contains(count), count < bytes.count, bytes[count] == UInt8(ascii: "-") else { return nil }
        return Int(String(decoding: bytes[..<count], as: UTF8.self))
    }

    /// FNV-1a 64 (offset basis 0xcbf29ce484222325, prime 0x100000001b3) of the UTF-8 bytes.
    static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// ``fnv1a64(_:)`` as 16 lowercase hex digits.
    static func fnv1a64Hex(_ s: String) -> String {
        let hex = String(fnv1a64(s), radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func stripTrailingSlashes(_ s: String) -> String {
        var t = Substring(s)
        while t.count > 1, t.hasSuffix("/") { t = t.dropLast() }
        return String(t)
    }
}
