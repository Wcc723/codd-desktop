import Foundation
internal import GhosttyWrapper

/// The one libghostty app every `TerminalEngine` shares.
///
/// One app means one font-grid cache: surfaces with the same font share their glyph atlases, which
/// is most of what makes the 15th session cheaper than the first. libghostty aborts when two apps
/// are created at once, so this is also the only place one is created.
@MainActor
public enum TerminalRuntime {
    private static var sharedController: TerminalController?
    private static var appliedConfig: String?

    /// The configuration currently applied to every surface (nil before the first engine).
    public private(set) static var configuration: TerminalConfiguration?

    /// libghostty's complaint about the last applied config, or nil when it was accepted. A rejected
    /// config leaves libghostty on its built-in defaults (wrong colors and font).
    public static var lastConfigurationIssue: String? {
        sharedController?.lastConfigurationIssue
    }

    /// The libghostty build, as its XTVERSION reply reports it (`1.3.2-HEAD+1e9e14af5`).
    public nonisolated static var libghosttyVersion: String {
        GhosttyBuildInfo.version
    }

    /// Terminal variables every child of a CODD terminal gets (docs/M1-PLAN.md): `xterm-256color`
    /// needs no Ghostty terminfo on the system, and `TERM_PROGRAM=ghostty` turns on Claude Code's
    /// Ghostty behaviour (Cmd+click handling, notification method, OSC 8 links).
    public nonisolated static var childEnvironment: [String: String] {
        [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": GhosttyBuildInfo.version,
        ]
    }

    /// libghostty's diagnostics for `configuration` without applying it; empty when every line parses.
    public static func diagnostics(for configuration: TerminalConfiguration) -> [String] {
        TerminalController.configurationDiagnostics(for: configuration.renderedGhosttyConfig)
    }

    /// Applies `configuration` to every live and future surface (a settings change). The process
    /// has one config: the last one applied wins for all terminals.
    public static func apply(_ configuration: TerminalConfiguration) {
        _ = controller(for: configuration)
    }

    static func controller(for configuration: TerminalConfiguration) -> TerminalController {
        let rendered = configuration.renderedGhosttyConfig
        if let sharedController {
            if rendered != appliedConfig {
                sharedController.updateConfigSource(.generated(rendered))
                appliedConfig = rendered
                self.configuration = configuration
            }
            return sharedController
        }
        // An empty theme and no overrides: the rendered text is the whole config, identical in
        // light and dark appearance, so the system appearance never recolors a terminal.
        let controller = TerminalController(
            configSource: .generated(rendered),
            theme: GhosttyWrapper.TerminalTheme(),
            terminalConfiguration: GhosttyWrapper.TerminalConfiguration()
        )
        sharedController = controller
        appliedConfig = rendered
        self.configuration = configuration
        return controller
    }
}
