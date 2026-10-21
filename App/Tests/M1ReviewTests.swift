import AppKit
import CoddCore
import CoddHooks
import Darwin
import Foundation
import Testing
@testable import CODD

/// Regression tests for the M1 review findings on the app side. Temp data roots only; children are
/// `/bin/cat` (a fake `claude` script that runs cat), never a real claude.
@MainActor
@Suite("M1 review regressions (app)", .serialized)
final class M1ReviewAppTests {
    private let rootPath: String

    init() throws {
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/codd-r.XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        rootPath = CoddDataRoot(path: String(cString: created)).path
    }

    deinit {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", rootPath + "/"]
        try? pkill.run()
        pkill.waitUntilExit()
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    private var root: CoddDataRoot { CoddDataRoot(path: rootPath) }

    private func folder(_ name: String) throws -> String {
        let path = rootPath + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A launcher whose `claude` is a script that ignores its arguments and runs cat.
    private func launcher() throws -> HolderLauncher {
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        let fake = rootPath + "/fake-claude"
        if !FileManager.default.fileExists(atPath: fake) {
            try "#!/bin/sh\nexec /bin/cat\n".write(toFile: fake, atomically: true, encoding: .utf8)
            chmod(fake, 0o755)
        }
        return HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"],
                              claudePathOverride: fake)
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(8), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "timed out waiting for \(what)")
    }

    private func update(_ id: UUID, _ state: CoddCore.SessionState) -> SessionStateBatch {
        let activity = SessionActivity(state: .idle, since: JSDate.isoString(Date()))
        return SessionStateBatch(updates: [SessionStateUpdate(sessionID: id, state: state, activity: activity, hook: nil, hookSeen: true,
                                                              title: nil, registry: nil)], removed: [])
    }

    // MARK: - Hook pipeline: no hooks for a port that is not ours, and the bind is retried

    /// SEC-3: with the port held by something else, new claude sessions still got the token and
    /// every hook body sent there. E2E-1: the bind was never retried, so hooks stayed down for the
    /// whole run after a brief overlap with another instance.
    @Test func hookSettingsOnlyWhileListeningAndTheBindIsRetried() async throws {
        let blocker = try PortBlocker()
        let logs = Recorder<String>()
        let pipeline = HookPipeline(dataRoot: URL(fileURLWithPath: rootPath), claudeDirectory: ClaudeDirectory(path: try folder("claude")),
                                    port: blocker.port, bindRetryDelays: [.milliseconds(150)]) { logs.append($0) }
        await pipeline.start()
        #expect(pipeline.status == .portInUse(port: blocker.port, otherCODD: false))
        #expect(await pipeline.launchSettings(coddHook: "/usr/bin/true") == nil, "no token for a port this app does not hold")
        #expect(logs.values.contains { $0.hasPrefix("hooks not listening") })

        blocker.close()
        await waitUntil("listening after a retry") { pipeline.status.isListening }
        #expect(pipeline.status == .listening(port: blocker.port))
        #expect(logs.values.contains("hooks listening port=\(blocker.port) (after a retry)"))
        let setup = await pipeline.launchSettings(coddHook: "/usr/bin/true")
        #expect(setup?.settings.endpoint.port == blocker.port)
        #expect(setup.map { HookConfig.isValidToken($0.token) } == true)
        await pipeline.shutdown()
    }

    // MARK: - Pending prompt detail survives a relaunch

    /// E2E-2: after a relaunch a waiting question showed `1 Yes 2 No` (the real options came only
    /// with its hook, which is not repeated) and a permission prompt lost its command.
    @Test func pendingQuestionKeepsItsOptionsAcrossARelaunch() async throws {
        let launcher = try launcher()
        let first = HolderSessionStore(root: root, launcher: launcher) { _ in }
        await first.start()
        let id = try #require(first.createSession(NewSessionRequest(cwd: try folder("work"), kind: .claude)))
        let uuid = try #require(UUID(uuidString: id))
        await waitUntil("holder up") { first.connection(for: id)?.phase == .connected }
        let detail = HookToolDetail(tool: "AskUserQuestion", summary: "Which database should I use?",
                                    question: "Which database should I use?", options: ["Postgres", "SQLite", "MySQL"])
        first.applyDetail(.set(detail), for: uuid)
        first.apply(update(uuid, .waiting(.question)))
        #expect(first.session(id)?.answerOptions == ["Postgres", "SQLite", "MySQL"])
        PendingAnswerFile.flush()
        let file = root.sessionDirectory(id) + "/" + PendingAnswerFile.name
        #expect(FileManager.default.fileExists(atPath: file))
        #expect((try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        first.shutdown()

        // Relaunch: the engine reports the restored WAITING; no hook repeats the question.
        let second = HolderSessionStore(root: root, launcher: launcher) { _ in }
        await second.start()
        second.apply(update(uuid, .waiting(.question)))
        let session = try #require(second.session(id))
        #expect(session.answerOptions == ["Postgres", "SQLite", "MySQL"])
        #expect(session.detail == "Which database should I use?")
        // Answered: the next state clears it.
        second.apply(update(uuid, .busy))
        PendingAnswerFile.flush()
        #expect(!FileManager.default.fileExists(atPath: file))
        second.stop([id])
        await waitUntil("stopped") { !(second.session(id)?.state.isLive ?? true) }
        second.shutdown()
    }

    @Test func answerBarShowsNoGuessedOptionsAndNoDanglingSeparator() {
        let bar = AnswerBarView()
        bar.configure(reason: .question, tool: nil, detail: nil, options: [])
        #expect(bar.keyButtons.map(\.label) == ["取消"])
        #expect(bar.questionText.contains("選項沒有收到"))
        bar.configure(reason: .permission, tool: nil, detail: nil, options: [])
        #expect(bar.messageText == "Claude 需要授權")
        bar.configure(reason: .permission, tool: "Bash", detail: "ls", options: [])
        #expect(bar.messageText == "Claude 需要授權 ·")
    }

    // MARK: - Missing folder on RESUME, Chinese errors in the sheet

    /// E2E-6: RESUME into a deleted folder spawned anyway and ended `EXITED · code 126` with a
    /// message naming the program.
    @Test func resumeIntoAMissingFolderSaysSoAndSpawnsNothing() async throws {
        let work = try folder("gone")
        let group = ProjectGroup(name: "G", color: .purple, order: 0)
        let project = Project(groupId: group.id, name: "gone", path: work, order: 0)
        let record = SessionRecord(claudeSessionId: "claude-1", projectId: project.id, kind: .claude, order: 0,
                                   createdAt: Date(timeIntervalSinceNow: -60))
        try LayoutStore(fileURL: root.layoutURL).save(Layout(groups: [group], projects: [project], sessions: [record]))
        try FileManager.default.removeItem(atPath: work)
        let logs = Recorder<String>()
        let store = HolderSessionStore(root: root, launcher: try launcher()) { logs.append($0) }
        await store.start()
        let id = LayoutMapping.id(record.id)
        #expect(store.session(id)?.state == .stopped)
        store.resume(id)
        #expect(store.session(id)?.state == .stopped)
        #expect(store.session(id)?.launchError?.hasPrefix("找不到資料夾") == true)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!logs.values.contains { $0.hasPrefix("spawned session=") })
        store.shutdown()
    }

    /// E2E-7: the sheet showed `sessions are still loading` and the socket-path error in English.
    @Test func sheetErrorsAreInChinese() async throws {
        let early = HolderSessionStore(root: root, launcher: try launcher()) { _ in }
        #expect(early.createSession(NewSessionRequest(cwd: "/tmp", kind: .shell)) == nil)
        #expect(early.lastRefusal == "還在讀取 session，請稍候再試一次。")

        let long = CoddDataRoot(path: rootPath + "/" + String(repeating: "x", count: 90))
        var launcher = try launcher()
        launcher.root = long
        let store = HolderSessionStore(root: long, launcher: launcher) { _ in }
        await store.start()
        #expect(store.createSession(NewSessionRequest(cwd: "/tmp", kind: .shell)) == nil)
        #expect(store.lastRefusal == HolderStartError.socketPathTooLong(long.runPath).userMessage)
        store.shutdown()
    }

    // MARK: - Launch profile environment

    /// SEC-6: a profile's environment (CLAUDE_CONFIG_DIR for an account-pinned profile) was
    /// dropped for claude children.
    @Test func profileEnvironmentReachesClaudeWithTheBlockedNamesRules() throws {
        var launcher = try launcher()
        launcher.profiles = LaunchProfile.builtIn + [
            LaunchProfile(id: "acct-2", name: "claude #2", kind: .claude,
                          environment: ["CLAUDE_CONFIG_DIR": "/tmp/codd-acct-2", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]),
        ]
        var options = ClaudeLaunchOptions()
        options.profileID = "acct-2"
        let login = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/from/login"]
        let plan = try launcher.planClaude(sessionID: UUID(), cwd: "/tmp", options: options, hooks: nil, loginEnvironment: login)
        #expect(plan.environment["CLAUDE_CONFIG_DIR"] == "/tmp/codd-acct-2")
        #expect(plan.environment["DYLD_INSERT_LIBRARIES"] == nil)
        let plain = try launcher.planClaude(sessionID: UUID(), cwd: "/tmp", options: ClaudeLaunchOptions(), hooks: nil,
                                            loginEnvironment: login)
        #expect(plain.environment["CLAUDE_CONFIG_DIR"] == "/from/login")
    }
}

/// A listening TCP socket on a free 127.0.0.1 port in 43000-43999 that never accepts.
private final class PortBlocker {
    let port: UInt16
    private var fd: Int32

    init() throws {
        for _ in 0..<200 {
            let candidate = UInt16.random(in: 43000...43999)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if bound == 0, listen(fd, 4) == 0 {
                self.fd = fd
                port = candidate
                return
            }
            Darwin.close(fd)
        }
        throw POSIXError(.EADDRINUSE)
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }
}
