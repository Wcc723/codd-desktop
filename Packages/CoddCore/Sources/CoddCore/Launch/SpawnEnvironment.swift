import Foundation

/// Builds the EXACT environment a holder execs its child with (holder `--env-file`).
///
/// Per docs/ARCHITECTURE.md and critique H5: start from a clean allow-list of the app's own
/// environment (so Xcode / `DYLD_*` / `CLAUDECODE` / `CLAUDE_CODE_*` / launchd XPC variables never
/// leak into sessions — CODD itself may be launched from a Claude session or Xcode), take `PATH` from
/// the captured login shell, force a UTF-8 locale (zsh's line editor mangles 注音 input without one),
/// set `TERM=xterm-256color` and `COLORTERM=truecolor`, and add `CODD_SESSION_ID` (+ the hook token
/// for claude sessions).
public struct SpawnEnvironmentBuilder: Sendable, Equatable {
    /// Variables copied from the app's environment when present.
    public static let inheritedNames: [String] = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
    ]
    /// Profile overrides may never set these exact names.
    public static let blockedOverrideNames: Set<String> = ["PATH", "NODE_PATH", "NODE_OPTIONS", "TERM", "COLORTERM"]
    /// Profile overrides may never set names with these prefixes (`CODD_` is reserved for CODD).
    public static let blockedOverridePrefixes = ["LD_", "DYLD_", "CODD_"]
    public static let fallbackLocale = "en_US.UTF-8"

    /// `TERM_PROGRAM` value, or `nil` to leave it unset. Undecided until the M0 spike (critique H5:
    /// test `ghostty`, unset and `CODD`; Claude gates features on it).
    public var termProgram: String?
    public var termProgramVersion: String?

    public init(termProgram: String? = nil, termProgramVersion: String? = nil) {
        self.termProgram = termProgram
        self.termProgramVersion = termProgramVersion
    }

    /// - Parameters:
    ///   - base: the app's environment (`ProcessInfo.processInfo.environment`).
    ///   - login: the captured login-shell environment, or `nil` if capture failed / timed out.
    ///   - sessionId: the CODD session UUID.
    ///   - hookToken: set for claude sessions (hook auth); `nil` for shells.
    ///   - overrides: launch-profile variables (e.g. `CLAUDE_CONFIG_DIR` for an account-pinned
    ///     session); blocked names are dropped.
    public func build(base: [String: String], login: [String: String]?, sessionId: UUID,
                      hookToken: String?, overrides: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [:]
        for name in Self.inheritedNames {
            if let v = base[name], !v.isEmpty { env[name] = v }
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        env["HOME"] = home
        if env["SHELL"] == nil { env["SHELL"] = "/bin/zsh" }

        env["PATH"] = Self.resolvePath(login: login?["PATH"], base: base["PATH"], home: home)

        let locale = Self.utf8Locale(login?["LC_ALL"]) ?? Self.utf8Locale(login?["LANG"])
            ?? Self.utf8Locale(base["LC_ALL"]) ?? Self.utf8Locale(base["LANG"]) ?? Self.fallbackLocale
        env["LANG"] = locale
        env["LC_CTYPE"] = Self.utf8Locale(login?["LC_CTYPE"]) ?? locale

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if let termProgram {
            env["TERM_PROGRAM"] = termProgram
            if let termProgramVersion { env["TERM_PROGRAM_VERSION"] = termProgramVersion }
        }

        for (k, v) in overrides where Self.isAllowedOverride(k) && Self.isValidName(k) && !v.contains("\0") {
            env[k] = v
        }
        env[CoddEnvironmentName.sessionId] = sessionId.uuidString.lowercased()
        if let hookToken { env[CoddEnvironmentName.hookToken] = hookToken }
        return env
    }

    /// Login-shell PATH, else the app's PATH with the usual user tool directories prepended.
    static func resolvePath(login: String?, base: String?, home: String) -> String {
        if let login, !login.isEmpty { return login }
        let preferred = ["\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                         "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        var out: [String] = []
        for dir in preferred + (base ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
            if seen.insert(dir).inserted { out.append(dir) }
        }
        return out.joined(separator: ":")
    }

    /// The value if it names a UTF-8 locale (`…UTF-8` / `…utf8`), else `nil`.
    static func utf8Locale(_ value: String?) -> String? {
        guard let value else { return nil }
        let v = value.lowercased()
        return v.hasSuffix(".utf-8") || v.hasSuffix(".utf8") || v.contains(".utf-8@") || v.contains(".utf8@") ? value : nil
    }

    static func isAllowedOverride(_ name: String) -> Bool {
        !blockedOverrideNames.contains(name) && !blockedOverridePrefixes.contains { name.hasPrefix($0) }
    }

    /// POSIX-ish variable name: `[A-Za-z_][A-Za-z0-9_]*`.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.utf8.first, first == 0x5F || (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else {
            return false
        }
        return name.utf8.allSatisfy { $0 == 0x5F || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }
}

/// The holder's `--env-file` format: `KEY=VALUE` entries, each terminated by NUL, sorted by key.
public enum EnvironmentFile {
    public enum EncodeError: Error, Equatable {
        case invalidName(String)
        case nulInValue(String)
    }

    public static func encode(_ env: [String: String]) throws -> Data {
        var out = Data()
        for key in env.keys.sorted() {
            guard SpawnEnvironmentBuilder.isValidName(key) else { throw EncodeError.invalidName(key) }
            let value = env[key] ?? ""
            guard !value.contains("\0") else { throw EncodeError.nulInValue(key) }
            out.append(contentsOf: Array("\(key)=\(value)".utf8))
            out.append(0)
        }
        return out
    }

    /// Inverse of ``encode(_:)`` (also accepts a missing final NUL and skips empty entries).
    public static func decode(_ data: Data) -> [String: String] {
        var env: [String: String] = [:]
        for chunk in data.split(separator: 0, omittingEmptySubsequences: true) {
            let entry = String(decoding: chunk, as: UTF8.self)
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }
}
