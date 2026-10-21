import Foundation

/// One project of `~/.claude.json` that can be imported (D8).
public struct ImportCandidate: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// Standardized absolute path (no trailing slash).
    public let path: String
    /// The folder name.
    public let name: String
    /// D10: `parent/` shown dim before the name (nil: the name alone is clear).
    public let prefix: String?
    /// The full path with `~` for the home folder; the VIEW elides it to the column (D10).
    public let displayPath: String
    /// The newest transcript's modification time, else the transcript folder's; nil: never used.
    public let lastUsed: Date?
    /// `.jsonl` files in the project's transcript folders.
    public let transcripts: Int

    public enum Hidden: String, Sendable {
        /// A `/.claude-worktrees/` path (Claude's agent worktrees).
        case worktree
        /// Every one of its newest ≤ 3 transcripts was started by the Agent SDK (`sdk-*` entrypoint).
        case sdk
    }

    /// Hidden by default (`顯示隱藏項目` shows it dimmed).
    public let hidden: Hidden?

    public init(path: String, name: String, prefix: String?, displayPath: String, lastUsed: Date?, transcripts: Int,
                hidden: Hidden?) {
        self.path = path
        self.name = name
        self.prefix = prefix
        self.displayPath = displayPath
        self.lastUsed = lastUsed
        self.transcripts = transcripts
        self.hidden = hidden
    }
}

/// What step 2 can import, newest first.
public struct ProjectCatalog: Sendable, Equatable {
    /// `~/.claude.json` as read (with `~`); nil when no file was found.
    public let source: String?
    /// Every candidate, hidden ones included, sorted by last use (never used last, then by path).
    public let candidates: [ImportCandidate]
    /// Existing project folders of the file that are already in CODD (left out; `另有 n 個已在側欄`).
    public let alreadyInCODD: Int
    /// Why nothing could be read (`找不到 ~/.claude.json`, a file too big or not JSON); nil when read.
    public let problem: String?

    public init(source: String?, candidates: [ImportCandidate], alreadyInCODD: Int, problem: String?) {
        self.source = source
        self.candidates = candidates
        self.alreadyInCODD = alreadyInCODD
        self.problem = problem
    }

    /// Candidates shown without `顯示隱藏項目` (the totals of the lead, the chip and the stepper).
    public var visibleTotal: Int { candidates.reduce(0) { $0 + ($1.hidden == nil ? 1 : 0) } }
    public var hiddenCount: Int { candidates.count - visibleTotal }

    public func candidate(_ path: String) -> ImportCandidate? { candidates.first { $0.path == path } }

    /// The empty catalog (mock mode, a reader that was not run).
    public static let empty = ProjectCatalog(source: nil, candidates: [], alreadyInCODD: 0, problem: nil)
}

/// D10's name prefix: `parent/` before the folder name when the name is not unique among the
/// candidates, or shorter than 7 characters with a parent that is neither the home folder nor a
/// common root.
public enum NamePrefixRule {
    public static let commonRoots: Set<String> = [
        "Github", "GitHub", "github", "Project", "Projects", "Developer", "Code", "code", "src", "repos", "work",
    ]
    public static let shortNameLength = 7

    /// `paths` (standardized) → prefix, for every path that gets one.
    public static func prefixes(for paths: [String], home: String) -> [String: String] {
        var counts: [String: Int] = [:]
        for path in paths { counts[PathText.lastComponent(path), default: 0] += 1 }
        let home = PathText.standardize(home)
        var out: [String: String] = [:]
        for path in paths {
            let name = PathText.lastComponent(path)
            let parent = PathText.parent(path)
            guard parent != "/" else { continue }
            let parentName = PathText.lastComponent(parent)
            let duplicate = (counts[name] ?? 0) > 1
            let short = name.count < shortNameLength && parent != home && !commonRoots.contains(parentName)
            if duplicate || short { out[path] = parentName + "/" }
        }
        return out
    }
}

/// Claude Code's transcript folder for a cwd (§2.5): every UTF-16 unit outside `[A-Za-z0-9]` becomes
/// `-` (JavaScript `replace(/[^a-zA-Z0-9]/g,'-')`, the rule of App/Real/ClaudeDirectory.swift and
/// CoddCore's TranscriptCatalog, reimplemented here to stay Foundation only).
public enum TranscriptFolderName {
    /// Claude cuts a longer name to this many characters and appends `-<hash>`.
    public static let maxLength = 200

    public static func sanitized(_ path: String) -> String {
        String(decoding: path.utf16.map { unit -> UInt8 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: UInt8(unit)
            default: 0x2D
            }
        }, as: UTF8.self)
    }
}

/// Reads `~/.claude.json` for step 2 (D8, §2.5). READ ONLY: it never writes, renames or touches any
/// Claude file (`.claude.json` is opened read-only; through a symlink, since dotfile managers link
/// it; transcript folders and files are `lstat`ed and never followed). Blocking: call it off the
/// main actor. Budget: 200 projects < 150 ms.
public enum ProjectCatalogReader {
    /// `.claude.json` keeps per-project history and can grow; a bigger file is not read.
    public static let maxFileBytes = 64 << 20
    /// At most this many project keys are looked at (sorted by key, so the cut is stable).
    public static let maxProjectKeys = 2000
    /// The SDK check reads at most this many of a project's newest transcripts …
    public static let sdkCheckFiles = 3
    /// … and at most this many bytes of each.
    public static let sdkCheckBytes = 8192

    /// - Parameters:
    ///   - claudeDirectory: `~/.claude` (the file is `<dir>/../.claude.json`, else `<dir>/.claude.json`).
    ///   - home: the home folder (for `~` and D10).
    ///   - existingProjectPaths: projects already in CODD (left out and counted).
    public static func read(claudeDirectory: URL, home: String, existingProjectPaths: Set<String>) -> ProjectCatalog {
        read(claudeDirectory: claudeDirectory, home: home, existingProjectPaths: existingProjectPaths, maxFileBytes: maxFileBytes,
             maxProjectKeys: maxProjectKeys)
    }

    /// `read` with the caps as parameters (tests use small ones).
    static func read(claudeDirectory: URL, home: String, existingProjectPaths: Set<String>, maxFileBytes: Int,
                     maxProjectKeys: Int) -> ProjectCatalog {
        let claudeDir = PathText.standardize(claudeDirectory.path, home: home)
        let files = [PathText.parent(claudeDir) + "/.claude.json", claudeDir + "/.claude.json"]
        guard let file = files.first(where: { isRegularFile(followingLinks: $0) }) else {
            return ProjectCatalog(source: nil, candidates: [], alreadyInCODD: 0, problem: "找不到 ~/.claude.json")
        }
        let source = PathText.abbreviate(file, home: home)
        let data: Data
        switch readFile(file, limit: maxFileBytes) {
        case .success(let bytes): data = bytes
        case .failure(let problem): return ProjectCatalog(source: source, candidates: [], alreadyInCODD: 0, problem: problem.message(source))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProjectCatalog(source: source, candidates: [], alreadyInCODD: 0, problem: "\(source) 無法解析")
        }
        let keys = ((object["projects"] as? [String: Any])?.keys).map(Array.init) ?? []
        return catalog(keys: keys, source: source, claudeDir: claudeDir, home: home, existing: existingProjectPaths,
                       maxKeys: maxProjectKeys)
    }

    /// The catalog of `keys` (the project keys of a `.claude.json`), for `read` and tests.
    static func catalog(keys: [String], source: String, claudeDir: String, home: String, existing: Set<String>,
                        maxKeys: Int = maxProjectKeys) -> ProjectCatalog {
        var known = Set<String>()
        for path in existing where path.hasPrefix("/") || path.hasPrefix("~") {
            let standardized = PathText.standardize(path, home: home)
            known.insert(standardized)
            if let real = realPath(standardized) { known.insert(real) }
        }
        let projectsDir = claudeDir + "/projects"
        var listing: [String]?
        var seen = Set<String>()
        var already = 0
        var raw: [(path: String, lastUsed: Date?, transcripts: Int, hidden: ImportCandidate.Hidden?)] = []
        for key in keys.filter({ $0.hasPrefix("/") }).sorted().prefix(maxKeys) {
            let path = PathText.standardize(key)
            guard path != "/", seen.insert(path).inserted, isDirectory(followingLinks: path) else { continue }
            if known.contains(path) || realPath(path).map(known.contains) == true {
                already += 1
                continue
            }
            var folders: [String] = []
            for form in [key, path] {
                let slug = TranscriptFolderName.sanitized(form)
                if slug.utf8.count <= TranscriptFolderName.maxLength {
                    let folder = projectsDir + "/" + slug
                    if !folders.contains(folder) { folders.append(folder) }
                    continue
                }
                // Claude cut the name and appended a hash (which may differ between versions):
                // every folder that starts with the 200-character prefix and `-` counts.
                let prefix = String(slug.prefix(TranscriptFolderName.maxLength)) + "-"
                if listing == nil { listing = ((try? FileManager.default.contentsOfDirectory(atPath: projectsDir)) ?? []).sorted() }
                for name in listing ?? [] where name.hasPrefix(prefix) {
                    let folder = projectsDir + "/" + name
                    if !folders.contains(folder) { folders.append(folder) }
                }
            }
            let scan = scanTranscripts(in: folders)
            let hidden: ImportCandidate.Hidden? = path.contains("/.claude-worktrees/") ? .worktree : (scan.sdkOnly ? .sdk : nil)
            raw.append((path, scan.newest ?? scan.folderModified, scan.count, hidden))
        }
        raw.sort { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.path < rhs.path
            }
        }
        let prefixes = NamePrefixRule.prefixes(for: raw.map(\.path), home: home)
        let candidates = raw.map { item in
            ImportCandidate(path: item.path, name: PathText.lastComponent(item.path), prefix: prefixes[item.path],
                            displayPath: PathText.abbreviate(item.path, home: home), lastUsed: item.lastUsed,
                            transcripts: item.transcripts, hidden: item.hidden)
        }
        return ProjectCatalog(source: source, candidates: candidates, alreadyInCODD: already, problem: nil)
    }

    // MARK: Transcripts

    struct Scan {
        var count = 0
        var newest: Date?
        var folderModified: Date?
        var sdkOnly = false
    }

    /// Counts the `.jsonl` regular files (lstat: links are not followed) in the real folders among
    /// `folders` and checks the newest ≤ 3 for the SDK entrypoint.
    static func scanTranscripts(in folders: [String]) -> Scan {
        var scan = Scan()
        var files: [(path: String, modified: Date)] = []
        for folder in folders {
            guard let info = lstatInfo(folder), info.kind == S_IFDIR else { continue }
            if scan.folderModified.map({ info.modified > $0 }) ?? true { scan.folderModified = info.modified }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".jsonl") {
                let file = folder + "/" + name
                guard let entry = lstatInfo(file), entry.kind == S_IFREG else { continue }
                files.append((file, entry.modified))
            }
        }
        scan.count = files.count
        files.sort { $0.modified > $1.modified }
        scan.newest = files.first?.modified
        let newest = files.prefix(sdkCheckFiles)
        scan.sdkOnly = !newest.isEmpty && newest.allSatisfy { startsWithSDKEntrypoint($0.path) }
        return scan
    }

    private static let sdkNeedles: [[UInt8]] = [
        Array(#""entrypoint":"sdk-"#.utf8), Array(#""entrypoint": "sdk-"#.utf8),
    ]

    /// Whether the first 8 KiB of `file` carry `"entrypoint":"sdk-` (opened with O_NOFOLLOW).
    static func startsWithSDKEntrypoint(_ file: String) -> Bool {
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: sdkCheckBytes)
        var filled = 0
        while filled < buffer.count {
            let got = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: filled), raw.count - filled)
            }
            if got <= 0 { break }
            filled += got
        }
        let head = buffer.prefix(filled)
        return sdkNeedles.contains { needle in contains(head, needle) }
    }

    private static func contains(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count, let first = needle.first else { return false }
        var index = haystack.startIndex
        let last = haystack.endIndex - needle.count
        while index <= last {
            if haystack[index] == first, haystack[index..<(index + needle.count)].elementsEqual(needle) { return true }
            index += 1
        }
        return false
    }

    // MARK: Files

    enum ReadProblem: Error {
        case tooLarge, unreadable(String)

        func message(_ source: String) -> String {
            switch self {
            case .tooLarge: "\(source) 太大（超過 64 MB），沒有讀取"
            case .unreadable(let reason): "讀不到 \(source)：\(reason)"
            }
        }
    }

    /// The whole file, read through a symlink (reading is harmless), at most `maxFileBytes`.
    static func readFile(_ path: String, limit: Int = maxFileBytes) -> Result<Data, ReadProblem> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable(String(cString: strerror(errno)))) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.unreadable("不是一般檔案")) }
        guard info.st_size <= Int64(limit) else { return .failure(.tooLarge) }
        var data = Data(count: Int(info.st_size) + 1)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while filled < raw.count {
                let got = Darwin.read(fd, raw.baseAddress!.advanced(by: filled), raw.count - filled)
                if got < 0 { return false }
                if got == 0 { break }
                filled += got
            }
            return true
        }
        guard ok else { return .failure(.unreadable(String(cString: strerror(errno)))) }
        guard filled <= limit else { return .failure(.tooLarge) }
        data.count = filled
        return .success(data)
    }

    struct Info {
        let kind: mode_t
        let modified: Date
    }

    static func lstatInfo(_ path: String) -> Info? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return Info(kind: info.st_mode & S_IFMT, modified: modified)
    }

    static func isRegularFile(followingLinks path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isDirectory(followingLinks path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
