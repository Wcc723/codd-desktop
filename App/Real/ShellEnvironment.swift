import CoddCore
import CoddTerminal
import Foundation

/// The exact environment of a session CODD starts in a holder (M1 plan, "Claude session
/// environment"; shells get the same): the user's captured login-shell environment minus variables
/// that describe another process or terminal, then CoddCore's `SpawnEnvironmentBuilder` on top
/// (HOME, login PATH, UTF-8 LANG / LC_CTYPE, CODD_SESSION_ID, and CODD_HOOK_TOKEN for claude) and
/// the terminal's own variables (`TERM=xterm-256color`, `COLORTERM=truecolor`,
/// `TERM_PROGRAM=ghostty`, its version).
enum ShellEnvironment {
    /// Exact names never carried over from the login environment.
    static let deniedNames: Set<String> = [
        // The capture shell's own state, wrong for a new shell in another folder.
        "PWD", "OLDPWD", "_", "SHLVL", "LINES", "COLUMNS",
        // Set below for CODD's terminal.
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        // A Claude Code process CODD itself may run under.
        "CLAUDECODE", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_ENTRYPOINT",
        // Another terminal or multiplexer.
        "TMUX", "TMUX_PANE", "STY", "WINDOWID",
        // launchd / the app's own process.
        "SECURITYSESSIONID", "LaunchInstanceID", "MallocNanoZone",
    ]
    /// Name prefixes never carried over (`__CF_USER_TEXT_ENCODING` comes from the app's own
    /// environment through `SpawnEnvironmentBuilder`).
    static let deniedPrefixes = [
        "DYLD_", "__CF", "XPC_", "__XPC_", "__XCODE", "XCODE_", "CODD_", "OS_ACTIVITY_", "MallocStack",
        "NSZombie", "GHOSTTY_", "ITERM_", "KITTY_", "WEZTERM_",
    ]

    static func isDenied(_ name: String) -> Bool {
        deniedNames.contains(name) || deniedPrefixes.contains { name.hasPrefix($0) }
    }

    /// The login environment without denied names, and without an `LC_ALL` that is not UTF-8
    /// (it would override the UTF-8 locale and break 注音 in zsh's line editor).
    static func sanitized(login: [String: String]) -> [String: String] {
        var env = login.filter { !isDenied($0.key) && isValidName($0.key) && !$0.value.contains("\0") }
        if let all = env["LC_ALL"], !isUTF8Locale(all) { env["LC_ALL"] = nil }
        return env
    }

    /// The child environment for a session or a shell tab. `hookToken` (claude sessions) adds
    /// `CODD_HOOK_TOKEN`, `extra` adds CODD's own variables (`CODD_HOOK_URL`), `overrides` is the
    /// launch profile's environment (`CLAUDE_CONFIG_DIR` for an account-pinned profile), applied
    /// over the login environment with `SpawnEnvironmentBuilder`'s blocked-name rules.
    static func build(base: [String: String], login: [String: String]?, sessionID: UUID, hookToken: String? = nil,
                      overrides: [String: String] = [:], extra: [String: String] = [:]) -> [String: String] {
        let builder = SpawnEnvironmentBuilder(termProgram: "ghostty", termProgramVersion: TerminalRuntime.libghosttyVersion)
        let built = builder.build(base: base, login: login, sessionId: sessionID, hookToken: hookToken, overrides: overrides)
        var env = sanitized(login: login ?? [:])
        env.merge(built) { _, ours in ours }
        env.merge(extra) { _, ours in ours }
        env.merge(TerminalRuntime.childEnvironment) { _, terminal in terminal }
        return env
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`, what the holder's env file accepts.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.utf8.first, first == 0x5F || (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else {
            return false
        }
        return name.utf8.allSatisfy { $0 == 0x5F || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }

    private static func isUTF8Locale(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.hasSuffix(".utf-8") || v.hasSuffix(".utf8") || v.contains(".utf-8@") || v.contains(".utf8@")
    }
}

/// The login-shell environment, captured once per app run (`$SHELL -l -i -c`, 5 s timeout, in its
/// own session). Shared by every spawn; nil when the capture failed or is disabled.
@MainActor
enum LoginEnvironment {
    private static let cache = LoginEnvironmentCache(provider: LoginShellEnvironmentCapture.standard())

    /// DEBUG `-codd-login-env NO` turns the capture off (smoke runs); hosted unit tests never run
    /// the user's rc files.
    static var isEnabled = !isHostingUnitTests

    static func current() async -> [String: String]? {
        guard isEnabled else { return nil }
        return await cache.environment()
    }

    /// Starts the capture early so the first spawn does not wait for the user's rc files.
    static func warmUp() {
        guard isEnabled else { return }
        let cache = self.cache
        Task.detached(priority: .utility) { _ = await cache.environment() }
    }
}
