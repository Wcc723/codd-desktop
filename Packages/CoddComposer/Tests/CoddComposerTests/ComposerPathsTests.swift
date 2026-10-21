import Testing
@testable import CoddComposer

@Suite("Composer path escaping")
struct ComposerPathsTests {
    @Test(arguments: [
        ("/Users/a/Library/Application Support/CODD/x.png", #"/Users/a/Library/Application\ Support/CODD/x.png"#),
        ("/tmp/plain-name_1.2,3+4@5^6.txt", "/tmp/plain-name_1.2,3+4@5^6.txt"),
        ("/Users/a/截圖 2026-10-16 下午3.04.12.png", #"/Users/a/截圖\ 2026-10-16\ 下午3.04.12.png"#),
        ("/Users/a/注音輸入法/設定.json", "/Users/a/注音輸入法/設定.json"),
        ("/tmp/it's \"quoted\"", #"/tmp/it\'s\ \"quoted\""#),
        ("/tmp/$HOME/`id`", #"/tmp/\$HOME/\`id\`"#),
        ("/tmp/a&b;c|d", #"/tmp/a\&b\;c\|d"#),
        ("/tmp/<in>(x)[y]{z}", #"/tmp/\<in\>\(x\)\[y\]\{z\}"#),
        ("/tmp/*?!#~=%", ##"/tmp/\*\?\!\#\~\=\%"##),
        ("/tmp/back\\slash", #"/tmp/back\\slash"#),
        ("/tmp/tab\there", "/tmp/tab\\\there"),
        ("", ""),
    ])
    func escapesLikeATerminalDrop(path: String, expected: String) {
        #expect(ComposerPaths.escaped(path) == expected)
    }

    @Test func everyListedCharacterGetsOneBackslash() {
        let listed = " \t'\"`$&;|<>()[]{}*?!#~=%\\"
        for scalar in listed.unicodeScalars {
            #expect(ComposerPaths.escaped(String(scalar)) == "\\" + String(scalar), "\(scalar.escaped(asASCII: true))")
        }
        #expect(ComposerPaths.escapedScalars.count == listed.unicodeScalars.count)
    }

    /// Review security-data-3: a line break in a file name would become a second command.
    @Test(arguments: [
        "/tmp/report\nrm -rf ~/x #.txt", "/tmp/a\rb", "/tmp/a\r\nb", "/tmp/a\u{85}b", "/tmp/a\u{2028}b",
        "/tmp/a\u{2029}b", "/tmp/a\u{1B}[31mb", "/tmp/a\u{7F}", "/tmp/a\u{9B}b", "/tmp/a\u{0}b",
    ])
    func controlCharactersAreNotInsertable(path: String) {
        #expect(!ComposerPaths.isInsertable(path))
    }

    @Test func ordinaryPathsAreInsertable() {
        for path in ["/Users/a/截圖 2026-10-16 下午3.04.12.png", "/tmp/tab\there", "/tmp/$HOME/`id`", "/tmp/cafe\u{301}"] {
            #expect(ComposerPaths.isInsertable(path), "\(path)")
        }
    }

    @Test func combiningMarksStayAttached() {
        // A decomposed "é" (e + U+0301), as some file systems store names.
        let path = "/tmp/cafe\u{301} menu.png"
        #expect(ComposerPaths.escaped(path) == "/tmp/cafe\u{301}\\ menu.png")
    }
}
