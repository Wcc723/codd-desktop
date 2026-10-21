import Foundation

/// What git says about one path (porcelain v2 entry kinds, collapsed to what the tree shows).
public enum GitFileChange: String, Sendable {
    case modified, added, deleted, renamed, copied, untracked, conflicted, typeChanged
}

/// `git status --porcelain=v2 --branch` of one work tree.
public struct GitRepoStatus: Sendable, Equatable {
    /// The work tree's top level (the folder the status ran in).
    public var root: URL
    /// The checked-out branch; nil while detached.
    public var branch: String?
    public var detached: Bool
    /// `origin/main`; nil without an upstream.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Repo-relative path → change. Renames and copies are keyed by the new path.
    public var changes: [String: GitFileChange]
    /// Repo-relative new path → original path of a rename or copy (a renamed file's HEAD text lives
    /// at the original path: `headText(root:relativePath: renamedFrom[path])`).
    public var renamedFrom: [String: String]
    /// The HEAD commit; nil before the first commit (`(initial)`).
    public var headOID: String?

    public init(root: URL, branch: String? = nil, detached: Bool = false, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                changes: [String: GitFileChange] = [:], renamedFrom: [String: String] = [:], headOID: String? = nil) {
        self.root = root
        self.branch = branch
        self.detached = detached
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.renamedFrom = renamedFrom
        self.headOID = headOID
    }

    /// Paths the tree badges `M` (everything git reports, untracked included).
    public var changedPaths: Set<String> { Set(changes.keys) }

    /// Whether `folder` (repo-relative, "" = the root) contains a change (the tree's folder dot).
    public func folderContainsChanges(_ folder: String) -> Bool {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return changes.keys.contains { $0.hasPrefix(prefix) }
    }
}

/// Why a git read failed.
public enum GitError: Error, Equatable, Sendable {
    /// git exited non-zero (stderr's first line, capped).
    case failed(subcommand: String, status: Int32, message: String)
    /// The run itself failed: not launchable, killed at the timeout, too much output, cancelled.
    case run(subcommand: String, ProcessRunError)
    /// The output did not parse.
    case malformed(String)
}

/// The read-only git calls the file editor makes (D24). ``GitReader`` runs `/usr/bin/git`; mock
/// mode (D35) and tests use a fake such as ``StaticGitReader``. Every call is read-only: no index
/// refresh, no lock, no fsmonitor.
public protocol GitReading: Sendable {
    /// The work tree's top level for `folder`; nil when it is not inside a work tree.
    func repoRoot(for folder: URL) async -> URL?
    /// Branch, upstream, ahead / behind and the changed paths of the work tree at `root`.
    func status(root: URL) async throws -> GitRepoStatus
    /// The bytes of `relativePath` in HEAD; nil when HEAD has no such file (or no HEAD yet).
    func headText(root: URL, relativePath: String) async throws -> Data?
    /// Ignored paths, untracked ignored folders collapsed to the folder (`node_modules`), without
    /// trailing slashes.
    func ignored(root: URL) async throws -> Set<String>
    /// Tracked and untracked, not ignored, repo-relative paths (⌘P).
    func trackedAndUntracked(root: URL) async throws -> [String]
}

/// A ``GitReading`` over fixed values (mock mode, tests, previews). Never runs git.
public struct StaticGitReader: GitReading {
    public var root: URL?
    public var statusValue: GitRepoStatus?
    /// Repo-relative path → HEAD bytes.
    public var headFiles: [String: Data]
    public var ignoredPaths: Set<String>
    public var files: [String]

    public init(root: URL?, status: GitRepoStatus? = nil, headFiles: [String: Data] = [:], ignored: Set<String> = [], files: [String] = []) {
        self.root = root
        self.statusValue = status
        self.headFiles = headFiles
        self.ignoredPaths = ignored
        self.files = files
    }

    public func repoRoot(for folder: URL) async -> URL? {
        guard let root else { return nil }
        let r = root.standardizedFileURL.path
        let f = folder.standardizedFileURL.path
        return f == r || f.hasPrefix(r + "/") ? root : nil
    }

    public func status(root: URL) async throws -> GitRepoStatus {
        guard let statusValue else { throw GitError.failed(subcommand: "status", status: 128, message: "not a git repository") }
        return statusValue
    }

    public func headText(root: URL, relativePath: String) async throws -> Data? { headFiles[relativePath] }
    public func ignored(root: URL) async throws -> Set<String> { ignoredPaths }
    public func trackedAndUntracked(root: URL) async throws -> [String] { files }
}
