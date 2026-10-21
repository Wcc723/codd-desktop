import CoddCore
import Darwin
import Foundation
import Testing
@testable import CoddHooks

@Suite("Registry watcher")
struct RegistryWatcherTests {
    func entryJSON(pid: Int, status: String, updated: Int64 = 1_792_032_120_000, sessionId: String? = nil) -> Data {
        let sid = sessionId ?? "00000000-0000-4000-8000-\(String(format: "%012d", pid))"
        return Data(#"{"pid":\#(pid),"sessionId":"\#(sid)","cwd":"/synthetic","status":"\#(status)","statusUpdatedAt":\#(updated),"updatedAt":\#(updated),"kind":"interactive","entrypoint":"cli"}"#.utf8)
    }

    /// Claude-style atomic write: temp file + rename.
    func writeAtomically(_ data: Data, _ url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    /// In-place rewrite (truncate + write), the shape a directory-level kqueue watch would miss.
    func writeInPlace(_ data: Data, _ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func makeWatcher(_ dirs: [URL], liveness: FakeLiveness, retry: Duration = .milliseconds(50),
                     recheck: Duration? = nil) -> (RegistryWatcher, Collector<RegistrySnapshot>) {
        let watcher = RegistryWatcher(
            configuration: .init(directories: dirs, debounce: .milliseconds(100), missingDirectoryRetry: retry,
                                 livenessRecheck: recheck),
            liveness: liveness)
        let collector = Collector(watcher.snapshots)
        watcher.start()
        return (watcher, collector)
    }

    func statuses(_ s: RegistrySnapshot?) -> [Int: String] {
        var out: [Int: String] = [:]
        for e in s?.entries ?? [] { if let pid = e.pid { out[pid] = e.status } }
        return out
    }

    @Test func initialSnapshotThenAtomicAndInPlaceWrites() async throws {
        let tmp = try TempDir("codd-reg")
        defer { tmp.remove() }
        try entryJSON(pid: 101, status: "idle").write(to: tmp.file("101.json"))
        try Data("SECRET".utf8).write(to: tmp.file("101.abc.key"))
        let liveness = FakeLiveness([101, 102])
        let (watcher, snaps) = makeWatcher([tmp.url], liveness: liveness)
        defer { watcher.finish() }
        #expect(await snaps.wait { statuses($0.last) == [101: "idle"] })

        try writeAtomically(entryJSON(pid: 102, status: "busy"), tmp.file("102.json"))
        #expect(await snaps.wait { statuses($0.last) == [101: "idle", 102: "busy"] })

        try writeInPlace(entryJSON(pid: 101, status: "waiting"), tmp.file("101.json"))
        #expect(await snaps.wait { statuses($0.last) == [101: "waiting", 102: "busy"] })

        try FileManager.default.removeItem(at: tmp.file("102.json"))
        #expect(await snaps.wait { statuses($0.last) == [101: "waiting"] })
        // Pid order and priority order are kept.
        #expect(snaps.values.last?.entries.map(\.pid) == [101])
    }

    @Test func partialWriteKeepsThePreviousEntry() async throws {
        let tmp = try TempDir("codd-reg")
        defer { tmp.remove() }
        try entryJSON(pid: 201, status: "busy").write(to: tmp.file("201.json"))
        let liveness = FakeLiveness([201, 202])
        let (watcher, snaps) = makeWatcher([tmp.url], liveness: liveness)
        defer { watcher.finish() }
        #expect(await snaps.wait { statuses($0.last) == [201: "busy"] })
        let countBefore = snaps.count

        // Half-written JSON (Claude caught mid-write): the entry must not disappear.
        let full = entryJSON(pid: 201, status: "idle")
        try writeInPlace(full.prefix(full.count / 2), tmp.file("201.json"))
        // A brand-new file that is still partial is simply absent.
        try Data(#"{"pid":202,"stat"#.utf8).write(to: tmp.file("202.json"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(snaps.values.dropFirst(countBefore).allSatisfy { statuses($0) == [201: "busy"] })
        #expect(statuses(snaps.values.last) == [201: "busy"])

        // Completing the writes is picked up.
        try writeInPlace(full, tmp.file("201.json"))
        try writeInPlace(entryJSON(pid: 202, status: "busy"), tmp.file("202.json"))
        #expect(await snaps.wait { statuses($0.last) == [201: "idle", 202: "busy"] })
    }

    @Test func directoryCreatedLater() async throws {
        let tmp = try TempDir("codd-reg")
        defer { tmp.remove() }
        let dir = tmp.file("sessions")
        let liveness = FakeLiveness([301])
        let (watcher, snaps) = makeWatcher([dir], liveness: liveness)
        defer { watcher.finish() }
        #expect(await snaps.wait { $0.count == 1 && $0[0].entries.isEmpty })

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try await Task.sleep(for: .milliseconds(150)) // the retry noticed the directory and started its stream
        try writeAtomically(entryJSON(pid: 301, status: "idle"), dir.appendingPathComponent("301.json"))
        #expect(await snaps.wait { statuses($0.last) == [301: "idle"] })

        // Deleted and recreated: entries go away, then come back.
        try FileManager.default.removeItem(at: dir)
        #expect(await snaps.wait { $0.last?.entries.isEmpty == true })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try entryJSON(pid: 301, status: "busy").write(to: dir.appendingPathComponent("301.json"))
        #expect(await snaps.wait { statuses($0.last) == [301: "busy"] })
    }

    @Test func severalDirectoriesInPriorityOrder() async throws {
        let a = try TempDir("codd-reg-a")
        let b = try TempDir("codd-reg-b")
        defer { a.remove(); b.remove() }
        try entryJSON(pid: 9, status: "idle").write(to: b.file("9.json"))
        try entryJSON(pid: 50, status: "busy").write(to: a.file("50.json"))
        let liveness = FakeLiveness([9, 50, 51])
        let (watcher, snaps) = makeWatcher([a.url, b.url], liveness: liveness)
        defer { watcher.finish() }
        #expect(await snaps.wait { $0.last?.entries.map(\.pid) == [50, 9] })
        watcher.setDirectories([b.url])
        #expect(await snaps.wait { $0.last?.entries.map(\.pid) == [9] })
    }

    @Test func deadProcessesAreFilteredAndRechecked() async throws {
        let tmp = try TempDir("codd-reg")
        defer { tmp.remove() }
        try entryJSON(pid: 401, status: "busy").write(to: tmp.file("401.json"))
        try entryJSON(pid: 402, status: "idle").write(to: tmp.file("402.json"))
        let liveness = FakeLiveness([401, 402])
        let (watcher, snaps) = makeWatcher([tmp.url], liveness: liveness, recheck: .milliseconds(50))
        defer { watcher.finish() }
        #expect(await snaps.wait { statuses($0.last) == [401: "busy", 402: "idle"] })
        // 402 crashed: its file stays, no file event fires; the periodic liveness check drops it.
        liveness.set([401])
        #expect(await snaps.wait { statuses($0.last) == [401: "busy"] })
    }

    @Test func burstsAreCoalesced() async throws {
        let tmp = try TempDir("codd-reg")
        defer { tmp.remove() }
        let liveness = FakeLiveness(Set(1000..<1050))
        let (watcher, snaps) = makeWatcher([tmp.url], liveness: liveness)
        defer { watcher.finish() }
        #expect(await snaps.wait(count: 1))
        let passesBefore = watcher.readPasses()
        for pid in 1000..<1050 {
            try writeAtomically(entryJSON(pid: pid, status: "busy"), tmp.file("\(pid).json"))
        }
        #expect(await snaps.wait { $0.last?.entries.count == 50 })
        try await Task.sleep(for: .milliseconds(250))
        // 50 writes in a few ms: a handful of reads, not 50.
        #expect(watcher.readPasses() - passesBefore <= 5)
    }

    @Test func stopAndRestart() async throws {
        let tmp = try TempDir("codd-reg")
        defer { tmp.remove() }
        let liveness = FakeLiveness([501, 502])
        try entryJSON(pid: 501, status: "idle").write(to: tmp.file("501.json"))
        let (watcher, snaps) = makeWatcher([tmp.url], liveness: liveness)
        defer { watcher.finish() }
        #expect(await snaps.wait { statuses($0.last) == [501: "idle"] })
        watcher.stop()
        try entryJSON(pid: 502, status: "busy").write(to: tmp.file("502.json"))
        try await Task.sleep(for: .milliseconds(250))
        #expect(statuses(snaps.values.last) == [501: "idle"])
        watcher.start()
        #expect(await snaps.wait { statuses($0.last) == [501: "idle", 502: "busy"] })
    }
}
