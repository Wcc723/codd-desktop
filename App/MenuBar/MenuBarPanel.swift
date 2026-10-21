import AppKit
import CoddUI

/// Non-activating dropdown under the status item: opening it never raises the main CODD
/// window over the app you are working in. Esc closes; clicks elsewhere close.
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel("CODD 選單列面板")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
}

/// Shows / hides the panel under the status button and owns the outside-click monitors
/// (they exist only while the panel is open: no idle cost).
@MainActor
final class MenuBarPanelPresenter {
    let panel = MenuBarPanel()
    private let content: MenuBarPanelView
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var anchor: NSStatusBarButton?

    var isShown: Bool { panel.isVisible }
    /// The panel opened (true) or closed (D36: the host line samples while it is open).
    var onVisibilityChange: ((Bool) -> Void)?

    init(content: MenuBarPanelView) {
        self.content = content
        panel.contentView = content
        panel.onClose = { [weak self] in self?.close() }
        content.onLayoutChange = { [weak self] in self?.resizeToFit() }
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        content.activate()
        resizeToFit()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
        onVisibilityChange?(true)
    }

    func close() {
        guard isShown else { return }
        panel.orderOut(nil)
        content.deactivate()
        anchor?.highlight(false)
        removeMonitors()
        onVisibilityChange?(false)
    }

    #if DEBUG
    /// The panel filled and sized as `show(from:)` does, without ordering it in (layout sweep; its
    /// rows come in on the observation loop's next turn).
    func layOutWithoutShowing() async -> NSWindow {
        content.activate()
        try? await Task.sleep(for: .milliseconds(300))
        resizeToFit()
        content.layoutSubtreeIfNeeded()
        return panel
    }
    #endif

    /// The panel's width: the artboard's 380 at the current zoom (the content's own width).
    static var width: CGFloat { UIZoom.pt(380) }

    /// Height follows the content; the top stays pinned under the status item.
    private func resizeToFit() {
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: min(content.fittingSize.height, maxHeight))
        guard let button = anchor, let buttonWindow = button.window else {
            panel.setContentSize(size)
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = buttonRect.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        let top = buttonRect.minY - 4
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private var maxHeight: CGFloat {
        let screen = anchor?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 0, height: 900)
        return max(320, screen.height - 16)
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.panel, event.window !== self.anchor?.window { self.close() }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
