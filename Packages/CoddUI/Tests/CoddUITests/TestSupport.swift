import AppKit
import CoddUI

/// Shared test helpers. Everything here goes through CoddUI's public API only.
@MainActor
enum TestSupport {
    /// The repository root, from this file's location (Packages/CoddUI/Tests/CoddUITests/…).
    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    /// Registers App/Fonts (idempotent) and makes sure an NSApplication exists for windows.
    @discardableResult
    static func prepare() -> Bool {
        _ = NSApplication.shared
        return Typeface.registerFonts(in: repositoryRoot.appendingPathComponent("App/Fonts", isDirectory: true))
    }

    /// An offscreen window hosting `view` at `size` (never ordered in), laid out.
    static func host(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = FlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        return window
    }

    /// A left-click at `point` (the view's flipped coordinates).
    static func click(_ view: NSView, at point: CGPoint) {
        guard let window = view.window else { return }
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    /// A key-down event (`characters` such as " " or the arrow function-key characters).
    static func key(_ characters: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    /// Renders `view` and returns how many pixels differ from the page color.
    static func inkedPixels(_ view: NSView, size: NSSize? = nil, width: CGFloat? = nil) -> Int {
        guard let rep = ViewSnapshot.render(view, size: size, width: width) else { return 0 }
        return ViewSnapshot.pixelsDiffering(from: Palette.bg, in: rep)
    }

    /// sRGB components 0...255.
    static func rgb(_ color: NSColor?) -> [Int] {
        guard let color = color?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    static func close(_ value: [Int], _ expected: [Int], tolerance: Int = 6) -> Bool {
        value.count == expected.count && zip(value, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

/// Counts target / action messages.
@MainActor
final class ActionCounter: NSObject {
    private(set) var count = 0
    private(set) var lastSender: AnyObject?

    @objc func fire(_ sender: AnyObject?) {
        count += 1
        lastSender = sender
    }
}
