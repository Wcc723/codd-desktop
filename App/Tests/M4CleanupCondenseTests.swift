import CoddCore
import CoddNotes
import Foundation
import Testing
@testable import CODD

// M4 I4a, D32: `交給 Claude 濃縮` with a fake claude (a /bin/sh script that records its argv,
// environment, cwd and stdin, then prints a summary or sleeps). Temp data root, the hook config
// loaded but no server bound, no real claude, no network.

@Suite("M4 cleanup · condense")
@MainActor
struct M4CleanupCondenseTests {
    /// The fake claude: `CONDENSE_MODE=ok` prints a summary, `sleep` waits 30 s, `fail` exits 3.
    static let script = """
    #!/bin/sh
    out="$CONDENSE_TEST_OUT"
    printf '%s\\n' "$@" > "$out/argv.txt"
    env | sort > "$out/env.txt"
    pwd > "$out/cwd.txt"
    ls "$PWD" > "$out/files.txt"
    cat > "$out/stdin.txt"
    case "$CONDENSE_MODE" in
      sleep) sleep 30 ;;
      fail) echo "boom: something broke" >&2; exit 3 ;;
    esac
    printf '# 摘要 · 10/18 清理（3 則）\\n\\n## 舊審查清單草稿\\n- v1 的「程式碼風格」改成「驗證方式」\\n'
    """

    private struct Fixture {
        let rig: CleanupRig
        let runner: CondenseRunner
        let out: String
    }

    private func fixture(_ prefix: String, mode: String = "ok") async throws -> Fixture {
        let rig = try await CleanupRig(prefix, hooks: true)
        let out = rig.folder + "/out"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let claude = rig.folder + "/bin/claude"
        try FileManager.default.createDirectory(atPath: rig.folder + "/bin", withIntermediateDirectories: true)
        try Self.script.write(toFile: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)
        let runner = CondenseRunner(notes: rig.notes, holders: rig.store, mcp: nil, clock: rig.clock.function, timeZone: CleanupRig.taipei,
                                    log: { rig.logs.append($0) })
        runner.claudeExecutable = { claude }
        let home = rig.folder + "/home"
        runner.environment = {
            (["HOME": home, "PATH": "/usr/bin:/bin", "USER": "tester"],
             ["CONDENSE_TEST_OUT": out, "CONDENSE_MODE": mode, "CODD_SESSION_ID": "leak", "CODD_HOOK_TOKEN": "leak"])
        }
        return Fixture(rig: rig, runner: runner, out: out)
    }

    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    @Test func argvIsExactAndEveryVariadicFlagIsFollowedByAnOption() {
        let argv = CondenseRunner.arguments(model: "sonnet-5.5", mcpConfig: "/r/mcp.json")
        #expect(argv == ["-p", "--model", "sonnet-5.5", "--output-format", "text", "--tools", "", "--permission-prompts", "none",
                         "--strict-mcp-config", "--mcp-config", "/r/mcp.json", "--allowedTools", "mcp__codd__notes_read",
                         "--no-session-persistence"])
        for flag in ["--tools", "--mcp-config", "--allowedTools"] {
            let index = try! #require(argv.firstIndex(of: flag))
            #expect(argv.indices.contains(index + 2) && argv[index + 2].hasPrefix("--"), "\(flag) is followed by another option")
        }
        #expect(!argv.contains { !$0.hasPrefix("-") && $0 != "" && $0 != "sonnet-5.5" && $0 != "text" && $0 != "none"
                && $0 != "/r/mcp.json" && $0 != "mcp__codd__notes_read" }, "no positional prompt")
    }

    @Test func theEnvironmentCarriesNoCODDTokenAndPinsOnlyAChosenAccount() {
        let id = UUID()
        let login = ["CODD_SESSION_ID": "x", "CODD_HOOK_TOKEN": "y", "CODD_HOOK_URL": "z", "FOO": "1", "PATH": "/usr/bin"]
        let env = CondenseRunner.childEnvironment(base: ["HOME": "/Users/t"], login: login, runID: id, configDirectory: nil)
        #expect(env["CODD_SESSION_ID"] == nil && env["CODD_HOOK_TOKEN"] == nil && env["CODD_HOOK_URL"] == nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(env["FOO"] == "1" && env["HOME"] == "/Users/t")
        let pinned = CondenseRunner.childEnvironment(base: ["HOME": "/Users/t"], login: login, runID: id, configDirectory: "/tmp/profile-3")
        #expect(pinned["CLAUDE_CONFIG_DIR"] == "/tmp/profile-3")
    }

    @Test func aRunReadsTheNotesOnStdinThenApplyArchivesTheOriginalsAndUndoRestoresThem() async throws {
        let f = try await fixture("codd-m4-condense")
        defer { f.rig.tearDown() }
        let rig = f.rig
        let checklist = try await rig.note("舊審查清單草稿", body: "# 舊審查清單草稿\n\nv1 的審查項目：程式碼風格、錯誤處理、文件。\n")
        let prompt = try await rig.note("keynote 第 2 章大綱", body: "# keynote 第 2 章大綱\n\n2-4 demo 順序。\n", kind: .prompt)
        let secret = try await rig.note("不給 AI 的私人紀錄", body: "# 不給 AI 的私人紀錄\n\nOFF-NOTE-SECRET-42\n", ai: .off)
        let daily = try await rig.note("每日工作日誌", body: """
        # 每日工作日誌

        ## 2026-08-01 改用 cswap
        舊段落一 LOG-OLD-1

        ## 2026-08-03 hooks
        舊段落二 LOG-OLD-2

        ## 2026-08-09 帳號
        舊段落三 LOG-OLD-3

        ## 2026-10-17 今天
        新段落 LOG-NEW

        """)
        let before = try await rig.library.document(daily).body

        await f.runner.prepare([checklist, prompt, secret, daily], longNotes: [daily])
        #expect(f.runner.excluded == [secret], "AI OFF notes are left out")
        #expect(f.runner.sources.map(\.id) == [checklist, prompt, daily])
        f.runner.generate(account: "follow", model: "sonnet-5.5")
        await f.runner.waitForRun()
        guard case .preview(let output) = f.runner.phase else {
            Issue.record("no preview: \(f.runner.phase) logs: \(rig.logs.values.suffix(5))")
            return
        }
        #expect(output.contains("## 舊審查清單草稿"))

        // argv, cwd, environment and stdin as D32 says.
        let argv = Array(read(f.out + "/argv.txt").components(separatedBy: "\n").dropLast())
        let mcpConfig = argv.count > 11 ? argv[11] : ""
        #expect(argv == CondenseRunner.arguments(model: "sonnet-5.5", mcpConfig: mcpConfig))
        #expect(mcpConfig.hasPrefix(rig.root.runPath + "/condense-") && mcpConfig.hasSuffix("/mcp.json"))
        let folder = read(f.out + "/cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((folder as NSString).lastPathComponent == ((mcpConfig as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                "claude runs in the run folder")
        #expect(read(f.out + "/files.txt").contains("mcp.json"), "the run folder carries its mcp.json while claude runs")
        let env = read(f.out + "/env.txt")
        #expect(!env.contains("CODD_SESSION_ID=") && !env.contains("CODD_HOOK_TOKEN=") && !env.contains("CODD_HOOK_URL="))
        #expect(!env.contains("CLAUDE_CONFIG_DIR="), "follow: the global login")
        let stdin = read(f.out + "/stdin.txt")
        #expect(stdin.contains("請把下面 3 則筆記濃縮成"))
        #expect(stdin.contains("v1 的審查項目") && stdin.contains("2-4 demo 順序"))
        #expect(!stdin.contains("OFF-NOTE-SECRET-42"), "an OFF note never reaches claude")
        #expect(stdin.contains("LOG-OLD-1") && stdin.contains("LOG-OLD-3") && stdin.contains("（舊段落 3 段）"))
        #expect(!stdin.contains("LOG-NEW"), "a long note gives only its sections older than 30 days")
        // The run folder (token, notes' text) is gone; the child is no EXT any more.
        #expect(f.runner.lastRun?.folderRemoved == true)
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: rig.root.runPath)) ?? []).contains { $0.hasPrefix("condense-") })
        #expect(rig.store.transientClaudePids.isEmpty)
        #expect(rig.logs.values.contains { $0.hasPrefix("exec claude path=") && $0.hasSuffix("sub=-p") })
        #expect(await rig.status(checklist) == "active", "nothing changes before the apply")

        // Apply: the summary, the originals archived by condense, the long note kept active.
        let result = await f.runner.apply()
        guard case .success(let applied) = result else {
            Issue.record("apply failed: \(result)")
            return
        }
        #expect(applied.title == "摘要 · 10/18 清理（3 則）")
        #expect(applied.summary.rawValue.hasPrefix("cleanup-1018-"))
        let summary = try await rig.library.document(applied.summary)
        #expect(summary.metadata.condensedFrom == [checklist, prompt, daily])
        #expect(summary.body.hasPrefix("# 摘要 · 10/18 清理（3 則）"))
        #expect(summary.body.contains("## 濃縮自") && summary.body.contains("- codd://note/\(checklist.rawValue)"))
        for id in [checklist, prompt] {
            let m = try await rig.library.document(id).metadata
            #expect(m.state.status == "archived")
            if case .archived(_, let by) = m.state { #expect(by == .condense) }
            #expect(m.condensedInto == applied.summary)
            #expect(!(try await rig.library.history(of: id)).isEmpty, "a snapshot of the original is kept")
        }
        #expect(await rig.status(daily) == "active", "a long note is never cut or archived")
        #expect(try await rig.library.document(daily).body == before)
        #expect(applied.kept == [daily])
        let candidates = await rig.library.cleanupCandidates(liveSessions: [])
        #expect(!candidates.contains { $0.id == daily }, "keepUntil +30 d: Cleanup stops suggesting it")
        #expect(CondenseRunner.appliedToast(applied).hasPrefix("✻ 已建立「摘要 · 10/18 清理（3 則）」· 2 則原稿已封存"))

        // UNDO: the originals back, the summary into CODD's TRASH.
        await f.runner.undo(applied)
        #expect(await rig.status(checklist) == "active")
        #expect(await rig.status(prompt) == "active")
        #expect(await rig.status(applied.summary) == "trashed")
        #expect(try await rig.library.document(checklist).metadata.condensedInto == nil)
    }

    @Test func aTimeoutStopsTheRunAndCancelGoesBackToIdle() async throws {
        let f = try await fixture("codd-m4-condense-slow", mode: "sleep")
        defer { f.rig.tearDown() }
        let note = try await f.rig.note("長時間")
        await f.runner.prepare([note], longNotes: [])
        f.runner.timeout = .seconds(1)
        f.runner.generate(account: "follow", model: "sonnet-5.5")
        await f.runner.waitForRun()
        guard case .failed(let reason) = f.runner.phase else {
            Issue.record("expected a failure, got \(f.runner.phase)")
            return
        }
        #expect(reason.contains("秒沒有完成"))
        #expect(f.runner.lastRun?.timedOut == true && f.runner.lastRun?.folderRemoved == true)

        f.runner.timeout = .seconds(60)
        f.runner.generate(account: "follow", model: "sonnet-5.5")
        await m3Eventually("claude started") { FileManager.default.fileExists(atPath: f.out + "/stdin.txt") && !f.rig.store.transientClaudePids.isEmpty }
        let pid = try #require(f.rig.store.transientClaudePids.first)
        f.runner.cancel()
        await f.runner.waitForRun()
        #expect(f.runner.phase == .idle)
        #expect(f.runner.lastRun?.cancelled == true)
        #expect(kill(pid_t(pid), 0) != 0, "the process group is gone")
        #expect(f.rig.store.transientClaudePids.isEmpty)
    }

    @Test func aFailedRunShowsTheReasonAndChangesNothing() async throws {
        let f = try await fixture("codd-m4-condense-fail", mode: "fail")
        defer { f.rig.tearDown() }
        let note = try await f.rig.note("會失敗")
        await f.runner.prepare([note], longNotes: [])
        f.runner.generate(account: "follow", model: "sonnet-5.5")
        await f.runner.waitForRun()
        #expect(f.runner.phase == .failed("claude 結束碼 3：boom: something broke"))
        #expect(await f.rig.status(note) == "active")
        if case .failure = await f.runner.apply() {} else { Issue.record("apply without a preview must refuse") }
    }

    @Test func aTestRootWithoutTheDebugClaudeIsDisabled() async throws {
        let f = try await fixture("codd-m4-condense-off")
        defer { f.rig.tearDown() }
        f.runner.unavailableReason = { CondenseRunner.testRootReason }
        let note = try await f.rig.note("不會跑")
        await f.runner.prepare([note], longNotes: [])
        f.runner.generate(account: "follow", model: "sonnet-5.5")
        await f.runner.waitForRun()
        #expect(f.runner.phase == .failed(CondenseRunner.testRootReason))
        #expect(!FileManager.default.fileExists(atPath: f.out + "/argv.txt"), "nothing was started")
        #expect(CondenseRunner.summaryTitle(now: CleanupRig.start, count: 5, timeZone: CleanupRig.taipei) == "摘要 · 10/18 清理（5 則）")
        #expect(CondenseRunner.idPrefix(now: CleanupRig.start, timeZone: CleanupRig.taipei) == "cleanup-1018")
    }

    @Test func theCondenseRunIsNeverAnExternalSession() async throws {
        let rig = try await CleanupRig("codd-m4-condense-ext")
        defer { rig.tearDown() }
        let entry = ClaudeRegistryEntry(pid: 31_337, sessionId: UUID().uuidString.lowercased(),
                                        cwd: rig.root.runPath + "/condense-" + UUID().uuidString.lowercased())
        #expect(rig.store.isCondenseRun(entry))
        let other = ClaudeRegistryEntry(pid: 31_338, sessionId: UUID().uuidString.lowercased(), cwd: rig.work)
        #expect(!rig.store.isCondenseRun(other))
        rig.store.transientClaudePids = [31_338]
        #expect(rig.store.isCondenseRun(other), "a running condense child's pid")
    }
}
