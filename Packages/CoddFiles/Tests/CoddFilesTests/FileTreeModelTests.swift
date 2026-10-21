import Foundation
import Testing
@testable import CoddFiles

@Suite("FileTreeModel")
struct FileTreeModelTests {
    @Test func childrenAreFoldersFirstInNaturalOrder() throws {
        let dir = TempDir()
        for name in ["file10.txt", "file2.txt", "File1.txt", "b.vue", "A.vue", ".env.local", ".DS_Store"] { try dir.write(name, "x") }
        for folder in ["src", "node_modules", "Public", ".git"] {
            try FileManager.default.createDirectory(at: dir.file(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: dir.file("linked"), withDestinationURL: dir.file("src"))
        try FileManager.default.createSymbolicLink(at: dir.file("alias.txt"), withDestinationURL: dir.file("b.vue"))
        let model = FileTreeModel(root: dir.url)
        let entries = try model.children(of: "", ignored: ["node_modules", ".env.local"])
        #expect(entries.map(\.name) == ["linked", "node_modules", "Public", "src", ".env.local", "A.vue", "alias.txt", "b.vue",
                                        "File1.txt", "file2.txt", "file10.txt"])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["linked"]?.isDirectory == true && byName["linked"]?.isSymlink == true)
        #expect(byName["alias.txt"]?.isDirectory == false && byName["alias.txt"]?.isSymlink == true)
        #expect(byName["node_modules"]?.isIgnored == true)
        #expect(byName[".env.local"]?.isHidden == true && byName[".env.local"]?.isIgnored == true)
        #expect(byName["src"]?.isIgnored == false)
        #expect(byName[".git"] == nil && byName[".DS_Store"] == nil)
    }

    @Test func nestedRelativePathsAndIgnoredParents() throws {
        let dir = TempDir()
        try dir.write("node_modules/vue/index.js", "x")
        try dir.write("src/pages/punch.vue", "x")
        let model = FileTreeModel(root: dir.url)
        let pages = try model.children(of: "src/pages", ignored: [])
        #expect(pages.map(\.relativePath) == ["src/pages/punch.vue"])
        let vue = try model.children(of: "node_modules/vue", ignored: ["node_modules"])
        #expect(vue.first?.isIgnored == true, "inside an ignored folder")
        #expect(throws: FileTreeError.self) { try model.children(of: "missing", ignored: []) }
    }

    @Test func aHugeFolderStopsAtTwoThousandWithAMarker() throws {
        let dir = TempDir()
        defer { dir.remove() }
        for index in 0..<2_050 { FileManager.default.createFile(atPath: dir.file("f\(index).txt").path, contents: nil) }
        let entries = try FileTreeModel(root: dir.url).children(of: "", ignored: [])
        #expect(entries.count == 2_001)
        let marker = try #require(entries.last)
        #expect(marker.isOverflow && marker.overflowCount == 50 && marker.name == "\u{2026}")
        #expect(entries[1_999].name == "f1999.txt", "natural order: f0 … f1999 are kept")
    }

    @Test func walkIsBoundedAndSkipsHeavyFolders() throws {
        let dir = TempDir()
        try dir.write("a.txt", "x")
        try dir.write("src/b.txt", "x")
        try dir.write("node_modules/pkg/c.js", "x")
        try dir.write(".git/HEAD", "x")
        var deep = "d"
        for _ in 0..<15 { deep += "/d" }
        try dir.write(deep + "/deep.txt", "x")
        try FileManager.default.createSymbolicLink(at: dir.file("loop"), withDestinationURL: dir.url)
        let model = FileTreeModel(root: dir.url)
        let all = model.walk()
        #expect(all.contains("a.txt") && all.contains("src/b.txt"))
        #expect(!all.contains { $0.hasPrefix("node_modules") || $0.hasPrefix(".git") || $0.hasPrefix("loop") })
        #expect(!all.contains { $0.hasSuffix("deep.txt") }, "deeper than 12 levels")
        #expect(model.walk(limit: 1).count == 1)
    }
}
