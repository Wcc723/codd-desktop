import Darwin
import Foundation
import Testing
@testable import CoddCore

@Suite("Launch profile store")
struct LaunchProfileStoreTests {
    func withStore<T>(_ body: (LaunchProfileStore, TempDir) throws -> T) throws -> T {
        let temp = try TempDir("codd-profiles")
        defer { temp.remove() }
        return try body(LaunchProfileStore(fileURL: temp.file("profiles.json")), temp)
    }

    func write(_ text: String, _ store: LaunchProfileStore) throws {
        try Data(text.utf8).write(to: store.fileURL)
    }

    @Test func builtInNamesAreTheArtboardNames() {
        #expect(LaunchProfile.builtIn.map(\.id) == ["claude-default", "claude-plan", "claude-rc", "zsh"])
        #expect(LaunchProfile.builtIn.map(\.name) == ["claude-default", "claude-plan", "claude-rc", "zsh"])
        #expect(LaunchProfile.builtIn.map(\.kind) == [.claude, .claude, .claude, .shell])
        #expect(LaunchProfile.builtIn[1].defaultPermissionMode == .plan)
        #expect(LaunchProfile.builtIn[2].extraArguments == ["--remote-control"])
    }

    @Test func missingFileIsSeededAndNotWritten() throws {
        try withStore { store, _ in
            let doc = try store.load()
            #expect(doc == .seeded)
            #expect(doc.defaultProfileId == "claude-default")
            #expect(doc.profiles == LaunchProfile.builtIn)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    @Test func roundTripWithPermissionsAndFormat() throws {
        try withStore { store, _ in
            var doc = LaunchProfileDocument.seeded
            doc.profiles.append(LaunchProfile(
                id: "acct-2", name: "帳號 #2", kind: .claude, defaultModel: "opus", defaultPermissionMode: .acceptEdits,
                extraArguments: ["--verbose", "--append-system-prompt=be brief"],
                environment: ["CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-2"]))
            doc.profiles.append(LaunchProfile(id: "bash", name: "bash", kind: .shell, shellPath: "/bin/bash"))
            doc.defaultProfileId = "acct-2"
            try store.save(doc)
            #expect(try store.load() == doc)

            var info = stat()
            #expect(stat(store.fileURL.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)

            let text = try String(contentsOf: store.fileURL, encoding: .utf8)
            #expect(text.contains("\n  \"defaultProfileId\""))            // pretty printed
            #expect(!text.contains("\\/"))                               // slashes not escaped
            let json = try #require(JSONValue.parse(Data(text.utf8))?.objectValue)
            #expect(json["version"] == 1)
            #expect(json["defaultProfileId"] == "acct-2")
            // Sorted keys: defaultProfileId, profiles, version.
            let positions = ["defaultProfileId", "profiles", "version"].compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
            #expect(positions.count == 3 && positions == positions.sorted())
            let stored = try #require(json["profiles"]?.arrayValue?.last?.objectValue)
            #expect(stored["shellPath"] == "/bin/bash")
            #expect(stored["defaultModel"] == nil) // nil optionals are omitted
            let acct = try #require(json["profiles"]?.arrayValue?[4].objectValue)
            #expect(acct["defaultPermissionMode"] == "acceptEdits")
            #expect(acct["environment"] == ["CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-2"])
        }
    }

    @Test func tolerantDecodingSkipsBadEntries() throws {
        try withStore { store, _ in
            try write("""
            {"version": 1, "defaultProfileId": "claude-plan", "profiles": [
              {"id": "claude-default", "name": "claude-default", "kind": "claude", "extraArguments": [], "environment": {}},
              {"id": "weird", "name": "weird", "kind": "fish"},
              {"id": "bad-args", "name": "bad", "kind": "claude", "extraArguments": "--remote-control"},
              {"id": "", "name": "blank", "kind": "claude"},
              42,
              {"id": "claude-plan", "kind": "claude", "defaultPermissionMode": "plan", "futureKey": true},
              {"id": "claude-default", "name": "duplicate", "kind": "claude"},
              {"id": "zsh", "name": "zsh", "kind": "shell", "shellPath": null, "defaultModel": "  "}
            ]}
            """, store)
            let doc = try store.load()
            #expect(doc.profiles.map(\.id) == ["claude-default", "claude-plan", "zsh"])
            #expect(doc.profiles[0].name == "claude-default")
            #expect(doc.profiles[1].name == "claude-plan")       // missing name → id
            #expect(doc.profiles[1].defaultPermissionMode == .plan)
            #expect(doc.profiles[2].defaultModel == nil)
            #expect(doc.defaultProfileId == "claude-plan")
        }
    }

    @Test(arguments: [#""defaultProfileId": "gone","#, #""defaultProfileId": 7,"#, ""])
    func unknownOrMissingDefaultFallsBackToTheFirstClaudeProfile(defaultField: String) throws {
        try withStore { store, _ in
            try write("""
            {"version": 1, \(defaultField) "profiles": [
              {"id": "zsh", "name": "zsh", "kind": "shell"},
              {"id": "mine", "name": "mine", "kind": "claude"},
              {"id": "other", "name": "other", "kind": "claude"}
            ]}
            """, store)
            #expect(try store.load().defaultProfileId == "mine")
        }
    }

    @Test func aShellDefaultIsKept() throws {
        try withStore { store, _ in
            var doc = LaunchProfileDocument.seeded
            doc.defaultProfileId = "zsh"
            try store.save(doc)
            #expect(try store.load().defaultProfileId == "zsh")
        }
    }

    @Test func noClaudeProfileLeftAddsTheBuiltInBack() throws {
        try withStore { store, _ in
            try write(#"{"version": 1, "defaultProfileId": "zsh", "profiles": [{"id": "zsh", "name": "zsh", "kind": "shell"}]}"#, store)
            let doc = try store.load()
            #expect(doc.profiles.map(\.id) == ["claude-default", "zsh"])
            #expect(doc.profiles[0] == LaunchProfile.builtIn[0])
            #expect(doc.defaultProfileId == "zsh")
            // The id is taken by a shell profile: the added one gets a suffix.
            try write(#"{"version": 1, "profiles": [{"id": "claude-default", "name": "sh", "kind": "shell"}]}"#, store)
            let taken = try store.load()
            #expect(taken.profiles.map(\.id) == ["claude-default-2", "claude-default"])
            #expect(taken.defaultProfileId == "claude-default-2")
            #expect(taken.claudeProfile(id: nil).id == "claude-default-2")
            // An empty or missing list.
            try write(#"{"version": 1}"#, store)
            #expect(try store.load().profiles.map(\.id) == ["claude-default"])
        }
    }

    @Test func newerVersionIsRefusedAndNeverOverwritten() throws {
        try withStore { store, _ in
            try write(#"{"version": 2, "profiles": []}"#, store)
            #expect(throws: LaunchProfileStoreError.unsupportedVersion(2)) { try store.load() }
            #expect(throws: LaunchProfileStoreError.unsupportedVersion(2)) { try store.save(.seeded) }
            #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == #"{"version": 2, "profiles": []}"#)
        }
    }

    @Test func corruptFilesAndMoveAside() throws {
        try withStore { store, temp in
            for text in ["not json", "[1]", #"{"profiles": []}"#, #"{"version": 0}"#, #"{"version": "1"}"#] {
                try write(text, store)
                #expect(throws: LaunchProfileStoreError.self) { try store.load() }
                do {
                    _ = try store.load()
                } catch {
                    guard case LaunchProfileStoreError.corrupt? = error as? LaunchProfileStoreError else { Issue.record("expected corrupt for \(text), got \(error)"); continue }
                }
            }
            let moved = try store.moveAside(now: JSDate.date(milliseconds: 1_792_032_120_000))
            #expect(moved.lastPathComponent == "profiles.json.corrupt-1792032120000")
            #expect(FileManager.default.fileExists(atPath: moved.path))
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
            #expect(try store.load() == .seeded)
            _ = temp
        }
    }

    @Test func unreadableFileIsAnIOError() throws {
        try withStore { store, _ in
            try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
            do {
                _ = try store.load()
                Issue.record("expected an error")
            } catch {
                guard case LaunchProfileStoreError.io? = error as? LaunchProfileStoreError else { Issue.record("expected io, got \(error)"); return }
            }
        }
    }

    @Test func documentHelpers() {
        let doc = LaunchProfileDocument.seeded
        #expect(doc.normalized() == doc)
        #expect(doc.defaultProfile?.id == "claude-default")
        #expect(doc.claudeProfile(id: "claude-rc").id == "claude-rc")
        #expect(doc.claudeProfile(id: "zsh").id == "claude-default")     // not a claude profile
        #expect(doc.claudeProfile(id: "missing").id == "claude-default")
        #expect(doc.shellProfile.id == "zsh")
        let noShell = LaunchProfileDocument(profiles: [LaunchProfile.builtIn[0]], defaultProfileId: "claude-default")
        #expect(noShell.shellProfile.id == "zsh")
        var shellDefault = doc
        shellDefault.defaultProfileId = "zsh"
        #expect(shellDefault.claudeProfile(id: nil).id == "claude-default")
        #expect(LaunchProfileEditing.uniqueId("claude-default", in: doc) == "claude-default-2")
        #expect(LaunchProfileEditing.uniqueId("new", in: doc) == "new")
        #expect(LaunchProfileEditing.uniqueId("  ", in: doc) == "profile")
    }
}

@Suite("Launch profile editing")
struct LaunchProfileEditingTests {
    typealias E = LaunchProfileEditing
    let doc = LaunchProfileDocument.seeded

    func claude(_ id: String = "custom", name: String = "custom", model: String? = nil, mode: PermissionMode? = nil,
                args: [String] = [], env: [String: String] = [:]) -> LaunchProfile {
        LaunchProfile(id: id, name: name, kind: .claude, defaultModel: model, defaultPermissionMode: mode, extraArguments: args,
                      environment: env)
    }

    @Test func validProfileHasNoIssues() {
        #expect(E.validate(claude(model: " opus ", mode: .acceptEdits, args: ["--verbose", "--remote-control"],
                                  env: ["CLAUDE_CONFIG_DIR": "/x", "ANTHROPIC_MODEL": "y"]), in: doc).isEmpty)
        #expect(E.validate(LaunchProfile.builtIn[1], in: doc).isEmpty) // editing itself is not a duplicate
        #expect(E.validate(claude(mode: .default), in: doc).isEmpty)
    }

    @Test func eachIssue() {
        #expect(E.validate(claude(name: "  \t"), in: doc) == [.emptyName])
        #expect(E.validate(claude(name: " CLAUDE-PLAN "), in: doc) == [.duplicateName])
        #expect(E.validate(claude(args: ["--resume", "--model=x", "--verbose", "-n", "--settings={}"]), in: doc)
            == [.reservedArgument("--resume"), .reservedArgument("--model=x"), .reservedArgument("-n"), .reservedArgument("--settings={}")])
        #expect(E.validate(claude(model: "opus 5"), in: doc) == [.invalidModel("opus 5")])
        #expect(E.validate(claude(model: "-x"), in: doc) == [.invalidModel("-x")])
        #expect(E.validate(claude(model: "   "), in: doc).isEmpty) // blank = no model
        #expect(E.validate(claude(mode: PermissionMode(rawValue: "plan mode")), in: doc) == [.invalidPermissionMode("plan mode")])
        #expect(E.validate(claude(mode: PermissionMode(rawValue: "")), in: doc) == [.invalidPermissionMode("")])
        #expect(E.validate(claude(env: ["PATH": "/x", "DYLD_INSERT_LIBRARIES": "y", "CODD_SESSION_ID": "z", "OK": "1"]), in: doc)
            == [.blockedEnvironment("CODD_SESSION_ID"), .blockedEnvironment("DYLD_INSERT_LIBRARIES"), .blockedEnvironment("PATH")])
        #expect(E.validate(claude(env: ["1BAD": "v", "A-B": "w", "NUL": "a\0b"]), in: doc)
            == [.invalidEnvironmentLine("1BAD=v"), .invalidEnvironmentLine("A-B=w"), .invalidEnvironmentLine("NUL=a\0b")])
        // Arguments, model and mode only matter for claude profiles.
        let shell = LaunchProfile(id: "sh", name: "sh", kind: .shell, defaultModel: "a b", extraArguments: ["--resume"],
                                  environment: ["TERM": "dumb"])
        #expect(E.validate(shell, in: doc) == [.blockedEnvironment("TERM")])
        // Several at once, in a stable order.
        #expect(E.validate(claude(name: "", model: "a b", args: ["-c"], env: ["PATH": "/"]), in: doc)
            == [.emptyName, .reservedArgument("-c"), .invalidModel("a b"), .blockedEnvironment("PATH")])
    }

    @Test func parseArguments() throws {
        let parsed = try E.parseArguments(#"--append-system-prompt "be brief"   --x='a b' plain\ word 中文 '' "say \"hi\" \$HOME" it\'s"#).get()
        #expect(parsed == ["--append-system-prompt", "be brief", "--x=a b", "plain word", "中文", "", #"say "hi" $HOME"#, "it's"])
        #expect(try E.parseArguments("").get() == [])
        #expect(try E.parseArguments(" \n\t ").get() == [])
        #expect(try E.parseArguments("a\\\nb c").get() == ["ab", "c"])         // line continuation
        #expect(try E.parseArguments(#""a\b" 'c\d'"#).get() == [#"a\b"#, #"c\d"#])
        #expect(try E.parseArguments("--add-dir\u{3000}/tmp").get() == ["--add-dir", "/tmp"])
        #expect(E.parseArguments(#""unterminated"#) == .failure(.unbalancedQuotes))
        #expect(E.parseArguments("'unterminated") == .failure(.unbalancedQuotes))
        #expect(E.parseArguments(#"ok "a'b"#) == .failure(.unbalancedQuotes))
    }

    @Test func formatArguments() {
        #expect(E.formatArguments(["--remote-control"]) == "--remote-control")
        #expect(E.formatArguments(["--model=opus", "a/b.c:d,e+f@g%h"]) == "--model=opus a/b.c:d,e+f@g%h")
        #expect(E.formatArguments(["be brief"]) == #""be brief""#)
        #expect(E.formatArguments(["it's"]) == #""it's""#)
        #expect(E.formatArguments(["$HOME"]) == "'$HOME'")
        #expect(E.formatArguments([#"a'b"c"#]) == #"'a'\''b"c'"#)
        #expect(E.formatArguments([""]) == "''")
        #expect(E.formatArguments(["中文", "流程改寫"]) == "中文 流程改寫")
        #expect(E.formatArguments(["=cmd", "~/x", "*.swift", "#tag", "a;b"]) == ##""=cmd" "~/x" "*.swift" "#tag" "a;b""##)
        #expect(E.formatArguments([]) == "")
    }

    @Test(arguments: [
        ["--append-system-prompt", "be brief"], ["it's", #"say "hi""#, "$HOME", "`x`", "!!", "a\\b"], ["", "中文 空白", "\u{3000}"],
        ["line\nbreak", "tab\there", "=x", "~", "--x=a b"], ["\u{1F680} deploy", "é", "-n"],
    ])
    func formatThenParseRoundTrips(args: [String]) throws {
        #expect(try E.parseArguments(E.formatArguments(args)).get() == args)
    }

    @Test func parseEnvironment() throws {
        let text = "CLAUDE_CONFIG_DIR=/Users/synthetic/.claude-2\r\n# comment\n\n  export FOO = bar  \nQUOTED=\"a b\"\nSINGLE='x'\nEMPTY=\nEQ=a=b\n"
        #expect(try E.parseEnvironment(text).get() == [
            "CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-2", "FOO": "bar", "QUOTED": "a b", "SINGLE": "x", "EMPTY": "", "EQ": "a=b",
        ])
        #expect(try E.parseEnvironment("").get() == [:])
        #expect(try E.parseEnvironment("A=1\nA=2").get() == ["A": "2"])
        #expect(E.parseEnvironment("OK=1\nNOEQUALS\n") == .failure(.invalidEnvironmentLine("NOEQUALS")))
        #expect(E.parseEnvironment("  =value") == .failure(.invalidEnvironmentLine("=value")))
        #expect(E.parseEnvironment("1X=y") == .failure(.invalidEnvironmentLine("1X=y")))
        #expect(E.parseEnvironment("export") == .failure(.invalidEnvironmentLine("export")))
    }

    @Test func formatEnvironmentRoundTrips() throws {
        let env = ["B": "two words", "A": "/x", "C": " padded ", "D": "\"quoted\"", "E": ""]
        let text = E.formatEnvironment(env)
        #expect(text.hasPrefix("A=/x\nB=two words\n"))
        #expect(try E.parseEnvironment(text).get() == env)
    }

    let sessionId = "7c1e9a04-5b6c-4d3e-8f90-123456789abc"
    let resumeId = "3f2a91c0-0000-4000-8000-000000000000"

    @Test func commandPreviewArtboardStrings() {
        let p = LaunchProfile.builtIn[0]
        #expect(E.commandPreview(p, sessionId: sessionId, model: "opus-5.5", permissionMode: .acceptEdits, name: "修正登入 API 401",
                                 resumeId: nil, remoteControl: false)
            == #"claude --session-id 7c1e9a04-… --model opus-5.5 --permission-mode acceptEdits -n "修正登入 API 401""#)
        #expect(E.commandPreview(p, sessionId: sessionId, model: "opus-5.5", permissionMode: .acceptEdits, name: "refresh token 流程改寫",
                                 resumeId: resumeId, remoteControl: false)
            == #"claude --resume 3f2a91c0-… --model opus-5.5 --permission-mode acceptEdits -n "refresh token 流程改寫""#)
        #expect(E.commandPreview(p, sessionId: sessionId, model: "opus-5.5", permissionMode: .acceptEdits, name: "修正登入 API 401",
                                 resumeId: nil, remoteControl: false, abbreviated: false)
            == #"claude --session-id 7c1e9a04-5b6c-4d3e-8f90-123456789abc --model opus-5.5 --permission-mode acceptEdits -n "修正登入 API 401""#)
        #expect(E.commandPreview(p, sessionId: nil, model: nil, permissionMode: nil, name: nil, resumeId: nil, remoteControl: false)
            == "claude --session-id <new>")
        #expect(E.commandPreview(p, sessionId: sessionId.uppercased(), model: nil, permissionMode: nil, name: nil, resumeId: nil,
                                 remoteControl: false, abbreviated: false) == "claude --session-id \(sessionId)")
    }

    @Test func commandPreviewProfilesAndRemoteControl() {
        let (def, plan, rc, zsh) = (LaunchProfile.builtIn[0], LaunchProfile.builtIn[1], LaunchProfile.builtIn[2], LaunchProfile.builtIn[3])
        #expect(E.commandPreview(def, sessionId: nil, model: nil, permissionMode: nil, name: nil, resumeId: nil, remoteControl: true)
            == "claude --session-id <new> --remote-control")
        #expect(E.commandPreview(rc, sessionId: nil, model: nil, permissionMode: nil, name: "x", resumeId: nil, remoteControl: true)
            == #"claude --session-id <new> -n "x" --remote-control"#)
        #expect(E.commandPreview(rc, sessionId: nil, model: nil, permissionMode: nil, name: nil, resumeId: nil, remoteControl: false)
            == "claude --session-id <new> --remote-control")
        #expect(E.commandPreview(plan, sessionId: nil, model: nil, permissionMode: nil, name: nil, resumeId: nil, remoteControl: false)
            == "claude --session-id <new> --permission-mode plan")
        // The request's mode overrides the profile's; `default` means no flag at all (like LaunchBuilder).
        #expect(E.commandPreview(plan, sessionId: nil, model: nil, permissionMode: .default, name: nil, resumeId: nil, remoteControl: false)
            == "claude --session-id <new>")
        let custom = LaunchProfile(id: "c", name: "c", kind: .claude, defaultModel: "sonnet", extraArguments: ["--append-system-prompt", "be brief"])
        #expect(E.commandPreview(custom, sessionId: nil, model: nil, permissionMode: nil, name: "-dash", resumeId: nil, remoteControl: false)
            == #"claude --session-id <new> --model sonnet --name="-dash" --append-system-prompt "be brief""#)
        #expect(E.commandPreview(custom, sessionId: nil, model: "opus", permissionMode: nil, name: #"say "hi" $x"#, resumeId: nil,
                                 remoteControl: false)
            == #"claude --session-id <new> --model opus -n "say \"hi\" \$x" --append-system-prompt "be brief""#)
        #expect(E.commandPreview(zsh, sessionId: sessionId, model: "opus", permissionMode: .plan, name: "n", resumeId: nil, remoteControl: true)
            == "zsh -l")
        #expect(E.commandPreview(LaunchProfile(id: "b", name: "b", kind: .shell, shellPath: "/bin/bash"), sessionId: nil, model: nil,
                                 permissionMode: nil, name: nil, resumeId: nil, remoteControl: false) == "bash -l")
    }

    /// The unabbreviated preview is exactly the argv LaunchBuilder runs, minus `--settings`.
    @Test func commandPreviewMatchesTheBuilder() throws {
        let profile = LaunchProfile(id: "c", name: "c", kind: .claude, defaultModel: "sonnet", defaultPermissionMode: .plan,
                                    extraArguments: ["--append-system-prompt", "be brief", "--remote-control"])
        let uuid = try #require(UUID(uuidString: sessionId))
        let builder = LaunchBuilder(hooks: nil, isExecutable: { $0 == "/synthetic/bin/claude" })
        for (resume, name) in [(String?.none, "修正登入 API 401"), (resumeId, "-leading dash"), (nil, #"quote " and $ sign"#)] {
            let request = LaunchRequest(profile: profile, cwd: "/p", sessionId: uuid, mode: resume == nil ? .new : .resume,
                                        resumeClaudeSessionId: resume, name: name, model: "opus-5.5", permissionMode: .acceptEdits)
            let spec = try builder.build(request, baseEnvironment: ["HOME": "/Users/synthetic"],
                                         loginEnvironment: ["PATH": "/synthetic/bin"], hookToken: "t")
            let preview = E.commandPreview(profile, sessionId: sessionId, model: "opus-5.5", permissionMode: .acceptEdits, name: name,
                                           resumeId: resume, remoteControl: true, abbreviated: false)
            #expect(try E.parseArguments(preview).get() == ["claude"] + spec.argv.dropFirst())
        }
    }

    @Test func profileCommands() {
        #expect(LaunchProfile.builtIn.map(E.profileCommand) == ["claude", "claude --permission-mode plan", "claude --remote-control", "zsh"])
        let custom = LaunchProfile(id: "c", name: "c", kind: .claude, defaultModel: "opus", defaultPermissionMode: .acceptEdits,
                                   extraArguments: ["--verbose", "--append-system-prompt=be brief"])
        #expect(E.profileCommand(custom) == #"claude --model opus --permission-mode acceptEdits --verbose "--append-system-prompt=be brief""#)
        #expect(E.profileCommand(LaunchProfile(id: "d", name: "d", kind: .claude, defaultPermissionMode: .default)) == "claude")
        #expect(E.profileCommand(LaunchProfile(id: "f", name: "f", kind: .shell, shellPath: "/opt/homebrew/bin/fish")) == "fish")
    }

    @Test func abbreviatedIds() {
        #expect(E.abbreviatedId("7c1e9a04-5b6c-4d3e-8f90-123456789abc") == "7c1e9a04-…")
        #expect(E.abbreviatedId("7C1E9A04-5B6C-4D3E-8F90-123456789ABC") == "7C1E9A04-…")
        #expect(E.abbreviatedId("abcdefghijklmn") == "abcdefgh…")
        #expect(E.abbreviatedId("abcdefghijkl") == "abcdefghijkl") // 12: unchanged
        #expect(E.abbreviatedId("short") == "short")
        #expect(E.abbreviatedId("7c1e9a04-5b6c-4d3e-8f90-123456789abg") == "7c1e9a04…") // not hex: plain long id
    }

    @Test func removeRules() {
        var doc = LaunchProfileDocument.seeded
        #expect(E.remove("claude-plan", from: &doc) == nil)
        #expect(doc.profiles.map(\.id) == ["claude-default", "claude-rc", "zsh"])
        #expect(doc.defaultProfileId == "claude-default")
        // Removing the default: the first remaining claude profile takes over.
        #expect(E.remove("claude-default", from: &doc) == nil)
        #expect(doc.defaultProfileId == "claude-rc")
        // The last claude profile stays.
        #expect(E.remove("claude-rc", from: &doc) == .lastClaudeProfile)
        #expect(doc.profiles.map(\.id) == ["claude-rc", "zsh"])
        // Shell profiles can always go; an unknown id changes nothing.
        #expect(E.remove("zsh", from: &doc) == nil)
        #expect(E.remove("missing", from: &doc) == nil)
        #expect(doc.profiles.map(\.id) == ["claude-rc"])
        // A removed shell default falls back to the first claude profile.
        var shellDefault = LaunchProfileDocument.seeded
        shellDefault.defaultProfileId = "zsh"
        #expect(E.remove("zsh", from: &shellDefault) == nil)
        #expect(shellDefault.defaultProfileId == "claude-default")
    }
}

/// M2 review round 1 (e2e-4, correctness-3): profiles LaunchBuilder would refuse are skipped when
/// a launch picks its profile, and typed models are checked with LaunchBuilder's rule.
@Suite("Launch profiles (M2 review fixes)")
struct LaunchProfileReviewFixTests {
    @Test func unlaunchableProfilesAreSkippedWhenALaunchPicksOne() throws {
        let bad = LaunchProfile(id: "bad", name: "bad", kind: .claude, extraArguments: ["--settings", "{}"])
        let spaced = LaunchProfile(id: "spaced", name: "spaced", kind: .claude, defaultModel: "opus 4")
        let good = LaunchProfile(id: "good", name: "good", kind: .claude, extraArguments: ["--verbose"])
        let document = LaunchProfileDocument(profiles: [bad, spaced, good], defaultProfileId: "bad")
        #expect(LaunchProfileEditing.launchIssues(bad) == [.reservedArgument("--settings")])
        #expect(LaunchProfileEditing.launchIssues(spaced) == [.invalidModel("opus 4")])
        #expect(LaunchProfileEditing.launchIssues(good).isEmpty)
        #expect(document.unlaunchableProfiles.map(\.id) == ["bad", "spaced"])
        #expect(document.claudeProfile(id: nil).id == "good", "the default cannot launch: the first that can")
        #expect(document.claudeProfile(id: "spaced").id == "good")
        #expect(document.claudeProfile(id: "good").id == "good")
        let onlyBad = LaunchProfileDocument(profiles: [bad], defaultProfileId: "bad")
        #expect(onlyBad.claudeProfile(id: "bad").id == LaunchProfileDocument.builtInDefaultId, "the built-in default is the last resort")
        // Name problems and dropped environment names do not stop a launch.
        let blocked = LaunchProfile(id: "env", name: "", kind: .claude, environment: ["PATH": "/x"])
        #expect(LaunchProfileEditing.launchIssues(blocked).isEmpty)
        let builder = LaunchBuilder(hooks: nil, isExecutable: { $0 == "/synthetic/bin/claude" })
        let built = try builder.build(LaunchRequest(profile: document.claudeProfile(id: "bad"), cwd: "/tmp", sessionId: UUID()),
                                      baseEnvironment: ["PATH": "/synthetic/bin", "HOME": "/tmp"], loginEnvironment: nil, hookToken: "t")
        #expect(!built.argv.contains("--settings"))
        #expect(throws: LaunchBuildError.self) {
            try builder.build(LaunchRequest(profile: bad, cwd: "/tmp", sessionId: UUID()), baseEnvironment: ["PATH": "/synthetic/bin"],
                              loginEnvironment: nil, hookToken: "t")
        }
    }

    @Test func typedModelsFollowLaunchBuildersRule() {
        for good in [nil, "", "  ", "opus", "claude-opus-4-5", " sonnet "] as [String?] {
            #expect(LaunchProfileEditing.isValidModel(good), "\(good ?? "nil")")
        }
        for bad in ["opus 4", "-x", "a\tb", "x\u{7F}"] {
            #expect(!LaunchProfileEditing.isValidModel(bad), "\(bad)")
        }
    }
}
