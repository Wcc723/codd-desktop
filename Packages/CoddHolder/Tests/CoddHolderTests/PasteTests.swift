import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing
@testable import CoddHolderClient
@testable import CoddHolderCore

/// Capability `input.paste` (INPUT flag bit1): the holder brackets a paste by the child's current
/// modes and submits 50 ms after it; clients bracket themselves for holders without the capability.
@Suite("Paste input", .serialized, .timeLimit(.minutes(3)))
struct PasteTests {
    private static let start = BracketedPaste.startMarker
    private static let end = BracketedPaste.endMarker

    /// A `codd-holder-testhelper chunks` child, attached, after READY.
    private func chunkSession(bracketed: Bool) throws -> (TestSession, HolderConnection, StreamCapture) {
        let session = try TestSession([TestBinaries.helper, "chunks"] + (bracketed ? ["bracketed"] : []))
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        return (session, connection, capture)
    }

    // MARK: - Holder

    @Test("?2004 on: one bracketed unit, CR at least 45 ms after the closing marker, later input behind it")
    func bracketedPasteWithSubmit() throws {
        let (session, connection, initial) = try chunkSession(bracketed: true)
        defer { withExtendedLifetime(session) {} }
        var capture = initial
        let text = Array("line one\nline two\ttabbed".utf8)
        try connection.send(.input(flags: [.paste, .submit], bytes: text))
        try connection.send(.input(flags: [], bytes: Array("z".utf8)))
        #expect(try connection.collect(into: &capture) { receivedBytes($0.text).last == 0x7A })

        let received = receivedBytes(capture.text)
        #expect(received == Self.start + text + Self.end + [0x0D, 0x7A], "got \(String(decoding: received, as: UTF8.self).debugDescription)")
        let stamps = byteStamps(capture.text)
        if let closing = lastIndex(of: Self.end, in: received), let cr = received.lastIndex(of: 0x0D), cr > closing {
            let delay = Double(stamps[cr] - stamps[closing + Self.end.count - 1]) / 1000
            #expect(delay >= 45, "\\r arrived \(delay) ms after the closing marker")
            #expect(delay < 1000)
        } else {
            Issue.record("closing marker or CR missing")
        }
    }

    @Test("?2004 off: the payload unchanged; the paste submit is still 50 ms")
    func plainPasteWithSubmit() throws {
        let (session, connection, initial) = try chunkSession(bracketed: false)
        defer { withExtendedLifetime(session) {} }
        var capture = initial
        let text = Array("a\nb\u{1B}[201~c".utf8)
        try connection.send(.input(flags: [.paste, .submit], bytes: text))
        #expect(try connection.collect(into: &capture) { receivedBytes($0.text).last == 0x0D })
        let received = receivedBytes(capture.text)
        #expect(received == text + [0x0D], "markers stay when the holder does not bracket")
        let stamps = byteStamps(capture.text)
        if received.count == text.count + 1 {
            let delay = Double(stamps[text.count] - stamps[text.count - 1]) / 1000
            #expect(delay >= 45, "\\r arrived \(delay) ms after the paste")
        }
    }

    @Test("markers inside the payload are stripped, also the ones that stripping uncovers")
    func markersStripped() throws {
        let (session, connection, initial) = try chunkSession(bracketed: true)
        defer { withExtendedLifetime(session) {} }
        var capture = initial
        let esc = "\u{1B}"
        let text = Array("x\(esc)[201~y\(esc)[20\(esc)[200~0~z\(esc)[200~".utf8)
        try connection.send(.input(flags: [.paste], bytes: text))
        try connection.send(.input(flags: [], bytes: Array("!".utf8)))
        #expect(try connection.collect(into: &capture) { receivedBytes($0.text).last == UInt8(ascii: "!") })
        #expect(receivedBytes(capture.text) == Self.start + Array("xyz".utf8) + Self.end + Array("!".utf8))
    }

    @Test("paste without submit: the bracketed unit and nothing else")
    func pasteWithoutSubmit() throws {
        let (session, connection, initial) = try chunkSession(bracketed: true)
        defer { withExtendedLifetime(session) {} }
        var capture = initial
        try connection.send(.input(flags: [.paste], bytes: Array("abc".utf8)))
        try connection.send(.input(flags: [], bytes: Array("d".utf8)))
        #expect(try connection.collect(into: &capture) { receivedBytes($0.text).last == UInt8(ascii: "d") })
        let received = receivedBytes(capture.text)
        #expect(received == Self.start + Array("abc".utf8) + Self.end + Array("d".utf8))
        #expect(!received.contains(0x0D))
    }

    @Test("the holder decides by the modes read so far: ?2004l after ?2004h turns bracketing off")
    func modesFollowTheChild() throws {
        let script = "printf '\\033[?2004h\\033[?2004lREADY'; stty raw -echo; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        Clock.sleep(milliseconds: 100)  // stty raw before the input arrives
        let before = capture.bytes.count
        try connection.send(.input(flags: [.paste], bytes: Array("plain".utf8)))
        #expect(try connection.collect(into: &capture) { $0.bytes.count - before >= 5 })
        #expect(Array(capture.bytes[before...]) == Array("plain".utf8))
    }

    @Test("multi-frame plain input is unchanged (regression): bytes in order, one CR at the end")
    func multiFramePlainInput() throws {
        let session = try TestSession(["/bin/sh", "-c", "stty raw -echo; printf READY; exec cat"])
        let (connection, welcome) = try session.attach(from: 0)
        #expect(welcome.caps.contains(HolderCapability.inputPaste))
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        var random = SplitMix64(state: 7)
        let payload = (0..<(Message.maxInputChunk + 200_000)).map { _ in UInt8.random(in: 0x20...0x7E, using: &random) }
        let messages = Message.inputMessages(payload, submit: true)
        #expect(messages.count == 2)
        let start = capture.bytes.count
        try connection.sendInput(payload, submit: true)
        #expect(try connection.collect(into: &capture, timeoutMilliseconds: 30_000) { $0.bytes.count - start >= payload.count + 1 })
        let echoed = Array(capture.bytes[start...])
        #expect(echoed.count == payload.count + 1)
        #expect(fnv1a(echoed) == fnv1a(payload + [0x0D]))
    }

    @Test("input queue: a paste submit marker holds later input like a submit and resolves to CR")
    func inputQueuePasteSubmit() {
        var queue = InputQueue()
        queue.append(Array("ab".utf8), submit: true, paste: true)
        queue.append(Array("c".utf8), submit: true)
        queue.consume(2)
        #expect(queue.head == .pasteSubmit)
        #expect(queue.headIsSubmit)
        queue.resolveSubmit()
        #expect(queue.withHeadBytes { Array($0) } == [0x0D])
        queue.consume(1)
        queue.consume(1)
        #expect(queue.head == .submit, "plain submit after plain input")
        queue.append([], submit: true, paste: true)
        queue.resolveSubmit()
        queue.consume(1)
        #expect(queue.head == .pasteSubmit)
        #expect(queue.pendingBytes == 0)
    }

    // MARK: - HolderStream against an M2 holder

    @Test("supportsPaste: false before WELCOME, true against an M2 holder; sendInput(paste:) brackets")
    func streamPaste() throws {
        let session = try TestSession([TestBinaries.helper, "chunks", "bracketed"])
        let stream = try HolderStream(socketPath: session.socketPath, clientName: "paste-tests")
        let recorder = StreamRecorder(stream)
        defer { stream.close() }
        #expect(!stream.supportsPaste)
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.text.contains("READY") })
        #expect(stream.supportsPaste)
        try stream.sendInput(Array("first\nsecond".utf8), submit: true, paste: true)
        try stream.sendInput(Array("q".utf8))
        #expect(recorder.wait { receivedBytes($0.text).last == UInt8(ascii: "q") })
        let state = recorder.snapshot
        #expect(receivedBytes(state.text) == Self.start + Array("first\nsecond".utf8) + Self.end + [0x0D, UInt8(ascii: "q")])
        #expect(stream.pendingOutboundBytes == 0, "reservations returned in full")
    }

    // MARK: - Client fallback (holders without input.paste)

    @Test("fallback function: brackets only for a holder without the capability whose modes say ?2004")
    func fallbackFunction() {
        var on = TerminalModes()
        on.bracketedPaste = true
        let off = TerminalModes()
        let text = Array("a\u{1B}[201~b".utf8)
        let wrapped = Self.start + Array("ab".utf8) + Self.end

        #expect(InputFraming.prepare(text, paste: true, holderSupportsPaste: true, modes: on) == (text, true))
        #expect(InputFraming.prepare(text, paste: true, holderSupportsPaste: true, modes: off) == (text, true))
        #expect(InputFraming.prepare(text, paste: true, holderSupportsPaste: false, modes: on) == (wrapped, false))
        #expect(InputFraming.prepare(text, paste: true, holderSupportsPaste: false, modes: off) == (text, false))
        #expect(InputFraming.prepare(text, paste: true, holderSupportsPaste: false, modes: nil) == (text, false))
        #expect(InputFraming.prepare(text, paste: false, holderSupportsPaste: false, modes: on) == (text, false))
        #expect(InputFraming.prepare(text, paste: false, holderSupportsPaste: true, modes: on) == (text, false))
    }

    @Test("frames: plain input encodes exactly as before; paste sets bit1 on every frame, submit only on the last")
    func frameEncoding() throws {
        for count in [0, 5, Message.maxInputChunk, Message.maxInputChunk + 1, 2 * Message.maxInputChunk + 3] {
            let payload = [UInt8](repeating: 0x61, count: count)
            for submit in [false, true] {
                var plain: [UInt8] = []
                InputFraming.appendFrames(payload, submit: submit, paste: false, to: &plain)
                var legacy: [UInt8] = []
                for message in Message.inputMessages(payload, submit: submit) { message.append(to: &legacy) }
                #expect(plain == legacy, "count \(count) submit \(submit)")
                #expect(plain.count <= InputFraming.reservation(byteCount: count, paste: false))

                var pasted: [UInt8] = []
                let written = InputFraming.appendFrames(payload, submit: submit, paste: true, to: &pasted)
                #expect(written == pasted.count)
                var viaMessages: [UInt8] = []
                for message in Message.inputMessages(payload, submit: submit, paste: true) { message.append(to: &viaMessages) }
                #expect(pasted == viaMessages)
                var decoder = FrameDecoder()
                decoder.append(contentsOf: pasted)
                var flags: [UInt8] = []
                while let frame = try decoder.next() { flags.append(frame.payload[0]) }
                let expected = flags.indices.map { index -> UInt8 in index == flags.count - 1 && submit ? 0x03 : 0x02 }
                #expect(flags == expected)
            }
        }
    }

    @Test("HolderStream facing an older holder: a paste before WELCOME waits for it, then is bracketed by WELCOME modes")
    func streamFallbackUsesWelcomeModes() throws {
        let directory = try TemporaryDirectory()
        let fake = try FakeHolder(path: directory.path + "/old.sock")
        let stream = try HolderStream(socketPath: fake.path, clientName: "fallback-tests")
        let recorder = StreamRecorder(stream)
        defer { stream.close() }
        try fake.accept()
        // Sent before start: nothing is known about the holder yet.
        try stream.sendInput(Array("p1\np2".utf8), submit: true, paste: true)
        try stream.sendInput(Array("k".utf8))
        stream.start(takeover: false, attachFrom: .noAttach)
        let hello = try #require(try fake.receive())
        #expect(hello.type == .hello)
        var modes = TerminalModes()
        modes.bracketedPaste = true
        try fake.send(.welcome(fake.welcome(modes: modes, caps: [HolderCapability.inputSubmit])))
        #expect(recorder.wait { $0.welcome != nil })
        #expect(!stream.supportsPaste)
        let paste = try #require(try fake.receive())
        #expect(paste.type == .input)
        #expect(paste.payload == [InputFlags.submit.rawValue] + Self.start + Array("p1\np2".utf8) + Self.end)
        let key = try #require(try fake.receive())
        #expect(key.payload == [0] + Array("k".utf8), "input behind a held paste keeps its order")
        #expect(recorder.wait { _ in stream.pendingOutboundBytes == 0 })
    }

    @Test("HolderStream facing an older holder: ATTACHED current modes are newer than WELCOME's")
    func streamFallbackUsesAttachedModes() throws {
        var on = TerminalModes()
        on.bracketedPaste = true
        for (welcomeModes, attachedModes, bracketed) in [(TerminalModes(), on, true), (on, TerminalModes(), false)] {
            let directory = try TemporaryDirectory()
            let fake = try FakeHolder(path: directory.path + "/old.sock")
            let stream = try HolderStream(socketPath: fake.path, clientName: "fallback-tests")
            let recorder = StreamRecorder(stream)
            defer { stream.close() }
            try fake.accept()
            stream.start(takeover: false, attachFrom: .latestResync)
            #expect(try fake.receive()?.type == .hello)
            #expect(try fake.receive()?.type == .attach)
            try fake.send(.welcome(fake.welcome(modes: welcomeModes, caps: [HolderCapability.attachAck, HolderCapability.attachModes])))
            try fake.send(AttachedInfo(start: 0, replayEnd: 0, modes: TerminalModes(), currentModes: attachedModes).frame)
            #expect(recorder.wait { !$0.attaches.isEmpty })
            try stream.sendInput(Array("t".utf8), submit: true, paste: true)
            let frame = try #require(try fake.receive())
            let expected = bracketed ? Self.start + Array("t".utf8) + Self.end : Array("t".utf8)
            #expect(frame.payload == [InputFlags.submit.rawValue] + expected, "welcome \(welcomeModes.bracketedPaste) attached \(attachedModes.bracketedPaste)")
        }
    }

    @Test("HolderConnection facing an older holder brackets by the WELCOME modes; with the capability it sets the flag")
    func connectionFallback() throws {
        let directory = try TemporaryDirectory()
        let fake = try FakeHolder(path: directory.path + "/old.sock")
        let connection = try HolderConnection(socketPath: fake.path)
        try fake.accept()
        var on = TerminalModes()
        on.bracketedPaste = true
        try fake.send(.welcome(fake.welcome(modes: on, caps: [])))
        _ = try connection.handshake()
        #expect(try fake.receive()?.type == .hello)
        #expect(!connection.supportsPaste)
        try connection.sendInput(Array("u".utf8), paste: true)
        #expect(try fake.receive()?.payload == [0] + Self.start + Array("u".utf8) + Self.end)

        let session = try TestSession(["/bin/cat"])
        let (live, _) = try session.connect()
        #expect(live.supportsPaste)
    }

    // MARK: - codd-holderctl

    @Test("codd-holderctl send --paste --submit")
    func ctlSendPaste() throws {
        let (session, connection, initial) = try chunkSession(bracketed: true)
        defer { withExtendedLifetime(session) {} }
        var capture = initial
        let sent = try runCommand(TestBinaries.ctl, ["send", "--socket", session.socketPath, "--takeover", "--paste", "--submit", "--escapes", "one\\ntwo"])
        #expect(sent.status == 0)
        // ctl took the holder over; read what the child reported through a new connection.
        connection.close()
        let (again, _) = try session.attach(from: 0)
        capture = StreamCapture()
        #expect(try again.collect(into: &capture) { receivedBytes($0.text).last == 0x0D })
        #expect(receivedBytes(capture.text) == Self.start + Array("one\ntwo".utf8) + Self.end + [0x0D])
    }
}

// MARK: - Helpers

/// Bytes the `chunks` probe reported, in order ("C <µs> <hex>" lines).
func receivedBytes(_ text: String) -> [UInt8] {
    chunkLines(text).flatMap(\.bytes)
}

/// The probe's timestamp (µs) of every byte in `receivedBytes`.
func byteStamps(_ text: String) -> [UInt64] {
    chunkLines(text).flatMap { line in Array(repeating: line.micros, count: line.bytes.count) }
}

private func chunkLines(_ text: String) -> [(micros: UInt64, bytes: [UInt8])] {
    text.components(separatedBy: "\r\n").compactMap { line in
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "C", let micros = UInt64(fields[1]) else { return nil }
        let hex = Array(fields[2].utf8)
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = 0
        while index < hex.count {
            guard let byte = UInt8(String(decoding: hex[index..<(index + 2)], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return (micros, bytes)
    }
}

func lastIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for index in stride(from: haystack.count - needle.count, through: 0, by: -1)
    where haystack[index..<(index + needle.count)].elementsEqual(needle) {
        return index
    }
    return nil
}

/// A holder stand-in that only speaks what a test scripts: for clients facing an older holder
/// (no `input.paste`). One connection.
final class FakeHolder {
    let path: String
    private let listener: Int32
    private var fd: Int32 = -1
    private var decoder = FrameDecoder()

    init(path: String) throws {
        self.path = path
        // Not UnixSocket.bind: its umask switch is process-wide, and tests run in parallel.
        var address = try UnixSocket.address(path: path)
        let socket = try UnixSocket.makeStreamSocket()
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket, 4) == 0 else {
            Descriptor.closeQuietly(socket)
            throw SystemError.current("bind/listen(\(path))")
        }
        listener = socket
    }

    deinit {
        if fd >= 0 { Descriptor.closeQuietly(fd) }
        Descriptor.closeQuietly(listener)
        unlink(path)
    }

    func accept() throws {
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { throw SystemError.current("accept") }
        fd = accepted
    }

    func welcome(modes: TerminalModes, caps: [String]) -> Welcome {
        Welcome(holder: "0.1", session: "fake", childPid: 1, cols: 80, rows: 24, ringStart: 0, ringEnd: 0, resync: 0,
                modes: modes, caps: caps, resyncModes: TerminalModes())
    }

    func send(_ message: Message) throws {
        try Descriptor.writeAll(fd, message.encoded())
    }

    func send(_ frame: Frame) throws {
        try Descriptor.writeAll(fd, frame.encoded())
    }

    /// Next frame from the client, nil after the timeout.
    func receive(timeoutMilliseconds: Int = 5000) throws -> Frame? {
        let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        while true {
            if let frame = try decoder.next() { return frame }
            let now = Clock.monotonicNanoseconds()
            guard now < deadline else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw TestFailure("client closed") }
            decoder.append(contentsOf: buffer[0..<count])
        }
    }
}
