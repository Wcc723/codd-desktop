import Testing
@testable import CoddComposer

@Suite("Composer payload encoding")
struct ComposerEncodingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var input: String
        var bytes: String
        var paste: Bool
        var testDescription: String { input.debugDescription }
    }

    @Test(arguments: [
        // Single line: typed as is, Enter follows.
        Case(input: "hello", bytes: "hello", paste: false),
        Case(input: "修正登入 API 401", bytes: "修正登入 API 401", paste: false),
        Case(input: "  indented", bytes: "  indented", paste: false),
        // Multi-line: one paste, line breaks as CR.
        Case(input: "第一行\r\n第二行", bytes: "第一行\r第二行", paste: true),
        Case(input: "第一行\n第二行", bytes: "第一行\r第二行", paste: true),
        Case(input: "a\rb", bytes: "a\rb", paste: true),
        Case(input: "a\n\nb", bytes: "a\r\rb", paste: true),
        Case(input: "a\r\n\r\nb", bytes: "a\r\rb", paste: true),
        Case(input: "a\u{2028}b", bytes: "a\rb", paste: true),
        Case(input: "a\u{2029}b\u{85}c", bytes: "a\rb\rc", paste: true),
        // A TAB would trigger completion in Claude's prompt if typed.
        Case(input: "a\tb", bytes: "a\tb", paste: true),
        Case(input: "\tlead", bytes: "\tlead", paste: true),
        // Controls removed, ESC first (no escape sequence can be smuggled, nor a paste end marker).
        Case(input: "ab\u{1B}[31mc", bytes: "ab[31mc", paste: false),
        Case(input: "x\u{1B}[201~y", bytes: "x[201~y", paste: false),
        Case(input: "a\u{0}b\u{7F}c\u{7}d\u{8}e\u{1F}f", bytes: "abcdef", paste: false),
        Case(input: "a\u{9B}31mb\u{80}c", bytes: "a31mbc", paste: false),
        // Trailing whitespace and newlines dropped.
        Case(input: "hello\n\n  \n", bytes: "hello", paste: false),
        Case(input: "hello \t", bytes: "hello", paste: false),
        Case(input: "第一行\n第二行\n\n", bytes: "第一行\r第二行", paste: true),
        Case(input: "done\u{3000}", bytes: "done", paste: false),
        Case(input: "end\u{1B}", bytes: "end", paste: false),
    ])
    func encodes(_ example: Case) throws {
        let payload = try ComposerEncoding.payload(for: example.input)
        #expect(payload == ComposerPayload(bytes: Array(example.bytes.utf8), paste: example.paste, submit: true))
    }

    @Test(arguments: ["", " ", "\n\n", " \t\r\n", "\u{1B}", "\u{1B}\u{7}\u{0}", "\u{3000}"])
    func emptyAfterCleaning(_ input: String) {
        #expect(throws: ComposerEncodingError.empty) { try ComposerEncoding.payload(for: input) }
    }

    @Test func submitPassesThrough() throws {
        #expect(try ComposerEncoding.payload(for: "hi", submit: false).submit == false)
        #expect(try ComposerEncoding.payload(for: "a\nb", submit: false) == ComposerPayload(
            bytes: Array("a\rb".utf8), paste: true, submit: false
        ))
    }

    @Test func limitIsInclusive() throws {
        let exact = String(repeating: "a", count: ComposerEncoding.maxBytes)
        #expect(try ComposerEncoding.payload(for: exact).bytes.count == ComposerEncoding.maxBytes)
        // Trailing newlines do not count: they are trimmed first.
        #expect(try ComposerEncoding.payload(for: exact + "\n\n").bytes.count == ComposerEncoding.maxBytes)
    }

    @Test func tooLongReportsTheByteCount() {
        let ascii = String(repeating: "a", count: ComposerEncoding.maxBytes + 1)
        #expect(throws: ComposerEncodingError.tooLong(ComposerEncoding.maxBytes + 1)) {
            try ComposerEncoding.payload(for: ascii)
        }
        // CJK is 3 UTF-8 bytes per character: the limit is in bytes, not characters.
        let characters = ComposerEncoding.maxBytes / 3 + 1
        let cjk = String(repeating: "修", count: characters)
        #expect(throws: ComposerEncodingError.tooLong(characters * 3)) {
            try ComposerEncoding.payload(for: cjk)
        }
    }

    @Test func maxBytesIs256KiB() {
        #expect(ComposerEncoding.maxBytes == 262_144)
    }
}
