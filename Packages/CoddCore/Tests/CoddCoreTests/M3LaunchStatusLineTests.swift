import Foundation
import Testing
@testable import CoddCore

/// The exact `--settings` JSON of M2 for this configuration (no status line): an M3 build without a
/// ``StatusLineInjection`` must produce these bytes.
private let m2SettingsJSON = #"{"hooks":{"Notification":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}],"matcher":"*"}],"PermissionRequest":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}],"matcher":"*"}],"PostCompact":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"PostToolUse":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}],"matcher":"*"}],"PostToolUseFailure":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}],"matcher":"*"}],"PreCompact":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"PreToolUse":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}],"matcher":"*"}],"SessionEnd":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":1,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"SessionStart":[{"hooks":[{"args":["session-start","--url","http://127.0.0.1:47821/hooks"],"command":"/opt/codd/codd-hook","timeout":5,"type":"command"}]}],"Stop":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"StopFailure":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"SubagentStart":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"SubagentStop":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}],"UserPromptSubmit":[{"hooks":[{"allowedEnvVars":["CODD_HOOK_TOKEN","CODD_SESSION_ID"],"headers":{"X-CODD-Session":"$CODD_SESSION_ID","X-CODD-Token":"$CODD_HOOK_TOKEN"},"timeout":2,"type":"http","url":"http://127.0.0.1:47821/hooks"}]}]}}"#

private let sid = UUID(uuidString: "7C1E9A04-5B2D-4E8F-9A31-0C6D2E4F8B17") ?? UUID()
private let base: [String: String] = [
    "HOME": "/Users/synthetic", "USER": "synthetic", "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin",
    "ANTHROPIC_API_KEY": "sk-synthetic", "CLAUDE_CODE_OAUTH_TOKEN": "t", "LANG": "C",
]
private let login: [String: String] = ["PATH": "/Users/synthetic/.local/bin:/usr/bin:/bin", "LANG": "zh_TW.UTF-8"]
private let profilePath = "/Users/synthetic/.claude-swap-backup/sessions/2-north-example-com"

private func hooks(_ statusLine: StatusLineInjection? = nil) -> ClaudeHookSettings {
    ClaudeHookSettings(endpoint: HookEndpoint(port: 47821), sessionStartCommand: "/opt/codd/codd-hook", statusLine: statusLine)
}

private func builder(_ statusLine: StatusLineInjection? = nil, withHooks: Bool = true) -> LaunchBuilder {
    LaunchBuilder(hooks: withHooks ? hooks(statusLine) : nil,
                  isExecutable: { ["/Users/synthetic/.local/bin/claude", "/bin/zsh"].contains($0) })
}

private func profile(_ id: String) throws -> LaunchProfile {
    try #require(LaunchProfile.builtIn.first { $0.id == id })
}

private func decodeBase64(_ s: String?) -> String? {
    s.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
}

@Suite("Hook settings with statusLine (M3)")
struct StatusLineSettingsTests {
    @Test func withoutAStatusLineTheJSONIsM2s() throws {
        #expect(try hooks().settingsJSON() == m2SettingsJSON)
        #expect(hooks().settingsObject.objectValue?.keys.sorted() == ["hooks"])
        #expect(hooks().statusLine == nil)
    }

    @Test func statusLineObjectIsMergedWithExtras() throws {
        let injection = StatusLineInjection(
            command: "/Users/synthetic/Library/Application Support/CODD/bin/codd-statusline-0123456789ab",
            extras: ["padding": .number(2), "refreshInterval": .number(5), "hideVimModeIndicator": .bool(true)],
            chainCommand: "~/.hook-tap/statusline.sh")
        let json = try hooks(injection).settingsJSON()
        let parsed = try #require(JSONValue.parse(Data(json.utf8)))
        #expect(parsed.objectValue?.keys.sorted() == ["hooks", "statusLine"])
        // Single-quoted: Claude runs the status line through `/bin/sh -c`, and this root has a space.
        #expect(parsed["statusLine"] == .object([
            "type": .string("command"),
            "command": .string("'/Users/synthetic/Library/Application Support/CODD/bin/codd-statusline-0123456789ab'"),
            "padding": .number(2), "refreshInterval": .number(5), "hideVimModeIndicator": .bool(true),
        ]))
        // Sorted keys and compact; the hooks part is unchanged; the chain never appears in argv.
        #expect(json.hasSuffix(#""statusLine":{"command":"'/Users/synthetic/Library/Application Support/CODD/bin/codd-statusline-0123456789ab'","hideVimModeIndicator":true,"padding":2,"refreshInterval":5,"type":"command"}}"#))
        #expect(json.hasPrefix(String(m2SettingsJSON.dropLast())))
        #expect(!json.contains("hook-tap"))
        #expect(parsed["hooks"] == JSONValue.parse(Data(m2SettingsJSON.utf8))?["hooks"])
    }

    @Test func extrasCannotOverrideTypeOrCommand() throws {
        let injection = StatusLineInjection(command: "/opt/codd/codd-statusline",
                                            extras: ["type": .string("static"), "command": .string("/evil"), "padding": .number(0)])
        let statusLine = try #require(JSONValue.parse(Data(try hooks(injection).settingsJSON().utf8))?["statusLine"])
        #expect(statusLine == .object(["type": .string("command"), "command": .string("'/opt/codd/codd-statusline'"), "padding": .number(0)]))
        #expect(injection.settingsValue == statusLine)
    }

    @Test func quotingRoundTripsAndEscapesSingleQuotes() {
        #expect(ShellQuoting.single("/a b/c") == "'/a b/c'")
        #expect(ShellQuoting.single("/x'y/$(z)") == #"'/x'\''y/$(z)'"#)
        for path in ["/a b/c", "/x'y/$(z);`w`", "", "''"] {
            #expect(ShellQuoting.unquoteSingle(ShellQuoting.single(path)) == path)
        }
        #expect(ShellQuoting.unquoteSingle("/plain/path") == "/plain/path")
        #expect(ShellQuoting.unquoteSingle("'a'b'") == "'a'b'", "not one quoted word")
    }

    /// Regression (M3 review): an unquoted path split at the space of `Application Support`, so
    /// every CODD session's status line exited 127. Runs the generated command the way Claude does.
    @Test func generatedCommandRunsThroughShFromARootWithASpaceAndAQuote() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codd sl'q \(UUID().uuidString.prefix(6)) $(x)")
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let script = bin.appendingPathComponent("codd-statusline-0123456789ab")
        try Data("#!/bin/sh\nread line; printf 'RAN:%s' \"$line\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let injection = StatusLineInjection(command: script.path)
        let command = try #require(injection.settingsValue["command"]?.stringValue)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = base
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("{}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(printed == "RAN:{}")
    }

    @Test func environmentNames() {
        #expect(CoddEnvironmentName.hookURL == "CODD_HOOK_URL")
        #expect(CoddEnvironmentName.statusLineChain == "CODD_STATUSLINE_CHAIN")
        #expect(LaunchBuilder.authOverrideNames == [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
        ])
        #expect(LaunchBuilder.maxEncodedChainBytes == 16_384)
    }
}

@Suite("Launch builder M3 environment")
struct LaunchStatusLineEnvironmentTests {
    @Test func chainTravelsBase64InTheEnvironment() throws {
        let chain = "printf 'SL-%s' \"$(cat | head -c 3)\"; echo 工作 | tr -d '\\n'"
        let spec = try builder(StatusLineInjection(command: "/opt/codd/codd-statusline", chainCommand: chain))
            .build(LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sid), baseEnvironment: base,
                   loginEnvironment: login, hookToken: "tok")
        let encoded = try #require(spec.environment["CODD_STATUSLINE_CHAIN"])
        #expect(decodeBase64(encoded) == chain)
        #expect(spec.coddEnvironment == ["CODD_STATUSLINE_CHAIN": encoded])
        #expect(spec.removedNames.isEmpty)
        #expect(!spec.argv.joined(separator: " ").contains(encoded))
        #expect(!spec.argv.joined(separator: " ").contains("SL-"))
        // CODD_HOOK_URL comes from the app's holder launcher, not from the builder.
        #expect(spec.environment["CODD_HOOK_URL"] == nil)
        let settings = try #require(spec.argv.firstIndex(of: "--settings"))
        #expect(JSONValue.parse(Data(spec.argv[settings + 1].utf8))?["statusLine"]?["command"] == .string("'/opt/codd/codd-statusline'"))
    }

    @Test func chainCapIs16KiBEncoded() throws {
        // 12 288 bytes encode to exactly 16 384; one more byte is over the cap.
        let atCap = String(repeating: "a", count: 12_288)
        let over = String(repeating: "a", count: 12_289)
        #expect(LaunchBuilder.encodedChain(atCap)?.utf8.count == 16_384)
        #expect(LaunchBuilder.encodedChain(over) == nil)
        let request = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sid)
        let ok = try builder(StatusLineInjection(command: "/x", chainCommand: atCap))
            .build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(decodeBase64(ok.coddEnvironment["CODD_STATUSLINE_CHAIN"]) == atCap)
        let tooBig = try builder(StatusLineInjection(command: "/x", chainCommand: over))
            .build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(tooBig.environment["CODD_STATUSLINE_CHAIN"] == nil)
        #expect(tooBig.coddEnvironment.isEmpty)
        // The statusLine itself is still injected (CODD's CLI runs, it just chains nothing).
        #expect(tooBig.argv.contains { $0.contains("\"statusLine\"") })
    }

    @Test func blankOrMissingChainsAreNotSet() throws {
        let request = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sid)
        for injection in [StatusLineInjection(command: "/x"), StatusLineInjection(command: "/x", chainCommand: "  \n")] {
            let spec = try builder(injection).build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
            #expect(spec.environment["CODD_STATUSLINE_CHAIN"] == nil)
            #expect(spec.coddEnvironment.isEmpty)
        }
        let noHooks = try builder(withHooks: false).build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(noHooks.coddEnvironment.isEmpty && noHooks.removedNames.isEmpty)
    }

    @Test func shellsAreUnaffected() throws {
        let request = LaunchRequest(profile: try profile("zsh"), cwd: "/p", sessionId: sid, claudeConfigDir: profilePath)
        let spec = try builder(StatusLineInjection(command: "/x", chainCommand: "echo hi"))
            .build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(spec.argv == ["/bin/zsh", "-l"])
        #expect(spec.coddEnvironment.isEmpty)
        #expect(spec.removedNames.isEmpty)
        #expect(spec.environment["CODD_STATUSLINE_CHAIN"] == nil)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == nil)
        // A relative pin on a shell is ignored too, not an error.
        var relative = request
        relative.claudeConfigDir = "relative/dir"
        #expect(try builder().build(relative, baseEnvironment: base, loginEnvironment: login, hookToken: "t").coddEnvironment.isEmpty)
    }

    @Test func claudeConfigDirWinsOverTheProfileAndScrubsAuthOverrides() throws {
        let pinnedProfile = LaunchProfile(id: "p", name: "p", kind: .claude, environment: [
            "CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-swap-backup/sessions/3-other",
            "ANTHROPIC_API_KEY": "sk-from-profile", "ANTHROPIC_AUTH_TOKEN": "x", "CLAUDE_CODE_OAUTH_TOKEN": "y",
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR": "3", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR": "4", "KEEP": "1",
        ])
        let request = LaunchRequest(profile: pinnedProfile, cwd: "/p", sessionId: sid, claudeConfigDir: profilePath)
        let spec = try builder().build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == profilePath)
        #expect(spec.coddEnvironment == ["CLAUDE_CONFIG_DIR": profilePath])
        #expect(spec.removedNames == LaunchBuilder.authOverrideNames)
        for name in LaunchBuilder.authOverrideNames { #expect(spec.environment[name] == nil, "\(name)") }
        #expect(spec.environment["KEEP"] == "1")
        #expect(spec.environment["CODD_HOOK_TOKEN"] == "t")
        // The pin never reaches argv.
        #expect(!spec.argv.joined(separator: " ").contains("2-north"))
    }

    @Test func withoutAPinTheProfileEnvironmentIsKept() throws {
        let pinnedProfile = LaunchProfile(id: "p", name: "p", kind: .claude, environment: [
            "CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-swap-backup/sessions/3-other", "ANTHROPIC_API_KEY": "sk-from-profile",
        ])
        let spec = try builder().build(LaunchRequest(profile: pinnedProfile, cwd: "/p", sessionId: sid),
                                       baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == "/Users/synthetic/.claude-swap-backup/sessions/3-other")
        #expect(spec.environment["ANTHROPIC_API_KEY"] == "sk-from-profile")
        #expect(spec.coddEnvironment.isEmpty)
        #expect(spec.removedNames.isEmpty)
    }

    @Test func aRelativeOrBrokenPinIsRejected() throws {
        for bad in ["sessions/2-x", "", "~/x", "/a\u{0}b"] {
            let request = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sid, claudeConfigDir: bad)
            #expect(throws: LaunchBuildError.invalidValue(flag: "CLAUDE_CONFIG_DIR", value: bad)) {
                try builder().build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
            }
        }
    }

    @Test func chainAndPinTogether() throws {
        let request = LaunchRequest(profile: try profile("claude-default"), cwd: "/p", sessionId: sid, mode: .resume,
                                    resumeClaudeSessionId: "9d2f0b15-6c3e-4f9a-8b42-1d7e3f5a9c28", claudeConfigDir: profilePath)
        let spec = try builder(StatusLineInjection(command: "/x", chainCommand: "echo ok"))
            .build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(Set(spec.coddEnvironment.keys) == ["CODD_STATUSLINE_CHAIN", "CLAUDE_CONFIG_DIR"])
        #expect(decodeBase64(spec.coddEnvironment["CODD_STATUSLINE_CHAIN"]) == "echo ok")
        for (k, v) in spec.coddEnvironment { #expect(spec.environment[k] == v) }
        #expect(Array(spec.argv.prefix(3)) == ["/Users/synthetic/.local/bin/claude", "--resume", "9d2f0b15-6c3e-4f9a-8b42-1d7e3f5a9c28"])
        // The env file round-trips the new variables.
        #expect(EnvironmentFile.decode(try spec.environmentFile()) == spec.environment)
    }

    /// `CODD_` stays reserved: a launch profile cannot inject its own chain.
    @Test func profilesCannotSetCoddVariables() throws {
        let sneaky = LaunchProfile(id: "s", name: "s", kind: .claude, environment: [
            "CODD_STATUSLINE_CHAIN": Data("rm -rf ~".utf8).base64EncodedString(), "CODD_HOOK_URL": "http://evil",
        ])
        let request = LaunchRequest(profile: sneaky, cwd: "/p", sessionId: sid)
        let plain = try builder().build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(plain.environment["CODD_STATUSLINE_CHAIN"] == nil)
        #expect(plain.environment["CODD_HOOK_URL"] == nil)
        let chained = try builder(StatusLineInjection(command: "/x", chainCommand: "echo ok"))
            .build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t")
        #expect(decodeBase64(chained.environment["CODD_STATUSLINE_CHAIN"]) == "echo ok")
    }

    @Test func m2ArgvIsUnchangedWithoutTheNewOptions() throws {
        let request = LaunchRequest(profile: try profile("claude-default"), cwd: "/synthetic/project", sessionId: sid,
                                    name: "修正登入 API 401", model: "opus-5.5", permissionMode: .acceptEdits)
        let spec = try builder().build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "tok")
        #expect(spec.argv == [
            "/Users/synthetic/.local/bin/claude", "--session-id", "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
            "--model", "opus-5.5", "--permission-mode", "acceptEdits", "-n", "修正登入 API 401", "--settings", m2SettingsJSON,
        ])
        #expect(spec.coddEnvironment.isEmpty)
        #expect(spec.removedNames.isEmpty)
        #expect(spec == LaunchSpec(argv: spec.argv, environment: spec.environment, cwd: spec.cwd))
    }
}
