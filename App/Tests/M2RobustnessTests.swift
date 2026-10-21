import AppKit
import CoddHolderClient
import CoddHooks
import CoddProtocol
import CoddTerminal
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CODD

/// M2 step I1: the test-root hook port (D24), the single-instance lock (D9), the problem banner,
/// UNREACHABLE (D8), dead-session ring replay (D7) and occlusion while the window is away (D10).
/// Temp data roots and Claude directories only; children are `/bin/sh` and `cat`.

/// A fresh, normalized `$TMPDIR` folder (short: socket paths must fit 104 bytes).
private func makeTempRoot(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return CoddDataRoot(path: String(cString: created)).path
}

/// Kills every process whose command line names `root` (holders and their children), then
/// removes the folder.
private func cleanUp(root: String) {
    for signal in ["-CONT", "-KILL"] {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = [signal, "-f", root + "/"]
        try? pkill.run()
        pkill.waitUntilExit()
    }
    try? FileManager.default.removeItem(atPath: root)
}

@MainActor
private func waitUntil(_ what: String, timeout: Duration = .seconds(8), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

// MARK: - D24

@Suite("Test-root hook port (D24)")
struct TestRootHookPortTests {
    @Test func standardRootKeepsTheUserRangeEveryOtherRootGetsTheTestRange() {
        #expect(HookPipeline.portRange(for: .standard) == HookConfigStore.portRange)
        #expect(HookPipeline.portRange(for: .standard) == 47821...47899)
        #expect(HookPipeline.portRange(for: CoddDataRoot(path: "/tmp/codd-x")) == 43000...43999)
        #expect(HookPipeline.testPortRange == 43000...43999)
    }

    @MainActor @Test func storeForAnExplicitRootUsesTheTestRange() throws {
        let root = try makeTempRoot("codd-p")
        defer { cleanUp(root: root) }
        var options = RealModeOptions()
        options.dataRoot = root
        options.claudeDir = root + "/claude"
        let store = HolderSessionStore.make(options: options)
        #expect(store.hooks?.portRange == HookPipeline.testPortRange)
        // Construction touches nothing on disk (the instance lock comes first).
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root)) == [])
    }

    @MainActor @Test func missingConfigIsCreatedInTheTestRangeAndLoggedOnce() async throws {
        let root = try makeTempRoot("codd-p")
        defer { cleanUp(root: root) }
        let logs = Recorder<String>()
        let pipeline = HookPipeline(dataRoot: URL(fileURLWithPath: root), claudeDirectory: ClaudeDirectory(path: root + "/claude"),
                                    portRange: HookPipeline.testPortRange) { logs.append($0) }
        let config = try #require(await pipeline.loadConfig())
        #expect(HookPipeline.testPortRange.contains(config.port))
        #expect(logs.values.filter { $0 == "hooks port-range=test" }.count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: root + "/config.json")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // The next launch reads the same file: same port, no second log line.
        let again = HookPipeline(dataRoot: URL(fileURLWithPath: root), claudeDirectory: ClaudeDirectory(path: root + "/claude"),
                                 portRange: HookPipeline.testPortRange) { logs.append($0) }
        #expect(await again.loadConfig()?.port == config.port)
        #expect(logs.values.filter { $0 == "hooks port-range=test" }.count == 1)
    }

    @MainActor @Test func existingConfigIsUsedAsIs() async throws {
        let root = try makeTempRoot("codd-p")
        defer { cleanUp(root: root) }
        let token = String(repeating: "ab", count: 32)
        let text = "{\"port\":47830,\"token\":\"\(token)\",\"v\":1}\n"
        try text.write(toFile: root + "/config.json", atomically: true, encoding: .utf8)
        chmod(root + "/config.json", 0o600)
        let logs = Recorder<String>()
        let pipeline = HookPipeline(dataRoot: URL(fileURLWithPath: root), claudeDirectory: ClaudeDirectory(path: root + "/claude"),
                                    portRange: HookPipeline.testPortRange) { logs.append($0) }
        let config = try #require(await pipeline.loadConfig())
        #expect(config.port == 47830)
        #expect(config.token == token)
        // M4 §3.11: the file only gains the external MCP token at the first start; port, token and
        // every other key stay as written.
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "/config.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["port"] as? Int == 47830 && object["token"] as? String == token && object["v"] as? Int == 1)
        #expect((object["mcpToken"] as? String)?.count == 64)
        #expect(Set(object.keys) == ["port", "token", "v", "mcpToken"])
        #expect(!logs.values.contains("hooks port-range=test"))
    }
}

// MARK: - D9

@Suite("Single-instance lock (D9)", .serialized)
struct InstanceLockTests {
    @Test func secondAcquireFailsNamesTheOwnerAndSucceedsAfterRelease() throws {
        let base = try makeTempRoot("codd-l")
        defer { cleanUp(root: base) }
        let root = base + "/nested/root"  // missing: created 0700
        let started = Date(timeIntervalSince1970: 1_700_000_000.25)
        guard case .acquired(let first) = InstanceLock.acquire(dataRoot: root, pid: 4242, app: "/Applications/CODD.app", now: started)
        else { Issue.record("first acquire failed"); return }
        #expect(first.path == root + "/codd.lock")
        #expect(InstanceLock.readOwner(path: first.path) == InstanceLockOwner(pid: 4242, app: "/Applications/CODD.app",
                                                                               startedAt: 1_700_000_000_250))
        let text = try String(contentsOfFile: first.path, encoding: .utf8)
        #expect(text == "{\"app\":\"/Applications/CODD.app\",\"pid\":4242,\"startedAt\":1700000000250}\n")
        let fileMode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        let rootMode = try FileManager.default.attributesOfItem(atPath: root)[.posixPermissions] as? NSNumber
        #expect(rootMode?.intValue == 0o700)
        // Holders never inherit it.
        #expect(fcntl(first.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)

        // Another descriptor (flock is per open file): refused, owner read from the file.
        guard case .heldByAnother(let owner) = InstanceLock.acquire(dataRoot: root) else {
            Issue.record("second acquire was not refused")
            return
        }
        #expect(owner?.pid == 4242)
        // The refused attempt left the owner's record alone.
        #expect(InstanceLock.readOwner(path: first.path)?.pid == 4242)

        first.release()
        #expect(!first.isHeld)
        guard case .acquired(let again) = InstanceLock.acquire(dataRoot: root) else {
            Issue.record("acquire after release failed")
            return
        }
        #expect(InstanceLock.readOwner(path: again.path)?.pid == getpid())
        again.release()
    }

    @Test func staleFileOfADeadProcessIsLockedAgain() throws {
        let root = try makeTempRoot("codd-l")
        defer { cleanUp(root: root) }
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        while dead.isRunning { usleep(10_000) }
        let deadPid = dead.processIdentifier
        let path = InstanceLock.path(dataRoot: root)
        try "{\"pid\":\(deadPid),\"app\":\"/old/CODD.app\",\"startedAt\":1}\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o644)
        guard case .acquired(let lock) = InstanceLock.acquire(dataRoot: root) else {
            Issue.record("a stale lock file blocked the start")
            return
        }
        defer { lock.release() }
        #expect(InstanceLock.readOwner(path: path)?.pid == getpid())
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// Another process holding the flock (lockf(1) uses flock(2)) is seen as the owner; the
    /// kernel releases the lock when that process ends.
    @Test func lockHeldByAnotherProcessIsReleasedWhenItEnds() async throws {
        let root = try makeTempRoot("codd-l")
        defer { cleanUp(root: root) }
        let path = InstanceLock.path(dataRoot: root)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", path, "/bin/sleep", "2"]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        var outcome = InstanceLock.acquire(dataRoot: root)
        while case .acquired(let lock) = outcome, clock.now < deadline {
            // lockf has not taken it yet.
            lock.release()
            try await Task.sleep(for: .milliseconds(20))
            outcome = InstanceLock.acquire(dataRoot: root)
        }
        guard case .heldByAnother = outcome else {
            Issue.record("the other process's lock was not seen")
            return
        }
        // (lockf writes no record: the file still holds the probe's own, which is fine.)
        let exitDeadline = clock.now + .seconds(6)
        while holder.isRunning, clock.now < exitDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!holder.isRunning)
        guard case .acquired(let lock) = InstanceLock.acquire(dataRoot: root) else {
            Issue.record("the lock of an ended process was not released")
            return
        }
        #expect(InstanceLock.readOwner(path: path)?.pid == getpid())
        lock.release()
    }

    @Test func canonicalRootNamesThePhysicalFolder() throws {
        let root = try makeTempRoot("codd-l")
        defer { cleanUp(root: root) }
        let canonical = InstanceLock.canonicalRoot(root)
        #expect(InstanceLock.canonicalRoot(root + "/") == canonical)
        #expect(InstanceLock.canonicalRoot(root + "/./") == canonical)
        if root.hasPrefix("/var/") {
            #expect(InstanceLock.canonicalRoot("/private" + root) == canonical)
        }
        #expect(InstanceLock.canonicalRoot("/nonexistent/x/../y") == "/nonexistent/y")
    }
}

// MARK: - Options

@Suite("I1 options")
struct RobustnessOptionsTests {
    private func parse(_ args: [String]) -> RealModeOptions {
        RealModeOptions.parse(arguments: ["CODD"] + args, environment: [:], home: "/Users/tester")
    }

    @Test func unreachableKeepaliveWindowAndSelection() {
        let options = parse(["-codd-unreachable-after", "2", "-codd-keepalive", "1000,2000", "-codd-close-main-window", "YES",
                             "-codd-select-session", "1F341008-9C04-4DBD-9A0D-AAE1E3F34845"])
        #expect(options.unreachableAfterSeconds == 2)
        #expect(options.keepaliveIdleMilliseconds == 1000)
        #expect(options.keepaliveTimeoutMilliseconds == 2000)
        #expect(options.closeMainWindow)
        #expect(options.selectSession == "1f341008-9c04-4dbd-9a0d-aae1e3f34845")
        let tuning = options.connectionTuning
        #expect(tuning.unreachableAfter == .seconds(2))
        #expect(tuning.stream.keepaliveIntervalMilliseconds == 1000)
        #expect(tuning.stream.keepaliveTimeoutMilliseconds == 2000)
        // Defaults and bad values.
        #expect(parse([]).connectionTuning == PtyConnectionTuning())
        #expect(PtyConnectionTuning().unreachableAfter == .seconds(5))
        #expect(parse(["-codd-keepalive", "1000"]).keepaliveIdleMilliseconds == nil)
        #expect(parse(["-codd-unreachable-after", "-1"]).unreachableAfterSeconds == nil)
        // Release keeps none of them.
        #expect(options.releaseSubset == RealModeOptions())
    }
}

// MARK: - Problem banner

@MainActor
@Suite("Store problem")
struct StoreProblemTests {
    @Test func reportSurfacesDismissClearsAndRefusalsStayInTheSheet() throws {
        let root = try makeTempRoot("codd-q")
        defer { cleanUp(root: root) }
        let logs = Recorder<String>()
        let store = HolderSessionStore(root: CoddDataRoot(path: root), launcher: nil, claudeDirectory: ClaudeDirectory(path: root + "/c")) {
            logs.append($0)
        }
        #expect(store.problem == nil)
        store.report("讀不到 session 資料夾", detail: "listing failed")
        #expect(store.problem?.message == "讀不到 session 資料夾")
        #expect(store.problem?.sessionID == nil)
        #expect(logs.values.last == "error listing failed")
        store.report("只記在 log", surface: false)
        #expect(store.problem?.message == "讀不到 session 資料夾")
        store.report("另一個 CODD 接管了這個 session", sessionID: "abc")
        #expect(store.problem?.sessionID == "abc")
        store.dismissProblem()
        #expect(store.problem == nil)

        // A refusal goes back to the sheet, never to the banner.
        #expect(store.createSession(NewSessionRequest(cwd: "/tmp", kind: .shell)) == nil)
        #expect(store.lastRefusal == "還在讀取 session，請稍候再試一次。")
        #expect(store.problem == nil)
    }

    @Test func mockStoreHasNoProblemAndIgnoresRetries() {
        let store = MockSessionStore(shiftClock: false)
        #expect(store.problem == nil)
        store.dismissProblem()
        store.retryConnection("s1")
        #expect(store.problem == nil)
    }

    @Test func bannerShowsTheMessageAndItsAge() {
        let at = Date(timeIntervalSince1970: 1_000)
        let problem = StoreProblem(message: "shell 分頁無法啟動", at: at, sessionID: nil)
        #expect(ProblemBannerView.text(problem, now: at.addingTimeInterval(12)) == "shell 分頁無法啟動 · 12s 前")
        #expect(ProblemBannerView.text(problem, now: at.addingTimeInterval(125)) == "shell 分頁無法啟動 · 2m 前")
        let banner = ProblemBannerView()
        #expect(banner.isHidden)
        var dismissed = 0
        banner.onDismiss = { dismissed += 1 }
        banner.update(problem, now: at)
        #expect(!banner.isHidden)
        #expect(banner.actionButtons.map(\.title) == ["知道了"])
        banner.actionButtons.first?.performClick(nil)
        #expect(dismissed == 1)
        banner.update(nil, now: at)
        #expect(banner.isHidden)
    }

    @Test func unreachableStyleOverridesTheState() {
        let session = SessionVM(id: "x", projectID: "p", kind: .shell, title: "zsh", state: .shell, stateSince: Date())
        #expect(StateStyle.of(session).pill == "Shell")
        session.unreachableSince = Date()
        let style = StateStyle.of(session)
        #expect(style.glyph == "◌")
        #expect(style.pill == "Unreach")
        #expect(style.label == "UNREACHABLE")
        #expect(StateStyleKey(state: .shell, unreachable: true).style.label == "UNREACHABLE")
    }
}

// MARK: - D8

/// A UNIX socket that takes connections and never says a word (a holder that cannot answer).
private final class SilentListener {
    private var fd: Int32 = -1

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    deinit { close() }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

@MainActor
@Suite("UNREACHABLE (D8)", .serialized)
final class UnreachableTests {
    private let rootPath: String

    init() throws {
        rootPath = try makeTempRoot("codd-u")
    }

    deinit {
        cleanUp(root: rootPath)
    }

    private func launcher(_ argv: [String]) throws -> HolderLauncher {
        let root = CoddDataRoot(path: rootPath)
        let executable = try #require(HolderBinary.install(root: root) { _ in }, "CODD.app/Contents/MacOS/codd-holder is missing")
        return HolderLauncher(holderExecutable: executable, root: root, shellArgvOverride: argv)
    }

    private static let catArgv = ["/bin/sh", "-c", "printf 'up\\n'; exec /bin/cat"]

    /// A socket that accepts and never answers while meta.json names a live holder: UNREACHABLE
    /// after the configured delay, once. A real holder answering clears it, and `retryNow` does not
    /// wait for the (30 s) backoff.
    @Test func silentSocketIsUnreachableUntilARealHolderAnswers() async throws {
        let launcher = try launcher(Self.catArgv)
        let plan = try launcher.plan(sessionID: UUID(), cwd: "/tmp")
        let pid = try await Task.detached { try launcher.start(plan) }.value
        defer { kill(pid, SIGTERM) }
        let fakePath = rootPath + "/run/silent.sock"
        let listener = try SilentListener(path: fakePath)
        var tuning = PtyConnectionTuning()
        tuning.stream.handshakeTimeoutMilliseconds = 300
        tuning.unreachableAfter = .milliseconds(700)
        tuning.reconnectDelays = [.seconds(30)]
        tuning.slowReconnectDelay = .seconds(30)
        let events = Recorder<PtyEvent>()
        let logs = Recorder<String>()
        let connection = PtyConnection(sessionID: "silent", socketPath: fakePath, directory: plan.directory, tuning: tuning) {
            logs.append($0)
        }
        connection.onEvent = { events.append($0) }
        let clock = ContinuousClock()
        let started = clock.now
        connection.connect()
        await waitUntil("unreachable") { events.values.contains(.unreachable(true)) }
        #expect(clock.now - started >= .milliseconds(700))
        #expect(connection.isUnreachable)
        #expect(connection.unreachableSince != nil)
        #expect(connection.phase == .connecting || connection.phase == .reconnecting)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(events.values.filter { $0 == .unreachable(true) }.count == 1, "\(events.values)")

        // The path now leads to the real holder; the next attempt would be 30 s away.
        listener.close()
        unlink(fakePath)
        #expect(symlink(plan.socketPath, fakePath) == 0)
        let retried = clock.now
        connection.retryNow()
        await waitUntil("welcome after the retry", timeout: .seconds(3)) { connection.phase == .connected }
        #expect(clock.now - retried < .seconds(3))
        let tail = Array(events.values.drop { $0 != .unreachable(true) }.dropFirst())
        #expect(tail.first == .unreachable(false), "\(tail)")
        if tail.count > 1, case .welcome = tail[1] {} else { Issue.record("no WELCOME right after: \(tail)") }
        #expect(!connection.isUnreachable)
        #expect(connection.unreachableSince == nil)
        #expect(logs.values.contains { $0.hasPrefix("reconnect session=silent now") })
        connection.close()
    }

    /// No live holder behind the socket (meta.json missing): the connection ends, never UNREACHABLE.
    @Test func goneHolderEndsInsteadOfBeingUnreachable() async throws {
        var tuning = PtyConnectionTuning()
        tuning.unreachableAfter = .milliseconds(200)
        let events = Recorder<PtyEvent>()
        let connection = PtyConnection(sessionID: "gone", socketPath: rootPath + "/run/none.sock", directory: rootPath + "/none",
                                       tuning: tuning)
        connection.onEvent = { events.append($0) }
        connection.connect()
        await waitUntil("ended") { connection.phase == .ended }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(events.values == [.ended(.holderGone(exit: nil))])
        #expect(connection.ending == .holderGone(exit: nil))
    }

    /// A stopped holder (SIGSTOP) stops answering PING: the session is UNREACHABLE while its
    /// state stays. After SIGCONT the holder may still count another client for a moment (here a
    /// client that said HELLO while it was stopped): the reconnect is answered `busy`, the busy
    /// retry gets through, and the session is attached again, not taken over.
    @Test func stoppedHolderIsUnreachableThenAttachedAgainNotTakenOver() async throws {
        let launcher = try launcher(Self.catArgv)
        let logs = Recorder<String>()
        let store = HolderSessionStore(root: CoddDataRoot(path: rootPath), launcher: launcher,
                                       claudeDirectory: ClaudeDirectory(path: rootPath + "/claude")) { logs.append($0) }
        var tuning = PtyConnectionTuning()
        tuning.stream.keepaliveIntervalMilliseconds = 300
        tuning.stream.keepaliveTimeoutMilliseconds = 600
        tuning.stream.handshakeTimeoutMilliseconds = 3000
        tuning.unreachableAfter = .milliseconds(400)
        tuning.reconnectDelays = [.seconds(1)]
        tuning.slowReconnectDelay = .seconds(1)
        store.connectionTuning = tuning
        await store.start()
        let id = try #require(store.spawnShell(in: "/tmp"))
        await waitUntil("attached") { store.connection(for: id)?.phase == .connected && store.session(id)?.state == .shell }
        let holderPid = try #require(store.runtime(id)?.holderPid)
        let socketPath = try #require(store.runtime(id)?.socketPath)
        defer { kill(holderPid, SIGCONT) }

        kill(holderPid, SIGSTOP)
        await waitUntil("keepalive gave up") { logs.values.contains { $0.hasPrefix("closed session=\(id) reason=holder stopped answering") } }
        // Another client says HELLO while the holder is stopped: it is first in line.
        let other = try HolderConnection(socketPath: socketPath)
        defer { other.close() }
        try other.send(.hello(Hello(client: "stale-client")))
        await waitUntil("UNREACHABLE") { store.session(id)?.unreachableSince != nil }
        #expect(store.session(id)?.state == .shell, "the state stays while unreachable")
        await waitUntil("reconnect attempt queued") { logs.values.contains { $0.hasPrefix("reconnect session=\(id) attempt=") } }
        try? await Task.sleep(for: .milliseconds(150))

        kill(holderPid, SIGCONT)
        try? await Task.sleep(for: .milliseconds(150))
        other.close()  // gone before the busy retry
        await waitUntil("attached again", timeout: .seconds(10)) {
            store.connection(for: id)?.phase == .connected && store.session(id)?.unreachableSince == nil
        }
        #expect(store.session(id)?.state == .shell)
        #expect(store.connection(for: id)?.ending == nil)
        #expect(!logs.values.contains { $0.hasPrefix("ended session=\(id)") }, "\(logs.values.suffix(12))")
        #expect(logs.values.contains("reconnect session=\(id) after busy"), "busy retry not exercised: \(logs.values.suffix(12))")
        #expect(store.problem == nil)
        store.stop([id])
        await waitUntil("exit") { store.session(id)?.state == .exited }
        store.shutdown()
    }
}

// MARK: - D7, D10

/// Real holders streamed into real libghostty terminals in a window that is never ordered on screen.
@MainActor
@Suite("Dead-session replay and occlusion (D7, D10)", .serialized)
final class DeadSessionReplayTests {
    private let rootPath: String
    private let window: NSWindow
    private let container: NSView

    /// Prints its own pid (one token per process), then echoes what it is sent.
    private static let markerArgv = ["/bin/sh", "-c", "printf 'marker-%s\\n' $$; exec /bin/cat"]
    private static let footer = "holder 已結束 · 以上是最後的畫面（唯讀）"

    init() throws {
        rootPath = try makeTempRoot("codd-r")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = container
    }

    deinit {
        cleanUp(root: rootPath)
    }

    private struct Rig {
        let store: HolderSessionStore
        let shell: ShellState
        let hub: TerminalHub
        let main: TerminalSurface
        let panel: TerminalSurface
        let logs: Recorder<String>
    }

    private func makeRig(hotCapacity: Int = 6) async throws -> Rig {
        let root = CoddDataRoot(path: rootPath)
        let executable = try #require(HolderBinary.install(root: root) { _ in }, "CODD.app/Contents/MacOS/codd-holder is missing")
        let launcher = HolderLauncher(holderExecutable: executable, root: root, shellArgvOverride: Self.markerArgv)
        let logs = Recorder<String>()
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: ClaudeDirectory(path: rootPath + "/claude")) {
            logs.append($0)
        }
        let shell = ShellState()
        let hub = TerminalHub(store: store, shell: shell, hotCapacity: hotCapacity, probeWindow: .milliseconds(100)) { logs.append($0) }
        let main = hub.makeSurface(slot: .main)
        let panel = hub.makeSurface(slot: .panel)
        for (surface, y) in [(main, 300.0), (panel, 0.0)] {
            surface.view.frame = NSRect(x: 0, y: y, width: 900, height: 300)
            container.addSubview(surface.view)
        }
        await store.start()
        await hub.discoverTabs()
        return Rig(store: store, shell: shell, hub: hub, main: main, panel: panel, logs: logs)
    }

    private func tearDown(_ rig: Rig) {
        rig.hub.shutdown()
        rig.store.shutdown()
        rig.main.view.removeFromSuperview()
        rig.panel.view.removeFromSuperview()
    }

    private func text(_ rig: Rig) -> String { rig.hub.viewportText(.main) ?? "" }

    private func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    /// Relaunch after the holder was killed (`kill -9`): no connection at all; the ring has it.
    @Test func killedHolderReplaysItsLastScreenReadOnly() async throws {
        let first = try await makeRig()
        let id = try #require(first.store.spawnShell(in: "/tmp"))
        let target = TerminalTarget(sessionID: id, tab: .claude)
        first.main.attach(target)
        await waitUntil("streams") { first.hub.isStreaming(.main) && self.text(first).contains("marker-") }
        first.main.send(.text("typed-before-kill", submit: true))
        await waitUntil("echo") { self.occurrences("typed-before-kill", in: self.text(first)) >= 2 }
        let holderPid = try #require(first.store.runtime(id)?.holderPid)
        let child = try #require(first.store.session(id)?.pid)
        tearDown(first)
        kill(holderPid, SIGKILL)
        await waitUntil("holder gone") { !SessionDirectory.isHolderProcess(holderPid) }

        let second = try await makeRig()
        defer { tearDown(second) }
        #expect(second.store.session(id)?.state == .exited)
        #expect(second.store.connection(for: id) == nil)
        second.main.attach(target)
        await waitUntil("last screen replayed") {
            let screen = self.text(second)
            return screen.contains("marker-\(child)") && self.occurrences("typed-before-kill", in: screen) >= 2
                && screen.contains(Self.footer)
        }
        #expect(second.hub.isReplayed(id))
        #expect(second.logs.values.contains { $0.hasPrefix("replay session=\(id) bytes=") })
        let engine = try #require(second.hub.engine(for: target))
        #expect(engine.exitStatus != nil, "keys are disabled after the replay")
        // Typing goes nowhere.
        let typed = Mutex<[UInt8]>([])
        engine.onWrite = { bytes in typed.withLock { $0 += bytes } }
        engine.paste("typed-after-replay")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(typed.withLock { $0 }.isEmpty)
        engine.onWrite = nil
    }

    /// The holder ended while the terminal was cold (an EXITED session whose holder quit): the
    /// connection has ended, and showing it again replays the ring (it used to stay blank). A
    /// RESTART afterwards starts on a fresh surface: nothing of the old screen is mixed in.
    @Test func endedConnectionReplaysAndRestartGetsAFreshTerminal() async throws {
        let rig = try await makeRig(hotCapacity: 0)
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let target = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(target)
        await waitUntil("streams") { rig.hub.isStreaming(.main) && self.text(rig).contains("marker-") }
        rig.main.send(.text("typed-before-stop", submit: true))
        await waitUntil("echo") { self.occurrences("typed-before-stop", in: self.text(rig)) >= 2 }
        let oldChild = try #require(rig.store.session(id)?.pid)
        await waitUntil("pin released") { !rig.hub.isPinned(target) }
        rig.main.detach()
        #expect(rig.hub.tier(of: target) == .cold)

        rig.store.stop([id])
        await waitUntil("ended") { rig.store.connection(for: id)?.phase == .ended && rig.store.session(id)?.state == .exited }
        if case .holderGone? = rig.store.connection(for: id)?.ending {} else { Issue.record("not holderGone") }
        rig.main.attach(target)
        await waitUntil("replayed") {
            let screen = self.text(rig)
            return screen.contains("marker-\(oldChild)") && screen.contains("typed-before-stop") && screen.contains(Self.footer)
        }
        #expect(rig.hub.isReplayed(id))

        rig.store.restart(id)
        await waitUntil("restarted") { rig.store.session(id)?.state == .shell && rig.store.session(id)?.pid != oldChild }
        let newChild = try #require(rig.store.session(id)?.pid)
        await waitUntil("new process on screen") { self.text(rig).contains("marker-\(newChild)") }
        let screen = text(rig)
        #expect(!screen.contains("marker-\(oldChild)"), "\(screen)")
        #expect(!screen.contains(Self.footer), "\(screen)")
        #expect(!screen.contains("typed-before-stop"), "\(screen)")
        #expect(!rig.hub.isReplayed(id))
        // Keys flow again.
        rig.main.send(.text("typed-after-restart", submit: true))
        await waitUntil("echo after restart") { self.occurrences("typed-after-restart", in: self.text(rig)) >= 2 }
        rig.store.stop([id])
        await waitUntil("exit") { rig.store.session(id)?.state == .exited }
    }

    /// D10: the window closing occludes every shown terminal (also one shown while it is
    /// closed); showing it again restores them, tiers unchanged.
    @Test func closedWindowOccludesEveryTerminalAndShowRestores() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = try #require(rig.store.spawnShell(in: "/tmp"))
        let target = TerminalTarget(sessionID: id, tab: .claude)
        rig.main.attach(target)
        let panel = try #require(rig.shell.togglePanel(in: id))
        let panelTarget = TerminalTarget(sessionID: id, tab: .shell(panel.id))
        rig.panel.attach(panelTarget)
        await waitUntil("both stream") { rig.hub.isStreaming(.main) && rig.hub.isStreaming(.panel) }
        let mainEngine = try #require(rig.hub.engine(for: target))
        let panelEngine = try #require(rig.hub.engine(for: panelTarget))
        #expect(!mainEngine.isOccluded && !panelEngine.isOccluded)

        rig.hub.setWindowOccluded(true)
        #expect(rig.hub.isWindowOccluded)
        #expect(mainEngine.isOccluded && panelEngine.isOccluded)
        #expect(rig.hub.tier(of: target) == .visible)
        // A session shown while the window is closed does not render either.
        let other = try #require(rig.store.spawnShell(in: "/tmp"))
        let otherTarget = TerminalTarget(sessionID: other, tab: .claude)
        rig.main.attach(otherTarget)
        let otherEngine = try #require(rig.hub.engine(for: otherTarget))
        #expect(otherEngine.isOccluded)
        #expect(mainEngine.isOccluded)
        // Output still reaches it (parsing goes on).
        await waitUntil("hidden output parsed") { self.text(rig).contains("marker-") }

        rig.hub.setWindowOccluded(false)
        #expect(!otherEngine.isOccluded && !panelEngine.isOccluded)
        #expect(mainEngine.isOccluded, "hidden by the switch, hot")
        #expect(rig.logs.values.contains("terminals window-occluded=true"))
        #expect(rig.logs.values.contains("terminals window-occluded=false"))
        rig.store.stop([id, other])
        await waitUntil("exits") { rig.store.session(id)?.state == .exited && rig.store.session(other)?.state == .exited }
    }
}
