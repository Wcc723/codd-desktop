import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// codd-holderctl end to end. `attach` is exercised inside another holder, so its stdin/stdout are a
/// real PTY (raw mode, SIGWINCH, detach key).
@Suite("codd-holderctl", .serialized, .timeLimit(.minutes(2)))
struct HolderCtlTests {
    @Test("attach bridges a terminal: input, output, resize, ctrl-\\ detaches")
    func attachBridge() throws {
        let inner = try TestSession(["/bin/cat"])
        let outer = try TestSession([TestBinaries.ctl, "attach", "--socket", inner.socketPath], cols: 90, rows: 30)
        let (connection, _) = try outer.attach(from: 0)

        // Attached once the inner holder reports busy; give ctl a moment to enter raw mode.
        #expect(waitFor(timeoutMilliseconds: 5000) { isAttached(inner.socketPath) })
        Clock.sleep(milliseconds: 150)
        #expect(waitFor { inner.meta?.cols == 90 && inner.meta?.rows == 30 }, "attach sends its tty size")

        try connection.send(.input(flags: [], bytes: Array("bridged\r".utf8)))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("bridged\r\nbridged\r\n") })

        try connection.send(.resize(WindowSize(cols: 100, rows: 35)))
        #expect(waitFor { inner.meta?.cols == 100 && inner.meta?.rows == 35 }, "SIGWINCH becomes RESIZE")

        try connection.send(.input(flags: [], bytes: [0x1C]))
        #expect(try connection.collect(into: &capture) { $0.exit != nil })
        #expect(capture.exit == ExitInfo(status: 0, signaled: false))
        #expect(capture.text.contains("[detached]"))
        // The inner session keeps running and accepts a new client.
        let (again, welcome) = try inner.connect()
        #expect(!welcome.exited)
        again.close()
    }

    @Test("send --submit, tail --no-follow, list, kill --signal")
    func nonInteractiveCommands() throws {
        let session = try TestSession(["/bin/cat"])
        let sent = try runCommand(TestBinaries.ctl, ["send", "--socket", session.socketPath, "--submit", "via-ctl"])
        #expect(sent.status == 0)
        var tailed = ""
        #expect(waitFor {
            tailed = (try? runCommand(TestBinaries.ctl, [
                "tail", "--socket", session.socketPath, "--from", "start", "--no-follow",
            ]).output) ?? ""
            return tailed.contains("via-ctl\r\nvia-ctl\r\n")
        })

        let escaped = try runCommand(TestBinaries.ctl, ["send", "--socket", session.socketPath, "--escapes", "a\\x41\\n"])
        #expect(escaped.status == 0)

        let table = try runCommand(TestBinaries.ctl, ["list", "--root", session.root.path + "/sessions"]).output
        #expect(table.contains("test-session"))
        #expect(table.contains("RUNNING"))
        let json = try JSONValue.parse(try runCommand(TestBinaries.ctl, ["list", "--root", session.root.path + "/sessions", "--json"]).output)
        #expect(json.arrayValue?.first?["alive"]?.boolValue == true)
        #expect(json.arrayValue?.first?["holderPid"]?.intValue == Int(session.pid))

        let killed = try runCommand(TestBinaries.ctl, ["kill", "--socket", session.socketPath, "--signal", "INT"])
        #expect(killed.status == 0)
        #expect(waitFor { session.meta?.exited == true })
        #expect(session.meta?.signaled == true && session.meta?.exitStatus == SIGINT)
        let ended = try runCommand(TestBinaries.ctl, ["list", "--root", session.root.path + "/sessions"]).output
        #expect(ended.contains("EXITED sig 2"))
    }

    @Test("usage errors exit 64")
    func usageErrors() throws {
        #expect(try runCommand(TestBinaries.ctl, []).status == 64)
        #expect(try runCommand(TestBinaries.ctl, ["bogus"]).status == 64)
        #expect(try runCommand(TestBinaries.ctl, ["spawn", "--dir", "/tmp/x", "--socket", "/tmp/x.sock"]).status == 64)
        #expect(try runCommand(TestBinaries.holder, ["--session", "x"]).status == 64)
    }
}

/// True when the holder refuses a plain HELLO with `busy` (another client is attached).
func isAttached(_ socketPath: String) -> Bool {
    guard let probe = try? HolderConnection(socketPath: socketPath) else { return false }
    do {
        _ = try probe.handshake(client: "probe")
        return false
    } catch {
        if case .rejected(let info) = error { return info.code == HolderErrorCode.busy }
        return false
    }
}
