import Testing
@testable import CoddProtocol

@Suite("Handshake payloads, modes and meta.json")
struct HandshakeTests {
    @Test("HELLO JSON has the documented keys")
    func helloJSON() throws {
        let hello = Hello(client: "CODD/0.1", takeover: false, caps: ["x"])
        #expect(hello.jsonValue().serializedString() == "{\"proto\":1,\"client\":\"CODD/0.1\",\"takeover\":false,\"caps\":[\"x\"]}")
        let tolerant = try Hello(json: JSONValue.parse("{\"proto\":1,\"future\":{\"x\":1}}"))
        #expect(tolerant == Hello(client: "", takeover: false, caps: []))
    }

    @Test("WELCOME omits absent optionals and decodes tolerantly")
    func welcomeJSON() throws {
        let minimal = Welcome(holder: "0.1", session: "s", childPid: 1, cols: 80, rows: 24, ringStart: 0, ringEnd: 0, resync: 0)
        let text = minimal.jsonValue().serializedString()
        #expect(!text.contains("\"title\""))
        #expect(!text.contains("\"exitStatus\""))
        #expect(text.contains("\"modes\":{\"1\":false,\"25\":true,"))
        #expect(try Welcome(json: JSONValue.parse(text)) == minimal)
        #expect(throws: ProtocolError.self) { try Welcome(json: JSONValue.parse("{\"proto\":1,\"session\":\"s\"}")) }
        let extra = try Welcome(json: JSONValue.parse(
            "{\"proto\":1,\"session\":\"s\",\"cols\":80,\"rows\":24,\"ringStart\":5,\"ringEnd\":9,\"newField\":[1]}"))
        #expect(extra.resync == 5)
        #expect(extra.modes == TerminalModes())
    }

    @Test("WELCOME resyncModes round-trips and is optional")
    func welcomeResyncModes() throws {
        var modes = TerminalModes()
        modes.altScreen = true
        modes.kittyKeyboardFlags = 1
        let welcome = Welcome(
            holder: "0.1", session: "s", childPid: 1, cols: 80, rows: 24, ringStart: 0, ringEnd: 9, resync: 4,
            resyncModes: modes)
        let text = welcome.jsonValue().serializedString()
        #expect(text.contains("\"resyncModes\":{\"1\":false,"))
        #expect(try Welcome(json: JSONValue.parse(text)) == welcome)
        let without = try Welcome(json: JSONValue.parse("{\"proto\":1,\"session\":\"s\",\"cols\":80,\"rows\":24,\"ringStart\":0,\"ringEnd\":0}"))
        #expect(without.resyncModes == nil)
        let malformed = try Welcome(json: JSONValue.parse(
            "{\"proto\":1,\"session\":\"s\",\"cols\":80,\"rows\":24,\"ringStart\":0,\"ringEnd\":0,\"resyncModes\":7}"))
        #expect(malformed.resyncModes == nil)
    }

    @Test("ERROR JSON")
    func errorJSON() throws {
        let info = ErrorInfo(code: HolderErrorCode.takenOver, message: "taken over by CODD/0.1")
        #expect(try ErrorInfo(json: JSONValue.parse(info.jsonValue().serializedString())) == info)
    }

    @Test("terminal modes: bits, JSON and restore sequence")
    func modes() throws {
        var modes = TerminalModes()
        let tracked = [
            modes.setDECPrivateMode(2004, true), modes.setDECPrivateMode(1047, true),
            modes.setDECPrivateMode(25, false), modes.setDECPrivateMode(2026, true),
        ]
        let untracked = modes.setDECPrivateMode(12, true)
        #expect(tracked == [true, true, true, true])
        #expect(!untracked)
        modes.kittyKeyboardFlags = 5
        #expect(modes.altScreen)
        #expect(TerminalModes(bits: modes.bits, kittyKeyboardFlags: 5) == modes)
        #expect(TerminalModes(json: modes.jsonValue()) == modes)
        let restore = String(decoding: modes.restoreSequence(), as: UTF8.self)
        #expect(restore == "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[>5u")
        #expect(TerminalModes().restoreSequence().isEmpty)
    }

    @Test("meta.json round trip")
    func meta() throws {
        let meta = HolderMeta(
            session: "abc", holderVersion: "0.1", holderPid: 10, childPid: 11, argv: ["/bin/zsh", "-l"],
            cwd: "/Users/me", socket: "/run/a.sock", ring: "/s/ring", ringSize: 2 << 20, cols: 100, rows: 30,
            startedAt: 1_792_000_000_000, boot: "B", title: "t", oscCwd: "/x", progress: TerminalProgress(state: 1, value: 50),
            exited: true, exitStatus: 0,
            signaled: false, exitedAt: 1_792_000_000_500, holderExited: true)
        let decoded = try #require(HolderMeta(json: JSONValue.parse(meta.jsonValue().serializedString())))
        #expect(decoded == meta)
        #expect(HolderMeta(json: try JSONValue.parse("{\"session\":\"x\"}")) == nil)
    }
}
