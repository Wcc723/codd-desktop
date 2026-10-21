import AppKit

/// Grid size in character cells (shown as `120×38` in the tab strip; sent as RESIZE).
struct TerminalGridSize: Equatable, Sendable {
    var columns: Int
    var rows: Int
}

/// Which PTY a surface shows.
struct TerminalTarget: Hashable, Sendable {
    var sessionID: SessionID
    var tab: PaneTab
}

/// Where a surface sits in the session pane: the tab strip's terminal or the ⌘J bottom panel.
enum TerminalSlot: Hashable, Sendable, CaseIterable {
    case main
    case panel
}

/// Input the shell sends on the user's behalf (answer bar keys, the ⌘L composer). Typing goes
/// straight from the engine's `NSTextInputClient` to the PTY and never passes through here.
enum TerminalInput: Equatable, Sendable {
    /// A key name: `1`…`9`, `esc`, `enter`.
    case key(String)
    /// Text, optionally followed by Return (holder INPUT submit flag).
    case text(String, submit: Bool)
    /// A composer send (`ComposerEncoding.payload`): the bytes, the holder's `input.paste` flag
    /// (bracketed when the child has ?2004 on, D1) and the submit flag.
    case payload(bytes: [UInt8], submit: Bool, paste: Bool)

    /// What the PTY receives (submit is a separate flag, not part of the bytes).
    var bytes: [UInt8] {
        switch self {
        case .key(let name):
            switch name {
            case "esc": [0x1B]
            case "enter": [0x0D]
            default: Array(name.utf8)
            }
        case .text(let text, _):
            Array(text.utf8)
        case .payload(let bytes, _, _):
            bytes
        }
    }

    var submits: Bool {
        switch self {
        case .key: false
        case .text(_, let submit): submit
        case .payload(_, let submit, _): submit
        }
    }

    /// One bracketed paste (holder INPUT flag bit1).
    var pastes: Bool {
        if case .payload(_, _, let paste) = self { return paste }
        return false
    }

    /// The key names `.key` accepts: `1`…`9`, `esc`, `enter`.
    static func isAnswerKey(_ name: String) -> Bool {
        name == "esc" || name == "enter" || (name.count == 1 && "123456789".contains(name))
    }
}

/// The only thing the app shell knows about a terminal engine: one slot of the pane that shows
/// one PTY at a time. Terminal bytes never pass through here or through Observation: the engine
/// is fed from its holder stream's queue and renders on its own display link.
@MainActor
protocol TerminalSurface: AnyObject {
    /// The slot's view; the shell places it directly in the AppKit tree.
    var view: NSView { get }
    var gridSize: TerminalGridSize { get }
    /// Called when the grid size of the shown terminal changes (resize, font size, switch).
    var onGridSizeChange: ((TerminalGridSize) -> Void)? { get set }
    var fontSize: CGFloat { get set }
    /// Shows a session tab (attach / switch). Must be cheap for hot terminals (< 16 ms).
    func attach(_ target: TerminalTarget)
    /// Shows nothing (the ⌘J panel closed); the last terminal stays hot.
    func detach()
    /// Hidden or covered: stop rendering (the engine may keep parsing).
    func setOccluded(_ occluded: Bool)
    func send(_ input: TerminalInput)
    /// Moves keyboard focus into the shown terminal.
    func focus()
    /// Whether input sent now reaches a running process (the composer is disabled otherwise).
    var acceptsInput: Bool { get }
}

extension TerminalSurface {
    func detach() {}
    func focus() {}
    var acceptsInput: Bool { true }

    /// The window's first responder is inside this surface (⌘W picks what to close by it).
    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }
}

/// Creates surfaces and hears about tab lifecycle. Real mode: `TerminalHub` (libghostty engines
/// on holder streams); mock mode: `FakeTerminalSurfaceFactory`.
@MainActor
protocol TerminalSurfaceFactory {
    func makeSurface(slot: TerminalSlot) -> TerminalSurface
    /// The user closed a shell tab or the panel's shell: end its process.
    func closeShellTab(sessionID: SessionID, tabID: String)
    /// Sends input to a PTY whether or not a slot shows it (the error banner's resend, D26).
    /// False when nothing could take it.
    @discardableResult func send(_ input: TerminalInput, to target: TerminalTarget) -> Bool
}

extension TerminalSurfaceFactory {
    func closeShellTab(sessionID: SessionID, tabID: String) {}
    func send(_ input: TerminalInput, to target: TerminalTarget) -> Bool { false }
}
