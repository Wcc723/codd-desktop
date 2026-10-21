import CoddCore
import Darwin
import Foundation
import Testing
@testable import CoddHooks

/// Runs the built `codd-statusline` binary against a real server, with fake chains only (`printf`,
/// `cat`, `sleep`; never a real status line or claude).
@Suite("codd-statusline end to end", .serialized) // timing bounds: do not compete with each other
struct CoddStatusLineEndToEndTests {
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    static func binary() throws -> URL {
        try CoddHookEndToEndTests.binary(named: "codd-statusline", overrideVariable: "CODD_STATUSLINE_BINARY")
    }

    struct Run {
        var status: Int32
        var reason: Process.TerminationReason
        var stdout: Data
        var stderr: Data
        var elapsed: TimeInterval
        var out: String { String(decoding: stdout, as: UTF8.self) }
        var err: String { String(decoding: stderr, as: UTF8.self) }
    }

    func run(_ arguments: [String] = [], stdin: Data, environment: [String: String]) throws -> Run {
        let process = Process()
        process.executableURL = try Self.binary()
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, reason: process.terminationReason, stdout: out, stderr: err,
                   elapsed: Date().timeIntervalSince(start))
    }

    /// The fastest of `attempts` runs (timing assertions on a loaded machine running tests in parallel).
    func fastest(_ attempts: Int = 5, _ body: () throws -> Run) rethrows -> Run {
        var best: Run?
        for _ in 0..<attempts {
            let r = try body()
            if best == nil || r.elapsed < best!.elapsed { best = r }
        }
        return best!
    }

    /// What Claude Code writes on stdin (2.1.302 shape; only the fields CODD reads matter).
    func claudeInput(fiveUsed: Double = 9.5, sevenUsed: Double = 85, withLimits: Bool = true) -> Data {
        let limits = withLimits
            ? #","rate_limits":{"five_hour":{"used_percentage":\#(fiveUsed),"resets_at":1792042740},"seven_day":{"used_percentage":\#(sevenUsed),"resets_at":1792296000}}"#
            : ""
        return Data((#"{"session_id":"11111111-aaaa-4aaa-8aaa-111111111111","transcript_path":"/x/t.jsonl","cwd":"/x","model":{"id":"m","display_name":"M"},"workspace":{"current_dir":"/x"},"version":"2.1.302","cost":{"total_cost_usd":0.1}"#
            + limits + "}").utf8)
    }

    func env(port: UInt16?, token: String = testToken, chain: String? = nil, configDir: String? = nil,
             extra: [String: String] = [:]) -> [String: String] {
        var e = ["HOME": "/Users/u", "PATH": "/usr/bin:/bin", CoddEnvironmentName.hookToken: token, CoddEnvironmentName.sessionId: sid]
        if let port { e["CODD_HOOK_URL"] = "http://127.0.0.1:\(port)/hooks" }
        if let chain { e["CODD_STATUSLINE_CHAIN"] = Data(chain.utf8).base64EncodedString() }
        if let configDir { e["CLAUDE_CONFIG_DIR"] = configDir }
        for (k, v) in extra { e[k] = v }
        return e
    }

    func makeServer() async throws -> (HookServer, UInt16, Collector<StatusLineReport>) {
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        return (server, port, Collector(server.statusLines))
    }

    /// `kill(-pgid, 0)` fails with ESRCH once no process of the group is left.
    func groupGone(_ pgid: pid_t) async -> Bool {
        await eventually(timeout: 3) { kill(-pgid, 0) != 0 && errno == ESRCH }
    }

    @Test func reportArrivesWithSessionKeyAndWindows() async throws {
        let (server, port, reports) = try await makeServer()
        defer { Task { await server.finish() } }
        let r = try run(stdin: claudeInput(), environment: env(port: port, configDir: "/Users/u/.claude-swap-backup/sessions/2-north-example-com"))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)  // no chain: nothing at all on stdout
        #expect(r.stderr.isEmpty)  // silent without CODD_HOOK_DEBUG
        #expect(await reports.wait(count: 1))
        let report = try #require(reports.values.first)
        #expect(report.sessionID == UUID(uuidString: sid))
        #expect(report.configKey == "cswap-2")
        #expect(report.claudeSessionId == "11111111-aaaa-4aaa-8aaa-111111111111")
        #expect(report.fiveHour == StatusLineWindow(usedPercent: 9.5, resetsAt: Date(timeIntervalSince1970: 1_792_042_740)))
        #expect(report.sevenDay == StatusLineWindow(usedPercent: 85, resetsAt: Date(timeIntervalSince1970: 1_792_296_000)))
        // Without rate_limits (Claude omits it until a window is known) the report still arrives.
        let r2 = try run(stdin: claudeInput(withLimits: false), environment: env(port: port))
        #expect(r2.status == 0 && r2.stdout.isEmpty)
        #expect(await reports.wait(count: 2))
        #expect(reports.values.last?.hadRateLimits == false)
        #expect(reports.values.last?.configKey == "default")
        #expect(await server.statistics().statusLinesAccepted == 2)
    }

    @Test func chainOutputPassesThroughByteForByte() async throws {
        let (server, port, reports) = try await makeServer()
        defer { Task { await server.finish() } }
        let r = try run(stdin: claudeInput(), environment: env(port: port, chain: "printf 'SL-%s' ok"))
        #expect(r.status == 0)
        #expect(r.stdout == Data("SL-ok".utf8))
        #expect(r.stderr.isEmpty)
        #expect(await reports.wait(count: 1))
        // Multi-line, non-ASCII and escape sequences are untouched.
        let r2 = try run(stdin: claudeInput(), environment: env(port: port, chain: #"printf '\033[32m中文\033[0m\nline 2\n'"#))
        #expect(r2.stdout == Data("\u{1B}[32m中文\u{1B}[0m\nline 2\n".utf8))
    }

    @Test func chainReceivesTheSameStdin() async throws {
        let (server, port, reports) = try await makeServer()
        defer { Task { await server.finish() } }
        let input = claudeInput() + Data("\n".utf8)
        let r = try run(stdin: input, environment: env(port: port, chain: "cat"))
        #expect(r.status == 0)
        #expect(r.stdout == input)
        #expect(await reports.wait(count: 1))
        // An input larger than the pipe buffer still reaches a reading chain in full.
        let big = Data((#"{"pad":""# + String(repeating: "p", count: 200_000) + #""}"#).utf8)
        let r2 = try run(stdin: big, environment: env(port: port, chain: "cat"))
        #expect(r2.stdout == big)
    }

    @Test func chainExitStatusIsOurs() async throws {
        let (server, port, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let r = try run(stdin: claudeInput(), environment: env(port: port, chain: "printf x; exit 3"))
        #expect(r.status == 3 && r.reason == .exit)
        #expect(r.out == "x")
        // A chain killed by a signal: 128 + n, like a shell.
        let k = try run(stdin: claudeInput(), environment: env(port: port, chain: "kill -TERM $$"))
        #expect(k.status == 143 && k.reason == .exit)
    }

    @Test func noChainNoEndpointPrintsNothing() throws {
        let r = try run(stdin: claudeInput(), environment: ["HOME": "/Users/u", "PATH": "/usr/bin:/bin"])
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty && r.stderr.isEmpty)
        let debug = try run(stdin: claudeInput(), environment: ["CODD_HOOK_DEBUG": "1"])
        #expect(debug.stdout.isEmpty)
        #expect(debug.err.contains("report not sent"))
        // Garbage on stdin is no failure either.
        let junk = try run(stdin: Data("\u{0}\u{FF}not json".utf8), environment: env(port: 1))
        #expect(junk.status == 0 && junk.stdout.isEmpty)
    }

    @Test func endpointDownStillPrintsTheChainQuickly() throws {
        let port = freeNonEphemeralPort()
        let r = try fastest { try run(stdin: claudeInput(), environment: env(port: port, chain: "printf 'SL-%s' ok")) }
        #expect(r.status == 0)
        #expect(r.out == "SL-ok")
        #expect(r.elapsed < 0.05, "\(r.elapsed)")
        let debug = try run(stdin: claudeInput(), environment: env(port: port, extra: ["CODD_HOOK_DEBUG": "1"]))
        #expect(debug.err.contains("report failed: connect"), "\(debug.err)")
    }

    @Test func stalledEndpointCostsAtMostThePostBudget() throws {
        let stalled = try StalledListener()
        defer { stalled.close() }
        let r = try fastest(2) { try run(stdin: claudeInput(), environment: env(port: stalled.port, extra: ["CODD_HOOK_DEBUG": "1"])) }
        #expect(r.status == 0 && r.stdout.isEmpty)
        #expect(r.elapsed >= 0.29 && r.elapsed < 0.4, "\(r.elapsed)")
        #expect(r.err.contains("timedOut"), "\(r.err)")
        // With a chain: its output is printed and the run is the budget plus the chain.
        let c = try fastest(2) { try run(stdin: claudeInput(), environment: env(port: stalled.port, chain: "printf 'SL-%s' ok")) }
        #expect(c.out == "SL-ok" && c.status == 0)
        #expect(c.elapsed < 0.45, "\(c.elapsed)")
    }

    @Test func wrongTokenIsRefusedButTheChainRuns() async throws {
        let (server, port, reports) = try await makeServer()
        defer { Task { await server.finish() } }
        let r = try run(stdin: claudeInput(), environment: env(port: port, token: String(repeating: "cd", count: 32),
                                                               chain: "printf ok", extra: ["CODD_HOOK_DEBUG": "1"]))
        #expect(r.status == 0 && r.out == "ok")
        #expect(r.err.contains("endpoint answered 401"), "\(r.err)")
        try await Task.sleep(for: .milliseconds(50))
        #expect(reports.count == 0)
    }

    @Test func chainThatNeverExitsIsKilledWithItsGroup() async throws {
        let r = try run(stdin: claudeInput(), environment: env(port: nil, chain: "echo $$; sleep 30 & sleep 30",
                                                               extra: ["CODD_STATUSLINE_TIMEOUT_MS": "300", "CODD_HOOK_DEBUG": "1"]))
        #expect(r.status == 143, "\(r.err)")
        #expect(r.elapsed >= 0.29 && r.elapsed < 1.2, "\(r.elapsed)")
        #expect(r.err.contains("timed out after 300 ms"))
        let pgid = try #require(pid_t(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await groupGone(pgid)) // the background sleep went with it
    }

    @Test func chainIgnoringSIGTERMIsKilledAfterTheGrace() async throws {
        let r = try run(stdin: claudeInput(), environment: env(port: nil, chain: "trap '' TERM; echo $$; sleep 30",
                                                               extra: ["CODD_STATUSLINE_TIMEOUT_MS": "300"]))
        #expect(r.status == 137)
        #expect(r.elapsed >= 1.25 && r.elapsed < 2.5, "\(r.elapsed)")
        let pgid = try #require(pid_t(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await groupGone(pgid))
    }

    @Test func signalsAreForwardedToTheChainGroup() async throws {
        let process = Process()
        process.executableURL = try Self.binary()
        process.environment = env(port: nil, chain: "echo $$; sleep 30")
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(claudeInput())
        try input.fileHandleForWriting.close()
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let pgid = try #require(pid_t(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = Date()
        process.terminate() // SIGTERM, as Claude does when a newer status-line run supersedes this one
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 1)
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(await groupGone(pgid))
    }

    /// The fork race behind the re-sent signal: the group is signalled right as `sh` forks, many
    /// times over; no member may survive any run.
    @Test func forwardedSignalCatchesMembersForkedMeanwhile() async throws {
        for _ in 0..<10 {
            let process = Process()
            process.executableURL = try Self.binary()
            process.environment = env(port: nil, chain: "echo $$; while :; do /bin/sleep 30 & wait; done")
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            try input.fileHandleForWriting.close()
            var line = Data()
            while !line.contains(0x0A) {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                line.append(chunk)
            }
            let pgid = try #require(pid_t(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            process.terminate()
            process.waitUntilExit()
            #expect(process.terminationStatus == 1)
            #expect(await groupGone(pgid), "group \(pgid)")
        }
    }

    @Test func chainInheritsTheEnvironmentExceptItsOwnChain() throws {
        let r = try run(stdin: claudeInput(), environment: env(port: nil, chain: #"printf '%s|%s|%s' "$CODD_SESSION_ID" "$HOME" "${CODD_STATUSLINE_CHAIN-unset}""#,
                                                               extra: ["MY_VAR": "1"]))
        #expect(r.out == "\(sid)|/Users/u|unset")
        // A chain that runs codd-statusline again (a hand-written wrapper) does not recurse.
        let binary = try Self.binary().path
        let nested = try run(stdin: claudeInput(), environment: env(port: nil, chain: "printf 'outer '; '\(binary)'; printf ' done'"))
        #expect(nested.out == "outer  done")
        #expect(nested.status == 0)
    }

    @Test func chainGetsDefaultSIGPIPEAndNoExtraDescriptors() throws {
        // With SIGPIPE still ignored, `yes` would report "Broken pipe" on stderr.
        let r = try run(stdin: claudeInput(), environment: env(port: nil, chain: "yes | head -c 5"))
        #expect(r.status == 0)
        #expect(r.out == "y\ny\ny")
        #expect(r.stderr.isEmpty, "\(r.err)")
        // Only fds 0-2 reach the chain.
        let fds = try run(stdin: claudeInput(),
                          environment: env(port: nil, chain: "for fd in 3 4 5 6 7 8 9; do if { true >&$fd; } 2>/dev/null; then echo open $fd; fi; done"))
        #expect(fds.status == 0)
        #expect(fds.stdout.isEmpty, "\(fds.out)")
    }

    @Test func globalModeReadsConfigAndSendsNoSession() async throws {
        let (server, port, reports) = try await makeServer()
        defer { Task { await server.finish() } }
        let root = try TempDir("codd-statusline-root")
        defer { root.remove() }
        try Data(#"{"port":\#(port),"token":"\#(testToken)","v":1}"#.utf8).write(to: root.file("config.json"))
        chmod(root.file("config.json").path, 0o600)
        // A claude CODD did not start: no CODD_HOOK_URL; a stray CODD_SESSION_ID must not be sent.
        var e = env(port: nil)
        e[CoddEnvironmentName.hookToken] = nil
        let chain = Data("printf 'G-%s' ok".utf8).base64EncodedString()
        let r = try run(["--data-root", root.url.path, "--chain-b64", chain], stdin: claudeInput(fiveUsed: 33), environment: e)
        #expect(r.status == 0)
        #expect(r.out == "G-ok")
        #expect(await reports.wait(count: 1))
        let report = try #require(reports.values.first)
        #expect(report.sessionID == nil)
        #expect(report.configKey == "default")
        #expect(report.fiveHour?.usedPercent == 33)
        // A missing config.json: no report, the chain still runs.
        let missing = try run(["--data-root", root.url.path + "/nope", "--chain-b64", chain], stdin: claudeInput(), environment: e)
        #expect(missing.out == "G-ok" && missing.status == 0)
    }
}
