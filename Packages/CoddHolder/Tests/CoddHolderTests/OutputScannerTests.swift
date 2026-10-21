import Testing
@testable import CoddHolderCore
import CoddProtocol

/// Scans `text` in pieces of `chunk` bytes and returns the merged events plus final scanner.
private func scan(_ text: String, chunk: Int = .max, startOffset: UInt64 = 0) -> (OutputScanner, OutputScanner.Events) {
    var scanner = OutputScanner()
    var merged = OutputScanner.Events()
    let bytes = Array(text.utf8)
    var start = 0
    while start < bytes.count {
        let end = min(bytes.count, start + max(chunk, 1))
        bytes[start..<end].withUnsafeBytes { scanner.scan($0, at: startOffset + UInt64(start)) }
        let events = scanner.takeEvents()
        merged.titleChanged = merged.titleChanged || events.titleChanged
        merged.cwdChanged = merged.cwdChanged || events.cwdChanged
        merged.progressChanged = merged.progressChanged || events.progressChanged
        merged.modesChanged = merged.modesChanged || events.modesChanged
        merged.syncEnded = merged.syncEnded || events.syncEnded
        merged.bells += events.bells
        merged.resyncs += events.resyncs
        start = end
    }
    return (scanner, merged)
}

@Suite("Output scanner")
struct OutputScannerTests {
    static let esc = "\u{1B}"

    @Test("OSC 0/2 titles with BEL or ST, at every split point")
    func titles() {
        let text = "a\(Self.esc)]0;first\u{07}b\(Self.esc)]2;第二 ✳\(Self.esc)\\c"
        for chunk in 1...text.utf8.count {
            let (scanner, events) = scan(text, chunk: chunk)
            #expect(scanner.title == "第二 ✳")
            #expect(events.titleChanged)
            #expect(events.bells == 0, "a BEL terminating an OSC is not a bell")
        }
    }

    @Test("BEL in text, CSI and escape counts; inside DCS / APC it does not")
    func bells() {
        #expect(scan("x\u{07}y\u{07}").1.bells == 2)
        #expect(scan("\(Self.esc)[1\u{07}m").1.bells == 1)
        #expect(scan("\(Self.esc)Ptmux;\u{07}\(Self.esc)\\").1.bells == 0)
        #expect(scan("\(Self.esc)_Gf=24\u{07}\(Self.esc)\\").1.bells == 0)
    }

    @Test("OSC 7 cwd is URL-decoded")
    func cwd() {
        let (scanner, events) = scan("\(Self.esc)]7;file://mac.local/Users/me/a%20b/%E4%B8%AD\u{07}")
        #expect(events.cwdChanged)
        #expect(scanner.cwd == "/Users/me/a b/中")
        #expect(OutputScanner.decodeCwdURL(Array("kitty-shell-cwd://h/tmp".utf8)) == "/tmp")
        #expect(OutputScanner.decodeCwdURL(Array("relative".utf8)) == nil)
    }

    @Test("OSC 9;4 progress; plain OSC 9 is ignored")
    func progress() {
        let (scanner, events) = scan("\(Self.esc)]9;4;1;42\u{07}\(Self.esc)]9;hello\u{07}")
        #expect(events.progressChanged)
        #expect(scanner.progress == TerminalProgress(state: 1, value: 42))
    }

    @Test("resync points are the offsets right after the clearing sequence")
    func resyncPoints() {
        let text = "ab\(Self.esc)[2J" + "cd\(Self.esc)[H\(Self.esc)[3J" + "\(Self.esc)[?1049h" + "x\(Self.esc)c" + "\(Self.esc)[J\(Self.esc)[1J"
        let bytes = Array(text.utf8)
        func end(of marker: String, from start: Int = 0) -> UInt64 {
            let needle = Array(marker.utf8)
            for index in start...(bytes.count - needle.count) where Array(bytes[index..<(index + needle.count)]) == needle {
                return UInt64(index + needle.count) + 100
            }
            return 0
        }
        // `CSI 3 J` only erases the scrollback (the screen stays), so it is no resync point.
        let expected = [end(of: "\(Self.esc)[2J"), end(of: "\(Self.esc)[?1049h"), end(of: "\(Self.esc)c")]
        for chunk in [1, 2, 3, 7, 1000] {
            #expect(scan(text, chunk: chunk, startOffset: 100).1.resyncs.map(\.offset) == expected)
        }
    }

    @Test("clearing only the scrollback (lone CSI 3 J) is no resync point; clear's 2J + 3J gives one")
    func scrollbackClear() {
        #expect(scan("prompt$ ls\r\nfile\r\n\(Self.esc)[3J").1.resyncs.isEmpty)
        let clear = "x\(Self.esc)[H\(Self.esc)[2J\(Self.esc)[3J"  // what `clear` prints
        #expect(scan(clear).1.resyncs.map(\.offset) == [8])
    }

    @Test("each resync point carries the modes in effect at that offset, not later ones")
    func resyncModes() {
        let esc = Self.esc
        let text = "\(esc)[>1u\(esc)[?2004h\(esc)[2J" + "\(esc)[?1049h" + "\(esc)[>3u\(esc)[?1h" + "\(esc)c"
        for chunk in [1, 5, 1000] {
            let (scanner, events) = scan(text, chunk: chunk)
            #expect(events.resyncs.count == 3)
            guard events.resyncs.count == 3 else { continue }
            let clear = events.resyncs[0].modes
            #expect(clear.bracketedPaste && clear.kittyKeyboardFlags == 1 && !clear.altScreen)
            let alternate = events.resyncs[1].modes
            #expect(alternate.altScreen && alternate.bracketedPaste)
            #expect(alternate.kittyKeyboardFlags == 0, "the alternate screen starts with its own empty stack")
            #expect(!alternate.applicationCursorKeys, "?1h came after the resync point")
            #expect(events.resyncs[2].modes == TerminalModes(), "RIS resets everything")
            #expect(scanner.modes == TerminalModes())
        }
    }

    @Test("DEC private modes, including several per sequence and resets")
    func decModes() {
        let (scanner, events) = scan("\(Self.esc)[?1;2004;1000;1006h\(Self.esc)[?25l\(Self.esc)[?1004h\(Self.esc)[?1000l")
        #expect(events.modesChanged)
        #expect(scanner.modes.applicationCursorKeys)
        #expect(scanner.modes.bracketedPaste)
        #expect(scanner.modes.mouseSGR)
        #expect(!scanner.modes.mouseNormal)
        #expect(!scanner.modes.cursorVisible)
        #expect(scanner.modes.focusEvents)
        let reset = scan("\(Self.esc)[?2004h\(Self.esc)[?1049h\(Self.esc)c").0
        #expect(reset.modes == TerminalModes())
        let soft = scan("\(Self.esc)[?1h\(Self.esc)[?25l\(Self.esc)[!p").0
        #expect(!soft.modes.applicationCursorKeys && soft.modes.cursorVisible)
    }

    @Test("?2026l is reported for REPAINT")
    func synchronizedOutput() {
        let (scanner, events) = scan("\(Self.esc)[?2026h frame \(Self.esc)[?2026l")
        #expect(events.syncEnded)
        #expect(!scanner.modes.synchronizedOutput)
        #expect(!scan("\(Self.esc)[?2026h").1.syncEnded)
    }

    @Test("kitty keyboard flags: push, pop, set, separate stacks per screen")
    func kittyFlags() {
        #expect(scan("\(Self.esc)[>1u").0.modes.kittyKeyboardFlags == 1)
        #expect(scan("\(Self.esc)[>1u\(Self.esc)[>3u\(Self.esc)[<u").0.modes.kittyKeyboardFlags == 1)
        #expect(scan("\(Self.esc)[>1u\(Self.esc)[>3u\(Self.esc)[<5u").0.modes.kittyKeyboardFlags == 0)
        #expect(scan("\(Self.esc)[>1u\(Self.esc)[=4;2u").0.modes.kittyKeyboardFlags == 5)
        #expect(scan("\(Self.esc)[>7u\(Self.esc)[=2;3u").0.modes.kittyKeyboardFlags == 5)
        #expect(scan("\(Self.esc)[=9u").0.modes.kittyKeyboardFlags == 9)
        let screens = scan("\(Self.esc)[>1u\(Self.esc)[?1049h").0
        #expect(screens.modes.kittyKeyboardFlags == 0, "the alternate screen has its own stack")
        let back = scan("\(Self.esc)[>1u\(Self.esc)[?1049h\(Self.esc)[>8u\(Self.esc)[?1049l").0
        #expect(back.modes.kittyKeyboardFlags == 1)
        #expect(scan("\(Self.esc)[?u").0.modes.kittyKeyboardFlags == 0, "queries change nothing")
    }

    @Test("ESC aborts sequences; CAN/SUB return to ground; malformed CSI is ignored")
    func parserRecovery() {
        #expect(scan("\(Self.esc)[?20\(Self.esc)[?2004h").0.modes.bracketedPaste)
        #expect(!scan("\(Self.esc)[?2004\u{18}h").0.modes.bracketedPaste)
        #expect(!scan("\(Self.esc)[1?2004h").0.modes.bracketedPaste)
        #expect(scan("\(Self.esc)]0;unterminated\(Self.esc)[?2004h").0.modes.bracketedPaste)
        #expect(scan("\(Self.esc)(B\(Self.esc)[?1h").0.modes.applicationCursorKeys)
    }

    @Test("overlong OSC payloads are dropped, not truncated")
    func oscOverflow() {
        let long = String(repeating: "x", count: OutputScanner.maxOSCLength + 10)
        let (scanner, events) = scan("\(Self.esc)]0;\(long)\u{07}\(Self.esc)]0;ok\u{07}")
        #expect(scanner.title == "ok")
        #expect(events.titleChanged)
        #expect(scan("\(Self.esc)]0;\(long)\u{07}").0.title == nil)
    }

    @Test("plain text produces no events")
    func plainText() {
        let text = String(repeating: "hello world 你好 ", count: 1000)
        #expect(scan(text).1.isEmpty)
    }
}
