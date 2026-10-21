import AppKit
import CoddCodeEditor
import CoddFiles
import Foundation
import Testing
@testable import CODD

// M4 I3 test rig: the file editor over the C11 fixture repository (scripts/m4-fixtures/
// make-git-project.sh: `feat/punch-rwd ↑2`, punch.vue's `@@ -40,2 +40,4 @@`, the CRLF / BOM / Big5 /
// mixed-EOL / binary / 6 MiB files) in a temp folder. git runs only there and with an isolated
// config (an empty GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1). The editors live in a window that is
// never ordered in. The store is the mock one (s9 `打卡頁 RWD 調整`, tag pink), its project mapped
// onto the fixture.

@MainActor
final class FilesRig {
    let folder: String
    let repo: URL
    let store = MockSessionStore()
    let touchLog: AITouchLog
    let service: FileEditorService
    let mode: FilesModeController
    let window: NSWindow
    let logs = LockedLines()

    /// - Parameter fixture: build the C11 repository at `<folder>/frontend` (else an empty folder).
    init(_ prefix: String, fixture: Bool = true) async throws {
        folder = try m3TempFolder(prefix)
        repo = URL(fileURLWithPath: folder + "/frontend", isDirectory: true)
        if fixture {
            try Self.makeFixture(at: repo.path)
        } else {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        }
        try Data().write(to: URL(fileURLWithPath: folder + "/gitconfig"))
        let logs = self.logs
        let git = GitReader(environment: ["GIT_CONFIG_GLOBAL": folder + "/gitconfig", "GIT_CONFIG_NOSYSTEM": "1"],
                            log: { logs.append($0) })
        touchLog = AITouchLog(file: URL(fileURLWithPath: folder + "/data/files/ai-touches.json"), clock: { Date() },
                              saveDelay: .milliseconds(50))
        service = FileEditorService(git: git, recentStore: RecentFilesStore(file: URL(fileURLWithPath: folder + "/data/files/recent.json")),
                                    touchLog: touchLog, store: store, clock: { Date() },
                                    timeZone: TimeZone(identifier: "Asia/Taipei") ?? .current, log: { logs.append($0) })
        let root = repo.path
        // The mock frontend project (s9) works in the fixture.
        service.rootForCwd = { cwd in cwd.hasSuffix("/orb-toolkit-frontend") ? root : cwd }
        mode = FilesModeController(service: service, store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1368, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = mode.view
        mode.view.frame = NSRect(x: 0, y: 0, width: 1368, height: 900)
        mode.setActive(true)
    }

    /// The fixture script of C11 (it refuses any target outside the temp folder).
    static func makeFixture(at path: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/m4-fixtures/make-git-project.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "make-git-project.sh")
    }

    /// The workspace at the fixture with git loaded.
    @discardableResult
    func openRoot() async -> FilesWorkspace {
        let workspace = service.openRoot(repo)
        await m3Eventually("git loaded") { workspace.gitLoaded && workspace.children[""] != nil }
        return workspace
    }

    /// Opens a fixture file (pinned unless `preview`) and waits for its tab.
    func open(_ relative: String, preview: Bool = false, showAI: Bool = false) async throws -> FileTab {
        let tab = try #require(await service.open(repo.appendingPathComponent(relative), preview: preview, showAI: showAI, root: repo))
        mode.refreshSlot()
        mode.view.layoutSubtreeIfNeeded()
        return tab
    }

    func url(_ relative: String) -> URL { repo.appendingPathComponent(relative) }

    func bytes(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    /// Size, mtime (ns) and inode: "never written" means all three stay.
    func stamp(_ path: String) -> [Int64] {
        var st = stat()
        guard stat(path, &st) == 0 else { return [] }
        return [Int64(st.st_size), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), Int64(st.st_ino)]
    }

    /// Types at the caret as the keyboard does (committed text).
    func type(_ text: String, into tab: FileTab) {
        tab.editor?.textViewForTesting.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Waits for a diff run after `runs`.
    func diff(_ tab: FileTab, after runs: Int) async {
        await m3Eventually("diff of \(tab.title)") { tab.diffRuns > runs }
    }

    /// An external program writes the file (atomically, like most editors and Claude's Write).
    func writeExternally(_ relative: String, _ data: Data) throws {
        try data.write(to: url(relative), options: .atomic)
    }

    func tearDown() {
        mode.setActive(false)
        service.shutdown()
        window.contentView = nil
        window.close()
        m3RemoveFolder(folder)
        m4RemoveAgainLater(folder)
    }
}

/// A detached write that was still on its way at the tear-down (the RECENT list after an open, the
/// notebook's state.json 1 s after a change) recreates `data/…` in a removed temp folder: it goes
/// again once those writes have landed (the test process keeps running for the next suites).
func m4RemoveAgainLater(_ folder: String, after seconds: Double = 3) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
        try? FileManager.default.removeItem(atPath: folder)
    }
}
