import Darwin
import Foundation
import Testing
@testable import CoddCore

@Suite("Claude registry reader")
struct RegistryTests {
    /// Copies the synthetic fixture registry into a temp dir and adds files that must be skipped.
    func makeRegistry() throws -> TempDir {
        let tmp = try TempDir("codd-registry")
        let src = try Fixtures.directory("registry").appendingPathComponent("sessions")
        for name in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(name), to: tmp.file(name))
        }
        // Must never be opened: secret key files and non-registry names.
        try Data("SYNTHETIC-SECRET".utf8).write(to: tmp.file("48211.0f3a9c.key"))
        try Data("{\"pid\":1,\"status\":\"busy\"}".utf8).write(to: tmp.file("48211.backup.json"))
        try Data("{\"pid\":2,\"status\":\"busy\"}".utf8).write(to: tmp.file("abc.json"))
        try FileManager.default.createDirectory(at: tmp.file("99999.json"), withIntermediateDirectories: false)
        return tmp
    }

    @Test func readsOnlyNumericJSONFilesInPidOrder() throws {
        let tmp = try makeRegistry()
        defer { tmp.remove() }
        let entries = ClaudeRegistryReader().read(directory: tmp.url)
        // 48216 (truncated) and 48217 (array) are skipped; 48215 decodes with nils.
        #expect(entries.map(\.pid) == [48211, 48212, 48213, 48214, nil, 48218, 48219])
        #expect(!entries.contains { $0.pid == 1 || $0.pid == 2 })
    }

    @Test func readFilesKeepsUndecodableFilesByName() throws {
        let tmp = try makeRegistry()
        defer { tmp.remove() }
        let files = ClaudeRegistryReader().readFiles(directory: tmp.url)
        // Same filter and order as read(directory:); the truncated file, the array file and the
        // directory named like a registry file stay, with no entry.
        #expect(files.map(\.name) == ["48211.json", "48212.json", "48213.json", "48214.json", "48215.json",
                                     "48216.json", "48217.json", "48218.json", "48219.json", "99999.json"])
        #expect(files.first { $0.name == "48216.json" }?.entry == nil)
        #expect(files.first { $0.name == "48217.json" }?.entry == nil)
        #expect(files.first { $0.name == "99999.json" }?.entry == nil)
        #expect(files.compactMap(\.entry) == ClaudeRegistryReader().read(directory: tmp.url))
    }

    @Test func decodesDocumentedFields() throws {
        let tmp = try makeRegistry()
        defer { tmp.remove() }
        let e = try #require(ClaudeRegistryReader().read(directory: tmp.url).first { $0.pid == 48211 })
        #expect(e.sessionId == "11111111-aaaa-4aaa-8aaa-111111111111")
        #expect(e.cwd == "/synthetic/Project/orb-toolkit-backend")
        #expect(e.startedAt == JSDate.date(milliseconds: 1_792_032_000_000))
        #expect(e.procStart == "Thu Oct 15 02:40:00 2026")
        #expect(e.version == "2.1.300")
        #expect(e.kind == "interactive")
        #expect(e.entrypoint == "cli")
        #expect(e.name == "修正登入 API 401")
        #expect(e.nameSource == "derived")
        #expect(e.statusValue == .idle)
        #expect(e.waitingFor == nil)
        #expect(e.statusUpdatedAt == referenceNow)
        #expect(e.updatedAt == referenceNow)
        #expect(e.waitingReason == nil)
        #expect(!e.isSDK)
        #expect(!e.hasRemoteControl)
    }

    @Test func waitingForMapsToReasons() throws {
        let tmp = try makeRegistry()
        defer { tmp.remove() }
        let byPid = Dictionary(uniqueKeysWithValues: ClaudeRegistryReader().read(directory: tmp.url).compactMap { e in e.pid.map { ($0, e) } })
        #expect(byPid[48212]?.waitingReason == .permission)
        #expect(byPid[48214]?.waitingReason == .question)
        #expect(byPid[48218]?.waitingReason == .other)
        #expect(byPid[48219]?.waitingReason == .permission)
        #expect(byPid[48213]?.waitingReason == nil) // busy
    }

    @Test func toleratesOddValues() throws {
        let tmp = try makeRegistry()
        defer { tmp.remove() }
        let entries = ClaudeRegistryReader().read(directory: tmp.url)
        let sdk = try #require(entries.first { $0.pid == 48213 })
        #expect(sdk.isSDK)
        #expect(sdk.procStart == "Thu Oct  1 09:05:07 2026")
        let rc = try #require(entries.first { $0.pid == 48214 })
        #expect(rc.sessionId == "44444444-dddd-4ddd-8ddd-444444444444") // trimmed
        #expect(rc.hasRemoteControl)
        #expect(rc.statusUpdatedAt == JSDate.date(milliseconds: 1_792_032_000_000)) // epoch seconds accepted
        let garbage = try #require(entries.first { $0.pid == nil })
        #expect(garbage.sessionId == nil)
        #expect(garbage.cwd == nil)
        #expect(garbage.status == nil)
        #expect(garbage.startedAt == JSDate.date(fromISO: "2026-10-15T02:00:00.000Z"))
        // Present-but-invalid statusUpdatedAt does not fall back to updatedAt (session-insights rule).
        #expect(garbage.statusTimestampMilliseconds == nil)
        #expect(garbage.updatedAt != nil)
        let nullStamp = try #require(entries.first { $0.pid == 48219 })
        #expect(nullStamp.statusTimestampMilliseconds == 1_792_032_150_000) // null → updatedAt
    }

    @Test func missingDirectoryIsEmpty() {
        #expect(ClaudeRegistryReader().read(directory: URL(fileURLWithPath: "/nonexistent/codd/sessions")).isEmpty)
    }

    @Test func fileNameFilterAndOrder() {
        #expect(ClaudeRegistryReader.isRegistryFileName("123.json"))
        #expect(!ClaudeRegistryReader.isRegistryFileName("123.abc.key"))
        #expect(!ClaudeRegistryReader.isRegistryFileName(".json"))
        #expect(!ClaudeRegistryReader.isRegistryFileName("١٢.json")) // non-ASCII digits
        #expect(["10.json", "9.json", "0100.json", "11.json"].sorted(by: ClaudeRegistryReader.numericOrder)
                == ["9.json", "10.json", "11.json", "0100.json"])
    }

    @Test func defaultDirectory() {
        #expect(ClaudeRegistryReader.directory(configDir: nil, home: "/Users/x").path == "/Users/x/.claude/sessions")
        #expect(ClaudeRegistryReader.directory(configDir: "/p/profile").path == "/p/profile/sessions")
    }

    @Test func oversizedFileIsSkipped() throws {
        let tmp = try TempDir("codd-registry-big")
        defer { tmp.remove() }
        var big = "{\"pid\":5,\"pad\":\""
        big += String(repeating: "x", count: ClaudeRegistryReader.maxFileBytes)
        big += "\"}"
        try Data(big.utf8).write(to: tmp.file("5.json"))
        #expect(ClaudeRegistryReader().read(directory: tmp.url).isEmpty)
    }

    /// A FIFO named like a registry file must not block the reader (a plain open(2) would wait for
    /// a writer forever); symlinks to regular files are still read.
    @Test(.timeLimit(.minutes(1)))
    func fifosAreSkippedWithoutBlocking() throws {
        let tmp = try TempDir("codd-registry-fifo")
        defer { tmp.remove() }
        #expect(mkfifo(tmp.file("7.json").path, 0o600) == 0)
        try Data(#"{"pid":8,"status":"idle"}"#.utf8).write(to: tmp.file("real-8"))
        try FileManager.default.createSymbolicLink(at: tmp.file("8.json"), withDestinationURL: tmp.file("real-8"))
        let entries = ClaudeRegistryReader().read(directory: tmp.url)
        #expect(entries.map(\.pid) == [8])
    }
}

@Suite("Process liveness")
struct ProcessLivenessTests {
    /// `ps -o lstart= -p <pid>` with the given TZ: the exact layout Claude Code writes (in UTC).
    func psLstart(pid: Int32, tz: String) async throws -> String {
        let r = try await ProcessCommandRunner().run(CommandInvocation(
            executable: "/bin/ps", arguments: ["-o", "lstart=", "-p", String(pid)],
            environment: ["TZ": tz, "LANG": "C", "LC_ALL": "C"], timeout: .seconds(5)))
        return r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func procStartWrittenInUTCIsAliveInAnyLocalZone() async throws {
        let pid = getpid()
        let utcStamp = try await psLstart(pid: pid, tz: "UTC")
        #expect(!utcStamp.isEmpty)
        for zone in ["Asia/Taipei", "America/Los_Angeles", "UTC", "Pacific/Kiritimati"] {
            var checker = DarwinProcessLiveness()
            checker.fallbackTimeZone = try #require(TimeZone(identifier: zone))
            #expect(checker.isAlive(pid: Int(pid), procStart: utcStamp), "local zone \(zone), procStart \(utcStamp)")
        }
        // The parsed UTC stamp is the kernel start time truncated to the second.
        let started = try #require(DarwinProcessLiveness.startTime(pid: pid))
        let parsed = try #require(DarwinProcessLiveness.parseProcStart(utcStamp))
        #expect(started.timeIntervalSince(parsed) >= 0 && started.timeIntervalSince(parsed) < 1)
    }

    @Test func localTimeStampIsAcceptedAsFallback() async throws {
        let pid = getpid()
        var checker = DarwinProcessLiveness()
        checker.fallbackTimeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        #expect(checker.isAlive(pid: Int(pid), procStart: try await psLstart(pid: pid, tz: "Asia/Taipei")))
    }

    @Test func formatMatchesPsLayout() async throws {
        let pid = getpid()
        let started = try #require(DarwinProcessLiveness.startTime(pid: pid))
        #expect(DarwinProcessLiveness.formatProcStart(started) == (try await psLstart(pid: pid, tz: "UTC")))
    }

    @Test func recycledPidIsDead() throws {
        let pid = Int(getpid())
        let started = try #require(DarwinProcessLiveness.startTime(pid: getpid()))
        var checker = DarwinProcessLiveness()
        checker.fallbackTimeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        #expect(checker.isAlive(pid: pid, procStart: nil))
        #expect(checker.isAlive(pid: pid, procStart: DarwinProcessLiveness.formatProcStart(started)))
        // A different start time (in either interpretation) means the pid was recycled.
        for offset: TimeInterval in [-3600, -5, 5, 8 * 3600 + 5] {
            #expect(!checker.isAlive(pid: pid, procStart: DarwinProcessLiveness.formatProcStart(started.addingTimeInterval(offset))),
                    "offset \(offset)")
        }
        // Unparseable procStart falls back to pid existence.
        #expect(checker.isAlive(pid: pid, procStart: "not a date"))
    }

    @Test func impossiblePidsAreDead() {
        let checker = DarwinProcessLiveness()
        #expect(!checker.isAlive(pid: 0, procStart: nil))
        #expect(!checker.isAlive(pid: -5, procStart: nil))
        #expect(!checker.isAlive(pid: Int(Int32.max), procStart: nil))
    }

    @Test func parsesCtimeLayoutsAsUTC() throws {
        #expect(DarwinProcessLiveness.parseProcStart("Thu Oct 15 02:40:00 2026") == JSDate.date(milliseconds: 1_792_032_000_000))
        #expect(DarwinProcessLiveness.parseProcStart("Wed Oct 14 23:20:00 2026") == JSDate.date(milliseconds: 1_792_020_000_000))
        #expect(DarwinProcessLiveness.parseProcStart("Thu Oct  1 09:05:07 2026") == JSDate.date(fromISO: "2026-10-01T09:05:07Z"))
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        #expect(DarwinProcessLiveness.parseProcStart("Thu Oct 15 10:40:00 2026", timeZone: taipei) == JSDate.date(milliseconds: 1_792_032_000_000))
        for bad in ["yesterday", "Thu Feb 30 10:40:00 2026", "Xyz Oct 15 10:40:00 2026", "Thu Oct 15 24:00:00 2026",
                    "Thu Oct 15 10:40 2026", "Thu Oct 15 10:40:00", ""] {
            #expect(DarwinProcessLiveness.parseProcStart(bad) == nil, "\(bad)")
        }
    }

    @Test func liveEntriesDropDeadAndRecycledPids() throws {
        let me = Int(getpid())
        let started = try #require(DarwinProcessLiveness.startTime(pid: getpid()))
        let entries = [
            ClaudeRegistryEntry(pid: me, sessionId: "live", procStart: DarwinProcessLiveness.formatProcStart(started)),
            ClaudeRegistryEntry(pid: me, sessionId: "recycled", procStart: DarwinProcessLiveness.formatProcStart(started.addingTimeInterval(-86_400))),
            ClaudeRegistryEntry(pid: 0, sessionId: "zero"),
            ClaudeRegistryEntry(pid: nil, sessionId: "nopid"),
            ClaudeRegistryEntry(pid: Int(Int32.max), sessionId: "gone"),
        ]
        #expect(ClaudeRegistryReader.liveEntries(entries).map(\.sessionId) == ["live"])
    }

    /// Every fixture entry carries a UTC procStart consistent with its startedAt (as real files do).
    @Test func fixtureProcStartsAreUTC() throws {
        let dir = try Fixtures.directory("registry").appendingPathComponent("sessions")
        for e in ClaudeRegistryReader().read(directory: dir) where e.pid != 48213 {
            guard let procStart = e.procStart, let startedAt = e.startedAt else { continue }
            let parsed = try #require(DarwinProcessLiveness.parseProcStart(procStart))
            #expect(abs(parsed.timeIntervalSince(startedAt)) < 2, "pid \(e.pid ?? -1)")
        }
    }
}
