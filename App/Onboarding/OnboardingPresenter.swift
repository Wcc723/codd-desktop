import AppKit
import CoddOnboarding
import CoddOnboardingUI
import CoddPreferences

/// One open wizard: its controller, its window and the routing that sends a show-window request,
/// a Dock click or the status item's open action to it while it is open (D5). Opening probes
/// first (live mode) and shows the window when the facts are in.
@MainActor
final class OnboardingPresenter {
    let controller: OnboardingController
    private weak var host: OnboardingHost?
    private(set) var windowController: OnboardingWindowController?
    /// Probing before the window shows.
    private(set) var isOpening = false
    /// Settings › 外觀 › CRT 效果 (applied to the window as it is made, and live).
    var crt: CoddPreferences.CRT = .off {
        didSet { windowController?.setCRT(crt) }
    }
    /// The window is on screen (the DEBUG actions start then).
    var onShown: (() -> Void)?
    /// After every model change (the dump follows).
    var onChange: (() -> Void)?
    private let log: (String) -> Void

    init(controller: OnboardingController, host: OnboardingHost?, log: @escaping (String) -> Void) {
        self.controller = controller
        self.host = host
        self.log = log
        controller.onChange = { [weak self] in self?.modelChanged() }
    }

    /// Open until it ends (also while the first probe runs).
    var isOpen: Bool { !controller.hasEnded }

    var window: NSWindow? { windowController?.window }

    /// Probes (live mode), then shows the window.
    func open() async {
        guard windowController == nil, !isOpening else { return }
        isOpening = true
        let clock = ContinuousClock()
        let started = clock.now
        await controller.start()
        isOpening = false
        guard !controller.hasEnded, let model = controller.model else { return }
        let window = OnboardingWindowController(model: model, actions: actions())
        window.setCRT(crt)
        window.onUserClose = { [weak self] in self?.controller.windowClosed() }
        windowController = window
        window.present()
        let ms = Int(((clock.now - started) / .milliseconds(1)).rounded())
        log("onboarding shown reason=\(controller.reason) step=\(controller.flow.current.rawValue) source=\(controller.source == .mock ? "mock" : "live") "
            + "probeMs=\(ms)")
        onShown?()
    }

    /// D5: brings the wizard forward instead of the main window. False when it is not open, and
    /// while the first probe runs (no window yet: the caller shows the main window, so a Dock click,
    /// 開啟 CODD or the hotkey always shows something; the wizard still appears when the probe ends).
    @discardableResult
    func bringForward(reason: String) -> Bool {
        guard isOpen else { return false }
        guard let windowController else {
            log("onboarding bring-forward skipped reason=\(reason) probing=true")
            return false
        }
        windowController.bringForward()
        log("onboarding brought-forward reason=\(reason)")
        return true
    }

    /// The wizard ended: its window goes (the controller wrote `onboarding.json` already).
    func closeAfterEnding() {
        windowController?.closeAfterEnding()
    }

    /// CODD quits: the window closing now is not an ending (D7).
    func appWillTerminate() {
        controller.isQuitting = true
    }

    private func modelChanged() {
        if let model = controller.model { windowController?.onboardingView.update(model) }
        onChange?()
    }

    /// The view's buttons onto the controller and the host.
    private func actions() -> OnboardingActions {
        let controller = self.controller
        let log = self.log
        return OnboardingActions(
            next: { [weak controller] in controller?.next() },
            skip: { [weak controller] in controller?.skip() },
            back: { [weak controller] in controller?.back() },
            redetect: { [weak self, weak controller] in
                Task {
                    await self?.host?.onboardingRelocateCswap()
                    await controller?.redetect()
                }
            },
            importWeb: { [weak controller] in controller?.go(to: .hooks) },
            suggestGroups: { log("onboarding suggest") },
            previewHooks: { [weak self] in self?.host?.onboardingPreviewHooks(on: self?.window) },
            revealNotes: { [weak self] in self?.host?.onboardingRevealNotes() },
            registerClaudeCode: { [weak self] in self?.host?.onboardingRegisterClaudeCode(on: self?.window) },
            copyCodexSnippet: { [weak self] in self?.host?.onboardingCopyCodexSnippet(on: self?.window) },
            addAccount: { [weak self] in self?.host?.onboardingAddAccount() },
            requestNotifications: { [weak controller] in Task { await controller?.requestNotifications() } },
            finish: { [weak controller] in controller?.finish(.done) },
            goTo: { [weak controller] step in controller?.go(to: step) },
            importChanged: { [weak controller] selection in controller?.importChanged(selection) },
            newGroup: { path, name in log("onboarding new-group name=\(name) path=\(HolderSessionStore.abbreviate(path))") },
            copyCommand: { [weak self] command in self?.host?.onboardingCopyCommand(command) },
            runInTerminal: { [weak self] command in self?.host?.onboardingRunInTerminal(command) })
    }
}
