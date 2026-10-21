import Darwin
import Foundation

/// One name in a folder listing (names only: the tree never reads a file's contents).
public struct FileTreeEntry: Sendable, Equatable, Identifiable {
    /// Root-relative, `/`-separated (`src/pages/punch.vue`).
    public var relativePath: String
    public var name: String
    /// A folder, or a symbolic link to one.
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// A dot name (`.env.local`).
    public var isHidden: Bool
    /// The path or one of its folders is git-ignored.
    public var isIgnored: Bool
    /// The `…` marker after the first ``FileTreeModel/maxEntriesPerFolder`` entries.
    public var isOverflow: Bool
    /// How many entries the marker stands for (0 for real entries).
    public var overflowCount: Int
    public var id: String

    public init(relativePath: String, name: String, isDirectory: Bool, isSymlink: Bool = false, isHidden: Bool = false,
                isIgnored: Bool = false, isOverflow: Bool = false, overflowCount: Int = 0) {
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isIgnored = isIgnored
        self.isOverflow = isOverflow
        self.overflowCount = overflowCount
        self.id = isOverflow ? relativePath + "/\u{2026}" : relativePath
    }
}

public enum FileTreeError: Error, Equatable, Sendable {
    /// `opendir` failed (errno).
    case unreadable(path: String, errno: Int32)
}

/// The project tree, read lazily one folder at a time (D24): names and kinds from `readdir`
/// (`d_type`, an `lstat` only when the file system does not report it, a `stat` only for symlinks),
/// folders first, then natural case-insensitive order (`file2` before `file10`), at most
/// ``maxEntriesPerFolder`` entries per folder followed by one `…` marker.
public struct FileTreeModel: Sendable {
    public static let maxEntriesPerFolder = 2_000

    public let root: URL
    /// Names never listed (VS Code's default `files.exclude` for the tree).
    public var excludedNames: Set<String> = [".git", ".DS_Store"]

    public init(root: URL) {
        self.root = root
    }

    /// The entries of `relativePath` ("" = the root). `ignored` is the reader's ignored set
    /// (`GitReading.ignored`); an entry inside an ignored folder is ignored too.
    public func children(of relativePath: String, ignored: Set<String>) throws -> [FileTreeEntry] {
        let folder = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath, isDirectory: true)
        var raw = try Self.readNames(folder.path)
        raw.removeAll { excludedNames.contains($0.name) }
        // A link to a folder sorts and expands as a folder.
        for index in raw.indices where raw[index].isSymlink {
            var st = stat()
            raw[index].isDirectory = stat(folder.path + "/" + raw[index].name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        raw.sort(by: Self.order)
        let kept = raw.prefix(Self.maxEntriesPerFolder)
        var entries: [FileTreeEntry] = kept.map { item in
            let path = relativePath.isEmpty ? item.name : relativePath + "/" + item.name
            return FileTreeEntry(relativePath: path, name: item.name, isDirectory: item.isDirectory, isSymlink: item.isSymlink,
                                 isHidden: item.name.hasPrefix("."), isIgnored: Self.isIgnored(path, in: ignored))
        }
        if raw.count > kept.count {
            entries.append(FileTreeEntry(relativePath: relativePath, name: "\u{2026}", isDirectory: false, isOverflow: true,
                                         overflowCount: raw.count - kept.count))
        }
        return entries
    }

    /// Every file path under the root (⌘P outside git): depth-first in tree order, folders in
    /// `skipping` and symlinked folders not entered, at most `limit` paths, `maxDepth` levels.
    public func walk(limit: Int = 20_000, maxDepth: Int = 12, skipping: Set<String> = ["node_modules", ".git"]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(min(limit, 4096))
        func visit(_ relative: String, depth: Int) {
            guard out.count < limit, depth <= maxDepth else { return }
            let path = relative.isEmpty ? root.path : root.path + "/" + relative
            guard var items = try? Self.readNames(path) else { return }
            items.removeAll { excludedNames.contains($0.name) || skipping.contains($0.name) }
            items.sort(by: Self.order)
            for item in items {
                guard out.count < limit else { return }
                let child = relative.isEmpty ? item.name : relative + "/" + item.name
                if item.isDirectory {
                    visit(child, depth: depth + 1)
                } else if item.isSymlink {
                    // A link to a folder is not entered (cycles) and is not a file to open.
                    var st = stat()
                    if stat(path + "/" + item.name, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { out.append(child) }
                } else {
                    out.append(child)
                }
            }
        }
        visit("", depth: 0)
        return out
    }

    /// Whether `path` or one of its parent folders is in `ignored`.
    public static func isIgnored(_ path: String, in ignored: Set<String>) -> Bool {
        guard !ignored.isEmpty else { return false }
        var current = Substring(path)
        while true {
            if ignored.contains(String(current)) { return true }
            guard let slash = current.lastIndex(of: "/") else { return false }
            current = current[..<slash]
        }
    }

    /// Folders first, then names in natural, case- and width-insensitive order; `forcedOrdering`
    /// keeps names that compare equal (`a` / `A`) in a fixed order.
    static func order(_ a: RawName, _ b: RawName) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.compare(b.name, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]) == .orderedAscending
    }

    struct RawName {
        var name: String
        var isDirectory: Bool
        var isSymlink: Bool
    }

    /// `readdir` of `path` (`.` and `..` skipped).
    static func readNames(_ path: String) throws -> [RawName] {
        guard let dir = opendir(path) else { throw FileTreeError.unreadable(path: path, errno: errno) }
        defer { closedir(dir) }
        var out: [RawName] = []
        while let entry = readdir(dir) {
            let name: String = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: Int(entry.pointee.d_namlen))
                }
            }
            if name == "." || name == ".." { continue }
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                var st = stat()
                if lstat(path + "/" + name, &st) == 0 {
                    switch st.st_mode & S_IFMT {
                    case S_IFDIR: type = DT_DIR
                    case S_IFLNK: type = DT_LNK
                    default: type = DT_REG
                    }
                }
            }
            out.append(RawName(name: name, isDirectory: type == DT_DIR, isSymlink: type == DT_LNK))
        }
        return out
    }
}
