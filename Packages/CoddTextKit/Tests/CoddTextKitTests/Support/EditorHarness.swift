import AppKit
import Foundation
@testable import CoddTextKit

/// One `MarkdownEditorView` in a window that is never ordered on screen, its text view first
/// responder (live preview reveals the caret paragraph only with focus), every callback recorded.
@MainActor
final class EditorHarness {
    let window: NSWindow
    let editor: MarkdownEditorView
    var textView: MarkdownTextView { editor.textView }
    var layoutManager: NSLayoutManager { editor.layoutManagerRef }

    var textChanges: [String] = []
    var carets: [MarkdownCaret] = []
    var pastedImages: [MarkdownPastedImage] = []
    var pasteAnswer = true
    var openedLinks: [String] = []
    var annotated: [String] = []
    var commandReturns = 0
    /// What `modifierFlagsProvider` reports (NSApp.currentEvent is not the synthesized event).
    var flags: NSEvent.ModifierFlags = []

    init(width: CGFloat = 760, height: CGFloat = 820, style: MarkdownEditorStyle = .notebook) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        editor = MarkdownEditorView(style: style)
        editor.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = editor
        textView.modifierFlagsProvider = { [unowned self] in flags }
        editor.onTextChange = { [unowned self] in textChanges.append($0) }
        editor.onCaretChange = { [unowned self] in carets.append($0) }
        editor.onPasteImage = { [unowned self] image in
            pastedImages.append(image)
            return pasteAnswer
        }
        editor.onOpenLink = { [unowned self] in openedLinks.append($0) }
        editor.onEditImageAnnotations = { [unowned self] in annotated.append($0) }
        editor.onCommandReturn = { [unowned self] in commandReturns += 1 }
        editor.layoutSubtreeIfNeeded()
        window.makeFirstResponder(textView)
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    var text: String { textView.string }
    var caret: Int { textView.selectedRange().location }

    /// Loads a document with the caret at `caret` (default: the end) and lays it out.
    func load(_ text: String, caret: Int? = nil) {
        editor.load(text, selection: NSRange(location: caret ?? (text as NSString).length, length: 0))
        settle()
    }

    func settle() {
        editor.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: editor.container)
        editor.layoutSubtreeIfNeeded()
    }

    func select(_ location: Int, length: Int = 0) {
        textView.setSelectedRange(NSRange(location: location, length: length))
        settle()
    }

    func type(_ string: String) {
        textView.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Starts an input method composition at the caret, as 注音 does.
    func compose(_ marked: String = "ㄓ") {
        textView.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Lets the run loop finish a pass, which closes the undo manager's event group (and fires
    /// anything scheduled on the main queue).
    func endEvent(_ seconds: TimeInterval = 0) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// A key equivalent as AppKit delivers it (the window walks the views).
    @discardableResult
    func keyEquivalent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        textView.performKeyEquivalent(with: keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
    }

    /// A key-down through `interpretKeyEvents` (what the input system does with it).
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        flags = modifiers
        textView.keyDown(with: keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
        flags = []
    }

    func pressReturn(_ modifiers: NSEvent.ModifierFlags = []) {
        flags = modifiers
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        flags = []
    }

    // MARK: Inspection

    /// Every attribute run of `range` (for "nothing changed" checks).
    func attributeRuns(in range: NSRange) -> [String] {
        var runs: [String] = []
        editor.storage.enumerateAttributes(in: range, options: []) { attributes, run, _ in
            let keys = attributes.keys.map(\.rawValue).sorted()
            let described = keys.map { key -> String in
                let value = attributes[NSAttributedString.Key(key)]
                if let font = value as? NSFont { return "\(key)=\(font.fontName)@\(font.pointSize)" }
                if let color = value as? NSColor { return "\(key)=\(color.description)" }
                if let paragraph = value as? NSParagraphStyle {
                    return "\(key)=\(paragraph.minimumLineHeight)/\(paragraph.firstLineHeadIndent)/\(paragraph.headIndent)"
                }
                return "\(key)=\(String(describing: value))"
            }
            runs.append("\(run.location),\(run.length):\(described.joined(separator: ";"))")
        }
        return runs
    }

    /// The glyph property of the character at `index` (hidden characters are zero-advance control glyphs).
    func isHidden(_ index: Int) -> Bool {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let property = layoutManager.propertyForGlyph(at: glyph)
        let unit = editor.storage.mutableString.character(at: index)
        return property.contains(.controlCharacter) && unit != 0x0A && unit != 0x0D && unit != 0x09
    }

    /// The width a character's glyph takes.
    func glyphWidth(_ index: Int) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.container).width
    }

    /// The line fragment rect holding the character at `index`.
    func fragment(at index: Int) -> NSRect {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    func location(of substring: String, in text: String? = nil) -> Int {
        ((text ?? self.text) as NSString).range(of: substring).location
    }
}

/// A pasteboard of its own, so tests never touch the general one.
@MainActor
final class PrivatePasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("codd-textkit-test-\(UUID().uuidString)"))

    init() {
        pasteboard.clearContents()
    }

    func release() {
        pasteboard.releaseGlobally()
    }
}

/// A fresh directory under the system temp dir, removed by `remove()`.
struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("codd-textkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum TestImages {
    @MainActor
    static func png(width: Int = 4, height: Int = 3) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0 ..< width {
            for y in 0 ..< height { rep.setColor(NSColor(deviceRed: 1, green: 0.72, blue: 0.29, alpha: 1), atX: x, y: y) }
        }
        return rep.representation(using: .png, properties: [:])!
    }
}

/// A seeded generator for the property tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
