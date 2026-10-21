import AppKit
import CoddUI
@testable import CoddDialogsUI

/// Registers the repo's fonts once (so text widths match the app) and keeps the process an AppKit app.
@MainActor
enum TestFonts {
    private static var done = false

    static func register() {
        _ = NSApplication.shared
        guard !done else { return }
        done = true
        // Tests/CoddDialogsUITests/Support/DialogHarness.swift → repo root.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Typeface.registerFonts(in: repo.appendingPathComponent("App/Fonts", isDirectory: true))
    }
}

/// A dialog view hosted in a window that is never ordered on screen, laid out at its fitting size.
@MainActor
final class DialogHarness<View: DialogContentView> {
    let window: NSWindow
    let view: View

    init(_ view: View) {
        TestFonts.register()
        self.view = view
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.dialogWidth, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        settle()
    }

    func settle() {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.setContentSize(NSSize(width: view.dialogWidth, height: size.height))
        view.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    /// A key-down as the window would see it.
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    /// ⏎ through the window (AppKit's order: the key window's views claim key equivalents first).
    @discardableResult
    func pressReturn() -> Bool { window.performKeyEquivalent(with: key("\r", keyCode: 0x24)) }

    @discardableResult
    func pressEscape() -> Bool { window.performKeyEquivalent(with: key("\u{1B}", keyCode: 0x35)) }

    /// Renders the dialog into a bitmap (cacheDisplay draws every layer-backed view's `draw`).
    func render() -> NSBitmapImageRep? {
        settle()
        guard let rep = DialogSnapshot.sRGBBitmap(for: view.bounds.size) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// Records callback values.
@MainActor
final class Recorder<Value> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
    var count: Int { values.count }
}

extension NSBitmapImageRep {
    /// Pixels whose color differs from the frame background (#0a0a0a) by more than a little: the
    /// dialog drew text, borders and bars.
    func inkRatio() -> Double {
        var ink = 0
        var total = 0
        let step = 3
        for y in stride(from: 0, to: pixelsHigh, by: step) {
            for x in stride(from: 0, to: pixelsWide, by: step) {
                guard let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let distance = abs(color.redComponent - 10 / 255) + abs(color.greenComponent - 10 / 255) + abs(color.blueComponent - 10 / 255)
                if distance > 0.15 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    /// Whether some pixel is close to `target` (sRGB).
    func contains(_ target: NSColor, tolerance: CGFloat = 0.08) -> Bool {
        guard let t = target.usingColorSpace(.sRGB) else { return false }
        for y in stride(from: 0, to: pixelsHigh, by: 2) {
            for x in stride(from: 0, to: pixelsWide, by: 2) {
                guard let c = colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - t.redComponent) < tolerance, abs(c.greenComponent - t.greenComponent) < tolerance,
                   abs(c.blueComponent - t.blueComponent) < tolerance { return true }
            }
        }
        return false
    }
}

extension NSView {
    /// Every NSTextField string under this view (labels, wrapping labels), depth first.
    func allLabelTexts() -> [String] {
        var texts: [String] = []
        for sub in subviews where !sub.isHiddenOrHasHiddenAncestor {
            if let field = sub as? NSTextField, !field.isEditable { texts.append(field.stringValue) }
            texts += sub.allLabelTexts()
        }
        return texts
    }

    /// Every visible CoddButton label under this view.
    func allButtonLabels() -> [String] {
        var labels: [String] = []
        for sub in subviews where !sub.isHiddenOrHasHiddenAncestor {
            if let button = sub as? CoddButton { labels.append(button.label) }
            labels += sub.allButtonLabels()
        }
        return labels
    }
}
