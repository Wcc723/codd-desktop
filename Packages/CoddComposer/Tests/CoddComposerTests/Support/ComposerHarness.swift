import AppKit
import Foundation
@testable import CoddComposer

/// One `ComposerField` in a window that is never ordered on screen, its text view first responder,
/// every callback recorded and the modifier flags injected.
@MainActor
final class ComposerHarness {
    let window: NSWindow
    let field: ComposerField
    var textView: ComposerTextView { field.textView }

    var submitted: [String] = []
    var escapes = 0
    var historyRequests: [ComposerHistoryDirection] = []
    var historyAnswers: [ComposerHistoryDirection: String] = [:]
    var pastedImages: [ComposerPastedImage] = []
    var imageAnswer: String?
    var textChanges: [String] = []
    var heights: [CGFloat] = []
    /// What `modifierFlagsProvider` reports (NSApp.currentEvent is not the synthesized event).
    var flags: NSEvent.ModifierFlags = []

    init(width: CGFloat = 400, style: ComposerStyle = .standard, resizesToPreferredHeight: Bool = true) {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        window.contentView = host
        field = ComposerField(style: style)
        field.frame = NSRect(x: 0, y: 0, width: width, height: field.preferredHeight)
        host.addSubview(field)
        textView.modifierFlagsProvider = { [unowned self] in flags }
        textView.onSubmit = { [unowned self] in submitted.append($0) }
        textView.onEscape = { [unowned self] in escapes += 1 }
        textView.onHistory = { [unowned self] direction in
            historyRequests.append(direction)
            return historyAnswers[direction]
        }
        textView.onPasteImage = { [unowned self] image in
            pastedImages.append(image)
            guard let imageAnswer else { return false }
            textView.insertAttachmentText(imageAnswer)
            return true
        }
        textView.onTextChange = { [unowned self] in textChanges.append($0) }
        field.onHeightChange = { [unowned self] height in
            heights.append(height)
            if resizesToPreferredHeight {
                field.setFrameSize(NSSize(width: field.frame.width, height: height))
            }
        }
        field.layoutSubtreeIfNeeded()
        window.makeFirstResponder(textView)
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    /// Sets the text and caret the way a user would have left them (no callbacks).
    func set(_ text: String, caret: Int? = nil) {
        field.text = text
        let location = caret ?? (text as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))
        settle()
    }

    func settle() {
        field.layoutSubtreeIfNeeded()
    }

    /// A key-down as AppKit delivers it to the first responder; it goes through `interpretKeyEvents`.
    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        flags = modifiers
        textView.keyDown(with: keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
        flags = []
    }

    func pressReturn(_ modifiers: NSEvent.ModifierFlags = []) {
        press("\r", keyCode: 36, modifiers: modifiers)
    }

    /// Starts an input method composition at the caret, as 注音 does (`ㄓㄨˋ` before conversion).
    func compose(_ marked: String = "ㄓㄨˋ") {
        textView.setMarkedText(
            marked,
            selectedRange: NSRange(location: (marked as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    var caret: Int {
        textView.selectedRange().location
    }
}

/// A pasteboard of its own, so tests never touch the general one.
@MainActor
final class PrivatePasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("codd-composer-test-\(UUID().uuidString)"))

    init() {
        pasteboard.clearContents()
    }

    func release() {
        pasteboard.releaseGlobally()
    }
}

enum TestImages {
    /// A `width`×`height` bitmap filled with one color.
    @MainActor
    static func bitmap(width: Int = 3, height: Int = 2) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0 ..< width {
            for y in 0 ..< height {
                rep.setColor(NSColor(deviceRed: 1, green: 0.72, blue: 0.29, alpha: 1), atX: x, y: y)
            }
        }
        return rep
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
}

/// A fresh directory under the system temp dir, removed by `remove()`.
struct TempDirectory {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codd-composer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}
