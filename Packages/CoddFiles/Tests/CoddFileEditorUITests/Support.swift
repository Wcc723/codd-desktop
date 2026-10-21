import AppKit
import CoddUI
@testable import CoddFileEditorUI

/// Registers the repo's fonts once (text widths match the app) and makes the process an AppKit app.
@MainActor
enum TestFonts {
    private static var done = false

    static func register() {
        _ = NSApplication.shared
        guard !done else { return }
        done = true
        // Tests/CoddFileEditorUITests/Support.swift → repo root.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        Typeface.registerFonts(in: repo.appendingPathComponent("App/Fonts", isDirectory: true))
    }
}

/// Hosts a view at `size` in a window that is never ordered on screen (titled, so the field
/// editor can take the first responder for the IME tests).
@MainActor
final class Host<View: NSView> {
    let window: NSWindow
    let view: View

    init(_ view: View, size: NSSize) {
        TestFonts.register()
        self.view = view
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = FlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    /// Draws the view into an sRGB bitmap (`cacheDisplay` runs every `draw(_:)`), so token colors
    /// can be compared exactly.
    func render() -> NSBitmapImageRep? {
        layout()
        guard let rep = FileEditorSnapshot.sRGBBitmap(for: view.bounds.size, scale: 2) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

extension NSBitmapImageRep {
    /// Whether some pixel is within `tolerance` of `color` (sRGB 8-bit bitmaps from `render()`).
    func contains(_ color: NSColor, tolerance: Int = 14) -> Bool {
        guard let target = color.usingColorSpace(.sRGB), let data = bitmapData, samplesPerPixel >= 3, bitsPerSample == 8 else { return false }
        let t = [target.redComponent, target.greenComponent, target.blueComponent].map { Int(($0 * 255).rounded()) }
        for y in 0..<pixelsHigh {
            let row = data + y * bytesPerRow
            for x in 0..<pixelsWide {
                let p = row + x * samplesPerPixel
                if abs(Int(p[0]) - t[0]) <= tolerance, abs(Int(p[1]) - t[1]) <= tolerance, abs(Int(p[2]) - t[2]) <= tolerance { return true }
            }
        }
        return false
    }

    /// Share of pixels that differ from --bg by more than 8 in a channel (not blank).
    func inkRatio() -> Double {
        guard let data = bitmapData, samplesPerPixel >= 3 else { return 0 }
        var count = 0
        for y in 0..<pixelsHigh {
            let row = data + y * bytesPerRow
            for x in 0..<pixelsWide {
                let p = row + x * samplesPerPixel
                if Int(p[0]) > 5 + 8 || Int(p[1]) > 5 + 8 || Int(p[2]) > 5 + 8 { count += 1 }
            }
        }
        return Double(count) / Double(max(1, pixelsWide * pixelsHigh))
    }
}

/// Records callback values.
@MainActor
final class Calls<Value> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}
