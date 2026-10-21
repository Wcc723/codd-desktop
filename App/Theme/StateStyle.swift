import AppKit
import CoddUI

/// How a state pill is drawn (`.state` in helmet.html).
enum PillFill: Sendable {
    /// 1 px border in the state color.
    case outline
    /// Solid fill, black bold text (waiting = amber, done = cyan).
    case solid
    /// No border, state-colored text (idle, shell, exited, stopped).
    case bare
}

/// State → glyph / color / labels (SPEC §3, glyph + color double encoded).
/// Glyphs come from the CODD allow-list only (never emoji presentation).
struct StateStyle: Sendable {
    let glyph: String
    let color: NSColor
    /// Sidebar tree pill (rendered uppercase), e.g. `Waiting`.
    let pill: String
    /// Header chip label, e.g. `WAITING`.
    let label: String
    let pillFill: PillFill
    /// Lamp glow (busy = green glow, waiting = amber glow while pulsing).
    let glows: Bool
    /// Lamp alpha (unknown = 60 %).
    let lampAlpha: CGFloat
    /// Only waiting pulses (a render-server CA animation, see `LampView`); every other lamp is
    /// static.
    let pulses: Bool

    static func of(_ state: SessionState) -> StateStyle {
        switch state {
        case .waiting:
            StateStyle(glyph: "◆", color: Palette.amber, pill: "Waiting", label: "WAITING", pillFill: .solid,
                       glows: true, lampAlpha: 1, pulses: true)
        case .error:
            StateStyle(glyph: "▲", color: Palette.danger, pill: "Error", label: "ERROR", pillFill: .outline,
                       glows: false, lampAlpha: 1, pulses: false)
        case .done:
            StateStyle(glyph: "◇", color: Palette.cyan, pill: "Done", label: "DONE", pillFill: .solid,
                       glows: false, lampAlpha: 1, pulses: false)
        case .busy:
            StateStyle(glyph: "●", color: Palette.success, pill: "Busy", label: "BUSY", pillFill: .outline,
                       glows: true, lampAlpha: 1, pulses: false)
        case .compacting:
            StateStyle(glyph: "◌", color: Palette.successDim, pill: "Compact", label: "COMPACTING", pillFill: .outline,
                       glows: false, lampAlpha: 1, pulses: false)
        case .idle:
            StateStyle(glyph: "○", color: Palette.cyan, pill: "Idle", label: "IDLE", pillFill: .bare,
                       glows: false, lampAlpha: 1, pulses: false)
        case .starting:
            StateStyle(glyph: "◌", color: Palette.bone, pill: "Start", label: "STARTING", pillFill: .outline,
                       glows: false, lampAlpha: 1, pulses: false)
        case .unknown:
            StateStyle(glyph: "●", color: Palette.bone, pill: "—", label: "RUNNING", pillFill: .outline,
                       glows: false, lampAlpha: 0.6, pulses: false)
        case .shell:
            StateStyle(glyph: "$", color: Palette.bone, pill: "Shell", label: "SHELL", pillFill: .bare,
                       glows: false, lampAlpha: 1, pulses: false)
        case .exited:
            StateStyle(glyph: "✕", color: Palette.dimmer, pill: "Exited", label: "EXITED", pillFill: .bare,
                       glows: false, lampAlpha: 1, pulses: false)
        case .stopped:
            StateStyle(glyph: "⟲", color: Palette.dimmer, pill: "Stopped", label: "STOPPED", pillFill: .bare,
                       glows: false, lampAlpha: 1, pulses: false)
        }
    }

    /// D8 overlay: the session's live holder does not answer (`SessionVM.unreachableSince`).
    static var unreachable: StateStyle {
        StateStyle(glyph: "◌", color: Palette.danger, pill: "Unreach", label: "UNREACHABLE", pillFill: .outline,
                   glows: false, lampAlpha: 1, pulses: false)
    }

    /// The style a session's lamp, pill and chip draw: UNREACHABLE overrides its state.
    @MainActor
    static func of(_ session: SessionVM) -> StateStyle {
        session.unreachableSince != nil ? unreachable : of(session.state)
    }

    /// Aggregate badge order on group headers: `◆n ▲n ◇n ●n ◌n ○n $n ✕n` (only non-zero).
    static let aggregateOrder: [SessionState] = [.waiting, .error, .done, .busy, .compacting, .idle, .starting, .unknown, .shell, .exited, .stopped]
}

extension WaitingReason {
    /// Header chip / notification wording: `PERMISSION`, `QUESTION`, `PLAN`.
    var label: String {
        switch self {
        case .permission: "PERMISSION"
        case .question: "QUESTION"
        case .plan: "PLAN"
        case .other: "INPUT"
        }
    }

    /// Short NEEDS YOU pill: `Perm`, `Ask`, `Plan`.
    var shortPill: String {
        switch self {
        case .permission: "Perm"
        case .question: "Ask"
        case .plan: "Plan"
        case .other: "Wait"
        }
    }

    /// Lowercase prefix on the tree row's second line: `perm · 3m`.
    var rowPrefix: String {
        switch self {
        case .permission: "perm"
        case .question: "ask"
        case .plan: "plan"
        case .other: "wait"
        }
    }
}

// App-only theme parts that stayed behind when the design system moved to CoddUI (M3 D30): they
// need App model types (TagColor, QuotaTone, StateStyle).

extension TagColor {
    /// `--t-*` tokens. Tags render only as small squares (never on lamps or titles).
    var color: NSColor {
        switch self {
        case .red: NSColor(hex: 0xEF5B5B)
        case .blue: NSColor(hex: 0x5B8DEF)
        case .green: NSColor(hex: 0x4EC9B0)
        case .yellow: NSColor(hex: 0xE6C84E)
        case .purple: NSColor(hex: 0xB07CFF)
        case .orange: NSColor(hex: 0xFF9B4E)
        case .pink: NSColor(hex: 0xFF7CB5)
        case .cyan: NSColor(hex: 0x4ED1E6)
        }
    }
}

extension QuotaTone {
    var color: NSColor {
        switch self {
        case .ok: Palette.success
        case .warn: Palette.amber
        case .crit: Palette.danger
        case .muted: Palette.dimmer
        }
    }
}

extension ChipStyle {
    /// Sidebar / header state pill for `style`.
    static func statePill(_ style: StateStyle, size: CGFloat = 9.5, height: CGFloat = 15) -> ChipStyle {
        let weight: Typeface.Weight = style.pillFill == .solid ? .bold : .medium
        var text = TextStyle.caps(size, style.color, tracking: 0.14, weight)
        switch style.pillFill {
        case .solid:
            text.color = .black
            return ChipStyle(text: text, border: nil, fill: style.color, height: height, padding: 5)
        case .outline:
            return ChipStyle(text: text, border: style.color, fill: nil, height: height, padding: 5)
        case .bare:
            return ChipStyle(text: text, border: nil, fill: nil, height: height, padding: 2)
        }
    }
}
