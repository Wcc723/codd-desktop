import AppKit
import CoddUI

/// A toast CODD shows on its own (an AI's `notes_create`, a message from the session drawer's
/// editor after it left the screen) never takes away a toast the user may still act on: one with
/// `[UNDO]` (the Notebook's archive / trash) or a countdown (the sidebar's archive). It waits until
/// that one is gone, then shows (review data-2). Toasts marked ``identifier`` are CODD's own and
/// may be replaced by the next one at once.
@MainActor
enum PoliteToast {
    /// Marks a toast CODD showed on its own (a later one may replace it).
    static let identifier = NSUserInterfaceItemIdentifier("codd.polite-toast")
    /// How often a waiting toast looks again.
    static let retryInterval: Duration = .milliseconds(250)
    /// The longest wait: past it the toast shows anyway (an UNDO toast leaves after 6 s, a
    /// countdown after 5 s, so this only covers a toast that somehow stays).
    static let maxWait: Duration = .seconds(30)

    /// `toast` is still on screen and the user may still act on it.
    static func isProtected(_ toast: ToastView?) -> Bool {
        guard let toast, toast.superview != nil, toast.identifier != identifier else { return false }
        return toast.hasUndo || (toast.remainingSeconds ?? 0) > 0
    }

    /// Runs `show` now when `current()` (the toast where it would land, looked up again at every
    /// try) is not protected, else once it is gone or after `maxWait`. Returns the waiting task.
    @discardableResult
    static func whenFree(current: @escaping @MainActor () -> ToastView?, interval: Duration = retryInterval,
                         maxWait: Duration = maxWait, show: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard isProtected(current()) else {
            show()
            return nil
        }
        return Task { @MainActor in
            let deadline = ContinuousClock.now + maxWait
            while isProtected(current()), ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            show()
        }
    }

    /// Marks `toast` as CODD's own.
    static func mark(_ toast: ToastView?) {
        toast?.identifier = identifier
    }
}

extension AppDelegate {
    /// A message of the session drawer's editor while its document is off screen: over the
    /// visible sidebar like the drawer's sends, after any toast the user may still undo.
    func showDrawerEditorToast(_ text: String) {
        PoliteToast.whenFree(current: { [weak self] in self?.mainWindow?.currentToast }, show: { [weak self] in
            PoliteToast.mark(self?.mainWindow?.showToast(text, undo: nil))
        })
    }
}
