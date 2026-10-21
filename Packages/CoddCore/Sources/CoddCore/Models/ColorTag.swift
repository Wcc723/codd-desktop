/// The 8 Claude Code `/color` names plus `none` (SPEC §3). Rendered only as small squares;
/// tags never color lamps or titles.
public enum ColorTag: String, Sendable, Codable, CaseIterable {
    case none, red, blue, green, yellow, purple, orange, pink, cyan

    /// Design token hex value (`--t-*` in helmet.html); `nil` for ``none``.
    public var hex: String? {
        switch self {
        case .none: return nil
        case .red: return "#ef5b5b"
        case .blue: return "#5b8def"
        case .green: return "#4ec9b0"
        case .yellow: return "#e6c84e"
        case .purple: return "#b07cff"
        case .orange: return "#ff9b4e"
        case .pink: return "#ff7cb5"
        case .cyan: return "#4ed1e6"
        }
    }

    /// 24-bit RGB value for drawing; `nil` for ``none``.
    public var rgb: (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let hex, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    /// Lenient mapping (unknown names and Claude's `default` → ``none``).
    public init(lenient raw: String?) {
        self = raw.flatMap { ColorTag(rawValue: $0.lowercased()) } ?? .none
    }

    public init(from decoder: any Decoder) throws {
        self.init(lenient: try? decoder.singleValueContainer().decode(String.self))
    }
}
