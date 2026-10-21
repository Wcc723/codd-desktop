import Foundation
import Testing
@testable import CoddFiles

@Suite("GitReader (temp repos, isolated config)")
struct GitReaderTests {
    @Test func statusParsesBranchChangesAndOddNames() async throws {
        let repo = try TestRepo()
        try repo.write("a.txt", "one\n")
        try repo.write("old name.txt", "rename me\nline 2\nline 3\n")
        try repo.write("gone.txt", "bye\n")
        try repo.write("src/打卡 頁.vue", "<template/>\n")
        try repo.write("line\nbreak.txt", "odd\n")
        try repo.commitAll("first")

        try repo.write("a.txt", "one\ntwo\n")                      // modified (work tree)
        try repo.git("mv", "old name.txt", "new name.txt")          // renamed (index)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt")) // deleted
        try repo.write("src/打卡 頁.vue", "<template>x</template>\n") // CJK + space, modified
        try repo.write("staged.txt", "new\n")
        try repo.git("add", "staged.txt")                           // added
        try repo.write("untracked dir/新 檔.md", "u\n")              // untracked, nested
        try repo.write("line\nbreak.txt", "odd changed\n")          // newline in the name

        let logs = LogLines()
        let reader = repo.reader(log: logs.sink)
        let status = try await reader.status(root: repo.root)
        #expect(status.branch == "main")
        #expect(!status.detached)
        #expect(status.upstream == nil)
        #expect(status.headOID?.count == 40)
        #expect(status.changes["a.txt"] == .modified)
        #expect(status.changes["new name.txt"] == .renamed)
        #expect(status.renamedFrom["new name.txt"] == "old name.txt")
        #expect(status.changes["old name.txt"] == nil)
        #expect(status.changes["gone.txt"] == .deleted)
        #expect(status.changes["src/打卡 頁.vue"] == .modified)
        #expect(status.changes["staged.txt"] == .added)
        #expect(status.changes["untracked dir/新 檔.md"] == .untracked)
        #expect(status.changes["line\nbreak.txt"] == .modified)
        #expect(status.changes.count == 7)
        #expect(status.folderContainsChanges("src"))
        #expect(!status.folderContainsChanges("public"))
        #expect(logs.all == ["exec git path=\(GitReader.abbreviate(repo.root.path)) sub=status"])
    }

    @Test func aheadBehindAgainstALocalBareUpstream() async throws {
        let repo = try TestRepo()
        let upstream = repo.dir.url.appendingPathComponent("up.git")
        try Shell.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", upstream.path], environment: repo.environment)
        try repo.write("f.txt", "1\n")
        try repo.commitAll("c1")
        try repo.git("remote", "add", "origin", upstream.path)
        try repo.git("push", "-q", "-u", "origin", "main")
        // Someone else pushes one commit.
        let other = repo.dir.url.appendingPathComponent("other")
        try Shell.run("/usr/bin/git", ["clone", "-q", upstream.path, other.path], environment: repo.environment)
        try Data("2\n".utf8).write(to: other.appendingPathComponent("g.txt"))
        try repo.git("add", "g.txt", in: other)
        try repo.git("commit", "-q", "-m", "theirs", in: other)
        try repo.git("push", "-q", "origin", "main", in: other)
        // Two local commits, then fetch.
        try repo.write("f.txt", "1\n2\n")
        try repo.commitAll("c2")
        try repo.write("f.txt", "1\n2\n3\n")
        try repo.commitAll("c3")
        try repo.git("fetch", "-q", "origin")

        let status = try await repo.reader().status(root: repo.root)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.changes.isEmpty)
    }

    @Test func detachedHeadAndAnUnbornBranch() async throws {
        let unborn = try TestRepo("unborn")
        try unborn.write("x.txt", "x\n")
        let first = try await unborn.reader().status(root: unborn.root)
        #expect(first.branch == "main")
        #expect(first.headOID == nil)
        #expect(first.changes["x.txt"] == .untracked)
        #expect(try await unborn.reader().headText(root: unborn.root, relativePath: "x.txt") == nil, "no HEAD yet")

        let repo = try TestRepo()
        try repo.write("f.txt", "1\n")
        try repo.commitAll("c1")
        try repo.write("f.txt", "2\n")
        try repo.commitAll("c2")
        try repo.git("checkout", "-q", "--detach", "HEAD~1")
        let status = try await repo.reader().status(root: repo.root)
        #expect(status.detached)
        #expect(status.branch == nil)
    }

    @Test func conflictedAndConflictFreeMergeStates() async throws {
        let repo = try TestRepo()
        try repo.write("shared.txt", "base\n")
        try repo.write("other.txt", "o\n")
        try repo.commitAll("base")
        try repo.git("checkout", "-q", "-b", "side")
        try repo.write("shared.txt", "side\n")
        try repo.write("side-only.txt", "s\n")
        try repo.commitAll("side")
        try repo.git("checkout", "-q", "main")
        try repo.write("shared.txt", "main\n")
        try repo.commitAll("main")
        // A merge that stops on a conflict: `u` entries.
        _ = try? repo.git("merge", "-q", "--no-edit", "side")
        let conflicted = try await repo.reader().status(root: repo.root)
        #expect(conflicted.changes["shared.txt"] == .conflicted)
        #expect(conflicted.changes["side-only.txt"] == .added)
        try repo.git("merge", "--abort")

        // A conflict-free merge left uncommitted (`--no-commit`): only staged entries.
        try repo.git("checkout", "-q", "-b", "side2", "side")
        try repo.git("checkout", "-q", "main")
        try repo.git("reset", "-q", "--hard", "HEAD~1")
        try repo.git("merge", "-q", "--no-commit", "--no-ff", "side2")
        let merging = try await repo.reader().status(root: repo.root)
        #expect(merging.changes["shared.txt"] == .modified)
        #expect(merging.changes["side-only.txt"] == .added)
        #expect(!merging.changes.values.contains(.conflicted))
    }

    @Test func headTextIsPlumbingAndFollowsRenamesThroughTheStatus() async throws {
        let repo = try TestRepo()
        try repo.write(".gitattributes", "*.txt diff=upper\n")
        try repo.write("code.txt", "line 1\r\nline 2\r\n")
        try repo.write("before.vue", "position: fixed;\nbottom: 0;\n")
        try repo.commitAll("c1")
        // A textconv that would change the text if cat-file used it.
        try repo.git("config", "diff.upper.textconv", "tr a-z A-Z <")
        try repo.git("mv", "before.vue", "after.vue")
        try repo.write("after.vue", "position: sticky;\n")

        let reader = repo.reader()
        #expect(try await reader.headText(root: repo.root, relativePath: "code.txt") == Data("line 1\r\nline 2\r\n".utf8))
        let status = try await reader.status(root: repo.root)
        let original = try #require(status.renamedFrom["after.vue"])
        #expect(original == "before.vue")
        #expect(try await reader.headText(root: repo.root, relativePath: "after.vue") == nil)
        #expect(try await reader.headText(root: repo.root, relativePath: original) == Data("position: fixed;\nbottom: 0;\n".utf8))
        #expect(try await reader.headText(root: repo.root, relativePath: "missing.txt") == nil)
        #expect(try await reader.headText(root: repo.root, relativePath: "") == nil, "a tree is not a blob")
    }

    @Test func ignoredFoldersCollapseAndListsHonourGitignore() async throws {
        let repo = try TestRepo()
        try repo.write(".gitignore", "node_modules/\n.env.local\ndist/\n")
        try repo.write("node_modules/vue/index.js", "x")
        try repo.write("node_modules/vue/deep/a.js", "x")
        try repo.write("dist/app.js", "x")
        try repo.write(".env.local", "SECRET=1")
        try repo.write("src/main.js", "m")
        try repo.commitAll("c1")
        try repo.write("src/new file.js", "n")

        let reader = repo.reader()
        let ignored = try await reader.ignored(root: repo.root)
        #expect(ignored == ["node_modules", "dist", ".env.local"])
        let files = try await reader.trackedAndUntracked(root: repo.root)
        #expect(Set(files) == [".gitignore", "src/main.js", "src/new file.js"])
        #expect(FileTreeModel.isIgnored("node_modules/vue/deep/a.js", in: ignored))
        #expect(!FileTreeModel.isIgnored("src/main.js", in: ignored))
    }

    @Test func repoRootFromASubfolderAndOutsideARepo() async throws {
        let repo = try TestRepo()
        try repo.write("a/b/c.txt", "c")
        let reader = repo.reader()
        #expect(await reader.repoRoot(for: repo.root.appendingPathComponent("a/b")) == repo.root)
        let outside = TempDir("codd-norepo")
        // A folder outside any work tree (the temp folder is not inside a repository).
        #expect(await GitReader(environment: repo.isolation, log: { _ in }).repoRoot(for: outside.url) == nil)
    }

    /// The read-only proof: no reader call rewrites `.git/index`, even when the index is stale
    /// (a touched tracked file would make a plain `git status` refresh and rewrite it).
    @Test func indexIsNeverWrittenByAnyReaderCall() async throws {
        let repo = try TestRepo()
        defer { repo.dir.remove() }
        for index in 0..<40 { try repo.write("dir\(index % 4)/f\(index).txt", "content \(index)\n") }
        try repo.write(".gitignore", "build/\n")
        try repo.write("build/out.o", "o")
        try repo.commitAll("c1")
        // Make the index stale: same contents, new mtimes.
        try await Task.sleep(for: .milliseconds(1100))
        for index in 0..<40 { try repo.write("dir\(index % 4)/f\(index).txt", "content \(index)\n") }
        try repo.write("dir0/f0.txt", "changed\n")
        let reader = repo.reader()
        let before = repo.indexStamp()
        _ = await reader.repoRoot(for: repo.root)
        #expect(repo.indexStamp() == before, "rev-parse")
        _ = try await reader.status(root: repo.root)
        #expect(repo.indexStamp() == before, "status")
        _ = try await reader.status(root: repo.root)
        #expect(repo.indexStamp() == before, "status again")
        _ = try await reader.headText(root: repo.root, relativePath: "dir0/f0.txt")
        #expect(repo.indexStamp() == before, "cat-file")
        _ = try await reader.ignored(root: repo.root)
        #expect(repo.indexStamp() == before, "ls-files -o -i")
        _ = try await reader.trackedAndUntracked(root: repo.root)
        #expect(repo.indexStamp() == before, "ls-files -co")
        // Control (informational): a plain status may refresh the index here.
        try repo.git("status", "--porcelain")
        print("index rewritten by a plain `git status` in the same state: \(repo.indexStamp() != before)")
    }

    @Test func fsmonitorFromTheRepoConfigNeverStartsADaemon() async throws {
        let repo = try TestRepo()
        try repo.write("a.txt", "a")
        try repo.commitAll("c1")
        // A user's repository that opted into the builtin fsmonitor.
        try repo.git("config", "core.fsmonitor", "true")
        let daemonsBefore = processCommandLines().filter { $0.contains("fsmonitor--daemon") }.count
        let reader = repo.reader()
        _ = try await reader.status(root: repo.root)
        _ = try await reader.trackedAndUntracked(root: repo.root)
        try await Task.sleep(for: .milliseconds(300))
        let socket = repo.root.appendingPathComponent(".git/fsmonitor--daemon.ipc")
        #expect(!FileManager.default.fileExists(atPath: socket.path), "no daemon socket in the repository")
        let daemonsAfter = processCommandLines().filter { $0.contains("fsmonitor--daemon") }.count
        #expect(daemonsAfter <= daemonsBefore)
        #expect(!processCommandLines().contains { $0.contains(repo.root.path) }, "no git of ours is left running")
    }

    @Test func everyRunUsesTheReadOnlyFlagsAndEnvironment() {
        let folder = URL(fileURLWithPath: "/tmp/x y", isDirectory: true)
        #expect(GitReader.globalArguments(folder: folder) == ["-C", "/tmp/x y", "--no-optional-locks", "-c", "core.fsmonitor=false"])
        let reader = GitReader(environment: ["GIT_CONFIG_NOSYSTEM": "1"], log: { _ in })
        let env = reader.runEnvironment(base: ["PATH": "/usr/bin", "GIT_DIR": "/elsewhere/.git", "GIT_INDEX_FILE": "/x", "HOME": "/h"])
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(env["LC_ALL"] == "C")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_DIR"] == nil && env["GIT_INDEX_FILE"] == nil, "inherited GIT_* never redirect the reader")
        #expect(env["PATH"] == "/usr/bin" && env["HOME"] == "/h")
    }

    @Test func aHangingGitIsKilledAtTheTimeout() async throws {
        let dir = TempDir("codd-fakegit")
        let seconds = "29.\(Int.random(in: 10_000...99_999))"
        let script = try dir.write("git", "#!/bin/sh\n/bin/sleep \(seconds)\necho done\n")
        try Shell.run("/bin/chmod", ["+x", script.path])
        let reader = GitReader(gitPath: script.path, timeout: .milliseconds(300), log: { _ in })
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: GitError.run(subcommand: "status", .timedOut)) {
            _ = try await reader.status(root: dir.url)
        }
        #expect(clock.now - start < .seconds(3))
        try await Task.sleep(for: .milliseconds(200))
        let left = processCommandLines().filter { $0.contains(script.path) || $0.contains("sleep \(seconds)") }
        #expect(left.isEmpty, "the child and its process group are gone: \(left)")
    }

    @Test func statusOfFiveThousandFilesIsFast() async throws {
        let repo = try TestRepo()
        defer { repo.dir.remove() }
        for index in 0..<5_000 {
            try repo.write("pkg\(index % 50)/sub\(index % 7)/file\(index).txt", "line \(index)\n")
        }
        try repo.commitAll("bulk")
        for index in stride(from: 0, to: 5_000, by: 250) { try repo.write("pkg\(index % 50)/sub\(index % 7)/file\(index).txt", "edited\n") }
        let reader = repo.reader()
        _ = try await reader.status(root: repo.root) // warm the file system cache
        let clock = ContinuousClock()
        var best = Duration.seconds(10)
        for _ in 0..<3 {
            let start = clock.now
            let status = try await reader.status(root: repo.root)
            best = min(best, clock.now - start)
            #expect(status.changes.count == 20)
        }
        print("git status, 5,000 files: \(best.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        #expect(best < .milliseconds(300))
    }

    @Test func parserRejectsGarbageAndHandlesCopies() throws {
        let root = URL(fileURLWithPath: "/r")
        let copy = Data("# branch.head main\u{0}2 C. N... 100644 100644 100644 abc abc C100 b.txt\u{0}a.txt\u{0}".utf8)
        let status = try GitStatusParser.parse(copy, root: root)
        #expect(status.changes["b.txt"] == .copied)
        #expect(status.renamedFrom["b.txt"] == "a.txt")
        #expect(throws: GitError.self) { try GitStatusParser.parse(Data("x nonsense\0".utf8), root: root) }
        let typeChange = try GitStatusParser.parse(Data("1 .T N... 100644 120000 120000 a a link\0".utf8), root: root)
        #expect(typeChange.changes["link"] == .typeChanged)
    }
}
