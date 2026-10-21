import AppKit

/// App-level keyDown hook installed with a local event monitor, so it runs
/// before AppKit dispatches the event to the engine view:
///
/// - starts the keyDown→ptyWrite latency interval for the focused pane, but
///   not for keys an input method takes (注音: every key while a composition
///   is open, and the key that opens one); those write nothing or only the
///   committed text, and pairing them FIFO would report composing time as
///   latency;
/// - maps Cmd+V to Ctrl+V (0x16) when the clipboard holds only an image,
///   because Claude Code reads image pastes itself on ^V (terminal.md §1).
@MainActor
final class KeyRouter {
    private var monitor: Any?
    private let panes: () -> [EnginePane]

    init(panes: @escaping () -> [EnginePane]) {
        self.panes = panes
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.shouldSwallow(event) ?? false }
            return swallow ? nil : event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Records the keyDown for latency and reports whether the event was
    /// consumed here (the image-paste shim) instead of going to the engine.
    private func shouldSwallow(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let pane = panes().first(where: { $0.owns(window.firstResponder) })
        else { return false }

        if Self.isImageOnlyPaste(event) {
            pane.tracker.keyDown(eventTimestamp: event.timestamp)
            pane.sendRaw([0x16])
            return true
        }
        // Cmd shortcuts (copy, menu items) usually write nothing to the PTY.
        guard !event.modifierFlags.contains(.command), !Self.isComposing(window.firstResponder) else {
            return false
        }
        let tracker = pane.tracker
        let token = tracker.keyDown(eventTimestamp: event.timestamp)
        // AppKit dispatches the event right after this monitor returns. On the
        // next main-queue turn, marked text means the key opened a composition
        // and will not write anything itself.
        Task { @MainActor [weak window] in
            if Self.isComposing(window?.firstResponder) {
                tracker.cancel(token)
            }
        }
        return false
    }

    /// Whether `responder` has an open input-method composition (marked text).
    static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? any NSTextInputClient)?.hasMarkedText() ?? false
    }

    /// Plain Cmd+V while the pasteboard has image data and no text.
    static func isImageOnlyPaste(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
        let pasteboard = NSPasteboard.general
        let hasImage = pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
        let hasText = pasteboard.availableType(from: [.string, .fileURL]) != nil
        return hasImage && !hasText
    }
}
