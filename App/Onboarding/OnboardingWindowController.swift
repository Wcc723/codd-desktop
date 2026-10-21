import AppKit
import CoddOnboarding
import CoddOnboardingUI
import CoddPreferences
import CoddUI

/// The wizard's own window (M5 D6): hidden-inset title bar with the traffic lights over the
/// stepper's 52 px drag area, no rail, no sidebar, title `首次啟動設定` for the Window menu and
/// Mission Control, default content 1240 × 820, minimum 1011 × 640 (`OnboardingView`). The App's
/// scanline overlay follows Settings › 外觀 › CRT 效果 as on the main window. Never autosaved (D25)
/// and background-safe: ordering goes through `BackgroundWindows` in a background run, and CODD
/// never activates itself there.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let title = "首次啟動設定"

    let onboardingView: OnboardingView
    let container: MainContainerViewController
    /// The user closed the window (the traffic light, ⌘W): not called for `closeAfterEnding`.
    var onUserClose: (() -> Void)?
    private var closingAfterEnd = false

    init(model: OnboardingViewModel, actions: OnboardingActions) {
        onboardingView = OnboardingView(model: model, actions: actions)
        container = MainContainerViewController(content: OnboardingContentController(view: onboardingView))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Self.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Palette.bg
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setAccessibilityLabel("CODD · \(Self.title)")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = container
        window.contentMinSize = OnboardingView.minimumContentSize
        window.setContentSize(OnboardingView.defaultContentSize)
        window.center()
        window.initialFirstResponder = onboardingView.initialFirstResponder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window and makes it key. A background run keeps it behind the other apps
    /// (`BackgroundWindows`) and never activates CODD.
    func present() {
        showWindow(nil)
        bringForward()
    }

    /// A show-window request, a Dock click or the status item while the wizard is open (D5).
    func bringForward() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if let first = onboardingView.initialFirstResponder, window.firstResponder === window { window.makeFirstResponder(first) }
        if !AppActivation.isBackground { NSApp.activate() }
    }

    /// Closes the window once the wizard ended (no second ending; nothing to do when the user's
    /// close is what ended it).
    func closeAfterEnding() {
        guard !closingAfterEnd else { return }
        closingAfterEnd = true
        window?.close()
    }

    func setCRT(_ mode: CoddPreferences.CRT) { container.setCRT(mode) }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        guard !closingAfterEnd else { return }
        closingAfterEnd = true
        onUserClose?()
    }
}

/// Hosts the hand-laid-out `OnboardingView` as the container's content.
private final class OnboardingContentController: NSViewController {
    private let onboardingView: OnboardingView

    init(view: OnboardingView) {
        onboardingView = view
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = onboardingView }
}
