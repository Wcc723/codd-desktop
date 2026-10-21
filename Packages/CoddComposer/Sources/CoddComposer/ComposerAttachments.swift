import Darwin
import Foundation
import Synchronization

/// The composer's pasted images, `<sessionDir>/attachments/<yyyyMMdd-HHmmss>-<6 hex>.png` (M2 D4),
/// are temporary (user decision 2026-10-18, 「暫存可以 24 小時刪除」): a file goes once no unsent draft
/// of its session names it and 24 h have passed since it was last sent (since it was written, when
/// it never was).
///
/// The clock is the file's modification date: writing the file sets it, every send of a prompt that
/// names the file sets it again (`markSent`), so "24 h since the last send, or since it was written"
/// is one `lstat`. Nothing else has to be stored or migrated, and a draft that keeps an image for
/// days still gives it its full 24 h from the moment it is sent.
///
/// Only regular files directly in a session's `attachments/` whose names are CODD's own are ever
/// touched: links are never followed (the session folder and `attachments/` are opened with
/// `O_NOFOLLOW`, entries are checked with `AT_SYMLINK_NOFOLLOW`), anything else is left alone.
///
/// A send marks its images synchronously, before its bytes go to the PTY (one `utimensat` per name,
/// review attachments-2), and every mark and every per-file decision of a sweep (`fstatat`, then
/// `unlinkat`) run under one lock: a sweep already running when the mark lands either removed the
/// file first (the send then sees it missing and never sends its path) or sees the new date and
/// keeps it. The sweep itself is blocking file I/O: run it off the main actor.
///
/// The clock is the wall clock. A file dated in the future (a clock set ahead, then corrected) is
/// dated back to the sweep's `now`, so it stays at most 24 h after the clock is right again; a clock
/// jumped forward cannot be told from the dates alone, and a sweep then may remove images sent
/// minutes before in real time (the limit is stated in docs/ARCHITECTURE.md).
public enum ComposerAttachments {
    public static let folderName = "attachments"
    /// How long a sent image stays.
    public static let retention: TimeInterval = 24 * 60 * 60
    /// What a history entry shows in place of an image that is gone (drawn as a dim chip).
    public static let expiredMarker = "[圖已過期]"
    /// A file dated later than a sweep's `now` plus this is dated back to `now` (review attachments-5).
    public static let futureSlack: TimeInterval = 5 * 60
    /// Marks and the sweep's per-file decisions, one at a time (see the type's comment).
    static let fileLock = Mutex(())

    /// `<yyyyMMdd-HHmmss>-<6 lowercase hex>.png`, exactly what `writeAttachment` creates.
    public static func isAttachmentName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 26 else { return false }
        func digits(_ range: Range<Int>) -> Bool { range.allSatisfy { (0x30...0x39).contains(bytes[$0]) } }
        func hex(_ range: Range<Int>) -> Bool {
            range.allSatisfy { (0x30...0x39).contains(bytes[$0]) || (0x61...0x66).contains(bytes[$0]) }
        }
        return digits(0..<8) && bytes[8] == 0x2D && digits(9..<15) && bytes[15] == 0x2D && hex(16..<22)
            && Array(bytes[22..<26]) == Array(".png".utf8)
    }

    // MARK: References in a text

    /// One attachment path in a text.
    public struct Reference: Equatable {
        /// UTF-16 range of the path as written (Terminal.app-escaped, as the composer inserts it):
        /// from its leading `/`, or, written relative, from the first character of the path's own.
        public var range: NSRange
        /// The file name (`20261018-093000-a1b2c3.png`).
        public var name: String
        /// The unescaped absolute path; nil for a relative one.
        public var path: String?
    }

    static let referenceExpression: NSRegularExpression = {
        // A literal pattern: it always compiles.
        try! NSRegularExpression(pattern: "attachments/([0-9]{8}-[0-9]{6}-[0-9a-f]{6}\\.png)")
    }()

    /// Every `…/attachments/<CODD name>` path in `text`, in order. A path is one shell word: it starts
    /// after an unescaped space or line break, after the previous path (two pasted images in a row
    /// touch), or at the text's start; an opening bracket or quote before its `/` is not part of it.
    /// Words written straight after it are not part of it either (review attachments-1: Chinese has no
    /// spaces, and the composer inserts a pasted image's path at the caret, so `看這張/Users/…` is
    /// common): everything up to the last character before the path's first `/` that a relative path
    /// would not hold (anything but ASCII letters, digits, `._-~+@%=$` and backslash escapes) is the
    /// user's text. So `看這張/Users/…` names `/Users/…`, `看這張~/…` the relative `~/…`.
    public static func references(in text: String) -> [Reference] {
        guard text.contains("attachments/") else { return [] }
        let ns = text as NSString
        var out: [Reference] = []
        var floor = 0
        for match in referenceExpression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = match.range.location
            let end = NSMaxRange(match.range)
            var wordStart = start
            while wordStart > floor {
                let c = ns.character(at: wordStart - 1)
                if isSpace(c), !isEscaped(ns, at: wordStart - 1, floor: floor) { break }
                wordStart -= 1
            }
            // The head: the word up to the path's first `/` (or to `attachments/` without one).
            var from = wordStart
            var index = wordStart
            var slash: Int?
            while index < start {
                let c = ns.character(at: index)
                if c == 0x2F {
                    slash = index
                    break
                }
                if c == 0x5C, index + 1 < start {
                    // An escaped character belongs to the path.
                    index += 2
                    continue
                }
                if !isRelativePathCharacter(c) { from = index + 1 }
                index += 1
            }
            let range = NSRange(location: from, length: end - from)
            let path = slash == from ? unescaped(ns.substring(with: range)) : nil
            out.append(Reference(range: range, name: ns.substring(with: match.range(at: 1)), path: path))
            floor = end
        }
        return out
    }

    /// The attachment file names `text` names (drafts keep these; a send marks these).
    public static func referencedNames(in text: String) -> Set<String> {
        Set(references(in: text).map(\.name))
    }

    /// `text` with every attachment path whose file is gone replaced by `expiredMarker`, so a
    /// recalled history entry never sends a missing path. An absolute path is checked where it
    /// points; a relative one by its name in `sessionDirectory`'s folder (left as is without one).
    /// Two markers that would touch get a space between them.
    public static func replacingMissing(in text: String, sessionDirectory: String?,
                                        exists: (String) -> Bool = ComposerAttachments.fileExists) -> String {
        let found = references(in: text)
        guard !found.isEmpty else { return text }
        let out = NSMutableString(string: text)
        var nextReplacedAt: Int?
        for reference in found.reversed() {
            let target = reference.path ?? sessionDirectory.map { $0 + "/" + folderName + "/" + reference.name }
            guard let target, !exists(target) else {
                nextReplacedAt = nil
                continue
            }
            let touches = nextReplacedAt == NSMaxRange(reference.range)
            out.replaceCharacters(in: reference.range, with: touches ? expiredMarker + " " : expiredMarker)
            nextReplacedAt = reference.range.location
        }
        return out as String
    }

    /// Whether something is at `path` (followed like Claude Code would read it).
    public static func fileExists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    // MARK: Sent marks and the sweep

    /// A send of a prompt naming `names`: each such regular file in the session's folder gets `date`
    /// as its modification date, which starts its 24 h. Links and other names are skipped. Returns
    /// how many were marked. A few `utimensat` calls: a send makes them on the main actor, right
    /// before its bytes go out (a sweep holds the lock for one file at a time).
    @discardableResult
    public static func markSent(_ names: Set<String>, sessionDirectory: String, at date: Date) -> Int {
        let valid = names.filter(isAttachmentName)
        guard !valid.isEmpty, let folder = openFolder(sessionDirectory) else { return 0 }
        defer { close(folder) }
        let times = [fileTime(date), fileTime(date)]
        var marked = 0
        fileLock.withLock { _ in
            for name in valid.sorted() {
                var info = stat()
                guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                if utimensat(folder, name, times, AT_SYMLINK_NOFOLLOW) == 0 { marked += 1 }
            }
        }
        return marked
    }

    /// A send of `text` from the session in `sessionDirectory`: every image it names is marked in that
    /// session's folder by name, and an absolute path into another session's folder (a prompt copied
    /// from one session to another, review attachments-3) is marked there too. Another folder counts
    /// only when it is `<sessions>/<id>/attachments/` of the same `sessions/` folder; it is opened
    /// with the same no-link rules. Returns how many files were marked.
    @discardableResult
    public static func markSent(in text: String, sessionDirectory: String, at date: Date) -> Int {
        let found = references(in: text)
        guard !found.isEmpty else { return 0 }
        var byFolder: [String: Set<String>] = [sessionDirectory: Set(found.map(\.name))]
        for reference in found {
            guard let path = reference.path, let folder = sessionFolder(of: path, besides: sessionDirectory) else { continue }
            byFolder[folder, default: []].insert(reference.name)
        }
        return byFolder.keys.sorted().reduce(0) { $0 + markSent(byFolder[$1] ?? [], sessionDirectory: $1, at: date) }
    }

    /// The session folder an absolute attachment path points into when it is a sibling of
    /// `sessionDirectory` (`<sessions>/<other id>`), compared without touching the disk; nil otherwise.
    static func sessionFolder(of path: String, besides sessionDirectory: String) -> String? {
        let file = URL(fileURLWithPath: path).standardized
        let attachments = file.deletingLastPathComponent()
        guard attachments.lastPathComponent == folderName else { return nil }
        let session = attachments.deletingLastPathComponent()
        let id = session.lastPathComponent
        guard !id.isEmpty, id != "/", id != ".", id != ".." else { return nil }
        let sessions = URL(fileURLWithPath: sessionDirectory).standardized.deletingLastPathComponent()
        guard session.deletingLastPathComponent().path == sessions.path else { return nil }
        let folder = sessions.path + "/" + id
        return folder == URL(fileURLWithPath: sessionDirectory).standardized.path ? nil : folder
    }

    /// What one sweep did.
    public struct Sweep: Sendable, Equatable {
        /// The session has an `attachments/` folder (a real directory, not a link).
        public var folderFound = false
        /// The names removed, sorted.
        public var removed: [String] = []
        /// Due but still named by an unsent draft.
        public var keptInDraft = 0
        /// Their 24 h are not over yet (files dated in the future included).
        public var keptRecent = 0
        /// Dated later than `now` plus `futureSlack`: dated back to `now` (a clock that was set ahead).
        public var redated = 0
        /// Due, but the unlink failed.
        public var failed = 0

        public init() {}

        /// Adds another session's sweep (the launch sweep's total).
        public mutating func add(_ other: Sweep) {
            folderFound = folderFound || other.folderFound
            removed += other.removed
            keptInDraft += other.keptInDraft
            keptRecent += other.keptRecent
            redated += other.redated
            failed += other.failed
        }
    }

    /// Removes the session's attachment files that `keeping` (the names unsent drafts use) does not
    /// name and whose modification date is at least `retention` before `now`. Only regular files
    /// directly inside `<sessionDirectory>/attachments/` with CODD's names; a linked session folder
    /// or `attachments/` is not entered. A file dated more than `futureSlack` after `now` is dated
    /// back to `now` and kept. Each file's check and removal hold `fileLock` (a send's mark waits
    /// for at most one file).
    public static func sweep(sessionDirectory: String, keeping: Set<String>, now: Date,
                             retention: TimeInterval = ComposerAttachments.retention) -> Sweep {
        var result = Sweep()
        guard let folder = openFolder(sessionDirectory) else { return result }
        defer { close(folder) }
        result.folderFound = true
        let cutoff = now.timeIntervalSince1970 - retention
        let latest = now.timeIntervalSince1970 + futureSlack
        let times = [fileTime(now), fileTime(now)]
        for name in listNames(folder) where isAttachmentName(name) {
            fileLock.withLock { _ in
                var info = stat()
                guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
                let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                if modified > latest {
                    if utimensat(folder, name, times, AT_SYMLINK_NOFOLLOW) == 0 { result.redated += 1 }
                    result.keptRecent += 1
                    return
                }
                guard modified <= cutoff else {
                    result.keptRecent += 1
                    return
                }
                guard !keeping.contains(name) else {
                    result.keptInDraft += 1
                    return
                }
                // A file swapped for a link after the check: unlinkat removes the link, never its target.
                if unlinkat(folder, name, 0) == 0 {
                    result.removed.append(name)
                } else if errno != ENOENT {
                    result.failed += 1
                }
            }
        }
        result.removed.sort()
        return result
    }

    // MARK: Helpers

    /// `<sessionDirectory>/attachments` as a directory descriptor, neither component a link.
    static func openFolder(_ sessionDirectory: String) -> Int32? {
        let session = open(sessionDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard session >= 0 else { return nil }
        defer { close(session) }
        let folder = openat(session, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return folder >= 0 ? folder : nil
    }

    /// The entry names of an open directory (its own descriptor stays open for the `*at` calls).
    static func listNames(_ folder: Int32) -> [String] {
        let listing = dup(folder)
        guard listing >= 0 else { return [] }
        guard let directory = fdopendir(listing) else {
            close(listing)
            return []
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            var raw = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    static func fileTime(_ date: Date) -> timespec {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        return timespec(tv_sec: Int(whole), tv_nsec: Int(((seconds - whole) * 1_000_000_000).rounded(.down)))
    }

    /// What a relative path's head may hold: ASCII letters, digits and `._-~+@%=$` (escapes are
    /// handled by the caller). Anything else (CJK, punctuation, brackets, quotes) is the user's text.
    static func isRelativePathCharacter(_ c: unichar) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case 0x2E, 0x5F, 0x2D, 0x7E, 0x2B, 0x40, 0x25, 0x3D, 0x24: true
        default: false
        }
    }

    static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Whether the character at `index` follows an odd number of backslashes (escaped).
    static func isEscaped(_ text: NSString, at index: Int, floor: Int) -> Bool {
        var count = 0
        var at = index - 1
        while at >= floor, text.character(at: at) == 0x5C {
            count += 1
            at -= 1
        }
        return count % 2 == 1
    }

    /// The path a Terminal.app-escaped word names (each backslash keeps the next character).
    static func unescaped(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        var escaping = false
        for scalar in word.unicodeScalars {
            if escaping {
                out.append(scalar)
                escaping = false
            } else if scalar == "\\" {
                escaping = true
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
