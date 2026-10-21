import Foundation
import Testing
@testable import CoddCore

/// fb 「claude code 建立 session 不要選擇模型（使用用戶平常自動帶的）」: a claude session gets
/// `--model` only when the request (a model the user picked) or its launch profile names one. The
/// built-in profiles name none, so the default launch passes no `--model` and Claude Code's own
/// `model` setting applies. A model stored on a profile, a built-in included, was set by the user
/// (no CODD version ever seeded one), so loading and saving profiles.json keeps it.
@Suite("fb: no --model unless one is named")
struct FBLaunchModelTests {
    let sessionId = UUID(uuidString: "7C1E9A04-5B2D-4E8F-9A31-0C6D2E4F8B17") ?? UUID()
    let base: [String: String] = ["HOME": "/Users/synthetic", "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
    let login: [String: String] = ["PATH": "/Users/synthetic/.local/bin:/usr/bin:/bin"]

    func builder(hooks: Bool) -> LaunchBuilder {
        LaunchBuilder(
            hooks: hooks ? ClaudeHookSettings(endpoint: HookEndpoint(port: 47821), sessionStartCommand: "/opt/codd/codd-hook") : nil,
            isExecutable: { $0 == "/Users/synthetic/.local/bin/claude" })
    }

    func argv(_ request: LaunchRequest, hooks: Bool = true) throws -> [String] {
        try builder(hooks: hooks).build(request, baseEnvironment: base, loginEnvironment: login, hookToken: "t").argv
    }

    @Test func noBuiltInProfileNamesAModel() {
        #expect(LaunchProfile.builtIn.allSatisfy { $0.defaultModel == nil })
        #expect(LaunchProfileDocument.seeded.profiles.allSatisfy { $0.defaultModel == nil })
        #expect(LaunchProfileDocument.seeded.claudeProfile(id: nil).defaultModel == nil)
    }

    @Test(arguments: ["claude-default", "claude-plan", "claude-rc"])
    func builtInProfilesLaunchWithoutModel(id: String) throws {
        let profile = try #require(LaunchProfile.builtIn.first { $0.id == id })
        for mode in [LaunchRequest.Mode.new, .resume] {
            let request = LaunchRequest(profile: profile, cwd: "/synthetic/project", sessionId: sessionId, mode: mode)
            let args = try argv(request)
            #expect(!args.contains("--model"), "\(id) \(mode): \(args)")
            #expect(!args.contains { $0.hasPrefix("--model=") })
        }
        // The previews say the same (the ⌘N command strip, Settings rows).
        #expect(!LaunchProfileEditing.commandPreview(profile, sessionId: nil, model: nil, permissionMode: nil, name: nil, resumeId: nil,
                                                     remoteControl: false).contains("--model"))
        #expect(!LaunchProfileEditing.profileCommand(profile).contains("--model"))
    }

    @Test func aBlankRequestModelIsNoFlag() throws {
        let profile = LaunchProfileDocument.seeded.claudeProfile(id: nil)
        for blank in ["", "   ", "\t"] {
            let request = LaunchRequest(profile: profile, cwd: "/p", sessionId: sessionId, model: blank)
            #expect(!(try argv(request, hooks: false)).contains("--model"))
        }
    }

    @Test func aPickedModelIsPassed() throws {
        let profile = LaunchProfileDocument.seeded.claudeProfile(id: nil)
        let request = LaunchRequest(profile: profile, cwd: "/p", sessionId: sessionId, model: "sonnet")
        let args = try argv(request, hooks: false)
        let index = try #require(args.firstIndex(of: "--model"))
        #expect(args[index + 1] == "sonnet")
        #expect(args.filter { $0 == "--model" }.count == 1)
    }

    @Test func aProfileThatNamesAModelPassesItAndAPickWins() throws {
        let named = LaunchProfile(id: "opus-work", name: "opus-work", kind: .claude, defaultModel: "opus")
        let plain = try argv(LaunchRequest(profile: named, cwd: "/p", sessionId: sessionId), hooks: false)
        #expect(plain.suffix(2) == ["--model", "opus"])
        let picked = try argv(LaunchRequest(profile: named, cwd: "/p", sessionId: sessionId, model: "haiku"), hooks: false)
        #expect(picked.suffix(2) == ["--model", "haiku"])
        #expect(picked.filter { $0 == "--model" }.count == 1)
    }

    /// No migration strips a model: whatever a profile names (a built-in id included) was set on
    /// purpose, so profiles.json keeps it through load and save, and no backup file appears.
    @Test func aModelSetOnABuiltInIsKeptThroughLoadAndSave() throws {
        let temp = try TempDir("codd-fb-profiles")
        defer { temp.remove() }
        let store = LaunchProfileStore(fileURL: temp.file(LaunchProfileStore.fileName))
        var document = LaunchProfileDocument.seeded
        document.profiles[0].defaultModel = "opus"
        try store.save(document)
        let loaded = try store.load()
        #expect(loaded.profile(id: "claude-default")?.defaultModel == "opus")
        try store.save(loaded)
        #expect(try store.load() == document)
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(names == [LaunchProfileStore.fileName], "no backup or aside file: \(names)")
        let args = try argv(LaunchRequest(profile: loaded.claudeProfile(id: nil), cwd: "/p", sessionId: sessionId), hooks: false)
        #expect(args.suffix(2) == ["--model", "opus"])
    }

    /// A seeded profiles.json (what a fresh data root writes) has no `defaultModel` member at all.
    @Test func aSeededFileHasNoModelMember() throws {
        let temp = try TempDir("codd-fb-seeded")
        defer { temp.remove() }
        let store = LaunchProfileStore(fileURL: temp.file(LaunchProfileStore.fileName))
        try store.save(.seeded)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("defaultModel"))
    }
}
