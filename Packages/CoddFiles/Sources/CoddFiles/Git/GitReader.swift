import Foundation

/// Runs `/usr/bin/git` read-only (D24).
///
/// Every run is `git -C <folder> --no-optional-locks -c core.fsmonitor=false <subcommand> …` with
/// `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, stdin `/dev/null`, killed (with its
/// process group) at the timeout, and logs `exec git path=<folder, ~-abbreviated> sub=<subcommand>`.
/// `--no-optional-locks` keeps `status` from refreshing and rewriting `.git/index`; the fsmonitor
/// override keeps a user's `core.fsmonitor=true` from spawning a daemon in their repository. Only
/// reading subcommands are ever run (`rev-parse`, `status`, `cat-file`, `ls-files`).
///
/// The environment is the process's own minus every inherited `GIT_*` variable (a parent's
/// `GIT_DIR` / `GIT_INDEX_FILE` would point git at another repository), plus `environment`
/// (tests pass `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_NOSYSTEM` there), plus the fixed variables above.
public struct GitReader: GitReading {
    public let gitPath: String
    public let timeout: Duration
    public let environment: [String: String]
    /// Output cap per run (a status of a huge repository, a large HEAD blob).
    public var maxOutputBytes = 64 * 1024 * 1024
    private let log: @Sendable (String) -> Void

    public init(gitPath: String = "/usr/bin/git", timeout: Duration = .seconds(5), environment: [String: String] = [:],
                log: @escaping @Sendable (String) -> Void) {
        self.gitPath = gitPath
        self.timeout = timeout
        self.environment = environment
        self.log = log
    }

    /// The global options every run starts with (tests check them).
    public static func globalArguments(folder: URL) -> [String] {
        ["-C", folder.path, "--no-optional-locks", "-c", "core.fsmonitor=false"]
    }

    public func repoRoot(for folder: URL) async -> URL? {
        guard let result = try? await run(folder: folder, ["rev-parse", "--show-toplevel"]), result.status == 0 else { return nil }
        var text = String(decoding: result.stdout, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        guard text.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: text, isDirectory: true)
    }

    public func status(root: URL) async throws -> GitRepoStatus {
        let result = try await checked(folder: root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        return try GitStatusParser.parse(result.stdout, root: root)
    }

    /// `cat-file blob HEAD:<path>`: plumbing, so no textconv, no filters, no pager. Any non-zero
    /// exit (no such path in HEAD, no commit yet, a folder) is "no HEAD text".
    public func headText(root: URL, relativePath: String) async throws -> Data? {
        let result = try await run(folder: root, ["cat-file", "blob", "HEAD:\(relativePath)"])
        return result.status == 0 ? result.stdout : nil
    }

    public func ignored(root: URL) async throws -> Set<String> {
        let result = try await checked(folder: root, ["ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z"])
        return Set(Self.nulFields(result.stdout).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
    }

    public func trackedAndUntracked(root: URL) async throws -> [String] {
        let result = try await checked(folder: root, ["ls-files", "-co", "--exclude-standard", "-z"])
        var seen = Set<String>()
        return Self.nulFields(result.stdout).filter { seen.insert($0).inserted }
    }

    // MARK: - Running

    /// The environment of every run.
    public func runEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_") }
        for (key, value) in environment { env[key] = value }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private func run(folder: URL, _ arguments: [String]) async throws -> ProcessResult {
        let sub = arguments.first ?? "-"
        log("exec git path=\(Self.abbreviate(folder.path)) sub=\(sub)")
        do {
            return try await ProcessRunner.run(executable: gitPath, arguments: Self.globalArguments(folder: folder) + arguments,
                                               environment: runEnvironment(), timeout: timeout, maxOutputBytes: maxOutputBytes)
        } catch let error as ProcessRunError {
            throw GitError.run(subcommand: sub, error)
        }
    }

    private func checked(folder: URL, _ arguments: [String]) async throws -> ProcessResult {
        let result = try await run(folder: folder, arguments)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr.prefix(400), as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? ""
            throw GitError.failed(subcommand: arguments.first ?? "-", status: result.status, message: message)
        }
        return result
    }

    static func nulFields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `~/…` for paths in the home folder (the log never needs the user name).
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
