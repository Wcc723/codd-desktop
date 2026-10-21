import Foundation
import Testing
@testable import CoddClaudeSettings

@Suite("UserStatusLine")
struct UserStatusLineTests {
    func file(_ json: String) throws -> ClaudeSettingsFile {
        ClaudeSettingsFile(url: URL(fileURLWithPath: "/nonexistent/settings.json"), root: try OrderedJSON.parse(Data(json.utf8)))
    }

    func statusLine(_ command: String, _ extras: String = "") -> String {
        "{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONWriter.quoted(command))\(extras)}}"
    }

    @Test func unwrapRules() throws {
        let desktop = DesktopStatusLine(dataRoot: "/Users/u/Library/Application Support/CODD")
        // CODD Desktop's wrapper: its chain, never itself.
        let wrapped = UserStatusLine.chain(from: [try file(statusLine(desktop.command(chain: "~/.hook-tap/statusline.sh")))])
        #expect(wrapped?.command == "~/.hook-tap/statusline.sh")
        #expect(UserStatusLine.chain(from: [try file(statusLine(desktop.command(chain: nil)))]) == nil)
        // A hand-edited desktop wrapper: its decodable --chain-b64, else nothing.
        let edited = desktop.command(chain: "printf X").replacingOccurrences(of: "; fi", with: " ; fi")
        #expect(UserStatusLine.chain(from: [try file(statusLine(edited))])?.command == "printf X")
        let broken = "'/r/bin/codd-statusline' --data-root '/r' --chain-b64 eA"
        #expect(UserStatusLine.chain(from: [try file(statusLine(broken))]) == nil)
        // CODD web's wrapper and the user's own command are chained as they are.
        let web = "if [ -x '/n' ]; then '/n' '/r/codd-statusline.js' --chain-b64 eA==; else /bin/sh -c 'x'; fi"
        #expect(UserStatusLine.chain(from: [try file(statusLine(web))])?.command == web)
        #expect(UserStatusLine.chain(from: [try file(statusLine("~/bin/sl.sh --flag"))])?.command == "~/bin/sl.sh --flag")
        // A custom marker for a non-standard binary name.
        let custom = DesktopStatusLine(binary: "/r/tools/sl", dataRoot: "/r").command(chain: "y")
        #expect(UserStatusLine.chain(from: [try file(statusLine(custom))])?.command == custom)
        #expect(UserStatusLine.chain(from: [try file(statusLine(custom))], desktopBinaryMarker: "/tools/sl")?.command == "y")
    }

    @Test func extrasAreRawJSONFromTheWinningFile() throws {
        let winner = try file(statusLine("a", ", \"padding\": 2, \"refreshInterval\": 1.5, \"hideVimModeIndicator\": true, \"other\": 1"))
        let result = try #require(UserStatusLine.chain(from: [winner]))
        #expect(result.command == "a")
        #expect(result.extras == ["padding": "2", "refreshInterval": "1.5", "hideVimModeIndicator": "true"])
    }

    @Test func precedenceLocalThenProjectThenUser() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let cwd = tmp.file("project").path
        let user = tmp.file("home/.claude/settings.json")
        let urls = UserStatusLine.candidateURLs(cwd: cwd, userSettings: user)
        #expect(urls.map(\.path) == ["\(cwd)/.claude/settings.local.json", "\(cwd)/.claude/settings.json", user.path])

        try tmp.write("home/.claude/settings.json", statusLine("user-sl", ", \"refreshInterval\": 5"))
        #expect(UserStatusLine.chain(from: UserStatusLine.loadFiles(urls))?.command == "user-sl")
        #expect(UserStatusLine.chain(from: UserStatusLine.loadFiles(urls))?.extras == ["refreshInterval": "5"])

        try tmp.write("project/.claude/settings.json", statusLine("project-sl", ", \"padding\": 1"))
        let project = try #require(UserStatusLine.chain(from: UserStatusLine.loadFiles(urls)))
        #expect(project.command == "project-sl")
        #expect(project.extras == ["padding": "1"])

        // A local file with only extras does not win; one with a command does, with its own extras only.
        try tmp.write("project/.claude/settings.local.json", "{\"statusLine\": {\"padding\": 9}}")
        #expect(UserStatusLine.chain(from: UserStatusLine.loadFiles(urls))?.command == "project-sl")
        try tmp.write("project/.claude/settings.local.json", statusLine("local-sl"))
        let local = try #require(UserStatusLine.chain(from: UserStatusLine.loadFiles(urls)))
        #expect(local.command == "local-sl")
        #expect(local.extras == [:])
    }

    @Test func unreadableAndMissingFilesAreSkipped() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let cwd = tmp.file("p").path
        let user = tmp.file("u/settings.json")
        let urls = UserStatusLine.candidateURLs(cwd: cwd, userSettings: user)
        #expect(UserStatusLine.loadFiles(urls).isEmpty)
        #expect(UserStatusLine.chain(from: UserStatusLine.loadFiles(urls)) == nil)
        try tmp.write("p/.claude/settings.local.json", "{ broken")
        try tmp.write("p/.claude/settings.json", "[1]")
        try tmp.write("u/settings.json", statusLine("user-sl"))
        let files = UserStatusLine.loadFiles(urls)
        #expect(files.map(\.url) == [user])
        #expect(UserStatusLine.chain(from: files)?.command == "user-sl")
    }

    @Test func nothingFoundIsNil() throws {
        #expect(UserStatusLine.chain(from: []) == nil)
        #expect(UserStatusLine.chain(from: [try file("{}"), try file(#"{"statusLine": {"command": " "}}"#), try file(#"{"statusLine": "x"}"#)]) == nil)
    }
}

@Suite("Line diff")
struct LineDiffTests {
    /// Applying the ops to `a` must give `b`, and every op must be used in order.
    func check(_ a: [Int], _ b: [Int]) {
        let ops = LineDiff.diff(a, b)
        var rebuilt: [Int] = []
        var nextA = 0, nextB = 0
        for op in ops {
            switch op {
            case .equal(let x, let y):
                #expect(x == nextA && y == nextB && a[x] == b[y])
                rebuilt.append(a[x]); nextA += 1; nextB += 1
            case .delete(let x):
                #expect(x == nextA)
                nextA += 1
            case .insert(let y):
                #expect(y == nextB)
                rebuilt.append(b[y]); nextB += 1
            }
        }
        #expect(rebuilt == b)
        #expect(nextA == a.count && nextB == b.count)
    }

    @Test func reconstructsAndIsMinimal() {
        check([], [])
        check([1, 2, 3], [])
        check([], [1, 2])
        check([1, 2, 3, 4], [1, 3, 4, 5])
        // Myers' example: ABCABBA → CBABAC needs D = 5.
        let a = [1, 2, 3, 1, 2, 2, 1], b = [3, 2, 1, 2, 1, 3]
        check(a, b)
        let edits = LineDiff.diff(a, b).filter { if case .equal = $0 { return false } else { return true } }.count
        #expect(edits == 5)
        var generator = SplitMix(seed: 42)
        for _ in 0..<200 {
            let x = (0..<Int(generator.next() % 30)).map { _ in Int(generator.next() % 5) }
            let y = (0..<Int(generator.next() % 30)).map { _ in Int(generator.next() % 5) }
            check(x, y)
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
