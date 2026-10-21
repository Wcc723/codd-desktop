import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// What the child gets (environment, terminal settings) and what survives a deleted run directory.
@Suite("Child setup and socket supervision", .serialized, .timeLimit(.minutes(2)))
struct ChildSetupTests {
    @Test("the child gets exactly the --env-file environment, nothing inherited from the spawner")
    func exactEnvironment() throws {
        // The test runner's own environment (XPC_*, __CF*, DYLD_* under Xcode, …) must not leak through.
        let environment = testEnvironment + ["CODD_MARK=env-file", "WITH_SPACES=a b  c"]
        let session = try TestSession(["/usr/bin/env"], environment: environment)
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        // `env` prints in environ order, so the last entry ends the output. (Waiting for EXIT instead
        // is racy: an exit between WELCOME and ATTACH sends EXIT before the replayed output.)
        #expect(try connection.collect(into: &capture) { $0.text.contains("WITH_SPACES=a b  c\r\n") })
        let printed = capture.text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(printed.sorted() == environment.sorted())
    }

    @Test("the PTY is the child's controlling terminal and has IUTF8 set")
    func terminalSettings() throws {
        // `tty` names the controlling terminal; `stty -a` lists iutf8 (or -iutf8 when it is off).
        let session = try TestSession(["/bin/sh", "-c", "tty; stty -a; echo TTY-DONE; exec cat"])
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("TTY-DONE") })
        let words = capture.text.split { $0 == " " || $0 == "\r" || $0 == "\n" || $0 == "\r\n" || $0 == "\t" }
        #expect(capture.text.hasPrefix("/dev/ttys"), "\(capture.text.prefix(40).debugDescription)")
        #expect(words.contains("iutf8"), "IUTF8 keeps backspace over multi-byte input (Zhuyin) correct")
        #expect(!words.contains("-iutf8"))
    }

    @Test("the holder re-creates a deleted run directory (0700) and re-binds")
    func rebindsAfterRunDirectoryRemoval() throws {
        let session = try TestSession(["/bin/cat"])
        let runDirectory = PosixFile.directoryName(session.socketPath)
        try FileManager.default.removeItem(atPath: runDirectory)
        #expect(waitFor(timeoutMilliseconds: 3000) { UnixSocket.isLive(path: session.socketPath) })
        #expect(permissions(runDirectory) == 0o700)
        #expect(permissions(session.socketPath) == 0o600)
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        try connection.roundTrip(token: 11, into: &capture)

        // The new directory is watched too: a second removal is noticed as well.
        connection.close()
        try FileManager.default.removeItem(atPath: runDirectory)
        #expect(waitFor(timeoutMilliseconds: 3000) { UnixSocket.isLive(path: session.socketPath) })
    }
}

/// Silent connections are closed after the 5 s HELLO deadline (own suite: it waits, so it runs in
/// parallel with the others).
@Suite("Handshake deadline", .timeLimit(.minutes(1)))
struct HandshakeDeadlineTests {
    @Test("a connection that never sends HELLO gets hello-timeout and is closed; the session is fine")
    func helloTimeout() throws {
        let session = try TestSession(["/bin/cat"])
        let silent = try HolderConnection(socketPath: session.socketPath)
        var capture = StreamCapture()
        var closed = false
        do {
            _ = try silent.collect(into: &capture, timeoutMilliseconds: 9000) { _ in false }
        } catch HolderClientError.closed {
            closed = true
        }
        #expect(capture.errors.first?.code == HolderErrorCode.helloTimeout)
        #expect(closed, "the holder closes the connection after the ERROR")
        let (healthy, _) = try session.attach(from: 0)
        var ping = StreamCapture()
        try healthy.roundTrip(token: 12, into: &ping)
    }
}
