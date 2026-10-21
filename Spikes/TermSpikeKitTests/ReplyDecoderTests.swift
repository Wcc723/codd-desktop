import Testing
import TermSpikeKit

@Suite("ReplyDecoder")
struct ReplyDecoderTests {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    @Test("splits a full probe answer burst into tokens")
    func decodesBurst() {
        let reply = "\u{1B}P>|ghostty 1.3.1\u{1B}\\\u{1B}[?0u\u{1B}[?2026;2$y\u{1B}[?1016;2$y"
            + "\u{1B}_Gi=31;OK\u{1B}\\\u{1B}[6;34;16t\u{1B}[?62;22c"
        let tokens = ReplyDecoder.decode(bytes(reply))
        #expect(tokens.count == 7)
        #expect(tokens.first == .dcs(">|ghostty 1.3.1"))
        #expect(tokens.last == .csi(params: "?62;22", intermediates: "", final: "c"))

        let answers = ProbeInterpreter.answers(for: ClaudeProbes.all, tokens: tokens)
        let byID = Dictionary(uniqueKeysWithValues: answers.map { ($0.probeID, $0) })
        #expect(byID["xtversion"]?.answered == true)
        #expect(byID["xtversion"]?.meaning.contains("ghostty 1.3.1") == true)
        #expect(byID["kitty-keyboard"]?.meaning == "kitty keyboard flags = 0")
        #expect(byID["decrqm-2026"]?.meaning == "mode 2026 = 2 reset")
        #expect(byID["osc-7501"]?.answered == false)
        #expect(byID["kitty-graphics"]?.answered == true)
        #expect(byID["csi-16t"]?.meaning == "cell 16×34 px")
        #expect(byID["da1"]?.answered == true)
    }

    @Test("accepts BEL-terminated OSC and keeps plain text")
    func oscAndText() {
        let tokens = ReplyDecoder.decode(bytes("a\u{1B}]7501;?\u{07}\r"))
        #expect(tokens == [.text([0x61]), .osc("7501;?"), .text([0x0D])])
        let answers = ProbeInterpreter.answers(for: [ClaudeProbes.programStatus], tokens: tokens)
        #expect(answers.first?.answered == true)
    }

    @Test("counts replies only where Claude's own matcher would")
    func claudeMatchers() {
        // Claude 2.1.300: OSC 7501 data must start with `?`; graphics id must be 31.
        let status = ReplyDecoder.decode(bytes("\u{1B}]7501;state=idle:app=claude-code\u{1B}\\"))
        #expect(ProbeInterpreter.answers(for: [ClaudeProbes.programStatus], tokens: status).first?.answered == false)
        let otherImage = ReplyDecoder.decode(bytes("\u{1B}_Gi=7;OK\u{1B}\\"))
        #expect(ProbeInterpreter.answers(for: [ClaudeProbes.kittyGraphics], tokens: otherImage).first?.answered == false)
        let claudeImage = ReplyDecoder.decode(bytes("\u{1B}_Gi=31;EINVAL:bad\u{1B}\\"))
        #expect(ProbeInterpreter.answers(for: [ClaudeProbes.kittyGraphics], tokens: claudeImage).first?.answered == true)
    }

    @Test("keeps an unterminated tail as text")
    func truncated() {
        let tokens = ReplyDecoder.decode(bytes("\u{1B}[?2026;2"))
        #expect(tokens == [.text(bytes("\u{1B}[?2026;2"))])
        #expect(ReplyDecoder.decode(bytes("\u{1B}P>|half")) == [.text(bytes("\u{1B}P>|half"))])
    }

    @Test("reports tokens no probe asked for")
    func unclaimed() {
        let tokens = ReplyDecoder.decode(bytes("\u{1B}[?1u\u{1B}[I"))
        let extra = ProbeInterpreter.unclaimed(tokens, probes: ClaudeProbes.all)
        #expect(extra == [.csi(params: "", intermediates: "", final: "I")])
    }

    @Test("renders bytes with visible escapes")
    func escaping() {
        #expect(ByteEscaper.escape(bytes("\u{1B}[13;2u\r\u{16}")) == "\\e[13;2u\\r\\x16")
        #expect(ReplyToken.csi(params: "?2026;1", intermediates: "$", final: "y").display == "\\e[?2026;1$y")
    }

    @Test("Claude's probe burst ends with the DA1 sentinel")
    func burstOrder() {
        #expect(ClaudeProbes.all.last?.id == "da1")
        #expect(ClaudeProbes.burst.suffix(3) == bytes("\u{1B}[c")[...])
    }
}

@Suite("ReplyDecoder robustness")
struct ReplyDecoderRobustnessTests {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    @Test("a malformed CSI in the middle does not hide the replies after it")
    func malformedCSI() {
        // `ESC [ ?` interrupted by another ESC, then a real DA1 reply.
        let tokens = ReplyDecoder.decode(bytes("\u{1B}[?\u{1B}[?62;22c"))
        #expect(tokens.contains(.csi(params: "?62;22", intermediates: "", final: "c")))
        let answers = ProbeInterpreter.answers(for: [ClaudeProbes.da1], tokens: tokens)
        #expect(answers.first?.answered == true)
    }

    @Test("a string sequence aborted by ESC does not swallow the next reply")
    func abortedString() {
        // OSC cut short by a CSI (ESC aborts a control string), then XTVERSION.
        let tokens = ReplyDecoder.decode(bytes("\u{1B}]7501;\u{1B}[?0u\u{1B}P>|x 1\u{1B}\\"))
        #expect(tokens.contains(.csi(params: "?0", intermediates: "", final: "u")))
        #expect(tokens.contains(.dcs(">|x 1")))
    }
}

@Suite("ReplayProbe")
struct ReplayProbeTests {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    @Test("history carries the probes, the modes and the marker; live queries end with DA1")
    func shape() {
        let history = String(decoding: ReplayProbe.history, as: UTF8.self)
        #expect(history.hasPrefix(String(decoding: ClaudeProbes.burst, as: UTF8.self)))
        for mode in ReplayProbe.modes {
            #expect(history.contains("\u{1B}[?\(mode.number)h"))
        }
        #expect(history.contains("\u{1B}[>1u"))
        #expect(history.hasSuffix(ReplayProbe.marker))
        #expect(ReplayProbe.liveQueries.suffix(3) == bytes("\u{1B}[c")[...])
    }

    @Test("a fully restored engine passes")
    func restored() {
        let reply = "\u{1B}[?1049;1$y\u{1B}[?2004;1$y\u{1B}[?1000;1$y\u{1B}[?1006;1$y\u{1B}[?1u\u{1B}[?62;22c"
        let verdict = ReplayProbe.evaluate(ReplyDecoder.decode(bytes(reply)))
        #expect(verdict.allModesRestored)
        #expect(verdict.kittyRestored)
        #expect(verdict.sentinelAnswered)
        #expect(verdict.lostModes.isEmpty)
        #expect(verdict.unreportedModes.isEmpty)
    }

    @Test("a mode the engine cannot report (DECRPM 0) is unknown, not lost")
    func unreported() {
        let reply = "\u{1B}[?1049;0$y\u{1B}[?2004;1$y\u{1B}[?1000;1$y\u{1B}[?1006;1$y\u{1B}[?1u\u{1B}[?65;1c"
        let verdict = ReplayProbe.evaluate(ReplyDecoder.decode(bytes(reply)))
        #expect(verdict.allModesRestored)
        #expect(verdict.unreportedModes == [1049])
        #expect(String(decoding: ReplayProbe.leaveAltScreen, as: UTF8.self) == "\u{1B}[?1049l")
    }

    @Test("lost modes, lost kitty flags and silence are all reported")
    func lost() {
        let reply = "\u{1B}[?1049;1$y\u{1B}[?2004;2$y\u{1B}[?1006;1$y\u{1B}[?0u"
        let verdict = ReplayProbe.evaluate(ReplyDecoder.decode(bytes(reply)))
        #expect(!verdict.allModesRestored)
        #expect(verdict.lostModes == ["2004 bracketed paste = 2", "1000 mouse = no reply"])
        #expect(!verdict.kittyRestored)
        #expect(!verdict.sentinelAnswered)
        #expect(ReplayProbe.evaluate([]) == ReplayProbe.Verdict(modeReports: [:], kittyFlags: nil, sentinelAnswered: false))
    }
}

@Suite("ClaudeCapabilities")
struct ClaudeCapabilitiesTests {
    private func tokens(_ string: String) -> [ReplyToken] { ReplyDecoder.decode(Array(string.utf8)) }
    private func enabled(_ verdicts: [ClaudeCapabilities.Verdict]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: verdicts.map { ($0.capability, $0.enabled) })
    }

    /// The replies recorded in results/probe.json (2026-10-15).
    private let ghostty = "\u{1B}P>|ghostty 1.3.2-HEAD+1e9e14af5\u{1B}\\\u{1B}[?0u\u{1B}[?2026;2$y\u{1B}[?1016;2$y"
        + "\u{1B}_Gi=31;OK\u{1B}\\\u{1B}[6;17;8t\u{1B}[?62;22;52c"
    private let swiftTerm = "\u{1B}P>|SwiftTerm 1.99.0+v1.99.0:\u{1B}\\\u{1B}[?0u\u{1B}[?2026;2$y\u{1B}[?1016;2$y"
        + "\u{1B}]7501;?\u{1B}\\\u{1B}_Gi=31;OK\u{1B}\\\u{1B}[6;18;8t\u{1B}[?65;4;1;2;6;21;22;17;28c"

    @Test("Ghostty's replies: images on, program status off")
    func ghosttyReplies() {
        let verdict = enabled(ClaudeCapabilities.evaluate(tokens: tokens(ghostty)))
        #expect(verdict == [
            "kittyKeyboard": true, "extendedKeys": true, "programStatus": false,
            "synchronizedOutput": true, "kittyGraphics": true, "mousePixels": true,
        ])
    }

    @Test("SwiftTerm's replies: program status on, images only when forced")
    func swiftTermReplies() {
        let plain = enabled(ClaudeCapabilities.evaluate(tokens: tokens(swiftTerm)))
        #expect(plain["programStatus"] == true)
        #expect(plain["kittyGraphics"] == false)
        #expect(plain["synchronizedOutput"] == true)
        let forced = enabled(ClaudeCapabilities.evaluate(
            tokens: tokens(swiftTerm), environment: .init(forceTerminalImages: true)
        ))
        #expect(forced["kittyGraphics"] == true)
        let noTitle = enabled(ClaudeCapabilities.evaluate(
            tokens: tokens(swiftTerm), environment: .init(disableTerminalTitle: true)
        ))
        #expect(noTitle["programStatus"] == false)
    }

    @Test("without an XTVERSION answer the second burst is never sent")
    func noXTVersion() {
        let reply = "\u{1B}[?1u\u{1B}[?2026;1$y\u{1B}[?1016;1$y\u{1B}_Gi=31;OK\u{1B}\\\u{1B}[?62c"
        let verdict = enabled(ClaudeCapabilities.evaluate(tokens: tokens(reply)))
        #expect(verdict["kittyKeyboard"] == true)
        #expect(verdict["synchronizedOutput"] == false)
        #expect(verdict["kittyGraphics"] == false)
        #expect(verdict["mousePixels"] == false)
        let apple = enabled(ClaudeCapabilities.evaluate(
            tokens: tokens(ghostty), environment: .init(termProgram: "Apple_Terminal")
        ))
        #expect(apple["synchronizedOutput"] == false)
    }

    @Test("DECRPM 0 or 4 is unsupported; 1, 2 and 3 are supported")
    func decrpmStatuses() {
        for (status, expected) in [(0, false), (1, true), (2, true), (3, true), (4, false)] {
            let reply = "\u{1B}P>|x 1\u{1B}\\\u{1B}[?2026;\(status)$y\u{1B}[?62c"
            #expect(enabled(ClaudeCapabilities.evaluate(tokens: tokens(reply)))["synchronizedOutput"] == expected)
        }
    }

    @Test("kitty graphics allow-list follows Claude's nYo()")
    func allowList() {
        #expect(ClaudeCapabilities.isKittyGraphicsTerminal("ghostty"))
        #expect(ClaudeCapabilities.isKittyGraphicsTerminal("ghostty 1.3.2-HEAD+1e9e14af5"))
        #expect(ClaudeCapabilities.isKittyGraphicsTerminal("kitty(0.28.0)"))
        #expect(ClaudeCapabilities.isKittyGraphicsTerminal("kitty(0.35.2)"))
        #expect(!ClaudeCapabilities.isKittyGraphicsTerminal("kitty(0.27.9)"))
        #expect(!ClaudeCapabilities.isKittyGraphicsTerminal("ghosttyx 1.0"))
        #expect(!ClaudeCapabilities.isKittyGraphicsTerminal("SwiftTerm 1.99.0+v1.99.0:"))
        #expect(!ClaudeCapabilities.isKittyGraphicsTerminal("WezTerm 20240203"))
    }
}
