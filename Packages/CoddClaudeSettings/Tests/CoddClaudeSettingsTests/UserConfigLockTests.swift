import Darwin
import Foundation
import Testing
@testable import CoddClaudeSettings

/// Claude's `<file>.lock` protocol as the installer follows it (temp files only; the "other
/// holder" is a directory this test creates, as Claude's proper-lockfile would).
@Suite("~/.claude.json lock")
struct UserConfigLockTests {
    func setMTime(_ path: String, secondsFromNow offset: TimeInterval) {
        let when = Date().timeIntervalSince1970 + offset
        var times = [timeval(tv_sec: Int(when), tv_usec: 0), timeval(tv_sec: Int(when), tv_usec: 0)]
        utimes(path, &times)
    }

    @Test func aFreshForeignLockMakesApplyWaitThenGiveUp() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let before = try Data(contentsOf: file)
        let installer = MCPTest.installer(file, lockWait: .milliseconds(300))
        let plan = try installer.plan(MCPTest.register)
        #expect(mkdir(installer.lockPath, 0o755) == 0)
        let started = Date()
        #expect(throws: ClaudeUserConfigMCPError.lockBusy) { try installer.apply(plan) }
        #expect(Date().timeIntervalSince(started) >= 0.3)
        #expect(Date().timeIntervalSince(started) < 2)
        // The other holder's lock is never removed, the file never touched.
        #expect(MCPTest.isDirectory(installer.lockPath))
        #expect(try Data(contentsOf: file) == before)
        #expect(MCPTest.backups(tmp).isEmpty)
    }

    @Test func aLockReleasedInTimeLetsApplyProceed() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let installer = MCPTest.installer(file, lockWait: .seconds(3))
        let plan = try installer.plan(MCPTest.register)
        let lockPath = installer.lockPath
        #expect(mkdir(lockPath, 0o755) == 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { rmdir(lockPath) }
        let started = Date()
        let result = try installer.apply(plan)
        #expect(result.wrote)
        #expect(Date().timeIntervalSince(started) >= 0.2)
        #expect(!MCPTest.exists(lockPath))
    }

    @Test func aStaleLockIsRefusedAndKept() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let before = try Data(contentsOf: file)
        let installer = MCPTest.installer(file, lockWait: .seconds(3))
        let plan = try installer.plan(MCPTest.register)
        #expect(mkdir(installer.lockPath, 0o755) == 0)
        setMTime(installer.lockPath, secondsFromNow: -30)
        let started = Date()
        let message = UserConfigLock.staleMessage(BackupsIndex.abbreviate(installer.lockPath))
        #expect(throws: ClaudeUserConfigMCPError.staleLock(message)) { try installer.apply(plan) }
        // Refused at once, not after the wait.
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(MCPTest.isDirectory(installer.lockPath))
        #expect(try Data(contentsOf: file) == before)
        // The message the App shows for the real file.
        #expect(UserConfigLock.staleMessage(BackupsIndex.abbreviate(NSHomeDirectory() + "/.claude.json.lock"))
            == "~/.claude.json.lock 看起來是殘留的鎖，請確認沒有 claude 在執行後再試")
    }

    @Test func aLockGoingStaleDuringTheWaitIsRefused() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let installer = MCPTest.installer(file, lockWait: .seconds(3))
        let plan = try installer.plan(MCPTest.register)
        let lockPath = installer.lockPath
        #expect(mkdir(lockPath, 0o755) == 0)
        // 9.8 s old: fresh at first, stale a moment later (its holder stopped refreshing it).
        setMTime(lockPath, secondsFromNow: -9.5)
        #expect(throws: ClaudeUserConfigMCPError.staleLock(UserConfigLock.staleMessage(BackupsIndex.abbreviate(lockPath)))) {
            try installer.apply(plan)
        }
        #expect(MCPTest.isDirectory(lockPath))
    }

    @Test func claudesFutureMTimeCountsAsFresh() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let installer = MCPTest.installer(file, lockWait: .milliseconds(100))
        #expect(mkdir(installer.lockPath, 0o755) == 0)
        // proper-lockfile's probe sets the mtime to the next whole second + 5 ms.
        setMTime(installer.lockPath, secondsFromNow: 1)
        #expect(throws: ClaudeUserConfigMCPError.lockBusy) { try installer.apply(try installer.plan(MCPTest.register)) }
    }

    @Test func theLockIsHeldWhileReadingAndWriting() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        var installer = MCPTest.installer(file)
        let lockPath = installer.lockPath
        let held = LockedFlag()
        installer.afterLock = { held.set(MCPTest.isDirectory(lockPath)) }
        #expect(try installer.apply(try installer.plan(MCPTest.register)).wrote)
        #expect(held.value)
        #expect(!MCPTest.exists(lockPath))
    }

    @Test func aWriterIgnoringTheLockIsStillSeen() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        // Outside mcpServers: rebased on the bytes read under the lock.
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        var installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        let path = file
        installer.afterLock = { try? MCPTest.edit(path, "\"numStartups\": 412", "\"numStartups\": 999") }
        #expect(try installer.apply(plan).wrote)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("\"numStartups\": 999") && written.contains("\"codd\": {"))

        // Inside mcpServers: refused, nothing written, the lock released.
        let second = try MCPTest.write(tmp, "second.json", Data(ClaudeJSONFixture.text().utf8))
        var other = MCPTest.installer(second)
        let plan2 = try other.plan(MCPTest.register)
        let secondPath = second
        other.afterLock = { try? MCPTest.edit(secondPath, "\"desktop\"", "\"cli\"") }
        #expect(throws: ClaudeUserConfigMCPError.changedSinceRead) { try other.apply(plan2) }
        #expect(!(try String(contentsOf: second, encoding: .utf8)).contains("\"codd\""))
        #expect(!MCPTest.exists(other.lockPath))
        #expect(!MCPTest.backups(tmp).contains { $0.hasPrefix("second.json") })
    }

    @Test func aLockTakenOverIsNotReleasedByUs() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let before = try Data(contentsOf: file)
        var installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        let lockPath = installer.lockPath
        // Another writer removes ours as stale and takes the lock.
        installer.afterLock = {
            rmdir(lockPath)
            mkdir(lockPath, 0o755)
        }
        #expect(throws: ClaudeUserConfigMCPError.lockBusy) { try installer.apply(plan) }
        #expect(MCPTest.isDirectory(lockPath))
        #expect(try Data(contentsOf: file) == before)
        #expect(MCPTest.backups(tmp).isEmpty)
    }

    @Test func lockPrimitives() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let path = tmp.file("x.json.lock").path
        let lock = try UserConfigLock.acquire(path, wait: .zero, display: "x.json.lock")
        #expect(lock.isHeld)
        #expect(throws: ClaudeUserConfigMCPError.lockBusy) { try UserConfigLock.acquire(path, wait: .zero, display: "x") }
        setMTime(path, secondsFromNow: -5)
        try lock.refresh()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(UserConfigLock.age(info, now: Date()) < 2)
        lock.release()
        #expect(!MCPTest.exists(path))
        // A missing parent folder is an I/O error, not a busy lock.
        #expect(throws: ClaudeUserConfigMCPError.io("mkdir lock: No such file or directory")) {
            try UserConfigLock.acquire(tmp.file("missing/x.lock").path, wait: .zero, display: "x")
        }
        #expect(UserConfigLock.seconds(.milliseconds(1500)) == 1.5)
    }
}

/// The byte splicing under the installer.
@Suite("JSON object splicing")
struct JSONObjectEditTests {
    func edit(_ text: String, _ body: (UnsafeBufferPointer<UInt8>, JSONObjectSpan, JSONLayout) -> [UInt8]) -> String {
        let data = Data(text.utf8)
        return data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let root = JSONSpans.object(b, at: JSONSpans.skipWhitespace(b, 0))!
            let layout = JSONLayout.detect(b, root: root)
            var out = Array(UnsafeBufferPointer(rebasing: b[0..<root.start]))
            out += body(b, root, layout)
            out += Array(UnsafeBufferPointer(rebasing: b[root.end..<b.count]))
            return String(decoding: out, as: UTF8.self)
        }
    }

    @Test func spansOfAnObject() {
        let text = "{\n  \"a\": [1, {\"x\": \"}\"}],\n  \"b\\u0063\": \"q\\\"\",\n  \"n\": -1.5e3\n}"
        Data(text.utf8).withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let root = JSONSpans.object(b, at: 0)!
            #expect(root.members.map(\.key) == ["a", "bc", "n"])
            #expect(root.end == b.count)
            let values = root.members.map { String(decoding: UnsafeBufferPointer(rebasing: b[$0.valueStart..<$0.valueEnd]), as: UTF8.self) }
            #expect(values == ["[1, {\"x\": \"}\"}]", "\"q\\\"\"", "-1.5e3"])
            #expect(JSONLayout.detect(b, root: root) == JSONLayout(gap: Array("  ".utf8), crlf: false))
        }
    }

    @Test func removingEachPosition() {
        let text = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}"
        func without(_ key: String) -> String {
            edit(text) { b, root, _ in JSONObjectEdit.removing(b, object: root) { root.members[$0].key != key } }
        }
        #expect(without("a") == "{\n  \"b\": 2,\n  \"c\": 3\n}")
        #expect(without("b") == "{\n  \"a\": 1,\n  \"c\": 3\n}")
        #expect(without("c") == "{\n  \"a\": 1,\n  \"b\": 2\n}")
        #expect(edit(text) { b, root, _ in JSONObjectEdit.removing(b, object: root) { _ in false } } == "{}")
    }

    @Test func appendingInEachLayout() {
        let member = OrderedJSON.object([(key: "k", value: .number("1"))])
        func appended(_ text: String) -> String {
            edit(text) { b, root, layout in
                JSONObjectEdit.appending(b, object: root, memberText: layout.member("m", member, level: 1), level: 1, layout: layout)
            }
        }
        #expect(appended("{\n  \"a\": 1\n}") == "{\n  \"a\": 1,\n  \"m\": {\n    \"k\": 1\n  }\n}")
        #expect(appended("{}") == "{\n  \"m\": {\n    \"k\": 1\n  }\n}")
        #expect(appended("{\"a\":1}") == "{\"a\":1,\"m\":{\"k\":1}}")
        #expect(appended("  {\t\"a\" : 1 }  ") == "  {\t\"a\" : 1,\t\"m\":{\"k\":1} }  ")
        #expect(appended("{\r\n\t\"a\": 1\r\n}") == "{\r\n\t\"a\": 1,\r\n\t\"m\": {\r\n\t\t\"k\": 1\r\n\t}\r\n}")
    }
}
