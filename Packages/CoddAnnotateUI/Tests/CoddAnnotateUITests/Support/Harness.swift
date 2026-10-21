import AppKit
import CoddUI
@testable import CoddAnnotateUI

/// The screen at the demo's 1368 × 876 in an offscreen borderless window that is never ordered
/// in; events are synthesized and handed to the views directly.
@MainActor
final class AnnotateHarness {
    let view: ImageAnnotateView
    let window: NSWindow
    private(set) var changes: [AnnotationDocument] = []
    private(set) var done: [AnnotationDocument] = []
    private(set) var cancels = 0

    static let size = CGSize(width: 1368, height: 876)
    private static var cachedImage: CGImage?

    static var image: CGImage {
        if let cachedImage { return cachedImage }
        let image = ImageAnnotateSamples.placeholderImage()
        cachedImage = image
        return image
    }

    init(document: AnnotationDocument = ImageAnnotateSamples.document, size: CGSize = AnnotateHarness.size, selection: Int? = nil) {
        Self.registerFonts()
        view = ImageAnnotateView(image: Self.image, document: document, header: ImageAnnotateSamples.header)
        view.previewText = ImageAnnotateSamples.previewText
        view.markdownSource = ImageAnnotateSamples.markdownSource
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = FlippedView(frame: CGRect(origin: .zero, size: size))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        view.selection = selection
        view.onChange = { [unowned self] in self.changes.append($0) }
        view.onDone = { [unowned self] in self.done.append($0) }
        view.onCancel = { [unowned self] in self.cancels += 1 }
        settle()
    }

    func settle() { window.contentView?.layoutSubtreeIfNeeded() }

    func tearDown() {
        // Never shown: the tests synthesize events on views in a window that is never ordered in.
        precondition(!window.isVisible, "a test window was ordered in")
        window.contentView = nil
        window.close()
    }

    var canvas: AnnotateCanvasView { view.stage.canvas }
    var mapping: CanvasMapping { canvas.mapping }
    var panel: PanelContentView { view.panel.content }
    var items: [AnnotationDraft] { view.document.items }

    /// The canvas point of an image pixel.
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { mapping.view(x, y) }

    /// The image pixel in the middle of what the stage shows (zoomed views scroll).
    var visibleCenterPixel: CGPoint {
        let visible = canvas.visibleRect
        return mapping.pixel(CGPoint(x: visible.midX, y: visible.midY))
    }

    func mouse(_ type: NSEvent.EventType, _ point: CGPoint, shift: Bool = false, clicks: Int = 1) -> NSEvent {
        let location = canvas.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                             pressure: 1)
        else { fatalError("cannot make a mouse event") }
        return event
    }

    /// A press, drags in `steps` and a release on the canvas.
    func drag(_ from: CGPoint, _ to: CGPoint, shift: Bool = false, steps: Int = 4) {
        canvas.mouseDown(with: mouse(.leftMouseDown, from, shift: shift))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            canvas.mouseDragged(with: mouse(.leftMouseDragged, point, shift: shift))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, to, shift: shift))
    }

    func click(_ point: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, point))
        canvas.mouseUp(with: mouse(.leftMouseUp, point))
    }

    func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                           keyCode: keyCode)
        else { fatalError("cannot make a key event") }
        return event
    }

    /// Types on whatever has keyboard focus (the canvas, a field editor, the comment area).
    func press(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        window.firstResponder?.keyDown(with: key(characters, keyCode: keyCode, flags: flags))
    }

    static let keyV: UInt16 = 9, keyR: UInt16 = 15, keyP: UInt16 = 35, keyA: UInt16 = 0, keyT: UInt16 = 17, keyZ: UInt16 = 6
    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117, escape: UInt16 = 53

    // MARK: Panel fields

    var expanded: ExpandedItemView? { panel.expanded }

    /// Focuses a coordinate field and returns its field editor.
    @discardableResult
    func focus(_ field: CoordinateField) -> NSTextView {
        guard let coord = expanded?.field(field) else { fatalError("no field \(field)") }
        window.makeFirstResponder(coord.field)
        guard let editor = window.firstResponder as? NSTextView else { fatalError("no field editor") }
        return editor
    }

    /// Replaces a field's text and presses ⏎ (or leaves the field when `enter` is false).
    func type(_ text: String, in field: CoordinateField, enter: Bool = true) {
        let editor = focus(field)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        if enter {
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        } else {
            view.focusCanvas()
        }
    }

    var commentView: FocusTextView {
        guard let expanded else { fatalError("nothing expanded") }
        return expanded.comment.textView
    }

    private static var fontsRegistered = false

    /// App/Fonts from the repository (the tests also pass without them: Typeface falls back).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        Typeface.registerFonts(in: url.appendingPathComponent("App/Fonts", isDirectory: true))
    }
}
