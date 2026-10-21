import Foundation
import Testing
@testable import CoddClaudeSettings

@Suite("Inspection")
struct InspectionTests {
    static let legacyEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                               "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
    static let hookTapEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                            "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd", "PreCompact", "SubagentStop"]

    func inspect(_ json: String, desktop: DesktopStatusLine = DesktopStatusLine(dataRoot: "/tmp/codd root")) throws -> ClaudeSettingsInspection {
        let file = ClaudeSettingsFile(url: URL(fileURLWithPath: "/nonexistent/settings.json"), root: try OrderedJSON.parse(Data(json.utf8)))
        return ClaudeSettingsInstaller.inspect(file, desktop: desktop)
    }

    @Test func syntheticUserFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp))
        let result = ClaudeSettingsInstaller.inspect(file, desktop: ClaudeSettingsInstaller.testDesktop(tmp))
        #expect(result.legacyHookEvents == Self.legacyEvents)
        #expect(result.legacyHandlerCount == 10)
        #expect(result.foreign == [
            ForeignHookTool(name: "hook-tap", code: "hook-tap", events: Self.hookTapEvents,
                            blocking: [(event: "PermissionRequest", seconds: 600)]),
            ForeignHookTool(name: "通知", code: "osascript", events: ["Notification", "Stop"]),
        ])
        #expect(result.statusLine == .coddWeb(inner: Fixture.hookTapStatusLine(tmp)))
        #expect(result.duplicateNotificationHandlers == 2)
        #expect(result.hasLegacy)
        #expect(!result.isUpToDate)
        #expect(result.chainedCommand == Fixture.hookTapStatusLine(tmp))
    }

    @Test func bothHookShapesAreRead() throws {
        let result = try inspect(#"""
        {"hooks": {
          "Stop": [{"matcher": "*", "command": "node /x/status-writer.js"}],
          "SessionStart": [{"hooks": [{"type": "command", "command": "node '/y/status-writer.js'"}, {"type": "command", "command": "/opt/tool/bin/notify-me --x"}]}],
          "Bad": "not an array",
          "Odd": [42, {"hooks": "no"}]
        }}
        """#)
        #expect(result.legacyHookEvents == ["Stop", "SessionStart"])
        #expect(result.legacyHandlerCount == 2)
        #expect(result.foreign == [ForeignHookTool(name: "notify-me", code: "notify-me", events: ["SessionStart"])])
    }

    @Test func foreignToolNames() {
        let cases: [(String, String)] = [
            ("'/Users/u/My Tools/bin/hook.sh' --flag", "hook.sh"),
            ("\"/opt/a b/run\" x", "run"),
            ("FOO=1 BAR='x y' /usr/local/bin/tool arg", "tool"),
            ("  python3 -m thing", "python3"),
            ("node /path/x.js", "node"),
            ("/bin/echo\\ x; true", "echo x"),
            ("'FOO=1' cmd", "FOO=1"),
            ("", "command"),
        ]
        for (command, expected) in cases {
            #expect(ForeignToolName.programName(command) == expected, "\(command)")
        }
        #expect(ForeignToolName.classify([(key: "type", value: .string("http")), (key: "url", value: .string("http://x"))]) == ("http", "http"))
        #expect(ForeignToolName.classify([(key: "command", value: .string("x/hook-tap Stop"))]) == ("hook-tap", "hook-tap"))
        #expect(ForeignToolName.classify([(key: "command", value: .string("/usr/bin/osascript -e 'beep'"))]) == ("通知", "osascript"))
    }

    @Test func blockingNeedsPermissionRequestAndSixtySeconds() throws {
        let result = try inspect(#"""
        {"hooks": {
          "PreToolUse": [{"hooks": [{"type": "command", "command": "guard", "timeout": 900}]}],
          "PermissionRequest": [{"hooks": [
            {"type": "command", "command": "guard", "timeout": 59},
            {"type": "command", "command": "guard", "timeout": 60},
            {"type": "command", "command": "guard", "timeout": 1.2e2},
            {"type": "command", "command": "guard", "timeout": 60}
          ]}]
        }}
        """#)
        #expect(result.foreign.count == 1)
        #expect(result.foreign[0].events == ["PreToolUse", "PermissionRequest"])
        #expect(result.foreign[0].blocking.map(\.seconds) == [60, 120])
    }

    @Test func duplicateNotificationsOnlyOnNotificationAndStop() throws {
        let result = try inspect(#"""
        {"hooks": {
          "Notification": [{"hooks": [{"type": "command", "command": "osascript -e 'display notification \"a\"'"}]}],
          "Stop": [{"matcher": "", "command": "osascript -e 'display notification \"b\"'"}],
          "SubagentStop": [{"hooks": [{"type": "command", "command": "osascript -e 'display notification \"c\"'"}]}],
          "SessionEnd": [{"hooks": [{"type": "command", "command": "osascript -e 'say done'"}]}]
        }}
        """#)
        #expect(result.duplicateNotificationHandlers == 2)
        #expect(result.foreign == [ForeignHookTool(name: "通知", code: "osascript", events: ["Notification", "Stop", "SubagentStop", "SessionEnd"])])
    }

    @Test func statusLineStates() throws {
        let desktop = DesktopStatusLine(dataRoot: "/Users/u/Library/Application Support/CODD")
        func state(_ statusLine: String) throws -> StatusLineState {
            try inspect("{\"statusLine\": \(statusLine)}", desktop: desktop).statusLine
        }
        func json(_ s: String) -> String { OrderedJSON.string(s).serialized(indent: "") }
        #expect(try inspect("{}").statusLine == .none)
        #expect(try state(#"{"type": "command", "command": "  "}"#) == .none)
        #expect(try state(#""just a string""#) == .none)
        #expect(try state(#"{"type": "command", "command": "~/.hook-tap/statusline.sh"}"#) == .user("~/.hook-tap/statusline.sh"))

        let standaloneWeb = "if [ -x '/n' ] && [ -f '/r/configs/statusline/codd-statusline.js' ]; then STATUS_DIR_PATH='/s' '/n' '/r/configs/statusline/codd-statusline.js'; else :; fi"
        #expect(try state("{\"command\": \(json(standaloneWeb))}") == .coddWeb(inner: nil))
        let brokenWeb = "'/n' '/r/codd-statusline.js' --chain-b64 @@@notbase64"
        #expect(try state("{\"command\": \(json(brokenWeb))}") == .coddWeb(inner: nil))
        let alteredWeb = "'/n' '/r/codd-statusline.js' --chain-b64 eA"
        #expect(try state("{\"command\": \(json(alteredWeb))}") == .undecodable)

        let installed = desktop.command(chain: "~/.hook-tap/statusline.sh")
        #expect(try state("{\"type\": \"command\", \"command\": \(json(installed))}") == .coddDesktop(chain: "~/.hook-tap/statusline.sh", current: true))
        #expect(try state("{\"command\": \(json(installed))}") == .coddDesktop(chain: "~/.hook-tap/statusline.sh", current: false))
        let other = DesktopStatusLine(dataRoot: "/tmp/other root").command(chain: nil)
        #expect(try state("{\"type\": \"command\", \"command\": \(json(other))}") == .coddDesktop(chain: nil, current: false))
        let edited = installed.replacingOccurrences(of: "; fi", with: "; echo hi; fi")
        #expect(try state("{\"type\": \"command\", \"command\": \(json(edited))}") == .undecodable)
    }

    @Test func upToDateAfterUpdate() throws {
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let result = try inspect("{\"statusLine\": {\"type\": \"command\", \"command\": \(OrderedJSON.string(desktop.command(chain: nil)).serialized(indent: ""))}}", desktop: desktop)
        #expect(result.isUpToDate)
        #expect(!result.hasLegacy)
        #expect(result.chainedCommand == nil)
    }
}
