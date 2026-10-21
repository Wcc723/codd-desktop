import AppKit
import CoddCore
import CoddTerminal
import Foundation

/// Settings › 關於 versions (D28): App, macOS, Claude Code, cswap, libghostty.
///
/// `claude --version` runs once per Settings open (5 s timeout), and only for an executable this
/// run may start: on the standard data root the resolved `claude`, on any other root only the
/// DEBUG `-codd-claude-path` one (D3: a test instance never runs the user's claude); otherwise the
/// value is `—`. Every run is logged `exec claude path=<abbreviated> sub=--version` (D38). cswap's
/// version is the account store's own `cswap --version` (same isolation, D3).
@MainActor
final class VersionProbe {
    /// The executable `claude --version` may run (nil: none, `—`).
    let claudeExecutable: String?
    private let runner: any CommandRunner
    private let environment: [String: String]
    private let log: @MainActor (String) -> Void
    /// The last answer (`2.1.302`), nil before the first or after a failure.
    private(set) var claudeVersion: String?
    private(set) var runs = 0
    private var running: Task<Void, Never>?

    static let timeout: Duration = .seconds(5)

    init(claudeExecutable: String?, runner: any CommandRunner = ProcessCommandRunner(), environment: [String: String]? = nil,
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        // Only an absolute path is ever run (CommandInvocation does no PATH search).
        self.claudeExecutable = claudeExecutable.flatMap { $0.hasPrefix("/") ? $0 : nil }
        self.runner = runner
        self.log = log
        let home = NSHomeDirectory()
        self.environment = environment ?? ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NO_COLOR": "1", "LANG": "en_US.UTF-8"]
    }

    /// `claude --version` once (a second call while one runs waits for it).
    func refreshClaude() async {
        if let running { return await running.value }
        guard let executable = claudeExecutable else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.runs += 1
            self.log("exec claude path=\(HolderSessionStore.abbreviate(executable)) sub=--version")
            let invocation = CommandInvocation(executable: executable, arguments: ["--version"], environment: self.environment,
                                               timeout: Self.timeout, maxOutputBytes: 64 << 10)
            let runner = self.runner
            let output: String? = await Task.detached(priority: .utility) { () -> String? in
                guard let result = try? await runner.run(invocation), result.status == 0, !result.terminatedBySignal else { return nil }
                return String(decoding: result.stdout, as: UTF8.self)
            }.value
            self.claudeVersion = output.flatMap(Self.version(in:))
            if self.claudeVersion == nil { self.log("claude --version gave no version") }
        }
        running = task
        await task.value
        running = nil
    }

    /// The first `x.y.z` in the output (`2.1.302 (Claude Code)` → `2.1.302`).
    nonisolated static func version(in output: String) -> String? {
        guard let match = output.firstMatch(of: /(\d+)\.(\d+)\.(\d+)([-+][0-9A-Za-z.\-]+)?/) else { return nil }
        return String(match.output.0)
    }

    // MARK: The other rows

    /// `1.0.0 (12)`.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// `1.0.0`.
    static var appShortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// `27.0` / `26.1.2`.
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// `macOS · Apple Silicon`.
    static var platformLine: String {
        #if arch(arm64)
        "macOS \(macOSVersion) · Apple Silicon"
        #else
        "macOS \(macOSVersion) · Intel"
        #endif
    }

    static var libghosttyVersion: String { TerminalRuntime.libghosttyVersion }

    /// The five ABOUT cells in the artboard's order.
    static func rows(claude: String?, cswap: String?) -> [(key: String, value: String)] {
        [("App", appVersion), ("macOS", macOSVersion), ("Claude Code", claude ?? "—"), ("cswap", cswap ?? "—"),
         ("libghostty", libghosttyVersion)]
    }

    /// `複製版本資訊`: one `key value` line per row.
    static func diagnostics(_ rows: [(key: String, value: String)], dataRoot: String) -> String {
        (["CODD"] + rows.map { "\($0.key) \($0.value)" } + ["data root \(dataRoot)"]).joined(separator: "\n") + "\n"
    }
}
