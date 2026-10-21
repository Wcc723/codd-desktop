import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// End-to-end tests against the real built `codd-holder` (children: /bin/sh, cat, the test helper).
@Suite("Holder integration", .serialized, .timeLimit(.minutes(2)))
struct HolderIntegrationTests {
    @Test("output arrives, WELCOME describes the session")
    func outputArrives() throws {
        let session = try TestSession(["/bin/sh", "-c", "printf 'hello-holder\\n'; exec cat"], cols: 91, rows: 33)
        let (connection, welcome) = try session.attach(from: 0)
        #expect(welcome.proto == 1)
        #expect(welcome.session == "test-session")
        #expect(welcome.cols == 91 && welcome.rows == 33)
        #expect(welcome.childPid > 0)
        #expect(!welcome.exited)
        #expect(welcome.caps.contains(HolderCapability.inputSubmit))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("hello-holder\r\n") })
        #expect(capture.firstOffset == 0)
        #expect(capture.discontinuities == 0)
        let meta = try #require(session.meta)
        #expect(meta.holderPid == session.pid)
        #expect(meta.childPid == welcome.childPid)
        #expect(meta.argv.first == "/bin/sh")
        #expect(!meta.exited)
        #expect(permissions(session.socketPath) == 0o600)
        #expect(permissions(PosixFile.directoryName(session.socketPath)) == 0o700)
        #expect(permissions(session.sessionDirectory) == 0o700)
        #expect(permissions(session.sessionDirectory + "/ring") == 0o600)
        #expect(permissions(session.sessionDirectory + "/meta.json") == 0o600)
    }

    @Test("detach and reattach: replay from an offset and from the latest resync point")
    func reattachReplays() throws {
        let script = "printf AAA; printf '\\033[2J'; printf BBB; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        var first = StreamCapture()
        do {
            let (connection, _) = try session.attach(from: 0)
            #expect(try connection.collect(into: &first) { $0.text.contains("BBB") })
            try connection.send(.detach)
            // Output produced while detached must not be streamed to this connection.
            try connection.send(Message.inputMessages(Array("while-detached\n".utf8), submit: false))
            var detached = StreamCapture()
            try connection.roundTrip(token: 1, into: &detached)
            Clock.sleep(milliseconds: 100)
            _ = try connection.collect(into: &detached, timeoutMilliseconds: 200) { _ in false }
            #expect(detached.outputFrames == 0)
            connection.close()
        }
        let afterA: UInt64 = 3
        let resync: UInt64 = 7  // right after ESC [ 2 J

        let (fromOffset, welcome) = try session.attach(from: afterA)
        #expect(welcome.resync == resync)
        var replay = StreamCapture()
        #expect(try fromOffset.collect(into: &replay) { $0.text.contains("while-detached\r\nwhile-detached") })
        #expect(replay.firstOffset == afterA)
        #expect(replay.text.hasPrefix("\u{1B}[2JBBB"))
        fromOffset.close()

        let (latest, _) = try session.attach(from: Message.latestResync)
        var fromResync = StreamCapture()
        #expect(try latest.collect(into: &fromResync) { $0.text.contains("while-detached") })
        #expect(fromResync.firstOffset == resync)
        #expect(fromResync.text.hasPrefix("BBB"))
    }

    @Test("ATTACHED goes only to clients that list attach.ack, right before the attach's OUTPUT")
    func attachedIsOptIn() throws {
        let session = try TestSession(["/bin/sh", "-c", "printf AAA; printf '\\033[2J'; printf BBB; exec cat"])
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 10 })
        var frames: [Frame] = []
        func receiveFrames(_ connection: HolderConnection, until marker: String) throws {
            var text = ""
            let deadline = Clock.monotonicNanoseconds() + 5_000_000_000
            while !text.contains(marker), Clock.monotonicNanoseconds() < deadline {
                guard let message = try connection.receive(timeoutMilliseconds: 500) else { continue }
                frames.append(message.frame)
                if case .output(_, let bytes) = message { text += String(decoding: bytes, as: UTF8.self) }
            }
        }
        let plain = try HolderConnection(socketPath: session.socketPath)
        _ = try plain.handshake(client: "v1-client")
        try plain.send(.attach(fromOffset: Message.latestResync))
        try receiveFrames(plain, until: "BBB")
        #expect(!frames.contains { $0.type == .attached }, "a v1 client never sees ATTACHED")
        plain.close()

        frames = []
        let opted = try HolderConnection(socketPath: session.socketPath)
        let welcome = try opted.handshake(client: "acking", caps: [HolderCapability.attachAck])
        try opted.send(.attach(fromOffset: Message.latestResync))
        try receiveFrames(opted, until: "BBB")
        let first = try #require(frames.first)
        #expect(first.type == .attached)
        #expect(try AttachedInfo(payload: first.payload)
            == AttachedInfo(start: welcome.resync, replayEnd: 10, modes: TerminalModes(), currentModes: TerminalModes()))
        #expect(frames.dropFirst().first?.type == .output)
    }

    @Test("INPUT is echoed by the tty and by cat")
    func inputEchoThroughCat() throws {
        let session = try TestSession(["/bin/cat"])
        let (connection, _) = try session.attach(from: 0)
        try connection.send(.input(flags: [], bytes: Array("hello-input\n".utf8)))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("hello-input\r\nhello-input\r\n") })
    }

    @Test("submit flag: \\r is written 10 ms after the last payload byte, before later input")
    func submitFlag() throws {
        let session = try TestSession([TestBinaries.helper, "stamp"])
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        try connection.send(.input(flags: .submit, bytes: Array("xy".utf8)))
        try connection.send(.input(flags: [], bytes: Array("z".utf8)))
        #expect(try connection.collect(into: &capture) { $0.text.contains("S 7a ") })
        let stamps = parseStamps(capture.text)
        #expect(stamps.map(\.byte) == [0x78, 0x79, 0x0D, 0x7A], "later input must wait behind the submit")
        if stamps.count == 4 {
            let delay = Double(stamps[2].nanoseconds - stamps[1].nanoseconds) / 1e6
            #expect(delay >= 9.5, "\\r arrived \(delay) ms after the last byte")
            #expect(delay < 200)
        }

        let catSession = try TestSession(["/bin/cat"])
        let (catConnection, _) = try catSession.attach(from: 0)
        try catConnection.send(.input(flags: .submit, bytes: Array("submitted".utf8)))
        var catCapture = StreamCapture()
        #expect(try catConnection.collect(into: &catCapture) { $0.text.contains("submitted\r\nsubmitted\r\n") })
    }

    @Test("100 KB paste through cat arrives intact")
    func largePaste() throws {
        let session = try TestSession(["/bin/sh", "-c", "stty raw -echo; printf READY; exec cat"])
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        var random = SplitMix64(state: 99)
        let paste = (0..<100_000).map { _ in UInt8.random(in: 0x20...0x7E, using: &random) }
        let start = capture.bytes.count
        try connection.send(Message.inputMessages(paste, submit: false))
        #expect(try connection.collect(into: &capture, timeoutMilliseconds: 20_000) { $0.bytes.count - start >= paste.count })
        let echoed = Array(capture.bytes[start...])
        #expect(echoed.count == paste.count)
        #expect(fnv1a(echoed) == fnv1a(paste))
    }

    @Test("RESIZE is seen by stty size")
    func resizeSeenByStty() throws {
        let session = try TestSession(["/bin/sh"])
        let (connection, _) = try session.attach(from: 0)
        try connection.send(.resize(WindowSize(cols: 101, rows: 41)))
        try connection.send(.input(flags: [], bytes: Array("stty size\n".utf8)))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("41 101") })
        let meta = try #require(waitFor { session.meta.map { $0.cols == 101 } ?? false } ? session.meta : nil)
        #expect(meta.rows == 41)
    }

    @Test("OSC title / cwd and BEL become TITLE / CWD / BELL frames")
    func oscDetection() throws {
        let script = "printf '\\033]0;holder-title\\007'; printf '\\033]7;file://h/tmp/a%%20b\\033\\\\'; printf '\\007'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.titles.contains("holder-title") && !$0.cwds.isEmpty && $0.bells > 0 })
        #expect(capture.cwds.last == "/tmp/a b")
        connection.close()
        let (_, welcome) = try session.connect()
        #expect(welcome.title == "holder-title")
        #expect(welcome.cwd == "/tmp/a b")
        #expect(waitFor { session.meta?.title == "holder-title" })
    }

    @Test("EXIT carries the exit status or the signal", arguments: [
        (["/bin/sh", "-c", "exit 7"], ExitInfo(status: 7, signaled: false)),
        (["/bin/sh", "-c", "kill -9 $$"], ExitInfo(status: 9, signaled: true)),
        (["/nonexistent/program"], ExitInfo(status: 127, signaled: false)),
    ])
    func exitStatus(argv: [String], expected: ExitInfo) throws {
        let session = try TestSession(argv)
        let (connection, welcome) = try session.attach(from: 0)
        var capture = StreamCapture()
        if !welcome.exited {
            #expect(try connection.collect(into: &capture) { $0.exit != nil })
            #expect(capture.exit == expected)
        } else {
            #expect(welcome.exitStatus == expected.status)
            #expect(welcome.signaled == expected.signaled)
        }
        if argv[0].hasPrefix("/nonexistent") {
            _ = try connection.collect(into: &capture, timeoutMilliseconds: 500) { $0.text.contains("exec failed") }
            #expect(capture.text.contains("exec failed"))
        }
        let meta = try #require(waitFor { session.meta?.exited == true } ? session.meta : nil)
        #expect(meta.exitStatus == expected.status)
    }

    @Test("holder exits after the linger period once the child is gone and no client is attached")
    func exitLinger() throws {
        let session = try TestSession(["/bin/sh", "-c", "exit 3"], lingerMilliseconds: 300)
        let status = session.waitForExit(timeoutMilliseconds: 5000)
        #expect(status != nil)
        let meta = try #require(session.meta)
        #expect(meta.exited && meta.exitStatus == 3)
        #expect(meta.holderExited)
        #expect(!PosixFile.exists(session.socketPath), "socket removed on exit")
        #expect(PosixFile.exists(session.sessionDirectory + "/ring"), "ring stays")
    }

    @Test("the holder survives its spawner exiting (reparented to launchd)")
    func survivesSpawner() throws {
        let root = try TemporaryDirectory()
        let directory = root.path + "/sessions/x"
        let socket = root.path + "/run/x.sock"
        let result = try runCommand(TestBinaries.ctl, [
            "spawn", "--holder", TestBinaries.holder, "--dir", directory, "--socket", socket, "--session", "spawned",
            "--cwd", "/tmp", "--", "/bin/sh", "-c", "printf survived; exec cat",
        ])
        #expect(result.status == 0)
        // Cleanup first, from the pid ctl printed, so a failing assertion cannot leak the holder.
        let spawnedPid = result.output.split(separator: " ").first { $0.hasPrefix("pid=") }
            .flatMap { pid_t($0.dropFirst(4)) }
        defer {
            if let spawnedPid, ProcessQueries.isAlive(spawnedPid) { kill(spawnedPid, SIGKILL) }
        }
        let meta = try #require(SessionDirectory.readMeta(directory: directory), "meta.json exists once the socket accepts")
        #expect(meta.holderPid == spawnedPid)
        #expect(parentPID(of: meta.holderPid) == 1)
        let connection = try HolderConnection(socketPath: socket)
        _ = try connection.handshake()
        try connection.send(.attach(fromOffset: 0))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("survived") })
        connection.close()
        let records = try SessionDirectory.list(root: root.path + "/sessions")
        #expect(records.count == 1 && records[0].holderAlive)
        let killed = try runCommand(TestBinaries.ctl, ["kill", "--dir", directory])
        #expect(killed.status == 0)
        #expect(SessionDirectory.readMeta(directory: directory)?.holderExited == true)
    }

    @Test("the child sees no descriptors >= 3, even ones the holder inherited without CLOEXEC")
    func childHasNoExtraDescriptors() throws {
        let root = try TemporaryDirectory()
        let leak = open(root.path + "/leak", O_CREAT | O_RDWR, 0o600)  // deliberately no O_CLOEXEC
        #expect(leak >= 0)
        defer { Descriptor.closeQuietly(leak) }
        let session = try TestSession([TestBinaries.helper, "fds"], extraInheritedDescriptor: leak)
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        // "\r\n" is one Character in Swift, so look for the newline byte.
        #expect(try connection.collect(into: &capture) { $0.text.contains("FDS") && $0.bytes.contains(0x0A) })
        let line = capture.text.split(separator: "\r\n").first { $0.hasPrefix("FDS") }
        #expect(line == "FDS 0 1 2")
        #expect(try descriptorIsOpen(9, inProcess: session.pid), "the holder itself did inherit fd 9")
    }

    @Test("open-file soft limit is raised for the child")
    func fileLimitRaised() throws {
        let session = try TestSession(["/bin/sh", "-c", "echo LIMIT=$(ulimit -Sn); exec cat"], softFileLimit: 256)
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("LIMIT=") && $0.bytes.contains(0x0A) })
        let tail = capture.text.components(separatedBy: "LIMIT=").last ?? ""
        let value = String(tail.prefix { $0.isLetter || $0.isNumber })
        #expect(Int(value).map { $0 >= 10240 } ?? (value == "unlimited"), "child soft limit: \(value)")
    }

    @Test("takeover disconnects the previous client; without takeover a second client is refused")
    func takeover() throws {
        let session = try TestSession(["/bin/cat"])
        let (first, _) = try session.attach(from: 0)
        let refused = try HolderConnection(socketPath: session.socketPath)
        #expect(throws: HolderClientError.rejected(ErrorInfo(code: HolderErrorCode.busy, message: "session is attached by tests"))) {
            _ = try refused.handshake(client: "second", takeover: false)
        }
        let (second, welcome) = try session.connect(takeover: true, client: "third")
        #expect(welcome.session == "test-session")
        var old = StreamCapture()
        do {
            _ = try first.collect(into: &old) { !$0.errors.isEmpty }
            _ = try first.collect(into: &old, timeoutMilliseconds: 2000) { _ in false }
            Issue.record("the old client was not disconnected")
        } catch HolderClientError.closed {
            // expected
        }
        #expect(old.errors.first?.code == HolderErrorCode.takenOver)
        try second.send(.attach(fromOffset: 0))
        try second.send(.input(flags: [], bytes: Array("still-works\n".utf8)))
        var capture = StreamCapture()
        #expect(try second.collect(into: &capture) { $0.text.contains("still-works\r\nstill-works") })
    }

    @Test("frames before HELLO and garbage are rejected without hurting the session")
    func handshakeEnforcement() throws {
        let session = try TestSession(["/bin/cat"])
        let early = try HolderConnection(socketPath: session.socketPath)
        try early.send(.attach(fromOffset: 0))
        var capture = StreamCapture()
        _ = try? early.collect(into: &capture) { !$0.errors.isEmpty }
        #expect(capture.errors.first?.code == HolderErrorCode.helloRequired)

        let garbage = try HolderConnection(socketPath: session.socketPath)
        try Descriptor.writeAll(garbage.fd, [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01])
        var garbageCapture = StreamCapture()
        _ = try? garbage.collect(into: &garbageCapture) { !$0.errors.isEmpty }
        #expect(garbageCapture.errors.first?.code == HolderErrorCode.badFrame)

        let wrongProto = try HolderConnection(socketPath: session.socketPath)
        try wrongProto.send(.hello(Hello(proto: 99, client: "future")))
        var protoCapture = StreamCapture()
        _ = try? wrongProto.collect(into: &protoCapture) { !$0.errors.isEmpty }
        #expect(protoCapture.errors.first?.code == HolderErrorCode.unsupportedProto)

        let (healthy, _) = try session.attach(from: 0)
        var ping = StreamCapture()
        try healthy.roundTrip(token: 77, into: &ping)
    }

    @Test("SIGNAL goes to the foreground process group")
    func signalForeground() throws {
        let session = try TestSession(["/bin/cat"])
        let (connection, _) = try session.attach(from: 0)
        try connection.send(.signal(UInt8(SIGINT)))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.exit != nil })
        #expect(capture.exit == ExitInfo(status: SIGINT, signaled: true))
    }

    @Test("SIGNAL reaches the foreground job, not the job-control shell waiting for it")
    func signalForegroundJob() throws {
        // With `set -m` the shell runs `sleep` in its own process group and gives it the terminal.
        let script = "set -m; echo START; sleep 30; echo AFTER-$?; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        let (connection, welcome) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("START") })
        // tpgid = the terminal's foreground process group; it leaves the shell's group once sleep runs.
        let shell = String(welcome.childPid)
        #expect(waitFor {
            let group = (try? runCommand("/bin/ps", ["-o", "tpgid=", "-p", shell]).output)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return group.map { !$0.isEmpty && $0 != shell } ?? false
        })
        try connection.send(.signal(UInt8(SIGINT)))
        #expect(try connection.collect(into: &capture) { $0.text.contains("AFTER-130") }, "\(capture.text.debugDescription)")
        #expect(capture.exit == nil, "the shell itself must not get the signal")
    }

    @Test("REPAINT narrows by one column, then restores the size")
    func repaint() throws {
        let script = "trap 'echo SIZE $(stty size)' WINCH; echo READY; while :; do sleep 0.02; done"
        let session = try TestSession(["/bin/sh", "-c", script], cols: 80, rows: 24)
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        try connection.send(.repaint)
        #expect(try connection.collect(into: &capture) { $0.text.contains("SIZE 24 79") && $0.text.contains("SIZE 24 80") }, "\(capture.text.debugDescription)")
        if let narrow = capture.text.range(of: "SIZE 24 79"), let restored = capture.text.range(of: "SIZE 24 80") {
            #expect(narrow.lowerBound < restored.lowerBound)
        }
    }

    @Test("the holder re-binds when its socket path disappears")
    func rebindsSocket() throws {
        let session = try TestSession(["/bin/cat"])
        #expect(unlink(session.socketPath) == 0)
        #expect(waitFor(timeoutMilliseconds: 3000) { UnixSocket.isLive(path: session.socketPath) })
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        try connection.roundTrip(token: 5, into: &capture)
        #expect(session.log.contains("re-bound"))
    }

    @Test("a second holder refuses a socket that is in use")
    func refusesLiveSocket() throws {
        let session = try TestSession(["/bin/cat"])
        let other = try TemporaryDirectory()
        let launch = HolderLaunch(
            holderExecutable: TestBinaries.holder, session: "other", sessionDirectory: other.path + "/s",
            socketPath: session.socketPath, cols: 80, rows: 24, cwd: "/tmp", argv: ["/bin/cat"])
        let pid = try HolderSpawner.spawn(launch)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(ProcessTermination(waitStatus: status) == ProcessTermination(status: 71, signaled: false))
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        try connection.roundTrip(token: 3, into: &capture)
    }
}

// MARK: - Helpers

struct Stamp {
    var byte: UInt8
    var nanoseconds: UInt64
}

/// Lines "S <hex> <ns>" printed by `codd-holder-testhelper stamp`.
func parseStamps(_ text: String) -> [Stamp] {
    text.components(separatedBy: "\r\n").compactMap { line in
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "S", let byte = UInt8(fields[1], radix: 16), let ns = UInt64(fields[2]) else {
            return nil
        }
        return Stamp(byte: byte, nanoseconds: ns)
    }
}

/// Permission bits of a path (lstat).
func permissions(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
}

/// Polls `condition` every 10 ms.
func waitFor(timeoutMilliseconds: Int = 3000, _ condition: () -> Bool) -> Bool {
    let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
    while Clock.monotonicNanoseconds() < deadline {
        if condition() { return true }
        Clock.sleep(milliseconds: 10)
    }
    return condition()
}

/// Whether `fd` is open in another process (via lsof; slow, used once).
func descriptorIsOpen(_ fd: Int32, inProcess pid: pid_t) throws -> Bool {
    let result = try runCommand("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", String(fd), "-Fn"])
    return result.output.contains("f\(fd)")
}
