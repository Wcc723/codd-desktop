import Foundation
import Testing
@testable import CoddFiles

@Suite("TextFileCodec")
struct TextFileCodecTests {
    private func decoded(_ bytes: [UInt8]) throws -> DecodedText {
        try TextFileCodec.decode(Data(bytes)).get()
    }

    private func decoded(_ text: String) throws -> DecodedText {
        try TextFileCodec.decode(Data(text.utf8)).get()
    }

    /// decode → encode of the unchanged text gives back the very same bytes.
    private func expectRoundTrip(_ data: Data, _ label: String) throws {
        let text = try TextFileCodec.decode(data).get()
        let back = try TextFileCodec.encode(text.text, like: text)
        #expect(back == data, "\(label) round trip")
    }

    @Test func utf8WithAndWithoutBOM() throws {
        let plain = try decoded("const a = 1\n今日打卡\n")
        #expect(plain.encoding == .utf8)
        #expect(plain.text == "const a = 1\n今日打卡")
        #expect(plain.hasFinalNewline)
        #expect(!plain.readOnly)
        let bom = try decoded([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        #expect(bom.encoding == .utf8BOM)
        #expect(bom.text == "hi")
        try expectRoundTrip(Data([0xEF, 0xBB, 0xBF] + Array("hi\r\nthere\r\n".utf8)), "UTF-8 BOM CRLF")
    }

    @Test func utf16WithBOMBothByteOrders() throws {
        let text = "打卡\r\nok\r\n"
        let le = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        let a = try TextFileCodec.decode(le).get()
        let b = try TextFileCodec.decode(be).get()
        #expect(a.encoding == .utf16LE && b.encoding == .utf16BE)
        #expect(a.text == "打卡\nok" && b.text == "打卡\nok")
        #expect(a.lineEnding == .crlf)
        try expectRoundTrip(le, "UTF-16 LE")
        try expectRoundTrip(be, "UTF-16 BE")
    }

    @Test func big5BytesFor發票匯出() throws {
        // 發票匯出 in Big5, CRLF, as an old Windows tool writes it.
        let bytes: [UInt8] = [0xB5, 0x6F, 0xB2, 0xBC, 0xB6, 0xD7, 0xA5, 0x58, 0x0D, 0x0A] + Array("2026,ok".utf8) + [0x0D, 0x0A]
        let text = try decoded(bytes)
        #expect(text.encoding == .big5)
        #expect(text.text == "發票匯出\n2026,ok")
        #expect(text.lineEnding == .crlf)
        #expect(!text.readOnly)
        try expectRoundTrip(Data(bytes), "Big5")
        // An edit stays Big5 (and CRLF).
        let edited = try TextFileCodec.encode("發票匯出\n2026,done", like: text)
        #expect(edited == Data([0xB5, 0x6F, 0xB2, 0xBC, 0xB6, 0xD7, 0xA5, 0x58, 0x0D, 0x0A] + Array("2026,done\r\n".utf8)))
        #expect(throws: TextFileError.unencodable(.big5)) { try TextFileCodec.encode("發票 ก", like: text) }
    }

    @Test func invalidUTF8ThatIsNotBig5IsLatin1ReadOnly() throws {
        let bytes: [UInt8] = Array("caf".utf8) + [0xE9, 0x0A] + Array("na".utf8) + [0xEF, 0x76, 0x65, 0x0A]
        let text = try decoded(bytes)
        #expect(text.encoding == .latin1)
        #expect(text.readOnly)
        #expect(text.text == "café\nnaïve")
        try expectRoundTrip(Data(bytes), "Latin-1")
    }

    @Test func nulMeansBinaryOnlyInTheFirst8KB() throws {
        #expect(TextFileCodec.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])) == .failure(.binary))
        var late = Data(repeating: UInt8(ascii: "a"), count: TextFileCodec.binarySniffBytes)
        late.append(0)
        late.append(UInt8(ascii: "\n"))
        let text = try TextFileCodec.decode(late).get()
        #expect(text.encoding == .utf8)
    }

    @Test func sizeLimits() throws {
        let big = Data(repeating: UInt8(ascii: "x"), count: TextFileCodec.readOnlyBytes + 1)
        let text = try TextFileCodec.decode(big).get()
        #expect(text.readOnly)
        let huge = Data(count: TextFileCodec.refuseBytes + 1)
        #expect(TextFileCodec.decode(huge) == .failure(.tooLarge(TextFileCodec.refuseBytes + 1)))
    }

    @Test func lineEndingsCRLFCRMixedAndNoFinalNewline() throws {
        let crlf = try decoded("a\r\nb\r\n")
        #expect(crlf.lineEnding == .crlf && !crlf.mixedLineEndings && crlf.lineEndings == nil)
        let cr = try decoded("a\rb\rc")
        #expect(cr.lineEnding == .cr && !cr.hasFinalNewline && cr.text == "a\nb\nc")
        let mixed = try decoded("a\r\nb\nc\r\nd")
        #expect(mixed.mixedLineEndings)
        #expect(mixed.lineEnding == .crlf)
        #expect(mixed.lineEndings == [.crlf, .lf, .crlf])
        #expect(!mixed.hasFinalNewline)
        let none = try decoded("single line")
        #expect(none.lineEnding == .lf && !none.hasFinalNewline && none.lines == ["single line"])
        let empty = try decoded("")
        #expect(empty.text.isEmpty && !empty.hasFinalNewline)
        let tie = try decoded("a\nb\r\n")
        #expect(tie.lineEnding == .lf, "ties go to LF")
        for sample in ["a\r\nb\r\n", "a\rb\rc", "a\r\nb\nc\r\nd", "single line", "", "\n", "\r\n\r\n", "x\n\n\n", "a\r\r\nb"] {
            try expectRoundTrip(Data(sample.utf8), sample.debugDescription)
        }
    }

    @Test func mixedEndingsOneEditedLineChangesOnlyThatLine() throws {
        let original = "line 0\r\nline 1\nline 2\r\nline 3\nline 4\r\nline 5\n"
        let text = try decoded(original)
        #expect(text.mixedLineEndings)
        var lines = text.lines
        lines[3] = "LINE THREE (edited)"
        let written = try TextFileCodec.encode(lines.joined(separator: "\n"), like: text)
        let expected = "line 0\r\nline 1\nline 2\r\nLINE THREE (edited)\nline 4\r\nline 5\n"
        #expect(String(decoding: written, as: UTF8.self) == expected)
        // Bytes outside the edited line are identical.
        let a = Array(original.utf8)
        let b = Array(written)
        let prefix = zip(a, b).prefix { $0 == $1 }.count
        let suffix = zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
        #expect(prefix == Array("line 0\r\nline 1\nline 2\r\n".utf8).count)
        #expect(suffix == Array("\nline 4\r\nline 5\n".utf8).count)
    }

    @Test func mixedEndingsInsertedLinesTakeTheMajorityAndDeletionsKeepNeighbours() throws {
        let text = try decoded("a\r\nb\r\nc\nd\r\n")
        #expect(text.lineEnding == .crlf)
        var lines = text.lines
        lines.insert("new", at: 2)
        lines.remove(at: 0)
        let written = String(decoding: try TextFileCodec.encode(lines.joined(separator: "\n"), like: text), as: UTF8.self)
        #expect(written == "b\r\nnew\r\nc\nd\r\n")
    }

    @Test func indentationGuess() throws {
        #expect(try decoded("<template>\n  <main>\n    <h1/>\n  </main>\n</template>\n").indentation == .spaces(2))
        #expect(try decoded("def f():\n    if x:\n        y()\n    return 1\n").indentation == .spaces(4))
        #expect(try decoded("func f() {\n\tif x {\n\t\ty()\n\t}\n}\n").indentation == .tabs)
        #expect(try decoded("no indentation\nat all\n").indentation == .unknown)
    }
}
