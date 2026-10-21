import Foundation

/// The status line a CODD session chains (D8): the command Claude itself would have run below
/// CODD's `--settings` (D35), so a CODD session looks exactly like the user's other sessions.
public enum UserStatusLine {
    /// The statusLine keys CODD copies onto its injected statusLine object.
    public static let extraKeys = ["padding", "refreshInterval", "hideVimModeIndicator"]

    /// The command (and extras) a CODD session chains; nil without a status line. Unwraps CODD
    /// Desktop's own wrapper (CODD never chains itself); CODD web's wrapper is chained as is (it
    /// is the user's configuration until the installer migrates it).
    /// `files` in D35 precedence (cwd settings.local.json, cwd settings.json, user settings.json);
    /// the first one with a `statusLine.command` wins and its extras come from the same file.
    /// Extras are raw compact JSON texts (`2`, `true`, `"x"`).
    public static func chain(from files: [ClaudeSettingsFile],
                             desktopBinaryMarker: String = DesktopStatusLine.binaryMarker) -> (command: String, extras: [String: String])? {
        for file in files {
            guard let command = StatusLineKind.command(in: file.root) else { continue }
            var extras: [String: String] = [:]
            if let statusLine = file.root["statusLine"] {
                for key in extraKeys {
                    if let value = statusLine[key] { extras[key] = JSONWriter.compact(value) }
                }
            }
            guard DesktopStatusLine.looksLikeWrapper(command, marker: desktopBinaryMarker) else {
                return (command, extras)
            }
            guard let chain = desktopChain(command, marker: desktopBinaryMarker) else { return nil }
            return (chain, extras)
        }
        return nil
    }

    /// The D35 file list for a session: `<cwd>/.claude/settings.local.json`,
    /// `<cwd>/.claude/settings.json`, then the user's settings.
    public static func candidateURLs(cwd: String, userSettings: URL) -> [URL] {
        let project = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        return [project.appendingPathComponent("settings.local.json"),
                project.appendingPathComponent("settings.json"),
                userSettings]
    }

    /// Loads `urls` in order, skipping missing, unreadable and invalid files (Claude ignores
    /// them too). Blocking: call off the main actor.
    public static func loadFiles(_ urls: [URL], maxBytes: Int = 4 << 20) -> [ClaudeSettingsFile] {
        urls.compactMap { url in
            guard let file = try? ClaudeSettingsFile.load(url, maxBytes: maxBytes), file.exists else { return nil }
            return file
        }
    }

    /// A desktop wrapper's chain: the exact grammar first; for a hand-edited wrapper the
    /// `--chain-b64` payload when it round-trips; else none (chaining an unknown command would
    /// risk running CODD inside CODD).
    private static func desktopChain(_ command: String, marker: String) -> String? {
        if let parsed = DesktopStatusLine.parse(command, marker: marker) { return parsed.chain }
        if case .decoded(let chain) = ChainBase64.find(in: command), !chain.isEmpty { return chain }
        return nil
    }
}
