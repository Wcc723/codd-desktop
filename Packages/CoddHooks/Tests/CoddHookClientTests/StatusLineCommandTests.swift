import Darwin
import Testing
@testable import CoddHookClient

@Suite("Status-line account key (D6, same rows as CoddCore AccountKey)")
struct StatusLineAccountKeyTests {
    /// The table shared with C1 (CoddCore `AccountKey.from`); the hashes were computed independently.
    @Test(arguments: [
        (nil, "default"),
        ("", "default"),
        ("/Users/u/.claude", "default"),
        ("/Users/u/.claude/", "default"),
        ("/Users/u/.claude///", "default"),
        ("/Users/u/.claude-swap-backup/sessions/2-north-example-com", "cswap-2"),
        ("/Users/u/.claude-swap-backup/sessions/2-north-example-com/", "cswap-2"),
        ("/Users/u/.claude-swap-backup/sessions/0002-a", "cswap-2"),
        ("/Users/u/.claude-swap-backup/sessions/1234-a", "cswap-1234"),
        ("/Users/u/.claude-swap-backup/sessions/x-2", "cfg-6e6d10e147ae1a00"),
        ("/Users/u/.claude-swap-backup/sessions/12345-a", "cfg-fe320b7e0459ca16"),
        ("/tmp/cfg", "cfg-f5bd2271f472c382"),
        ("/Users/u/other/sessions/3-a", "cfg-a12e0d9ce4946399"),
        ("~/.claude", "cfg-d27e70c06cc58e96"), // the path as given: no tilde expansion
        ("/工作/設定", "cfg-0c9eebf055a0a5ad"),
    ] as [(String?, String)])
    func table(_ dir: String?, _ key: String) {
        #expect(StatusLineAccountKey.from(claudeConfigDir: dir, home: "/Users/u") == key)
    }

    @Test func homeHandling() {
        #expect(StatusLineAccountKey.from(claudeConfigDir: "/Users/u/.claude", home: "/Users/u/") == "default")
        // Without HOME the default directory cannot be recognised: it is hashed like any other.
        #expect(StatusLineAccountKey.from(claudeConfigDir: "/Users/u/.claude", home: nil).hasPrefix("cfg-"))
        #expect(StatusLineAccountKey.from(claudeConfigDir: nil, home: nil) == "default")
        // A cswap profile does not depend on HOME.
        #expect(StatusLineAccountKey.from(claudeConfigDir: "/x/.claude-swap-backup/sessions/7-a", home: nil) == "cswap-7")
        // Neither a dash-less number nor a leading dash is a slot.
        #expect(StatusLineAccountKey.from(claudeConfigDir: "/x/.claude-swap-backup/sessions/7", home: nil).hasPrefix("cfg-"))
        #expect(StatusLineAccountKey.from(claudeConfigDir: "/x/.claude-swap-backup/sessions/-7", home: nil).hasPrefix("cfg-"))
    }

    @Test func fnvKnownVectors() {
        #expect(StatusLineAccountKey.fnv1a64("".utf8) == 0xcbf2_9ce4_8422_2325)
        #expect(StatusLineAccountKey.fnv1a64("a".utf8) == 0xaf63_dc4c_8601_ec8c)
        #expect(StatusLineAccountKey.hex16(0x0c9e_ebf0_55a0_a5ad) == "0c9eebf055a0a5ad") // leading zero kept
        // Never the directory name: the slug is an e-mail.
        #expect(!StatusLineAccountKey.from(claudeConfigDir: "/p/north-example-com", home: "/Users/u").contains("example"))
    }
}

@Suite("Base64 (chain)")
struct Base64Tests {
    func text(_ s: String) -> String? { Base64.decode(s).map { String(decoding: $0, as: UTF8.self) } }

    @Test func rfc4648Vectors() {
        #expect(text("") == "")
        #expect(text("Zg==") == "f")
        #expect(text("Zm8=") == "fo")
        #expect(text("Zm9v") == "foo")
        #expect(text("Zm9vYg==") == "foob")
        #expect(text("Zm9vYmE=") == "fooba")
        #expect(text("Zm9vYmFy") == "foobar")
        // Unpadded is accepted; binary bytes and the +/ characters decode.
        #expect(text("Zm9vYg") == "foob")
        #expect(Base64.decode("+/+/") == [0xFB, 0xFF, 0xBF])
        #expect(text("cHJpbnRmICdTTC0lcycgb2s=") == "printf 'SL-%s' ok")
    }

    @Test(arguments: ["Zg=", "Z===", "Zm9v=", "Zm 9v", "Zm9v\n", "Zm-_", "Z", "Zm9vY", "=Zm9", "Zg==Zg=="])
    func invalid(_ s: String) {
        #expect(Base64.decode(s) == nil)
    }
}

@Suite("codd-statusline command")
struct StatusLineCommandTests {
    let token = String(repeating: "ab", count: 32)
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    func lookup(_ e: [String: String]) -> (String) -> String? { { e[$0] } }

    func b64(_ s: String) -> String {
        // Minimal encoder for the tests (the CLI only decodes).
        let table = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        let b = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            let n = min(3, b.count - i)
            let chunk = (0..<3).map { $0 < n ? UInt32(b[i + $0]) : 0 }
            let v = chunk[0] << 16 | chunk[1] << 8 | chunk[2]
            for k in 0..<4 { out.append(k <= n ? table[Int((v >> UInt32(18 - 6 * k)) & 63)] : UInt8(ascii: "=")) }
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    var sessionEnv: [String: String] {
        ["CODD_HOOK_URL": "http://127.0.0.1:47821/hooks", "CODD_HOOK_TOKEN": token, "CODD_SESSION_ID": sid, "HOME": "/Users/u"]
    }

    @Test func argumentParsing() {
        let a = StatusLineCommand(arguments: ["codd-statusline", "--data-root", "/r", "--chain-b64", b64("ls"), "--url", "http://127.0.0.1:1/"],
                                  environment: lookup([:]))
        #expect(a.dataRoot == "/r")
        #expect(a.chain == "ls")
        #expect(a.url == "http://127.0.0.1:1/")
        let b = StatusLineCommand(arguments: ["codd-statusline", "--verbose", "--data-root=/a b", "positional", "--chain-b64=\(b64("x"))"],
                                  environment: lookup([:]))
        #expect(b.dataRoot == "/a b")
        #expect(b.chain == "x")
        #expect(b.url == nil)
        // A dangling flag has no value; an empty value counts as none.
        let c = StatusLineCommand(arguments: ["codd-statusline", "--url=", "--data-root"], environment: lookup(["CODD_HOOK_URL": "http://localhost:2/hooks"]))
        #expect(c.dataRoot == nil)
        #expect(c.url == "http://localhost:2/hooks")
        let d = StatusLineCommand(arguments: ["codd-statusline"], environment: lookup(sessionEnv))
        #expect(d == StatusLineCommand(dataRoot: nil, url: "http://127.0.0.1:47821/hooks", token: token, sessionID: sid,
                                       configKey: "default", chain: nil))
        #expect(!d.debug)
        #expect(StatusLineCommand(arguments: ["x"], environment: lookup(["CODD_HOOK_DEBUG": "1"])).debug)
    }

    @Test func chainPrecedenceAndValidation() {
        func chain(_ args: [String], _ env: [String: String] = [:]) -> String? {
            StatusLineCommand(arguments: ["codd-statusline"] + args, environment: lookup(env)).chain
        }
        #expect(chain([], ["CODD_STATUSLINE_CHAIN": b64("~/.hook-tap/statusline.sh")]) == "~/.hook-tap/statusline.sh")
        #expect(chain(["--chain-b64", b64("flag")], ["CODD_STATUSLINE_CHAIN": b64("env")]) == "flag")
        // An invalid --chain-b64 still wins: the environment is not consulted.
        #expect(chain(["--chain-b64", "%%%"], ["CODD_STATUSLINE_CHAIN": b64("env")]) == nil)
        #expect(chain(["--chain-b64"], ["CODD_STATUSLINE_CHAIN": b64("env")]) == nil)
        #expect(chain([], ["CODD_STATUSLINE_CHAIN": "not base64!"]) == nil)
        #expect(chain([], ["CODD_STATUSLINE_CHAIN": b64(" \n\t ")]) == nil)    // blank
        #expect(chain([], ["CODD_STATUSLINE_CHAIN": "YQBi"]) == nil)            // "a\0b"
        #expect(chain([], ["CODD_STATUSLINE_CHAIN": "/w=="]) == nil)            // 0xFF: not UTF-8
        #expect(chain([], ["CODD_STATUSLINE_CHAIN": b64("printf '%s' \"中文\"")]) == "printf '%s' \"中文\"")
        #expect(chain([]) == nil)
    }

    @Test func timeoutOverrideOnlyShortens() {
        func timeout(_ v: String?) -> Int {
            StatusLineCommand(arguments: ["x"], environment: lookup(v.map { ["CODD_STATUSLINE_TIMEOUT_MS": $0] } ?? [:]))
                .chainTimeoutMilliseconds
        }
        #expect(timeout(nil) == 10_000)
        #expect(timeout("300") == 300)
        #expect(timeout("10000") == 10_000)
        #expect(timeout("1") == 1)
        for bad in ["0", "20000", "99999", "abc", "-5", "3e2", " 300", ""] {
            #expect(timeout(bad) == 10_000, "\(bad)")
        }
    }

    @Test func configKeyComesFromTheEnvironment() {
        var env = sessionEnv
        env["CLAUDE_CONFIG_DIR"] = "/Users/u/.claude-swap-backup/sessions/2-north-example-com"
        #expect(StatusLineCommand(arguments: ["x"], environment: lookup(env)).configKey == "cswap-2")
        env["CLAUDE_CONFIG_DIR"] = "/Users/u/.claude/"
        #expect(StatusLineCommand(arguments: ["x"], environment: lookup(env)).configKey == "default")
        env["CLAUDE_CONFIG_DIR"] = "/tmp/cfg"
        #expect(StatusLineCommand(arguments: ["x"], environment: lookup(env)).configKey == "cfg-f5bd2271f472c382")
    }

    @Test func perSessionEndpoint() throws {
        let noFile: (String) -> [UInt8]? = { _ in Issue.record("no file read in per-session mode"); return nil }
        let e = try #require(StatusLineCommand(arguments: ["x"], environment: lookup(sessionEnv)).endpoint(readFile: noFile))
        #expect(e.port == 47821 && e.token == token && e.session == sid)
        // --url wins over CODD_HOOK_URL; localhost is fine; the path does not matter.
        let f = try #require(StatusLineCommand(arguments: ["x", "--url", "http://localhost:5000/anything"], environment: lookup(sessionEnv))
            .endpoint(readFile: noFile))
        #expect(f.port == 5000)
        // A session id that the server would refuse is left out instead.
        var env = sessionEnv
        env["CODD_SESSION_ID"] = "not-a-uuid"
        #expect(try #require(StatusLineCommand(arguments: ["x"], environment: lookup(env)).endpoint(readFile: noFile)).session == nil)
        env["CODD_SESSION_ID"] = nil
        #expect(try #require(StatusLineCommand(arguments: ["x"], environment: lookup(env)).endpoint(readFile: noFile)).session == nil)

        func skip(_ env: [String: String]) -> StatusLineCommand.Skip? {
            if case .failure(let s) = StatusLineCommand(arguments: ["x"], environment: lookup(env)).resolveEndpoint(readFile: noFile) { return s }
            return nil
        }
        #expect(skip([:]) == .noEndpoint)
        #expect(skip(["CODD_HOOK_URL": "http://example.com:1/hooks", "CODD_HOOK_TOKEN": token]) == .notLoopbackURL)
        #expect(skip(["CODD_HOOK_URL": "https://127.0.0.1:1/hooks", "CODD_HOOK_TOKEN": token]) == .notLoopbackURL)
        #expect(skip(["CODD_HOOK_URL": "http://127.0.0.1:1/hooks"]) == .missingToken)
        #expect(skip(["CODD_HOOK_URL": "http://127.0.0.1:1/hooks", "CODD_HOOK_TOKEN": "a\r\nX-Evil: 1"]) == .missingToken)
    }

    @Test func globalEndpointReadsConfigJSON() throws {
        // What HookConfigStore writes (JSONEncoder, pretty printed, sorted keys).
        let config = Array("{\n  \"port\" : 47821,\n  \"token\" : \"\(token)\",\n  \"v\" : 1\n}\n".utf8)
        var paths: [String] = []
        func reader(_ bytes: [UInt8]?) -> (String) -> [UInt8]? { { paths.append($0); return bytes } }
        var env = sessionEnv // CODD_HOOK_URL / CODD_SESSION_ID of some other session must not matter
        env["CODD_HOOK_URL"] = "http://127.0.0.1:1/hooks"
        let command = StatusLineCommand(arguments: ["x", "--data-root", "/data/root/"], environment: lookup(env))
        let e = try #require(command.endpoint(readFile: reader(config)))
        #expect(e.port == 47821 && e.token == token && e.session == nil)
        #expect(paths == ["/data/root/config.json"])

        func skip(_ bytes: [UInt8]?) -> StatusLineCommand.Skip? {
            if case .failure(let s) = command.resolveEndpoint(readFile: { _ in bytes }) { return s }
            return nil
        }
        #expect(skip(nil) == .configUnreadable)
        #expect(skip(Array(repeating: 0x20, count: 4097)) == .configUnreadable)
        for bad in [#"{"port":0,"token":"t"}"#, #"{"port":70000,"token":"t"}"#, #"{"port":"47821","token":"t"}"#,
                    #"{"port":47821.5,"token":"t"}"#, #"{"port":47821}"#, #"{"port":47821,"token":"a\r\nb"}"#,
                    #"{"port":47821,"token":""}"#, #"{"port":47821,"token":7}"#, "[]", #"{"port":47821,"token":"t""#] {
            #expect(skip(Array(bad.utf8)) == .configInvalid, "\(bad)")
        }
        #expect(skip(Array(#"{"token":"t","port":1,"extra":{"x":[1]}}"#.utf8)) == nil)
    }

    @Test func reportBodyForwardsRateLimitsVerbatim() {
        let stdin = #"{"session_id":"11111111-aaaa-4aaa-8aaa-111111111111","cwd":"/x","rate_limits": {"five_hour": {"used_percentage": 9.5, "resets_at": 1792042740},"seven_day":{"used_percentage":85,"resets_at":1792296000}},"model":{"id":"m"}}"#
        var env = sessionEnv
        env["CLAUDE_CONFIG_DIR"] = "/Users/u/.claude-swap-backup/sessions/3-work-example-com"
        let body = StatusLineCommand(arguments: ["x"], environment: lookup(env)).reportBody(stdin: Array(stdin.utf8))
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"v":1,"session_id":"11111111-aaaa-4aaa-8aaa-111111111111","config_key":"cswap-3","rate_limits":{"five_hour": {"used_percentage": 9.5, "resets_at": 1792042740},"seven_day":{"used_percentage":85,"resets_at":1792296000}}}"#)
        #expect(JSONScan.members(body) != nil)
    }

    @Test func reportBodyNulls() {
        let command = StatusLineCommand(arguments: ["x"], environment: lookup(sessionEnv))
        func body(_ s: String) -> String { String(decoding: command.reportBody(stdin: Array(s.utf8)), as: UTF8.self) }
        let empty = #"{"v":1,"session_id":null,"config_key":"default","rate_limits":null}"#
        #expect(body(#"{"session_id":"s1","cwd":"/x"}"#) == #"{"v":1,"session_id":"s1","config_key":"default","rate_limits":null}"#)
        #expect(body("") == empty)
        #expect(body("not json") == empty)
        #expect(body(#"{"session_id":"s1","rate_limits":{"five_hour":"#) == empty) // truncated
        #expect(body(#"{"session_id":42,"rate_limits":null}"#) == empty)
        #expect(body(#"{"session_id":""# + String(repeating: "x", count: 300) + #""}"#) == empty)
        // Whatever Claude put in rate_limits is forwarded; the server decides what it means.
        #expect(body(#"{"rate_limits":"weird"}"#) == #"{"v":1,"session_id":null,"config_key":"default","rate_limits":"weird"}"#)
    }

    @Test func reportBodyStaysWithinTheEndpointLimit() {
        let command = StatusLineCommand(arguments: ["x"], environment: lookup(sessionEnv))
        let huge = #"{"session_id":"s","rate_limits":{"pad":""# + String(repeating: "y", count: 70_000) + #""}}"#
        let body = command.reportBody(stdin: Array(huge.utf8))
        #expect(String(decoding: body, as: UTF8.self) == #"{"v":1,"session_id":"s","config_key":"default","rate_limits":null}"#)
        // Exactly at the limit still carries it.
        let overhead = #"{"v":1,"session_id":"s","config_key":"default","rate_limits":{"pad":""}}"#.utf8.count
        let fits = #"{"session_id":"s","rate_limits":{"pad":""# + String(repeating: "y", count: StatusLineCommand.maxReportBytes - overhead) + #""}}"#
        #expect(command.reportBody(stdin: Array(fits.utf8)).count == StatusLineCommand.maxReportBytes)
        let over = #"{"session_id":"s","rate_limits":{"pad":""# + String(repeating: "y", count: StatusLineCommand.maxReportBytes - overhead + 1) + #""}}"#
        #expect(command.reportBody(stdin: Array(over.utf8)).count < 100)
    }

    @Test func requestBytes() throws {
        let command = StatusLineCommand(arguments: ["x"], environment: lookup(sessionEnv))
        let (port, bytes) = try command.request(stdin: Array("{}".utf8), readFile: { _ in nil }).get()
        #expect(port == 47821)
        let body = #"{"v":1,"session_id":null,"config_key":"default","rate_limits":null}"#
        #expect(String(decoding: bytes, as: UTF8.self)
            == "POST /statusline HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nContent-Type: application/json\r\n"
            + "X-CODD-Token: \(token)\r\nX-CODD-Session: \(sid)\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\nUser-Agent: codd-statusline/1\r\n\r\n" + body)
        // Global mode: no session header at all.
        let global = StatusLineCommand(arguments: ["x", "--data-root", "/r"], environment: lookup(sessionEnv))
        let config = Array(#"{"port":47900,"token":"\#(token)"}"#.utf8)
        let (gport, gbytes) = try global.request(stdin: [], readFile: { _ in config }).get()
        #expect(gport == 47900)
        let text = String(decoding: gbytes, as: UTF8.self)
        #expect(text.hasPrefix("POST /statusline HTTP/1.1\r\nHost: 127.0.0.1:47900\r\n"))
        #expect(!text.contains("X-CODD-Session"))
        #expect(text.contains("X-CODD-Token: \(token)\r\n"))
    }
}

@Suite("config.json reader (global mode)")
struct StatusLineConfigFileTests {
    /// A fresh directory under $TMPDIR (Darwin only; this test target has no Foundation).
    func tempDir() throws -> String {
        let base = (getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp/") + "codd-statusline-tests-XXXXXX"
        var template = Array(base.utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        try #require(made != nil)
        return String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func write(_ path: String, _ bytes: [UInt8]) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    @Test func readsSmallRegularFilesOnly() throws {
        let dir = try tempDir()
        defer {
            for name in ["config.json", "big.json", "link.json"] { unlink(dir + "/" + name) }
            rmdir(dir)
        }
        let config = Array(#"{"port":47821,"token":"t","v":1}"#.utf8)
        write(dir + "/config.json", config)
        #expect(StatusLineConfigFile.read(dir + "/config.json") == config)
        write(dir + "/big.json", Array(repeating: 0x20, count: 4097))
        #expect(StatusLineConfigFile.read(dir + "/big.json") == nil)
        #expect(StatusLineConfigFile.read(dir + "/big.json", limit: 5000)?.count == 4097)
        symlink(dir + "/config.json", dir + "/link.json")
        #expect(StatusLineConfigFile.read(dir + "/link.json") == nil) // a symlink is not followed
        #expect(StatusLineConfigFile.read(dir + "/missing.json") == nil)
        #expect(StatusLineConfigFile.read(dir) == nil) // a directory
        #expect(StatusLineCommand.configPath(dataRoot: dir + "//") == dir + "/config.json")
    }
}

@Suite("codd-statusline process helpers")
struct StatusLineProcessTests {
    @Test func exitCodes() {
        #expect(StatusLineProcess.exitCode(0) == 0)
        #expect(StatusLineProcess.exitCode(3 << 8) == 3)
        #expect(StatusLineProcess.exitCode(255 << 8) == 255)
        #expect(StatusLineProcess.exitCode(SIGTERM) == 143)
        #expect(StatusLineProcess.exitCode(SIGKILL | 0x80) == 137) // core-dump bit ignored
    }
}
