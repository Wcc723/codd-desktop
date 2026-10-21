import AppKit

/// Quota and meter tone (helmet `.tone-ok` / `.tone-warn` / `.tone-crit` / `.tone-muted`, which set
/// `--tone` for `.bar10 b`, `.qrow .v` and `.meter b`). Value-only, so models in other packages can
/// carry it without knowing the app's `QuotaTone`.
public enum Tone: String, Sendable, Equatable, Hashable, CaseIterable {
    case ok, warn, crit, muted

    /// `--tone`: success, amber, danger, dimmer.
    public var color: NSColor {
        switch self {
        case .ok: Palette.success
        case .warn: Palette.amber
        case .crit: Palette.danger
        case .muted: Palette.dimmer
        }
    }

    /// The app's quota rule (`QuotaWindow.tone`): muted before the window starts or without a number,
    /// crit under 20 % remaining, warn under 50 %, ok otherwise.
    public static func tone(forRemaining remaining: Double?, started: Bool = true) -> Tone {
        guard started, let remaining, remaining.isFinite else { return .muted }
        if remaining < 20 { return .crit }
        if remaining < 50 { return .warn }
        return .ok
    }
}
