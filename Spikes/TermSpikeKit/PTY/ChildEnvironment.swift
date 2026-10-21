import Foundation

/// Builds the exact environment for a terminal child.
///
/// Nothing is inherited wholesale: GUI apps carry Xcode, DYLD and launchd
/// variables (and, when the spike is started from a Claude Code session,
/// `CLAUDECODE` and friends) that must not leak into the shell. Only an
/// allow-list is copied; the login shell (`zsh -l`) rebuilds PATH itself.
public enum ChildEnvironment {
    /// Variables copied from the parent when present.
    public static let passthrough: [String] = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
    ]

    /// Minimal PATH; `/etc/zprofile` (path_helper) and the user's dotfiles extend it.
    public static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// - Parameters:
    ///   - parent: the environment to copy allow-listed values from.
    ///   - term: `TERM` for this engine (`xterm-ghostty` needs `TERMINFO`).
    ///   - termProgram: `TERM_PROGRAM`, or `nil` to leave it unset.
    ///   - extra: engine-specific additions (e.g. `TERMINFO`); win over defaults.
    public static func build(
        parent: [String: String],
        term: String,
        termProgram: String?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in passthrough {
            if let value = parent[key], !value.isEmpty {
                env[key] = value
            }
        }
        env["PATH"] = basePath
        env["LANG"] = utf8Locale(parent["LANG"])
        env["LC_CTYPE"] = env["LANG"]
        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        if let termProgram, !termProgram.isEmpty {
            env["TERM_PROGRAM"] = termProgram
            env["TERM_PROGRAM_VERSION"] = "0.1-spike"
        }
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }

    /// Keeps a UTF-8 `LANG` from the parent, otherwise falls back to `en_US.UTF-8`
    /// (zsh's line editor mangles Zhuyin input without a UTF-8 locale).
    static func utf8Locale(_ value: String?) -> String {
        if let value, value.uppercased().hasSuffix("UTF-8") || value.uppercased().hasSuffix("UTF8") {
            return value
        }
        return "en_US.UTF-8"
    }
}

/// Turns the spike's command field into an argv run through a login shell, so
/// PATH comes from the user's profile (GUI apps do not get it).
public enum CommandLineSpec {
    public static let shellPath = "/bin/zsh"

    /// `zsh -l -c 'exec <command>'` for simple commands; shell syntax is passed
    /// through without `exec`. An empty command starts an interactive login shell.
    /// A leading assignment (`FOO=1 claude`) is shell syntax too: zsh's
    /// `exec FOO=1 claude` looks for a command named `FOO=1`.
    public static func loginShell(command: String) -> (executable: String, arguments: [String]) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (shellPath, ["-zsh"])
        }
        let metacharacters = Set(";&|<>()$`\\\"'*?[]{}~!#\n")
        let firstWord = trimmed.prefix { !$0.isWhitespace }
        let isSimple = !trimmed.contains { metacharacters.contains($0) } && !firstWord.contains("=")
        let script = isSimple ? "exec \(trimmed)" : trimmed
        return (shellPath, ["zsh", "-l", "-c", script])
    }
}
