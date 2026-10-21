import Darwin
import Foundation
import Testing
@testable import CoddFiles

@Suite("FileWatch and DirectoryWatcher", .serialized)
struct WatchTests {
    /// Appends to the file through the same inode.
    private func writeInPlace(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Writes a temp file next to it and renames it over (what Claude's Write and most editors do).
    private func replaceAtomically(_ url: URL, _ text: String) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        try Data(text.utf8).write(to: temp)
        #expect(rename(temp.path, url.path) == 0)
    }

    @Test func fileWatchFollowsWritesReplacesDeletesAndRecreation() async throws {
        let dir = TempDir()
        let file = try dir.write("punch.vue", "<template/>\n")
        let watch = FileWatch(url: file)
        defer { watch.cancel() }
        let events = Collector(watch.events)
        defer { events.stop() }
        try await Task.sleep(for: .milliseconds(100))

        try writeInPlace(file, "a\n")
        #expect(await events.wait { $0 == [.modified] }, "in-place write: \(events.all)")

        try replaceAtomically(file, "replaced\n")
        #expect(await events.wait { $0.count == 2 }, "atomic replace: \(events.all)")
        #expect(events.all.last == .modified)

        // The watch moved to the new inode.
        try await Task.sleep(for: .milliseconds(150))
        try writeInPlace(file, "b\n")
        #expect(await events.wait { $0.count == 3 }, "write after replace: \(events.all)")
        #expect(events.all.last == .modified)

        try await Task.sleep(for: .milliseconds(150))
        chmod(file.path, 0o600)
        #expect(await events.wait { $0.count == 4 }, "chmod: \(events.all)")
        #expect(events.all.last == .attributes)

        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.removeItem(at: file)
        #expect(await events.wait { $0.count == 5 }, "delete: \(events.all)")
        #expect(events.all.last == .deleted)

        try await Task.sleep(for: .milliseconds(150))
        try Data("back\n".utf8).write(to: file, options: [])
        #expect(await events.wait { $0.count == 6 }, "recreate: \(events.all)")
        #expect(events.all.last == .modified)

        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.moveItem(at: file, to: dir.file("moved.vue"))
        #expect(await events.wait { $0.count == 7 }, "rename away: \(events.all)")
        #expect(events.all.last == .renamed)
    }

    @Test func fileWatchCoalescesABurst() async throws {
        let dir = TempDir()
        let file = try dir.write("burst.txt", "")
        let watch = FileWatch(url: file)
        defer { watch.cancel() }
        let events = Collector(watch.events)
        defer { events.stop() }
        try await Task.sleep(for: .milliseconds(100))
        for index in 0..<20 { try writeInPlace(file, "\(index)\n") }
        #expect(await events.wait { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.all == [.modified], "one event for the burst: \(events.all)")
    }

    @Test func cancelFinishesTheStream() async throws {
        let dir = TempDir()
        let file = try dir.write("x.txt", "x")
        let watch = FileWatch(url: file)
        watch.cancel()
        var count = 0
        for await _ in watch.events { count += 1 }
        #expect(count == 0)
    }

    @Test func directoryWatcherSeesNestedCreatesModifiesAndDeletes() async throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.file("src/pages/deep"), withIntermediateDirectories: true)
        try dir.write("src/pages/existing.vue", "x")
        let watcher = DirectoryWatcher(root: dir.url, latency: 0.05)
        defer { watcher.cancel() }
        let batches = Collector(watcher.changes)
        defer { batches.stop() }
        try await Task.sleep(for: .milliseconds(400))

        func seen(_ path: String) async -> Bool { await batches.wait { $0.joined().contains(path) } }

        try dir.write("src/pages/deep/new file.vue", "new")
        #expect(await seen("src/pages/deep/new file.vue"), "create: \(batches.all)")
        try dir.write("src/pages/existing.vue", "changed")
        #expect(await seen("src/pages/existing.vue"), "modify: \(batches.all)")
        try FileManager.default.removeItem(at: dir.file("src/pages/deep/new file.vue"))
        let before = batches.count
        #expect(await batches.wait { $0.count > before && $0.dropFirst(before).joined().contains("src/pages/deep/new file.vue") },
                "delete: \(batches.all)")
        try dir.write("打卡/紀錄.md", "cjk")
        #expect(await seen("打卡/紀錄.md"), "CJK path: \(batches.all)")
        #expect(batches.all.allSatisfy { batch in batch.allSatisfy { !$0.hasPrefix("/") } }, "paths are relative")
    }

    @Test func directoryWatcherCancelFinishesTheStream() async {
        let dir = TempDir()
        let watcher = DirectoryWatcher(root: dir.url)
        watcher.cancel()
        var count = 0
        for await _ in watcher.changes { count += 1 }
        #expect(count == 0)
    }
}
