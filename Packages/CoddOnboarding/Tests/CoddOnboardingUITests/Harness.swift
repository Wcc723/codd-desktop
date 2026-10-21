import AppKit
import CoddOnboarding
import CoddUI
@testable import CoddOnboardingUI

/// Records every action the wizard calls.
@MainActor
final class Recorder {
    private(set) var events: [String] = []
    private(set) var selections: [ImportSelection] = []
    private(set) var groups: [(path: String, name: String)] = []

    func record(_ event: String) { events.append(event) }

    var actions: OnboardingActions {
        OnboardingActions(
            next: { [unowned self] in record("next") }, skip: { [unowned self] in record("skip") },
            back: { [unowned self] in record("back") }, redetect: { [unowned self] in record("redetect") },
            importWeb: { [unowned self] in record("importWeb") }, suggestGroups: { [unowned self] in record("suggestGroups") },
            previewHooks: { [unowned self] in record("previewHooks") }, revealNotes: { [unowned self] in record("revealNotes") },
            registerClaudeCode: { [unowned self] in record("registerClaudeCode") },
            copyCodexSnippet: { [unowned self] in record("copyCodexSnippet") }, addAccount: { [unowned self] in record("addAccount") },
            requestNotifications: { [unowned self] in record("requestNotifications") }, finish: { [unowned self] in record("finish") },
            goTo: { [unowned self] step in record("goTo:\(step.rawValue)") },
            importChanged: { [unowned self] selection in
                selections.append(selection)
                record("importChanged")
            },
            newGroup: { [unowned self] path, name in
                groups.append((path, name))
                record("newGroup:\(name)")
            },
            copyCommand: { [unowned self] command in record("copy:\(command)") },
            runInTerminal: { [unowned self] command in record("run:\(command)") })
    }
}

/// The wizard in an offscreen borderless window (never ordered in, nothing activates).
@MainActor
final class Harness {
    static let artboardSize = CGSize(width: 1440, height: 900)

    let recorder = Recorder()
    let view: OnboardingView
    let window: NSWindow

    init(_ model: OnboardingViewModel = OnboardingSamples.artboard(), size: CGSize = Harness.artboardSize) {
        Self.registerFonts()
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view = OnboardingView(model: model, actions: recorder.actions)
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        settle()
    }

    func settle() { view.layoutSubtreeIfNeeded() }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    var texts: [String] { view.onboardingTexts() }

    /// Every view of the window, depth first.
    var allViews: [NSView] {
        var out: [NSView] = []
        func walk(_ view: NSView) {
            out.append(view)
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return out
    }

    func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    var returnKey: NSEvent { key("\r", keyCode: 36) }
    var space: NSEvent { key(" ", keyCode: 49) }
    var down: NSEvent { key("\u{F701}", keyCode: 125) }
    var up: NSEvent { key("\u{F700}", keyCode: 126) }
    var optionDown: NSEvent { key("\u{F701}", keyCode: 125, flags: [.option, .numericPad, .function]) }
    var escape: NSEvent { key("\u{1B}", keyCode: 53) }
    var commandBracket: NSEvent { key("[", keyCode: 33, flags: .command) }

    var rows: ImportRowsView { view.importView.table.rows }

    func row(_ tail: String) -> ImportRowView? { rows.row(for: OnboardingSamples.home + tail) }

    private static var fontsRegistered = false

    /// Registers App/Fonts from the repository (the tests also pass without them: Typeface falls
    /// back to the system monospaced font; the width-based checks then say so).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        fontsAvailable = Typeface.registerFonts(in: repo.appendingPathComponent("App/Fonts", isDirectory: true))
    }

    static var fontsAvailable = false
}

extension Array where Element == String {
    /// The expected strings that are missing (readable failures).
    func missing(_ expected: [String]) -> [String] { expected.filter { !contains($0) } }
}
