import AppKit
import Foundation
import Testing
@testable import CoddTerminal

@Suite("Key-equivalent policy")
struct KeyEquivalentPolicyTests {
    private let policy = KeyEquivalentPolicy.codd

    /// (charactersIgnoringModifiers, ANSI key code) as AppKit reports them on a US layout.
    private static let reservedCommandKeys: [(String, UInt16)] = [
        ("k", 0x28), ("\\", 0x2A), ("j", 0x26), ("t", 0x11), ("l", 0x25), (",", 0x2B), ("n", 0x2D),
        ("w", 0x0D), ("q", 0x0C), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("5", 0x17),
        ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
    ]

    @Test func reservesCoddShortcuts() {
        for (characters, keyCode) in Self.reservedCommandKeys {
            #expect(policy.isReserved(characters: characters, keyCode: keyCode, modifiers: .command), "⌘\(characters)")
        }
        // ⌘⇧[ and ⌘⇧]: AppKit applies Shift to charactersIgnoringModifiers.
        #expect(policy.isReserved(characters: "{", keyCode: 0x21, modifiers: [.command, .shift]))
        #expect(policy.isReserved(characters: "}", keyCode: 0x1E, modifiers: [.command, .shift]))
        #expect(policy.isReserved(characters: "[", keyCode: 0x21, modifiers: [.command, .shift]))
        #expect(policy.reserved.count == 20)
    }

    @Test func leavesTerminalShortcutsToTheTerminal() {
        let terminal: [(String, UInt16, KeyModifiers)] = [
            ("c", 0x08, .command), ("v", 0x09, .command), ("a", 0x00, .command), ("=", 0x18, .command),
            ("+", 0x18, [.command, .shift]), ("-", 0x1B, .command), ("0", 0x1D, .command),
        ]
        for (characters, keyCode, modifiers) in terminal {
            #expect(!policy.isReserved(characters: characters, keyCode: keyCode, modifiers: modifiers), "\(characters)")
        }
    }

    @Test func modifiersMustMatchExactly() {
        #expect(!policy.isReserved(characters: "K", keyCode: 0x28, modifiers: [.command, .shift]))
        #expect(!policy.isReserved(characters: "k", keyCode: 0x28, modifiers: .control))
        #expect(!policy.isReserved(characters: "k", keyCode: 0x28, modifiers: []))
        #expect(!policy.isReserved(characters: "1", keyCode: 0x12, modifiers: [.command, .option]))
        #expect(!policy.isReserved(characters: "[", keyCode: 0x21, modifiers: .command))
        #expect(!policy.isReserved(characters: "]", keyCode: 0x1E, modifiers: [.command, .control, .shift]))
    }

    @Test func inputMethodCharactersFallBackToTheKeyCode() {
        // 注音 reports the Zhuyin symbol of the key, not the Latin letter.
        #expect(policy.isReserved(characters: "ㄜ", keyCode: 0x28, modifiers: .command))
        #expect(policy.isReserved(characters: "ㄅ", keyCode: 0x12, modifiers: .command))
        #expect(!policy.isReserved(characters: "ㄏ", keyCode: 0x08, modifiers: .command)) // ⌘C stays
        #expect(policy.isReserved(characters: "", keyCode: 0x2D, modifiers: .command))
    }

    @Test func latinLayoutsMatchByCharacter() {
        // Dvorak: the key labelled K sits where QWERTY has V (0x09); ⌘K follows the character.
        #expect(policy.isReserved(characters: "k", keyCode: 0x09, modifiers: .command))
        #expect(!policy.isReserved(characters: "v", keyCode: 0x28, modifiers: .command))
    }

    @Test func ghosttyTriggersNameBothSpellings() {
        #expect(KeyChord("k", .command)?.ghosttyTriggers == ["super+k", "super+key_k"])
        #expect(KeyChord("1", .command)?.ghosttyTriggers == ["super+1", "super+digit_1"])
        #expect(KeyChord("\\", .command)?.ghosttyTriggers == ["super+backslash"])
        #expect(KeyChord("[", [.command, .shift])?.ghosttyTriggers == ["shift+super+[", "shift+super+bracket_left"])
        #expect(KeyChord("ß", .command) == nil)
    }

    @Test func describesChords() {
        #expect(KeyChord("k", .command)?.description == "⌘K")
        #expect(KeyChord("]", [.command, .shift])?.description == "⇧⌘]")
    }
}

@Suite("Image-only paste detection")
@MainActor
struct ImagePasteTests {
    /// A private pasteboard, so the user's clipboard is never touched.
    private func withPasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("codd-terminal-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        body(pasteboard)
    }

    private func commandV(_ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 0x09
        )!
    }

    @Test func imageWithoutTextSendsControlV() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            #expect(CoddTerminalView.isImageOnlyPaste(commandV(), pasteboard: pasteboard))
            #expect(!CoddTerminalView.isImageOnlyPaste(commandV([.command, .shift]), pasteboard: pasteboard))
        }
    }

    @Test func textOrFilesPasteNormally() {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            pasteboard.setString("caption", forType: .string)
            #expect(!CoddTerminalView.isImageOnlyPaste(commandV(), pasteboard: pasteboard))
            pasteboard.clearContents()
            #expect(!CoddTerminalView.isImageOnlyPaste(commandV(), pasteboard: pasteboard))
        }
    }
}
