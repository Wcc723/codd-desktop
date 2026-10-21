import Darwin
import Foundation
import Synchronization

/// One Claude Code conversation file (`<claudeDir>/projects/<slug>/<id>.jsonl`) as the resume
/// picker, the Home page and 刪除對話紀錄 show it.
public struct TranscriptSummary: Sendable, Equatable, Identifiable {
    public enum TitleSource: String, Sendable {
        /// The latest `custom-title` record (`/rename`, `-n`).
        case custom
        /// The latest `ai-title` record (Claude's generated title).
        case ai
        /// The first user prompt.
        case firstPrompt
        /// Nothing usable in the head of the file.
        case none
    }

    /// Claude session id (the file stem; what `claude --resume` takes).
    public var id: String
    /// Absolute `.jsonl` path.
    public var path: String
    /// From the lines (never decoded from the folder name: the slug is lossy).
    public var cwd: String?
    /// `customTitle` > `aiTitle` > first user prompt (≤ 80 characters) > `（沒有標題）`.
    public var title: String
    public var titleSource: TitleSource
    public var gitBranch: String?
    /// `cli`, `claude-desktop`, `claude-vscode`, `sdk-cli`, … (raw).
    public var entrypoint: String?
    /// The first line's `timestamp`.
    public var createdAt: Date?
    /// File modification time (what Claude's cleanup and `/resume` go by).
    public var lastActivity: Date
    public var sizeBytes: Int64

    public init(id: String, path: String, cwd: String?, title: String, titleSource: TitleSource, gitBranch: String? = nil,
                entrypoint: String? = nil, createdAt: Date? = nil, lastActivity: Date, sizeBytes: Int64) {
        self.id = id
        self.path = path
        self.cwd = cwd
        self.title = title
        self.titleSource = titleSource
        self.gitBranch = gitBranch
        self.entrypoint = entrypoint
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.sizeBytes = sizeBytes
    }
}

/// Reads Claude's transcripts READ-ONLY (D18, D20, D23): it locates and summarizes files and never
/// writes, renames or deletes anything (the app moves files to the Trash itself).
///
/// `~/.claude/projects` can hold gigabytes, so only the newest `limit` files of a folder are opened,
/// and of each only the first `headBytes` and the last `tailBytes`. Results are cached by path +
/// mtime + size (Mutex-protected), so repeated calls only `stat`. Every method blocks on file I/O:
/// call them off the main actor.
public final class TranscriptCatalog: Sendable {
    public let projectsDirectory: URL
    public let headBytes: Int
    public let tailBytes: Int

    /// Claude cuts folder names to this many characters and appends a hash.
    public static let maxFolderNameLength = 200
    public static let untitled = "（沒有標題）"
    static let titleMax = 80
    static let lastPromptMax = 200
    /// Custom / AI titles are short; this only bounds a hand-edited one.
    static let recordTitleMax = 200
    static let cacheLimit = 2048

    private let cache = Mutex(CacheState())

    public init(projectsDirectory: URL, headBytes: Int = 256 << 10, tailBytes: Int = 128 << 10) {
        self.projectsDirectory = projectsDirectory
        self.headBytes = max(1, headBytes)
        self.tailBytes = max(1, tailBytes)
    }

    // MARK: - Public API

    /// The conversations whose lines' cwd equals `cwd` (symlinks resolved on both sides), newest
    /// first, at most `limit`. All candidate files are `stat`ed and read newest first until `limit`
    /// of them match: `sdk-*` entrypoints (unless `includeSDK`) and other-cwd files do not count, so
    /// 50 newer `claude -p` runs never hide the folder's resumable conversations. At most
    /// `readLimit` files are opened (default `limit * 4 + 64`), so a huge folder stays cheap; fewer
    /// than `limit` may then come back.
    public func list(cwd: String, limit: Int = 50, includeSDK: Bool = false, readLimit: Int? = nil) -> [TranscriptSummary] {
        guard limit > 0, var matcher = CwdMatcher(cwd) else { return [] }
        let candidates = candidateFiles(for: cwd)
        let maxReads = max(limit, readLimit ?? (limit * 4 + 64))
        var out: [TranscriptSummary] = []
        var seenIds = Set<String>()
        for c in candidates.prefix(maxReads) {
            guard out.count < limit else { break }
            guard let summary = summarize(c, matcher: &matcher, includeSDK: includeSDK) else { continue }
            // The same conversation under two slugs (symlinked and physical folder): newest wins.
            guard seenIds.insert(c.id).inserted else { continue }
            out.append(summary)
        }
        return out
    }

    /// One conversation by its id (`claude --resume` title lookup), however old: the files named
    /// `<sessionId>.jsonl` in `cwd`'s folders whose lines carry `cwd`, newest first. `sdk-*`
    /// entrypoints are included (the caller asked for this id).
    public func transcript(sessionId: String, cwd: String) -> TranscriptSummary? {
        guard LaunchBuilder.isClaudeSessionId(sessionId), var matcher = CwdMatcher(cwd) else { return nil }
        var found: [Candidate] = []
        for folder in candidateFolders(for: cwd) {
            let path = folder + "/" + sessionId + ".jsonl"
            guard let info = ReadOnlyFile.regularFileInfo(path) else { continue }
            found.append(Candidate(id: sessionId, path: path, info: info))
        }
        found.sort(by: Candidate.newestFirst)
        for c in found {
            if let summary = summarize(c, matcher: &matcher, includeSDK: true) { return summary }
        }
        return nil
    }

    struct Candidate {
        var id: String
        var path: String
        var info: ReadOnlyFile.Info

        static func newestFirst(_ a: Candidate, _ b: Candidate) -> Bool {
            a.info.mtimeNanoseconds != b.info.mtimeNanoseconds ? a.info.mtimeNanoseconds > b.info.mtimeNanoseconds : a.path < b.path
        }
    }

    /// Every `<id>.jsonl` of `cwd`'s folders (each path once), newest first. Only `stat`.
    private func candidateFiles(for cwd: String) -> [Candidate] {
        var seenPaths = Set<String>()
        var candidates: [Candidate] = []
        for folder in candidateFolders(for: cwd) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(6))
                guard LaunchBuilder.isClaudeSessionId(id) else { continue }
                let path = folder + "/" + name
                guard seenPaths.insert(path).inserted, let info = ReadOnlyFile.regularFileInfo(path) else { continue }
                candidates.append(Candidate(id: id, path: path, info: info))
            }
        }
        candidates.sort(by: Candidate.newestFirst)
        return candidates
    }

    /// The summary of one candidate when its lines carry the wanted cwd (and, unless `includeSDK`,
    /// it is not an `sdk-*` run).
    private func summarize(_ c: Candidate, matcher: inout CwdMatcher, includeSDK: Bool) -> TranscriptSummary? {
        guard let (parsed, info) = summary(path: c.path, stat: c.info), matcher.matches(parsed.cwd) else { return nil }
        if !includeSDK, parsed.entrypoint?.hasPrefix("sdk-") == true { return nil }
        return TranscriptSummary(
            id: c.id, path: c.path, cwd: parsed.cwd, title: parsed.title, titleSource: parsed.titleSource,
            gitBranch: parsed.gitBranch, entrypoint: parsed.entrypoint, createdAt: parsed.createdAt,
            lastActivity: info.modified, sizeBytes: info.size)
    }

    /// The newest `last-prompt` record's `lastPrompt` in the tail of `<sessionId>.jsonl`, else the
    /// newest user message there (cleaned, ≤ 200 characters). D20 hover card / D26 resend fallback.
    public func lastPrompt(cwd: String, sessionId: String) -> String? {
        guard LaunchBuilder.isClaudeSessionId(sessionId), var matcher = CwdMatcher(cwd) else { return nil }
        for folder in candidateFolders(for: cwd) {
            let path = folder + "/" + sessionId + ".jsonl"
            guard let info = ReadOnlyFile.regularFileInfo(path), let (parsed, _) = summary(path: path, stat: info),
                  matcher.matches(parsed.cwd) else { continue }
            return parsed.lastPrompt
        }
        return nil
    }

    /// D26: the newest prompt of `<sessionId>.jsonl` exactly as the user sent it (only the
    /// surrounding whitespace trimmed: never cleaned, cut or flattened), for `↻ 重送上一則` after a
    /// relaunch. Read from the last `window` bytes, uncached (one call per failure). nil when no
    /// whole prompt line is in the window, or the newest prompt cannot be repeated as text (an
    /// image or several text blocks), so a resend never sends a part of what was asked. The
    /// `last-prompt` record is not used: Claude cuts it to 500 characters.
    public func resendablePrompt(cwd: String, sessionId: String, window: Int = 1 << 20) -> String? {
        guard LaunchBuilder.isClaudeSessionId(sessionId), var matcher = CwdMatcher(cwd) else { return nil }
        for folder in candidateFolders(for: cwd) {
            let path = folder + "/" + sessionId + ".jsonl"
            guard let info = ReadOnlyFile.regularFileInfo(path), let (parsed, _) = summary(path: path, stat: info),
                  matcher.matches(parsed.cwd) else { continue }
            let found = ReadOnlyFile.with(path, noFollow: true) { fd, info -> String? in
                let start = max(0, info.size - Int64(max(1, window)) - 1)
                guard let bytes = ReadOnlyFile.read(fd, offset: start, count: Int(info.size - start)) else { return nil }
                return bytes.withUnsafeBufferPointer { b in
                    // From offset 0 the first line is whole; else the byte before the window tells.
                    Self.newestFullPrompt(b, lines: Self.lineRanges(b, dropFirst: start > 0, dropLast: false))
                }
            }
            return found
        }
        return nil
    }

    /// Newest first: the first real user turn (``promptText(_:max:)``'s rules) decides; nil when it
    /// is not plain text.
    static func newestFullPrompt(_ b: UnsafeBufferPointer<UInt8>, lines: [Range<Int>]) -> String? {
        for r in lines.reversed() {
            let line = UnsafeBufferPointer(rebasing: b[r])
            guard contains(line, needleUser), !contains(line, needleToolResult), let o = object(line) else { continue }
            switch fullPromptText(o) {
            case .notAPrompt: continue
            case .prompt(let text): return text
            case .notRepeatable: return nil
            }
        }
        return nil
    }

    enum FullPrompt: Equatable {
        case notAPrompt
        case prompt(String)
        /// A real prompt that is not one plain text (an image, a document, several text blocks).
        case notRepeatable
    }

    /// The whole text of a real user turn (same filters as ``promptText(_:max:)``).
    static func fullPromptText(_ o: [String: JSONValue]) -> FullPrompt {
        guard o["type"]?.stringValue == "user", o["isMeta"]?.boolValue != true, o["isSidechain"]?.boolValue != true,
              o["isCompactSummary"]?.boolValue != true, o["toolUseResult"] == nil,
              let message = o["message"]?.objectValue, message["role"]?.stringValue == "user" else { return .notAPrompt }
        var texts: [String] = []
        var other = false
        switch message["content"] {
        case .string(let s)?:
            texts = [s]
        case .array(let blocks)?:
            if blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) { return .notAPrompt }
            for block in blocks {
                if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue {
                    texts.append(text)
                } else {
                    other = true
                }
            }
        default:
            return .notAPrompt
        }
        let typed = texts.map(JSText.trim).filter { text in
            !text.isEmpty && !skippedPromptPrefixes.contains(where: { text.hasPrefix($0) })
        }
        guard !typed.isEmpty else { return .notAPrompt }
        guard typed.count == 1, !other else { return .notRepeatable }
        return .prompt(typed[0])
    }

    /// The files of one conversation for D23: `<sessionId>.jsonl` when its lines carry `cwd`, plus
    /// the sibling `<sessionId>/` folder (subagents, tool results) when it exists. Symlinks are never
    /// returned and every path must resolve inside the projects directory, so a link cannot make the
    /// app trash something else. Read-only; empty when nothing matches.
    public func files(sessionId: String, cwd: String) -> [URL] {
        guard LaunchBuilder.isClaudeSessionId(sessionId), var matcher = CwdMatcher(cwd),
              let root = ReadOnlyFile.realPath(projectsDirectory.path) else { return [] }
        func isInside(_ path: String) -> String? {
            guard let real = ReadOnlyFile.realPath(path), real.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
            return real
        }
        var out: [URL] = []
        var seen = Set<String>()
        for folder in candidateFolders(for: cwd) {
            let path = folder + "/" + sessionId + ".jsonl"
            guard let info = ReadOnlyFile.regularFileInfo(path), let real = isInside(path), seen.insert(real).inserted,
                  let (parsed, _) = summary(path: path, stat: info), matcher.matches(parsed.cwd) else { continue }
            out.append(URL(fileURLWithPath: path, isDirectory: false))
            let sibling = folder + "/" + sessionId
            if ReadOnlyFile.isRealDirectory(sibling), let realSibling = isInside(sibling), seen.insert(realSibling).inserted {
                out.append(URL(fileURLWithPath: sibling, isDirectory: true))
            }
        }
        return out
    }

    /// Claude Code's folder name for a cwd (2.1.301 `Z0`): every UTF-16 unit outside `[A-Za-z0-9]`
    /// becomes `-` (JS `replace(/[^a-zA-Z0-9]/g,'-')`); a result over 200 characters is cut to 200
    /// and `-` + base-36 `|javaHash(cwd)|` is appended. Lossy: never decode it back to a path.
    public static func folderName(for cwd: String) -> String {
        let slug = sanitized(cwd)
        guard slug.utf8.count > maxFolderNameLength else { return slug }
        return String(slug.prefix(maxFolderNameLength)) + "-" + hashSuffix(cwd)
    }

    // MARK: - Folders

    /// `[A-Za-z0-9]` kept, every other UTF-16 unit `-` (so one CJK character is one `-`, an emoji two).
    static func sanitized(_ path: String) -> String {
        String(decoding: path.utf16.map { unit -> UInt8 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: UInt8(unit)
            default: 0x2D
            }
        }, as: UTF8.self)
    }

    /// `Math.abs(h).toString(36)` of the Java-style string hash Claude uses (`h = (h<<5) - h + unit | 0`).
    static func hashSuffix(_ path: String) -> String {
        var h: Int32 = 0
        for unit in path.utf16 { h = (h &<< 5) &- h &+ Int32(unit) }
        return String(abs(Int64(h)), radix: 36)
    }

    /// The folders that may hold `cwd`'s transcripts: the slugs of the cwd as given, standardized
    /// (`~`, `..`, `/private` stripped like `URL.standardizedFileURL`) and symlink-resolved (in both
    /// spellings, `/private/var/…` and `/var/…`), since Claude names the folder after whichever form
    /// it was started with. A slug over 200 characters is also looked up by its 200-character
    /// prefix (the hash may differ between versions); the lines' cwd decides in the end.
    func candidateFolders(for cwd: String) -> [String] {
        let base = projectsDirectory.path
        let standardized = Self.standardize(cwd)
        let real = ReadOnlyFile.realPath(standardized)
        let forms = [cwd, standardized, (standardized as NSString).standardizingPath, real, real.map(Self.standardize)]
        var slugs: [(slug: String, form: String)] = []
        for form in forms.compactMap({ $0 }) where form.hasPrefix("/") {
            let slug = Self.sanitized(form)
            if !slugs.contains(where: { $0.slug == slug }) { slugs.append((slug, form)) }
        }
        var names: [String] = []
        var listing: [String]?
        for (slug, form) in slugs {
            if slug.utf8.count <= Self.maxFolderNameLength {
                if !names.contains(slug) { names.append(slug) }
                continue
            }
            let prefix = String(slug.prefix(Self.maxFolderNameLength))
            let exact = prefix + "-" + Self.hashSuffix(form)
            if !names.contains(exact) { names.append(exact) }
            if listing == nil { listing = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted() }
            for name in listing ?? [] where name.hasPrefix(prefix) && !names.contains(name) {
                names.append(name)
            }
        }
        return names.map { base + "/" + $0 }
    }

    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Compares line cwds with the wanted one after standardizing and resolving symlinks on both
    /// sides (`/var` vs `/private/var`), memoized per call (most lines share one cwd).
    struct CwdMatcher {
        let wanted: String
        private var memo: [String: Bool] = [:]

        init?(_ cwd: String) {
            guard cwd.hasPrefix("/") || cwd.hasPrefix("~") else { return nil }
            wanted = Self.canonical(cwd)
        }

        mutating func matches(_ cwd: String?) -> Bool {
            guard let cwd, cwd.hasPrefix("/") else { return false }
            if let known = memo[cwd] { return known }
            let result = cwd == wanted || Self.canonical(cwd) == wanted
            memo[cwd] = result
            return result
        }

        static func canonical(_ path: String) -> String {
            let standardized = TranscriptCatalog.standardize(path)
            return ReadOnlyFile.realPath(standardized) ?? standardized
        }
    }

    // MARK: - Cache

    struct Parsed: Sendable, Equatable {
        var cwd: String?
        var gitBranch: String?
        var entrypoint: String?
        var createdAt: Date?
        var title: String
        var titleSource: TranscriptSummary.TitleSource
        var lastPrompt: String?
    }

    private struct CachedFile {
        var info: ReadOnlyFile.Info
        var parsed: Parsed
        var lastUse: UInt64
    }

    private struct CacheState {
        var files: [String: CachedFile] = [:]
        var tick: UInt64 = 0
        /// Files actually opened and parsed (tests check that a warm call reads nothing).
        var reads = 0
    }

    /// How many files have been opened and parsed so far (cache misses).
    var fileReads: Int { cache.withLock { $0.reads } }

    /// The parsed head/tail of `path`, from the cache when its mtime and size still match `stat`.
    /// The file is read outside the lock; the info returned is the one the parse saw.
    func summary(path: String, stat: ReadOnlyFile.Info) -> (Parsed, ReadOnlyFile.Info)? {
        let hit: (Parsed, ReadOnlyFile.Info)? = cache.withLock { state in
            guard var entry = state.files[path], entry.info == stat else { return nil }
            state.tick += 1
            entry.lastUse = state.tick
            state.files[path] = entry
            return (entry.parsed, entry.info)
        }
        if let hit { return hit }
        let head = headBytes, tail = tailBytes
        guard let (parsed, info) = ReadOnlyFile.with(path, noFollow: true, { fd, info -> (Parsed, ReadOnlyFile.Info)? in
            Self.read(fd, info: info, headBytes: head, tailBytes: tail).map { ($0, info) }
        }) else { return nil }
        cache.withLock { state in
            state.reads += 1
            state.tick += 1
            state.files[path] = CachedFile(info: info, parsed: parsed, lastUse: state.tick)
            if state.files.count > Self.cacheLimit {
                // Drop the least recently used quarter (cheaper than evicting one per insert).
                let victims = state.files.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(Self.cacheLimit / 4)
                for (key, _) in victims { state.files[key] = nil }
            }
        }
        return (parsed, info)
    }

    // MARK: - Reading

    /// One read when the file fits in head + tail, else the head and the tail (plus the byte before
    /// it, which tells whether the tail starts on a line boundary).
    static func read(_ fd: Int32, info: ReadOnlyFile.Info, headBytes: Int, tailBytes: Int) -> Parsed? {
        if info.size <= Int64(headBytes) + Int64(tailBytes) {
            guard let all = ReadOnlyFile.read(fd, offset: 0, count: Int(info.size)) else { return nil }
            return all.withUnsafeBufferPointer { b in
                let lines = lineRanges(b, dropFirst: false, dropLast: false)
                return parse(head: b, headLines: lines, tail: b, tailLines: lines)
            }
        }
        let tailStart = info.size - Int64(tailBytes) - 1
        guard let head = ReadOnlyFile.read(fd, offset: 0, count: headBytes),
              let tail = ReadOnlyFile.read(fd, offset: tailStart, count: tailBytes + 1) else { return nil }
        return head.withUnsafeBufferPointer { h in
            tail.withUnsafeBufferPointer { t in
                parse(head: h, headLines: lineRanges(h, dropFirst: false, dropLast: true),
                      tail: t, tailLines: lineRanges(t, dropFirst: true, dropLast: false))
            }
        }
    }

    /// LF-separated, non-empty line ranges (a trailing CR dropped). `dropFirst` / `dropLast` skip
    /// the segment a chunk boundary may have cut.
    static func lineRanges(_ b: UnsafeBufferPointer<UInt8>, dropFirst: Bool, dropLast: Bool) -> [Range<Int>] {
        guard let base = b.baseAddress, !b.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var start = 0
        var first = true
        func add(_ lower: Int, _ upper: Int) {
            defer { first = false }
            if first, dropFirst { return }
            var end = upper
            if end > lower, b[end - 1] == 0x0D { end -= 1 }
            if end > lower { out.append(lower..<end) }
        }
        while start <= b.count {
            let remaining = b.count - start
            guard remaining > 0, let hit = memchr(base + start, 0x0A, remaining) else {
                if !dropLast { add(start, b.count) }
                break
            }
            let lf = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            add(start, lf)
            start = lf + 1
        }
        return out
    }

    private static let needleCwd = Array("\"cwd\"".utf8)
    private static let needleEntrypoint = Array("\"entrypoint\"".utf8)
    private static let needleTimestamp = Array("\"timestamp\"".utf8)
    private static let needleBranch = Array("\"gitBranch\"".utf8)
    private static let needleEmptyBranch = Array("\"gitBranch\":\"\"".utf8)
    private static let needleUser = Array("\"user\"".utf8)
    private static let needleToolResult = Array("\"toolUseResult\"".utf8)
    private static let needleCustomTitle = Array("\"custom-title\"".utf8)
    private static let needleAITitle = Array("\"ai-title\"".utf8)
    private static let needleLastPrompt = Array("\"last-prompt\"".utf8)

    /// Head pass (oldest first): the first cwd, branch, entrypoint, timestamp and user prompt.
    /// Tail pass (newest first): titles, the last prompt, and cwd / branch when the head had none
    /// (a first line longer than the head). A line is decoded only when a byte search says it may
    /// carry something still missing, so a 256 KiB head of tool output costs a few `memmem`s.
    static func parse(head: UnsafeBufferPointer<UInt8>, headLines: [Range<Int>],
                      tail: UnsafeBufferPointer<UInt8>, tailLines: [Range<Int>]) -> Parsed {
        var cwd: String?, branch: String?, entrypoint: String?, createdAt: Date?, firstPrompt: String?
        var headCustom: String?, headAI: String?
        for r in headLines {
            let line = UnsafeBufferPointer(rebasing: head[r])
            let wantCwd = cwd == nil && contains(line, needleCwd)
            let wantEntry = entrypoint == nil && contains(line, needleEntrypoint)
            let wantTime = createdAt == nil && contains(line, needleTimestamp)
            let wantBranch = branch == nil && contains(line, needleBranch) && !contains(line, needleEmptyBranch)
            let wantPrompt = firstPrompt == nil && contains(line, needleUser) && !contains(line, needleToolResult)
            let wantCustom = contains(line, needleCustomTitle)
            let wantAI = contains(line, needleAITitle)
            guard wantCwd || wantEntry || wantTime || wantBranch || wantPrompt || wantCustom || wantAI,
                  let o = object(line) else { continue }
            if cwd == nil { cwd = JSText.nonBlank(o["cwd"]) }
            if entrypoint == nil { entrypoint = JSText.nonBlankTrimmed(o["entrypoint"]) }
            if createdAt == nil { createdAt = JSDate.timestamp(o["timestamp"]).map(JSDate.date(milliseconds:)) }
            if branch == nil { branch = JSText.nonBlankTrimmed(o["gitBranch"]) }
            if firstPrompt == nil { firstPrompt = promptText(o, max: titleMax) }
            if let t = recordTitle(o, type: "custom-title", key: "customTitle") { headCustom = t }
            if let t = recordTitle(o, type: "ai-title", key: "aiTitle") { headAI = t }
        }

        var tailCustom: String?, tailAI: String?, recordPrompt: String?, userPrompt: String?
        var tailCwd: String?, tailBranch: String?
        let needCwd = cwd == nil, needBranch = branch == nil
        for r in tailLines.reversed() {
            let line = UnsafeBufferPointer(rebasing: tail[r])
            let wantCustom = tailCustom == nil && contains(line, needleCustomTitle)
            let wantAI = tailAI == nil && contains(line, needleAITitle)
            let wantRecord = recordPrompt == nil && contains(line, needleLastPrompt)
            let wantUser = userPrompt == nil && contains(line, needleUser) && !contains(line, needleToolResult)
            let wantCwd = needCwd && tailCwd == nil && contains(line, needleCwd)
            let wantBranch = needBranch && tailBranch == nil && contains(line, needleBranch) && !contains(line, needleEmptyBranch)
            if wantCustom || wantAI || wantRecord || wantUser || wantCwd || wantBranch, let o = object(line) {
                if tailCustom == nil { tailCustom = recordTitle(o, type: "custom-title", key: "customTitle") }
                if tailAI == nil { tailAI = recordTitle(o, type: "ai-title", key: "aiTitle") }
                if recordPrompt == nil, o["type"]?.stringValue == "last-prompt" {
                    recordPrompt = o["lastPrompt"]?.stringValue.flatMap { cleaned($0, max: lastPromptMax) }
                }
                if userPrompt == nil { userPrompt = promptText(o, max: lastPromptMax) }
                if needCwd, tailCwd == nil { tailCwd = JSText.nonBlank(o["cwd"]) }
                if needBranch, tailBranch == nil { tailBranch = JSText.nonBlankTrimmed(o["gitBranch"]) }
            }
            let done = tailCustom != nil && tailAI != nil && recordPrompt != nil && (!needCwd || tailCwd != nil)
                && (!needBranch || tailBranch != nil)
            if done { break }
        }

        let title: String
        let source: TranscriptSummary.TitleSource
        if let custom = tailCustom ?? headCustom {
            (title, source) = (custom, .custom)
        } else if let ai = tailAI ?? headAI {
            (title, source) = (ai, .ai)
        } else if let firstPrompt {
            (title, source) = (firstPrompt, .firstPrompt)
        } else {
            (title, source) = (untitled, .none)
        }
        return Parsed(cwd: cwd ?? tailCwd, gitBranch: branch ?? tailBranch, entrypoint: entrypoint, createdAt: createdAt,
                      title: title, titleSource: source, lastPrompt: recordPrompt ?? userPrompt)
    }

    private static func object(_ line: UnsafeBufferPointer<UInt8>) -> [String: JSONValue]? {
        JSONValue.parse(Data(buffer: line))?.objectValue
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { n in memmem(base, haystack.count, n.baseAddress, n.count) != nil }
    }

    /// A `custom-title` / `ai-title` record's value, cleaned; `nil` for other lines or a blank value.
    private static func recordTitle(_ o: [String: JSONValue], type: String, key: String) -> String? {
        guard o["type"]?.stringValue == type, let raw = o[key]?.stringValue else { return nil }
        return cleaned(raw, max: recordTitleMax)
    }

    /// Text CODD or Claude put into the user turn, never what the user typed.
    static let skippedPromptPrefixes = [
        "<command-name>", "<command-message>", "<local-command-", "Caveat:",
        "<bash-stdout", "<bash-stderr", "<system-reminder>", "[Request interrupted by user",
    ]

    /// The prompt of a real user turn: `type` user, `message.role` user, not meta, not a sidechain,
    /// not a compaction summary or tool result; string content or `{type:'text'}` blocks (the first
    /// block that is not skipped). Cleaned and cut to `max` characters with a trailing `…`.
    static func promptText(_ o: [String: JSONValue], max: Int) -> String? {
        guard o["type"]?.stringValue == "user", o["isMeta"]?.boolValue != true, o["isSidechain"]?.boolValue != true,
              o["isCompactSummary"]?.boolValue != true, o["toolUseResult"] == nil,
              let message = o["message"]?.objectValue, message["role"]?.stringValue == "user" else { return nil }
        let texts: [String]
        switch message["content"] {
        case .string(let s)?:
            texts = [s]
        case .array(let blocks)?:
            if blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) { return nil }
            texts = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
        default:
            return nil
        }
        for text in texts {
            let trimmed = JSText.trim(text)
            guard !trimmed.isEmpty, !skippedPromptPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { continue }
            if let c = cleaned(trimmed, max: max) { return c }
        }
        return nil
    }

    /// Controls removed and whitespace collapsed (``JSText/cleanText(_:max:)``), then at most `max`
    /// characters, the last one `…` when cut.
    static func cleaned(_ text: String, max: Int) -> String? {
        guard max > 0, let c = JSText.cleanText(text, max: max * 4 + 16) else { return nil }
        guard c.count > max else { return c }
        return String(c.prefix(max - 1)) + "…"
    }
}

/// Claude deletes transcripts older than `cleanupPeriodDays` (default 30) at startup; the resume
/// picker warns before that happens (`! resume 4 天後過期`).
public enum TranscriptRetention {
    public static let defaultCleanupPeriodDays = 30

    /// `cleanupPeriodDays` minus the whole days since `lastActivity`, when that is between 0 and
    /// `warnWithin`; 0 when already overdue (the file still exists until Claude's next cleanup);
    /// `nil` otherwise (no warning).
    public static func daysLeft(lastActivity: Date, now: Date, cleanupPeriodDays: Int = 30, warnWithin: Int = 5) -> Int? {
        guard cleanupPeriodDays >= 1 else { return nil }
        let days = (now.timeIntervalSince(lastActivity) / 86_400).rounded(.down)
        guard days.isFinite else { return nil }
        let left = cleanupPeriodDays - Int(Swift.max(-1e9, Swift.min(1e9, days)))
        if left < 0 { return 0 }
        return left <= warnWithin ? left : nil
    }

    /// `cleanupPeriodDays` from Claude's settings.json (read-only, tolerant; `nil` when absent or invalid).
    public static func cleanupPeriodDays(settingsFile: URL) -> Int? {
        ClaudeUserSettings.read(settingsFile: settingsFile).cleanupPeriodDays
    }
}
