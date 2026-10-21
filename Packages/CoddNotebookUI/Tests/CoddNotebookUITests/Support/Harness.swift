import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

/// Registers the repo's fonts once (text widths match the app) and keeps the process an AppKit app.
@MainActor
enum TestFonts {
    private static var done = false

    static func register() {
        _ = NSApplication.shared
        guard !done else { return }
        done = true
        // Tests/CoddNotebookUITests/Support/Harness.swift → repo root.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Typeface.registerFonts(in: repo.appendingPathComponent("App/Fonts", isDirectory: true))
    }
}

/// A view hosted in a window that is never ordered on screen (field editors and first
/// responders work there), laid out at `size`.
@MainActor
final class Host<View: NSView> {
    let window: NSWindow
    let view: View

    init(_ view: View, size: CGSize) {
        TestFonts.register()
        self.view = view
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: CGRect(origin: .zero, size: size))
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        window.contentView = root
        settle()
    }

    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        #expect(!window.isVisible, "a test window was ordered in")
        window.contentView = nil
        window.close()
    }

    /// The frame of `sub` in the hosted view's coordinates.
    func frame(of sub: NSView) -> CGRect { sub.convert(sub.bounds, to: view) }
}

/// Records presented menus instead of showing them (no window is ever ordered in).
@MainActor
final class RecordingPresenter: NotebookMenuPresenting {
    private(set) var presented: [(menu: NSView, origin: CGPoint)] = []
    private var onClose: (() -> Void)?
    private(set) var dismissCount = 0

    var current: NotebookMenuView? { onClose == nil ? nil : presented.last?.menu as? NotebookMenuView }

    func present(_ menu: NSView, at topLeft: CGPoint, in host: NSView, onClose: @escaping () -> Void) {
        dismiss()
        presented.append((menu, topLeft))
        self.onClose = onClose
    }

    func dismiss() {
        guard let handler = onClose else { return }
        onClose = nil
        dismissCount += 1
        handler()
    }
}

/// Records callback values.
@MainActor
final class Recorder<Value> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
    var count: Int { values.count }
    var last: Value? { values.last }
}

@MainActor
enum Keys {
    static func event(_ keyCode: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    static var up: NSEvent { event(126, "\u{F700}") }
    static var down: NSEvent { event(125, "\u{F701}") }
    static var left: NSEvent { event(123, "\u{F702}") }
    static var right: NSEvent { event(124, "\u{F703}") }
    static var enter: NSEvent { event(36, "\r") }
    static var escape: NSEvent { event(53, "\u{1B}") }
}

/// Typing into a `NotebookTextField` through the real field editor.
@MainActor
enum Typing {
    static let notFound = NSRange(location: NSNotFound, length: 0)

    @discardableResult
    static func focus(_ field: NotebookTextField, in window: NSWindow) throws -> NSTextView {
        window.makeFirstResponder(field.field)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.moveToEndOfDocument(nil)
        return editor
    }

    static func type(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: notFound)
    }

    /// Asks the field's delegate about a command as the field editor would (true = the field
    /// took it). While marked text exists the field must decline (the input method's key).
    static func command(_ selector: Selector, field: NotebookTextField, editor: NSTextView) -> Bool {
        field.control(field.field, textView: editor, doCommandBy: selector)
    }

    /// An input method composing `text` (注音 syllables).
    static func compose(_ text: String, in editor: NSTextView) {
        editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: notFound)
    }
}

extension Array where Element == String {
    /// True when `expected` appear in this order (not necessarily adjacent).
    func containsInOrder(_ expected: [String]) -> Bool {
        var index = startIndex
        for item in expected {
            guard let found = self[index...].firstIndex(of: item) else { return false }
            index = found + 1
        }
        return true
    }

    func missing(_ expected: [String]) -> [String] { expected.filter { text in !contains(text) } }
}

/// Fast "not blank" check over a bitmap's raw bytes (every 3rd pixel).
enum Pixels {
    static func differing(from background: NSColor, in rep: NSBitmapImageRep, tolerance: Int = 8) -> Int {
        guard let data = rep.bitmapData, let bg = background.usingColorSpace(.sRGB) else { return 0 }
        let reference = [bg.redComponent, bg.greenComponent, bg.blueComponent].map { Int(($0 * 255).rounded()) }
        let bytesPerPixel = rep.bitsPerPixel / 8
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                let p = data + y * rep.bytesPerRow + x * bytesPerPixel
                if abs(Int(p[0]) - reference[0]) > tolerance || abs(Int(p[1]) - reference[1]) > tolerance
                    || abs(Int(p[2]) - reference[2]) > tolerance { count += 1 }
            }
        }
        return count
    }
}
