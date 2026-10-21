import AppKit
import CoddUI
@testable import CoddCleanupUI

/// Records every callback the page calls.
@MainActor
final class CallLog {
    private(set) var events: [String] = []
    private(set) var selections: [Set<String>] = []
    private(set) var bulks: [(String, Set<String>)] = []

    func record(_ event: String) { events.append(event) }

    func wire(_ page: CleanupPageView) {
        page.onBack = { [weak self] in self?.record("back") }
        page.onOpenSettings = { [weak self] in self?.record("settings") }
        page.onGenerate = { [weak self] in self?.record("generate") }
        page.onCancelRun = { [weak self] in self?.record("cancel") }
        page.onApply = { [weak self] in self?.record("apply") }
        page.onRegenerate = { [weak self] in self?.record("regenerate") }
        page.onDiscard = { [weak self] in self?.record("discard") }
        page.onTab = { [weak self] tab in self?.record("tab:\(tab.rawValue)") }
        page.onSelection = { [weak self] ids in
            self?.selections.append(ids)
            self?.record("selection:\(ids.count)")
        }
        page.onRowAction = { [weak self] id, title in self?.record("row:\(id):\(title)") }
        page.onBulk = { [weak self] action, ids in
            self?.bulks.append((action, ids))
            self?.record("bulk:\(action):\(ids.count)")
        }
        page.onCondenseAccount = { [weak self] id in self?.record("account:\(id)") }
        page.onCondenseModel = { [weak self] name in self?.record("model:\(name)") }
    }
}

/// The page in an offscreen borderless window (never ordered in) at the artboard's 1368 × 876.
@MainActor
final class CleanupHarness {
    static let size = CGSize(width: 1368, height: 876)

    let log = CallLog()
    let page: CleanupPageView
    let window: NSWindow

    init(_ model: CleanupPageModel = CleanupSamples.artboard, size: CGSize = CleanupHarness.size) {
        Self.registerFonts()
        page = CleanupPageView(model: model)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: CGRect(origin: .zero, size: size))
        page.frame = root.bounds
        root.addSubview(page)
        window.contentView = root
        log.wire(page)
        settle()
    }

    func update(_ model: CleanupPageModel) {
        page.update(model)
        settle()
    }

    func settle() { page.layoutSubtreeIfNeeded() }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    var texts: [String] { page.visibleTexts }
    var allText: String { texts.joined(separator: "\n") }

    func row(_ id: String) -> CleanupRowView {
        guard let row = page.review.rowViews[id] else { fatalError("no row \(id)") }
        return row
    }

    /// The page's frame of `view` (page coordinates, top-left origin).
    func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: page.document) }

    /// A key event for the page's window.
    func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    func press(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = key(characters, keyCode: keyCode, flags: flags)
        if flags.contains(.command) {
            _ = page.performKeyEquivalent(with: event)
        } else {
            page.keyDown(with: event)
        }
        settle()
    }

    func space() { press(" ", keyCode: 49) }
    func commandA() { press("a", keyCode: 0, flags: .command) }
    func delete() { press("\u{7F}", keyCode: 51) }
    func escape() { press("\u{1B}", keyCode: 53) }
    func down() { press("\u{F701}", keyCode: 125) }
    func up() { press("\u{F700}", keyCode: 126) }

    func focusPage() {
        window.makeFirstResponder(page)
        settle()
    }

    private static var fontsRegistered = false

    /// Registers App/Fonts from the repository (the tests also pass without them: Typeface falls
    /// back to the system monospaced font).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        Typeface.registerFonts(in: repo.appendingPathComponent("App/Fonts", isDirectory: true))
    }
}

extension CleanupHarness {
    /// A left mouse-down for `view` (the views act on mouse-down).
    func click(_ view: NSView) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
        settle()
    }

    /// The deepest view under `point` (page document coordinates).
    func hit(_ point: CGPoint) -> NSView? {
        // `hitTest` takes the point in the receiver's superview: the window's frame view, whose
        // coordinates are the window's for a borderless window.
        window.contentView?.hitTest(page.document.convert(point, to: nil))
    }

    var bulkButtons: [String: CoddButton] { page.review.bulkBar.buttons }
    var body: CondenseBodyView { page.condense.body }
}

extension Array where Element == String {
    /// The expected strings that are missing (readable failures).
    func missing(_ expected: [String]) -> [String] { expected.filter { !contains($0) } }
}
