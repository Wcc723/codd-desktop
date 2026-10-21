import Foundation
import Testing
@testable import CoddCore

@Suite("Hook settings JSON")
struct HookSettingsTests {
    let settings = ClaudeHookSettings(
        endpoint: HookEndpoint(port: 47821),
        sessionStartCommand: "/Users/synthetic/Library/Application Support/CODD/bin/codd-hook")

    func parsed() throws -> JSONValue {
        try #require(JSONValue.parse(Data(try settings.settingsJSON().utf8)))
    }

    @Test func everyEventIsConfigured() throws {
        let hooks = try #require(try parsed()["hooks"]?.objectValue)
        let expected = Set(["SessionStart"] + ClaudeHookSettings.httpEvents.map(\.rawValue))
        #expect(Set(hooks.keys) == expected)
        #expect(hooks.count == 14)
    }

    @Test func sessionStartIsACommandHookWithArgs() throws {
        let group = try #require(try parsed()["hooks"]?["SessionStart"]?.arrayValue?.first)
        #expect(group["matcher"] == nil)
        let handler = try #require(group["hooks"]?.arrayValue?.first)
        #expect(handler["type"] == .string("command"))
        #expect(handler["command"] == .string("/Users/synthetic/Library/Application Support/CODD/bin/codd-hook"))
        #expect(handler["args"] == .array(["session-start", "--url", "http://127.0.0.1:47821/hooks"].map(JSONValue.string)))
        #expect(handler["timeout"] == .number(5))
    }

    @Test(arguments: ClaudeHookSettings.httpEvents)
    func httpHandlers(event: HookEventName) throws {
        let group = try #require(try parsed()["hooks"]?[event.rawValue]?.arrayValue?.first)
        #expect(group["matcher"] == (ClaudeHookSettings.matcherEvents.contains(event) ? .string("*") : nil))
        let handler = try #require(group["hooks"]?.arrayValue?.first)
        #expect(handler["type"] == .string("http"))
        #expect(handler["url"] == .string("http://127.0.0.1:47821/hooks"))
        #expect(handler["headers"] == .object(["X-CODD-Token": .string("$CODD_HOOK_TOKEN"), "X-CODD-Session": .string("$CODD_SESSION_ID")]))
        #expect(handler["allowedEnvVars"] == .array([.string("CODD_HOOK_TOKEN"), .string("CODD_SESSION_ID")]))
        #expect(handler["timeout"] == .number(event == .sessionEnd ? 1 : 2))
        #expect(handler["onFailure"] == nil)
    }

    @Test func jsonIsCompactAndDeterministic() throws {
        let a = try settings.settingsJSON()
        #expect(a == (try settings.settingsJSON()))
        #expect(!a.contains("\n"))
        #expect(a.contains("\"timeout\":2"))
        #expect(a.contains("http://127.0.0.1:47821/hooks")) // slashes not escaped
    }
}

@Suite("Launch builder")
struct LaunchBuilderTests {
    let sessionId = UUID(uuidString: "7C1E9A04-5B2D-4E8F-9A31-0C6D2E4F8B17") ?? UUID()
    let base: [String: String] = [
        "HOME": "/Users/synthetic", "USER": "synthetic", "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin",
        "TMPDIR": "/var/folders/xx/T/", "SSH_AUTH_SOCK": "/private/tmp/launchd/Listeners",
        "DYLD_LIBRARY_PATH": "/Xcode/usr/lib", "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x", "XPC_SERVICE_NAME": "app",
        "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "ANTHROPIC_API_KEY": "sk-synthetic", "LANG": "C",
    ]
    let login: [String: String] = ["PATH": "/Users/synthetic/.local/bin:/opt/homebrew/bin:/usr/bin:/bin", "LANG": "zh_TW.UTF-8"]

    func builder(hooks: Bool = true, executables: Set<String> = ["/Users/synthetic/.local/bin/claude", "/bin/zsh"]) -> LaunchBuilder {
        LaunchBuilder(
            hooks: hooks ? ClaudeHookSettings(endpoint: HookEndpoint(port: 47821), sessionStartCommand: "/opt/codd/codd-hook") : nil,
            isExecutable: { executables.contains($0) })
    }

    func profile(_ id: String) throws -> LaunchProfile {
        try #require(LaunchProfile.builtIn.first { $0.id == id })
    }

    @Test func newClaudeSessionArgv() throws {
        let req = LaunchRequest(profile: try profile("claude-default"), cwd: "/synthetic/project", sessionId: sessionId,
                                name: "修正登入 API 401", model: "opus-5.5", permissionMode: .acceptEdits)
        let spec = try builder().build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "tok-synthetic")
        let settingsIndex = try #require(spec.argv.firstIndex(of: "--settings"))
        #expect(Array(spec.argv[..<settingsIndex]) == [
            "/Users/synthetic/.local/bin/claude",
            "--session-id", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
            "--model", "opus-5.5",
            "--permission-mode", "acceptEdits",
            "-n", "修正登入 API 401",
        ])
        #expect(spec.argv.count == settingsIndex + 2)
        #expect(JSONValue.parse(Data(spec.argv[settingsIndex + 1].utf8))?["hooks"] != nil)
        #expect(spec.cwd == "/synthetic/project")
        // The token travels in the environment, never in argv.
        #expect(!spec.argv.joined(separator: " ").contains("tok-synthetic"))
        #expect(spec.environment["CODD_HOOK_TOKEN"] == "tok-synthetic")
        #expect(spec.environment["CODD_SESSION_ID"] == "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")
    }

    @Test func resumeUsesResumeFlag() throws {
        let req = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sessionId, mode: .resume)
        let spec = try builder(hooks: false).build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(spec.argv == ["/Users/synthetic/.local/bin/claude", "--resume", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"])
    }

    /// After /clear or /branch the Claude conversation id differs from the CODD session id; a
    /// reboot-resume must reopen the CURRENT conversation, while CODD_SESSION_ID stays the CODD id.
    @Test func resumeUsesTheCurrentClaudeSessionId() throws {
        let current = "9d2f0b15-6c3e-4f9a-8b42-1d7e3f5a9c28"
        let req = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sessionId, mode: .resume,
                                resumeClaudeSessionId: current)
        let spec = try builder(hooks: false).build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(spec.argv == ["/Users/synthetic/.local/bin/claude", "--resume", current])
        #expect(spec.environment["CODD_SESSION_ID"] == "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")
        // A new session ignores the resume id.
        var fresh = req
        fresh.mode = .new
        let n = try builder(hooks: false).build(fresh, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(n.argv.suffix(2) == ["--session-id", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"])
    }

    @Test(arguments: ["--settings", "-x", "a b", "a/b", String(repeating: "a", count: 129)])
    func invalidResumeIdsAreRejected(id: String) throws {
        let req = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sessionId, mode: .resume,
                                resumeClaudeSessionId: id)
        #expect(throws: LaunchBuildError.invalidValue(flag: "--resume", value: id)) {
            try builder(hooks: false).build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        }
    }

    @Test func profileDefaultsAndOverrides() throws {
        let plan = LaunchRequest(profile: try profile("claude-plan"), cwd: "/p", sessionId: sessionId)
        let a = try builder(hooks: false).build(plan, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(a.argv.suffix(2) == ["--permission-mode", "plan"])
        var overridden = plan
        overridden.permissionMode = .default
        let b = try builder(hooks: false).build(overridden, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        // `default` is not a valid choice in Claude Code 2.1.300: it means "no flag".
        #expect(!b.argv.contains("--permission-mode"))
        #expect(!b.argv.contains("default"))
        overridden.permissionMode = .manual
        let m = try builder(hooks: false).build(overridden, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(m.argv.suffix(2) == ["--permission-mode", "manual"])
        let rc = LaunchRequest(profile: try profile("claude-rc"), cwd: "/p", sessionId: sessionId, name: "x")
        let c = try builder().build(rc, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(c.argv.last == "--remote-control")
    }

    @Test func reservedFlagsInProfilesAreRejected() throws {
        for bad in ["--session-id", "--resume", "-c", "--settings={}", "--model=opus", "-n", "--fork-session"] {
            let p = LaunchProfile(id: "x", name: "x", kind: .claude, extraArguments: [bad])
            let req = LaunchRequest(profile: p, cwd: "/p", sessionId: sessionId)
            #expect(throws: LaunchBuildError.reservedArgument(bad)) {
                try builder().build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
            }
        }
    }

    @Test func valuesThatLookLikeFlagsAreRejected() throws {
        let p = try profile("claude-default")
        #expect(throws: LaunchBuildError.invalidValue(flag: "--model", value: "--dangerous")) {
            try builder().build(LaunchRequest(profile: p, cwd: "/p", sessionId: sessionId, model: "--dangerous"),
                                baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        }
        #expect(throws: LaunchBuildError.invalidValue(flag: "--permission-mode", value: "plan mode")) {
            try builder().build(LaunchRequest(profile: p, cwd: "/p", sessionId: sessionId, permissionMode: PermissionMode(rawValue: "plan mode")),
                                baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        }
    }

    @Test func namesAreCleanedAndDashSafe() throws {
        let p = try profile("claude-default")
        let dash = try builder(hooks: false).build(LaunchRequest(profile: p, cwd: "/p", sessionId: sessionId, name: "-rf\u{7}  name\n"),
                                                   baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(dash.argv.last == "--name=-rf name")
        let blank = try builder(hooks: false).build(LaunchRequest(profile: p, cwd: "/p", sessionId: sessionId, name: "  \t"),
                                                    baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(!blank.argv.contains("-n"))
    }

    @Test func claudeResolution() throws {
        let p = try profile("claude-default")
        let req = LaunchRequest(profile: p, cwd: "/p", sessionId: sessionId)
        let viaPath = try builder(hooks: false, executables: ["/opt/homebrew/bin/claude", "/Users/synthetic/.local/bin/claude"])
            .build(req, baseEnvironment: base, loginEnvironment: ["PATH": "/opt/homebrew/bin:/Users/synthetic/.local/bin"], hookToken: "t")
        #expect(viaPath.argv.first == "/opt/homebrew/bin/claude")
        let fallback = try builder(hooks: false, executables: ["/Users/synthetic/.local/bin/claude"])
            .build(req, baseEnvironment: base, loginEnvironment: ["PATH": "/usr/bin"], hookToken: "t")
        #expect(fallback.argv.first == "/Users/synthetic/.local/bin/claude")
        #expect(throws: LaunchBuildError.executableNotFound("claude")) {
            try builder(executables: []).build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        }
    }

    @Test func shellProfile() throws {
        let req = LaunchRequest(profile: try profile("zsh"), cwd: "/synthetic/project", sessionId: sessionId, name: "ignored")
        let spec = try builder().build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "tok")
        #expect(spec.argv == ["/bin/zsh", "-l"])
        #expect(spec.environment["CODD_HOOK_TOKEN"] == nil)
        #expect(spec.environment["CODD_SESSION_ID"] == "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")
        let bad = LaunchProfile(id: "s", name: "s", kind: .shell, shellPath: "zsh")
        #expect(throws: LaunchBuildError.invalidShell("zsh")) {
            try builder().build(LaunchRequest(profile: bad, cwd: "/p", sessionId: sessionId), baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        }
    }

    @Test func relativeCwdIsRejected() throws {
        #expect(throws: LaunchBuildError.relativeCwd("project")) {
            try builder().build(LaunchRequest(profile: try profile("zsh"), cwd: "project", sessionId: sessionId),
                                baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        }
    }

    @Test func environmentFileRoundTrip() throws {
        let req = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sessionId)
        let spec = try builder().build(req, baseEnvironment: base, loginEnvironment: login, hookToken: "tok")
        let data = try spec.environmentFile()
        #expect(data.last == 0)
        #expect(EnvironmentFile.decode(data) == spec.environment)
    }
}

@Suite("Spawn environment")
struct SpawnEnvironmentTests {
    let sid = UUID(uuidString: "7C1E9A04-5B2D-4E8F-9A31-0C6D2E4F8B17") ?? UUID()
    let base: [String: String] = [
        "HOME": "/Users/synthetic", "USER": "synthetic", "LOGNAME": "synthetic", "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/var/folders/xx/T/", "SSH_AUTH_SOCK": "/tmp/agent",
        "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0", "DYLD_FRAMEWORK_PATH": "/Xcode", "DYLD_LIBRARY_PATH": "/Xcode/lib",
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/b", "__XPC_DYLD_LIBRARY_PATH": "/b", "OS_ACTIVITY_DT_MODE": "YES",
        "XPC_SERVICE_NAME": "application.x", "XPC_FLAGS": "0x0", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
        "CLAUDE_CONFIG_DIR": "/should/not/leak", "TERM_PROGRAM": "Apple_Terminal", "TERM": "dumb", "LANG": "C", "PWD": "/",
    ]

    @Test func cleanAllowListOnly() {
        let env = SpawnEnvironmentBuilder().build(base: base, login: ["PATH": "/login/bin"], sessionId: sid, hookToken: nil)
        #expect(Set(env.keys) == [
            "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
            "LANG", "LC_CTYPE", "TERM", "COLORTERM", "CODD_SESSION_ID",
        ])
        #expect(env["PATH"] == "/login/bin")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == nil) // undecided until the M0 spike
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["LC_CTYPE"] == "en_US.UTF-8")
        #expect(env["CODD_SESSION_ID"] == "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")
    }

    @Test func localePreference() {
        let b = SpawnEnvironmentBuilder()
        #expect(b.build(base: base, login: ["LANG": "zh_TW.UTF-8"], sessionId: sid, hookToken: nil)["LANG"] == "zh_TW.UTF-8")
        #expect(b.build(base: base, login: ["LANG": "C", "LC_ALL": "en_GB.utf8"], sessionId: sid, hookToken: nil)["LANG"] == "en_GB.utf8")
        var utf8Base = base
        utf8Base["LANG"] = "ja_JP.UTF-8"
        #expect(b.build(base: utf8Base, login: nil, sessionId: sid, hookToken: nil)["LANG"] == "ja_JP.UTF-8")
        let ctype = b.build(base: base, login: ["LANG": "zh_TW.UTF-8", "LC_CTYPE": "UTF-8"], sessionId: sid, hookToken: nil)
        #expect(ctype["LC_CTYPE"] == "zh_TW.UTF-8") // bare "UTF-8" is not a locale name
    }

    @Test func fallbackPathWhenCaptureFailed() {
        let env = SpawnEnvironmentBuilder().build(base: base, login: nil, sessionId: sid, hookToken: nil)
        #expect(env["PATH"] == "/Users/synthetic/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func termProgramWhenConfigured() {
        let env = SpawnEnvironmentBuilder(termProgram: "CODD", termProgramVersion: "0.1.0")
            .build(base: base, login: nil, sessionId: sid, hookToken: nil)
        #expect(env["TERM_PROGRAM"] == "CODD")
        #expect(env["TERM_PROGRAM_VERSION"] == "0.1.0")
    }

    @Test func overridesAreSanitized() {
        let env = SpawnEnvironmentBuilder().build(base: base, login: nil, sessionId: sid, hookToken: "tok", overrides: [
            "CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-swap-backup/sessions/2-x", "PATH": "/evil",
            "DYLD_INSERT_LIBRARIES": "/evil.dylib", "LD_PRELOAD": "/evil.so", "NODE_OPTIONS": "--require /evil",
            "CODD_SESSION_ID": "spoof", "TERM": "vt100", "BAD-NAME": "x", "NUL": "a\0b", "FOO": "bar",
        ])
        #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/synthetic/.claude-swap-backup/sessions/2-x")
        #expect(env["FOO"] == "bar")
        #expect(env["PATH"] != "/evil")
        for k in ["DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "NODE_OPTIONS", "BAD-NAME", "NUL"] { #expect(env[k] == nil) }
        #expect(env["CODD_SESSION_ID"] == "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["CODD_HOOK_TOKEN"] == "tok")
    }

    @Test func missingHomeAndShell() {
        let env = SpawnEnvironmentBuilder().build(base: [:], login: nil, sessionId: sid, hookToken: nil)
        #expect(env["SHELL"] == "/bin/zsh")
        #expect(env["HOME"]?.isEmpty == false)
    }

    @Test func environmentFileFormat() throws {
        let data = try EnvironmentFile.encode(["B": "2", "A": "x=y", "EMPTY": ""])
        #expect(data == Data("A=x=y\0B=2\0EMPTY=\0".utf8))
        #expect(EnvironmentFile.decode(data) == ["A": "x=y", "B": "2", "EMPTY": ""])
        #expect(EnvironmentFile.decode(Data("A=1\0\0=bad\0B=2".utf8)) == ["A": "1", "B": "2"])
        #expect(throws: EnvironmentFile.EncodeError.invalidName("1X")) { try EnvironmentFile.encode(["1X": "a"]) }
        #expect(throws: EnvironmentFile.EncodeError.nulInValue("A")) { try EnvironmentFile.encode(["A": "a\0"]) }
    }
}

@Suite("Login shell environment capture")
struct LoginShellCaptureTests {
    @Test func parsesBetweenMarkersIgnoringRcNoise() throws {
        var out = Data("Welcome to zsh!\nlast login…".utf8)
        out += Data("__CODD_ENV_BEGIN__\0PATH=/a:/b\0MULTI=line1\nline2\0EQ=a=b\0junk-without-eq\0__CODD_ENV_END__\0trailing".utf8)
        let env = try #require(LoginShellEnvironmentCapture.parse(out))
        #expect(env == ["PATH": "/a:/b", "MULTI": "line1\nline2", "EQ": "a=b"])
        #expect(LoginShellEnvironmentCapture.parse(Data("no markers".utf8)) == nil)
        #expect(LoginShellEnvironmentCapture.parse(Data("__CODD_ENV_BEGIN__\0A=1\0".utf8)) == nil)
    }

    @Test func usesRunnerWithFlagsAndTimeout() async throws {
        let runner = FakeRunner(stdout: Data("__CODD_ENV_BEGIN__\0PATH=/x\0__CODD_ENV_END__\0".utf8))
        let capture = LoginShellEnvironmentCapture(shell: "/bin/zsh", runner: runner, environment: ["HOME": "/h"])
        #expect(try await capture.captureEnvironment() == ["PATH": "/x"])
        let inv = try #require(runner.invocations.first)
        #expect(inv.executable == "/bin/zsh")
        #expect(inv.arguments == ["-l", "-i", "-c", LoginShellEnvironmentCapture.script])
        #expect(inv.timeout == .seconds(5))
        #expect(inv.environment == ["HOME": "/h"])
    }

    @Test func failuresAreReported() async throws {
        let failing = LoginShellEnvironmentCapture(shell: "/bin/zsh", runner: FakeRunner(stdout: Data(), status: 1), environment: [:])
        await #expect(throws: LoginShellCaptureError.shellFailed(status: 1)) { try await failing.captureEnvironment() }
        let silent = LoginShellEnvironmentCapture(shell: "/bin/zsh", runner: FakeRunner(stdout: Data("hi".utf8)), environment: [:])
        await #expect(throws: LoginShellCaptureError.markersMissing) { try await silent.captureEnvironment() }
    }

    /// Real shell, without rc files (`zsh -f`).
    @Test func realZshWithoutRcFiles() async throws {
        let capture = LoginShellEnvironmentCapture(
            shell: "/bin/zsh", flags: ["-f", "-c"], timeout: .seconds(10),
            environment: ["PATH": "/usr/bin:/bin", "CODD_PROBE": "注音 ok", "HOME": NSTemporaryDirectory()])
        let env = try await capture.captureEnvironment()
        #expect(env["CODD_PROBE"] == "注音 ok")
        #expect(env["PATH"] == "/usr/bin:/bin")
    }

    /// Real interactive login shell, still without rc files (`zsh -f -l -i -c`). The runner starts it
    /// in a new session, so it cannot be stopped by job control even when the test process has a
    /// controlling terminal (verified manually under `script(1)`; a pty-less CI run cannot show it).
    @Test(.timeLimit(.minutes(1)))
    func realInteractiveLoginZshWithoutRcFiles() async throws {
        let capture = LoginShellEnvironmentCapture(
            shell: "/bin/zsh", flags: ["-f", "-l", "-i", "-c"], timeout: .seconds(10),
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb", "HOME": NSTemporaryDirectory()])
        let env = try await capture.captureEnvironment()
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["TERM"] == "dumb")
    }

    @Test func standardCaptureUsesUserShellAndMinimalEnv() {
        let c = LoginShellEnvironmentCapture.standard(base: ["SHELL": "/opt/homebrew/bin/fish", "HOME": "/h", "SECRET": "x"])
        #expect(c.shell == "/opt/homebrew/bin/fish")
        #expect(c.environment["SECRET"] == nil)
        #expect(c.environment["HOME"] == "/h")
        #expect(LoginShellEnvironmentCapture.standard(base: ["SHELL": "zsh"]).shell == "/bin/zsh")
    }

    @Test func cacheCapturesOnce() async throws {
        let runner = FakeRunner { _ in
            try await Task.sleep(for: .milliseconds(50))
            return CommandResult(status: 0, stdout: Data("__CODD_ENV_BEGIN__\0PATH=/x\0__CODD_ENV_END__\0".utf8))
        }
        let cache = LoginEnvironmentCache(provider: LoginShellEnvironmentCapture(shell: "/bin/zsh", runner: runner, environment: [:]))
        async let a = cache.environment()
        async let b = cache.environment()
        let (x, y) = await (a, b)
        #expect(x == ["PATH": "/x"])
        #expect(y == ["PATH": "/x"])
        #expect(await cache.environment() == ["PATH": "/x"])
        #expect(runner.invocations.count == 1)
    }

    @Test func cacheRemembersFailure() async throws {
        let runner = FakeRunner(stdout: Data(), status: 1)
        let cache = LoginEnvironmentCache(provider: LoginShellEnvironmentCapture(shell: "/bin/zsh", runner: runner, environment: [:]))
        #expect(await cache.environment() == nil)
        #expect(await cache.environment() == nil)
        #expect(runner.invocations.count == 1)
    }
}
