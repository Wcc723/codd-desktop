import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoddFiles

/// A settable clock for the stores.
final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in self.value.withLock { $0 } } }
}

@Suite("Recent files and AI touches")
struct StoreTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        _ = stat(url.path, &st)
        return st.st_mode & 0o777
    }

    @Test func recentKeepsTwentyNewestFirstAndExpires() throws {
        let dir = TempDir()
        let file = dir.file("files/recent.json")
        let clock = TestClock(t0)
        let store = RecentFilesStore(file: file, clock: clock.function)
        let root = URL(fileURLWithPath: "/work/frontend")
        for index in 0..<25 {
            store.record(URL(fileURLWithPath: "/work/frontend/f\(index).vue"), root: root, source: "user", at: t0.addingTimeInterval(Double(index)))
        }
        var items = store.load()
        #expect(items.count == 20)
        #expect(items.first?.path == "/work/frontend/f24.vue")
        #expect(items.last?.path == "/work/frontend/f5.vue")
        // Re-opening moves a file to the top without a duplicate.
        store.record(URL(fileURLWithPath: "/work/frontend/f10.vue"), root: root, source: "note", at: t0.addingTimeInterval(100))
        items = store.load()
        #expect(items.count == 20 && items.first?.path == "/work/frontend/f10.vue" && items.first?.source == "note")
        #expect(items.filter { $0.path == "/work/frontend/f10.vue" }.count == 1)
        #expect(mode(file) == 0o600)
        #expect(mode(file.deletingLastPathComponent()) == 0o700)
        // The format of §3.4.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(json?["v"] as? Int == 1)
        let first = (json?["items"] as? [[String: Any]])?.first
        #expect(first?["openedAt"] as? String == "2026-10-14T17:48:20.000Z")
        #expect(Set(first?.keys.map { $0 } ?? []) == ["path", "root", "openedAt", "source"])
        // A fresh store reads it back.
        #expect(RecentFilesStore(file: file, clock: clock.function).load() == items)
        // 30 days later only the re-opened one is left... after 31 days nothing.
        clock.advance(30 * 24 * 3600 + 50)
        #expect(RecentFilesStore(file: file, clock: clock.function).load().map(\.path) == ["/work/frontend/f10.vue"])
        clock.advance(24 * 3600)
        #expect(RecentFilesStore(file: file, clock: clock.function).load().isEmpty)
        store.remove(URL(fileURLWithPath: "/work/frontend/f10.vue"))
        #expect(!store.load().contains { $0.path == "/work/frontend/f10.vue" })
    }

    @Test func aCorruptStoreIsMovedAsideAndANewerOneIsNeverWritten() throws {
        let dir = TempDir()
        let file = try dir.write("files/recent.json", "{ not json")
        let store = RecentFilesStore(file: file, clock: { Date(timeIntervalSince1970: 1_792_000_000) })
        #expect(store.load().isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(aside.contains("recent.json.corrupt-1792000000000"))
        store.record(URL(fileURLWithPath: "/a/b.txt"), root: URL(fileURLWithPath: "/a"), source: "user", at: t0)
        #expect(store.load().count == 1)

        let newer = #"{"v":2,"items":[{"path":"/x","root":"/","openedAt":"2026-10-14T17:46:40.000Z","source":"user"}],"extra":true}"#
        let future = try dir.write("files2/recent.json", newer)
        let readOnly = RecentFilesStore(file: future, clock: { Date(timeIntervalSince1970: 1_792_000_000) })
        #expect(readOnly.load().map(\.path) == ["/x"])
        readOnly.record(URL(fileURLWithPath: "/y"), root: URL(fileURLWithPath: "/"), source: "user", at: t0)
        #expect(try String(contentsOf: future, encoding: .utf8) == newer, "never overwritten")
    }

    @Test func aiTouchesFilterByRootAndTimeAndKeepTheNewest() throws {
        let dir = TempDir()
        let file = dir.file("files/ai-touches.json")
        let clock = TestClock(t0)
        let log = AITouchLog(file: file, clock: clock.function, saveDelay: .milliseconds(50))
        log.record([
            AITouch(path: "/work/frontend/src/pages/punch.vue", session: "s9", tool: "Edit", at: t0.addingTimeInterval(-60)),
            AITouch(path: "/work/frontend/src/components/PunchButton.vue", session: "s9", tool: "Write", at: t0.addingTimeInterval(-30)),
            AITouch(path: "/work/frontend-other/x.js", session: "s2", tool: "Edit", at: t0),
            AITouch(path: "/work/frontend/src/pages/punch.vue", session: "s9", tool: "MultiEdit", at: t0.addingTimeInterval(-10)),
        ])
        let under = log.touches(under: URL(fileURLWithPath: "/work/frontend"), since: t0.addingTimeInterval(-3600))
        #expect(under.map(\.tool) == ["MultiEdit", "Write", "Edit"], "newest first, the sibling folder excluded")
        #expect(log.touches(under: nil, since: t0.addingTimeInterval(-15)).count == 2)
        #expect(log.latest(for: "/work/frontend/src/pages/punch.vue")?.tool == "MultiEdit")
        #expect(log.latest(for: "/nope") == nil)
        log.flush()
        #expect(mode(file) == 0o600)
        let reread = AITouchLog(file: file, clock: clock.function)
        #expect(reread.touches(under: nil, since: .distantPast).count == 4)
        // Seven days later the old ones are gone.
        clock.advance(7 * 24 * 3600 - 20)
        #expect(AITouchLog(file: file, clock: clock.function).touches(under: nil, since: .distantPast).map(\.tool) == ["Edit", "MultiEdit"])
    }

    /// M4 fix: a hook names `/private/var/…` (the session's physical cwd) while the app's URLs are
    /// standardized to `/var/…` (Foundation drops `/private`); both spellings find the touch.
    @Test func aiTouchesMatchEitherSpellingOfAPrivatePath() throws {
        let dir = TempDir()
        let root = URL(fileURLWithPath: dir.file("frontend").path, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let physical = try #require(realpath(root.path, &buffer).map { String(cString: $0) })
        let standardized = root.standardizedFileURL.path
        let now = t0
        let log = AITouchLog(file: dir.file("files/ai-touches.json"), clock: { now })
        log.record([AITouch(path: physical + "/src/punch.vue", session: "s9", tool: "Edit", at: now)])
        #expect(log.latest(for: standardized + "/src/punch.vue")?.session == "s9")
        #expect(log.latest(for: physical + "/src/punch.vue")?.session == "s9")
        #expect(log.touches(under: URL(fileURLWithPath: standardized, isDirectory: true), since: .distantPast).count == 1)
        #expect(log.touches(under: root.standardizedFileURL, since: .distantPast).count == 1)
        #expect(log.touches(under: URL(fileURLWithPath: standardized + "-other"), since: .distantPast).isEmpty)
        #expect(AITouchLog.lexicalSpellings(of: "/private/var/x/") == ["/private/var/x", "/var/x"])
        #expect(AITouchLog.lexicalSpellings(of: "/tmp/a") == ["/tmp/a", "/private/tmp/a"])
        #expect(AITouchLog.lexicalSpellings(of: "/Users/a") == ["/Users/a"])
    }

    @Test func aiTouchesCapAtTwoThousandAndSaveDebounced() async throws {
        let dir = TempDir()
        let file = dir.file("files/ai-touches.json")
        let log = AITouchLog(file: file, clock: { Date(timeIntervalSince1970: 1_792_000_000) }, saveDelay: .milliseconds(200))
        let touches = (0..<2_100).map { AITouch(path: "/p/\($0)", session: "s", tool: "Edit", at: t0.addingTimeInterval(Double($0) - 3000)) }
        for chunk in stride(from: 0, to: touches.count, by: 300) { log.record(Array(touches[chunk..<min(chunk + 300, touches.count)])) }
        #expect(!FileManager.default.fileExists(atPath: file.path), "debounced: nothing written yet")
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let all = AITouchLog(file: file, clock: { Date(timeIntervalSince1970: 1_792_000_000) }).touches(under: nil, since: .distantPast)
        #expect(all.count == 2_000)
        #expect(all.first?.path == "/p/2099" && all.last?.path == "/p/100", "the newest 2,000")
    }

    @Test func aCorruptTouchLogStartsOver() throws {
        let dir = TempDir()
        let file = try dir.write("files/ai-touches.json", #"{"v":1,"items":[{"path":1}]}"#)
        let log = AITouchLog(file: file, clock: { Date(timeIntervalSince1970: 1_792_000_000) })
        #expect(log.touches(under: nil, since: .distantPast).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("ai-touches.json.corrupt-") })
    }

    @Test func isoDatesMatchJavaScript() {
        #expect(ISODate.string(Date(timeIntervalSince1970: 1_792_000_000.1234)) == "2026-10-14T17:46:40.123Z")
        #expect(ISODate.string(Date(timeIntervalSince1970: 1_792_000_000)) == "2026-10-14T17:46:40.000Z")
        #expect(ISODate.string(Date(timeIntervalSince1970: 1_792_000_000.05)) == "2026-10-14T17:46:40.050Z")
        #expect(ISODate.parse("2026-10-14T17:46:40.123Z")?.timeIntervalSince1970 == 1_792_000_000.123)
        #expect(ISODate.parse("2026-10-14T17:46:40Z")?.timeIntervalSince1970 == 1_792_000_000)
        let date = Date(timeIntervalSince1970: 1_792_000_000.987)
        #expect(ISODate.parse(ISODate.string(date)) == date)
        #expect(ISODate.parse("yesterday") == nil)
    }
}
