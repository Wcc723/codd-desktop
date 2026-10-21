import CoddHolderClient
import CoddProtocol
import CoddTerminal
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CODD

@Suite("Real mode options")
struct RealModeOptionsTests {
    private let home = "/Users/tester"

    private func parse(_ args: [String], env: [String: String] = [:]) -> RealModeOptions {
        RealModeOptions.parse(arguments: ["CODD"] + args, environment: env, home: home)
    }

    @Test func realModeIsTheDefaultAndMockToolsImplyMock() {
        #expect(parse([]) == RealModeOptions())
        #expect(parse([]).enabled)
        #expect(!parse(["-codd-mock"]).enabled)
        #expect(!parse(["-codd-mock", "YES"]).enabled)
        #expect(parse(["-codd-mock", "NO"]).enabled)
        // DEBUG tools that draw the SPEC mock data never touch the real data root by accident.
        #expect(!parse(["-CODDSelfTest", "YES", "-NSDocumentRevisionsDebugMode", "YES"]).enabled)
        #expect(!parse(["-CODDSnapshotDir", "/tmp/s"]).enabled)
        #expect(parse(["-CODDMetrics", "YES", "-codd-real-holders"]).enabled)
    }

    @Test func claudeDirectoryAndClaudePathOverrides() {
        #expect(parse(["-codd-claude-dir", "~/c"]).claudeDir == "/Users/tester/c")
        #expect(parse([], env: ["CODD_CLAUDE_DIR": "/x/.claude"]).claudeDir == "/x/.claude")
        #expect(parse(["-codd-claude-dir", "/a"], env: ["CODD_CLAUDE_DIR": "/b"]).claudeDir == "/a")
        #expect(parse(["-codd-claude-path", "/t/fake-claude"]).claudePath == "/t/fake-claude")
        #expect(parse(["-codd-new-claude", "YES"]).newClaudeCwd == home)
        #expect(parse(["-codd-dump-state", "~/s.json"]).dumpStatePath == "/Users/tester/s.json")
        #expect(parse(["-codd-auto-answer", "ESC"]).autoAnswer == "esc")
        #expect(parse(["-codd-auto-answer", "x"]).autoAnswer == nil)
        #expect(!parse(["-codd-notifications", "NO"]).notifications)
        // A Release build keeps only mode, data root and Claude directory.
        let release = parse(["-codd-data-root", "/r", "-codd-claude-dir", "/c", "-codd-claude-path", "/f", "-codd-spawn-shell", "YES"])
            .releaseSubset
        #expect(release == RealModeOptions(dataRoot: "/r", claudeDir: "/c"))
    }

    @Test func realHoldersFlagWithAndWithoutValue() {
        #expect(parse(["-codd-real-holders"]).enabled)
        #expect(parse(["-codd-real-holders", "YES"]).enabled)
        #expect(!parse(["-codd-real-holders", "NO"]).enabled)
        // A following flag is not swallowed as the value.
        let options = parse(["-codd-real-holders", "-codd-data-root", "/tmp/r"])
        #expect(options.enabled)
        #expect(options.dataRoot == "/tmp/r")
    }

    @Test func dataRootFlagBeatsEnvironmentAndTildeExpands() {
        #expect(parse([], env: ["CODD_DATA_ROOT": "~/x"]).dataRoot == "/Users/tester/x")
        #expect(parse(["-codd-data-root", "/a"], env: ["CODD_DATA_ROOT": "/b"]).dataRoot == "/a")
        #expect(parse([], env: ["CODD_DATA_ROOT": ""]).dataRoot == nil)
    }

    @Test func spawnShellArgvAndQuit() {
        #expect(parse(["-codd-spawn-shell", "YES"]).spawnShellCwd == home)
        #expect(parse(["-codd-spawn-shell", "NO"]).spawnShellCwd == nil)
        #expect(parse(["-codd-spawn-shell", "~/p"]).spawnShellCwd == "/Users/tester/p")
        #expect(parse(["-codd-shell-argv", "/bin/zsh  -f"]).shellArgv == ["/bin/zsh", "-f"])
        #expect(parse(["-codd-quit-after", "2.5"]).quitAfterSeconds == 2.5)
        #expect(parse(["-codd-quit-after", "-1"]).quitAfterSeconds == nil)
        #expect(parse(["-codd-snapshot", "~/s.png"]).snapshotPath == "/Users/tester/s.png")
    }
}

@Suite("Data root")
struct CoddDataRootTests {
    @Test func pathsAreNormalized() {
        let root = CoddDataRoot(path: "/var/T//codd/")
        #expect(root.path == "/var/T/codd")
        #expect(root.sessionsPath == "/var/T/codd/sessions")
        #expect(root.sessionDirectory("abc") == "/var/T/codd/sessions/abc")
    }

    @Test func socketNameGrowsOnlyOnCollision() {
        let root = CoddDataRoot(path: "/r")
        let id = "1f341008-9c04-4dbd-9a0d-aae1e3f34845"
        #expect(root.socketPath(for: id) { _ in false } == "/r/run/1f341008.sock")
        #expect(root.socketPath(for: id) { $0 == "/r/run/1f341008.sock" } == "/r/run/1f3410089c04.sock")
        #expect(root.socketPath(for: "xyz") { _ in false } == nil)
    }

    @Test func socketPathMustFitSunPath() {
        let long = CoddDataRoot(path: "/" + String(repeating: "d", count: 100))
        #expect(long.socketPath(for: "1f341008-9c04-4dbd-9a0d-aae1e3f34845") { _ in false } == nil)
    }
}

/// Collects values from main-actor callbacks (a box, so `@Sendable` closures can capture it).
@MainActor
final class Recorder<Value> {
    var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// Real `codd-holder` processes (the copy embedded in CODD.app) in a temporary data root. The
/// child is `/bin/sh` printing an OSC 0 title and an OSC 7 cwd, then `cat`; never `claude`.
@MainActor
@Suite("Real holders", .serialized)
final class RealHolderIntegrationTests {
    private let rootPath: String
    private var holderPids: [pid_t] = []

    private static let childArgv = [
        "/bin/sh", "-c", "printf '\\033]0;codd-test-title\\007\\033]7;file://localhost/private/tmp\\007'; exec /bin/cat",
    ]

    init() throws {
        // $TMPDIR keeps socket paths far below the 104-byte sun_path limit.
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/codd-t.XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        rootPath = String(cString: created)
    }

    deinit {
        for pid in holderPids { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    private func makeLauncher(argv: [String] = RealHolderIntegrationTests.childArgv) throws -> HolderLauncher {
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        return HolderLauncher(holderExecutable: holder, root: CoddDataRoot(path: rootPath),
                              shellArgvOverride: argv)
    }

    /// Review F3: every TITLE frame used to hop to the main queue on its own, so a program that
    /// changes its title in a loop saturated the main thread. While the main thread is busy, the
    /// connection keeps only the newest title and delivers it once.
    @Test func titleFloodReachesTheMainActorCoalesced() async throws {
        let flood = "read go; i=0; while [ $i -lt 3000 ]; do printf '\\033]0;t%d\\007x' $i; i=$((i+1)); done; "
            + "printf '\\033]0;final-title\\007done-flood'; exec /bin/cat"
        let launcher = try makeLauncher(argv: ["/bin/sh", "-c", flood])
        let plan = try launcher.plan(sessionID: UUID(), cwd: "/tmp")
        let pid = try await Task.detached { try launcher.start(plan) }.value
        holderPids.append(pid)
        let events = Recorder<PtyEvent>()
        let connection = PtyConnection(sessionID: plan.sessionID, socketPath: plan.socketPath, directory: plan.directory)
        connection.onEvent = { events.append($0) }
        connection.connect()
        await waitUntil("connected") { connection.phase == .connected }
        #expect(connection.send(Array("go\n".utf8)))
        // The main thread is busy while the child floods (the stream queue keeps reading).
        usleep(1_500_000)
        await waitUntil("final title") { events.values.contains(.title("final-title")) }
        try? await Task.sleep(for: .milliseconds(100))
        let titles = events.values.compactMap { if case .title(let t) = $0 { t } else { nil } }
        #expect(titles.last == "final-title")
        #expect(titles.count <= 3, "\(titles.count) title hops: \(titles.prefix(5))")
        connection.close()
        kill(pid, SIGTERM)
    }

    /// Review finding: a taken-over client that missed the ERROR (paused, socket buffers full)
    /// saw only EOF, reconnected with takeover and took the holder back; two clients then fought
    /// forever. A reconnect now asks without takeover and ends as taken over on `busy`.
    @Test func reconnectAfterAnUnexplainedCloseDoesNotTakeOver() async throws {
        let launcher = try makeLauncher(argv: ["/bin/sh", "-c", "exec yes"])
        let plan = try launcher.plan(sessionID: UUID(), cwd: "/tmp")
        let pid = try await Task.detached { try launcher.start(plan) }.value
        holderPids.append(pid)
        try? await Task.sleep(for: .milliseconds(800))  // the 8 MiB ring fills
        let events = Recorder<PtyEvent>()
        let logs = Recorder<String>()
        let connection = PtyConnection(sessionID: plan.sessionID, socketPath: plan.socketPath, directory: plan.directory) {
            logs.append($0)
        }
        connection.onEvent = { events.append($0) }
        // Never in a window: nothing parses, so the replay's backlog pauses the stream for good.
        let engine = TerminalEngine(configuration: CoddTerminalSetup.configuration)
        defer { engine.dispose() }
        connection.attach(engine)
        connection.connect()
        await waitUntil("paused by the backlog") { connection.isBacklogged }
        try? await Task.sleep(for: .milliseconds(300))  // socket buffers fill

        let thief = try HolderConnection(socketPath: plan.socketPath)
        defer { thief.close() }
        _ = try thief.handshake(client: "thief", takeover: true)
        // The stream reads again (its ERROR may be lost behind full buffers), finds the
        // connection closed, and must not take the holder back.
        connection.detachEngine()
        await waitUntil("ended as taken over", timeout: .seconds(8)) { events.values.contains(.ended(.takenOver)) }
        #expect(connection.phase == .ended)
        // The thief still holds the holder.
        try thief.send(.ping(token: 42))
        var answer: Message?
        for _ in 0..<20 {
            answer = try thief.receive(timeoutMilliseconds: 250)
            if case .pong? = answer { break }
        }
        #expect(answer == .pong(token: 42), "\(String(describing: answer)); \(logs.values.suffix(5))")
        connection.close()
        kill(pid, SIGTERM)
    }

    @Test func inputHeldWhileReconnectingGoesOutOnTheNextStream() async throws {
        let launcher = try makeLauncher(argv: ["/bin/sh", "-c", "exec /bin/cat"])
        let plan = try launcher.plan(sessionID: UUID(), cwd: "/tmp")
        let pid = try await Task.detached { try launcher.start(plan) }.value
        holderPids.append(pid)
        let sink = PtySink()
        sink.write(Array("dropped\n".utf8))  // not reconnecting: nothing is held
        #expect(sink.heldInputByteCount == 0)
        sink.holdInput(true)
        sink.write(Array("held-keys\n".utf8))
        #expect(sink.heldInputByteCount == 10)
        #expect(!sink.hold([UInt8](repeating: 0x61, count: PtySink.heldInputLimit), submit: false), "bounded")
        let stream = try HolderStream(socketPath: plan.socketPath, clientName: "test")
        let output = Mutex("")
        stream.onOutput = { _, bytes, _ in
            let text = String(decoding: bytes, as: UTF8.self)
            output.withLock { $0 += text }
        }
        sink.setStream(stream)
        #expect(sink.heldInputByteCount == 0)
        stream.start(takeover: true, attachFrom: .latestResync)
        await waitUntil("held keys reached the child") { output.withLock { $0 }.contains("held-keys") }
        #expect(!output.withLock { $0 }.contains("dropped"))
        stream.close()
        sink.setStream(nil)
        kill(pid, SIGTERM)
    }

    @Test func relayDeliversTheLatestValueOncePerHop() {
        let relay = LatestValueRelay<Int>()
        #expect(relay.store(1))      // schedule a hop
        #expect(!relay.store(2))     // one is pending
        #expect(!relay.store(3))
        #expect(relay.take() == 3)
        #expect(relay.take() == nil) // nothing new
        #expect(relay.store(4))      // re-armed after a take
        #expect(relay.take() == 4)
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "timed out waiting for \(what)")
    }

    @Test func connectionReceivesWelcomeTitleAndExit() async throws {
        let launcher = try makeLauncher()
        let plan = try launcher.plan(sessionID: UUID(), cwd: "/tmp")
        let pid = try await Task.detached { try launcher.start(plan) }.value
        holderPids.append(pid)

        let events = Recorder<PtyEvent>()
        let connection = PtyConnection(sessionID: plan.sessionID, socketPath: plan.socketPath, directory: plan.directory)
        connection.onEvent = { events.append($0) }
        connection.connect()
        await waitUntil("WELCOME") { !events.values.isEmpty }
        guard case .welcome(let welcome)? = events.values.first else {
            Issue.record("first event is not WELCOME: \(events.values)")
            return
        }
        #expect(welcome.session == plan.sessionID)
        #expect(welcome.holderPid == pid)
        #expect(!welcome.exited)
        #expect(connection.phase == .connected)
        // The title arrives in WELCOME (already scanned) or as a TITLE frame right after.
        await waitUntil("title") {
            welcome.title == "codd-test-title" || events.values.contains(.title("codd-test-title"))
        }

        kill(pid, SIGTERM)
        await waitUntil("EXIT") { events.values.contains { if case .exit = $0 { true } else { false } } }
        // The holder exits right after (no client keeps it lingering once it is gone).
        await waitUntil("ended", timeout: .seconds(15)) {
            events.values.contains { if case .ended = $0 { true } else { false } }
        }
        connection.close()
    }

    @Test func storeSpawnsSurvivesDisconnectAndReattaches() async throws {
        let launcher = try makeLauncher()
        let root = CoddDataRoot(path: rootPath)
        let firstLogs = Recorder<String>()
        let secondLogs = Recorder<String>()

        let first = HolderSessionStore(root: root, launcher: launcher) { firstLogs.append($0) }
        await first.start()
        let id = try #require(first.spawnShell(in: "/tmp"))
        #expect(first.session(id)?.state == .starting)
        await waitUntil("first attach") { first.session(id)?.state == .shell }
        await waitUntil("OSC title") { first.session(id)?.title == "codd-test-title" }
        await waitUntil("OSC 7 cwd") { first.session(id)?.detail == "/private/tmp" }
        let holderPid = try #require(first.runtime(id)?.holderPid)
        holderPids.append(holderPid)
        #expect(first.project(forPath: "/tmp")?.sessionIDs == [id])

        // App quit: only the connection closes; the holder keeps running.
        first.shutdown()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(kill(holderPid, 0) == 0, "holder died with its client")

        // Next launch: discovered from meta.json and reattached.
        let second = HolderSessionStore(root: root, launcher: launcher) { secondLogs.append($0) }
        await second.start()
        #expect(second.session(id)?.state == .shell)
        #expect(secondLogs.values.contains { $0.hasPrefix("discovered") && $0.hasSuffix("sessions=1 live=1") })
        await waitUntil("reattach") {
            secondLogs.values.contains { $0.hasPrefix("attached session=\(id) holderPid=\(holderPid) ") }
        }
        // WELCOME carries the scanner's title and cwd (meta.json may not have caught up yet).
        await waitUntil("title after reattach") { second.session(id)?.title == "codd-test-title" }
        #expect(second.session(id)?.detail == "/private/tmp")
        #expect(firstLogs.values.filter { $0.hasPrefix("attached session=\(id)") }.count == 1)

        // STOP: SIGTERM to the holder; EXIT marks the row exited.
        second.stop([id])
        await waitUntil("exit") { second.session(id)?.state == .exited }
        second.shutdown()
        await waitUntil("holder exit", timeout: .seconds(3)) { kill(holderPid, 0) != 0 }

        // An ended session can be deleted with its directory.
        await second.deleteHistory(id)
        #expect(second.session(id) == nil)
        await waitUntil("directory removed") { !FileManager.default.fileExists(atPath: root.sessionDirectory(id)) }
    }
}
