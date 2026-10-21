import AppKit
import CoddCleanupUI
import CoddNotes

/// M4 I4a: the Cleanup mode of the NOTES area (D12, D31): C12's page over the whole area with the
/// app status bar under it. Entered from the Notebook footer's `清理建議 n →`, the menu bar's footer
/// line, Settings › 清理's head button and the digest notification's `查看`; `← NOTEBOOK` / esc (and
/// opening a note, ⌘⇧N, the rail's NOTES) go back to the Notebook.
extension NotesAreaViewController {
    func wireCleanup() {
        lists.onOpenCleanup = { [weak self] in self?.showCleanupMode() }
        guard let cleanupMode else { return }
        cleanupMode.onBack = { [weak self] in self?.showNotebookMode() }
        let store = self.store
        let service = self.service
        cleanupMode.presenter = { [weak self] in
            if let self { return self.presenter() }
            return NotebookPresenter(now: service.clock(), timeZone: service.timeZone, store: store, projects: [:])
        }
        cleanupMode.resolve = { [weak self] path in self?.resolve(path) ?? path }
        cleanupMode.session = { id in
            if let session = store.session(id) { return session }
            return (store as? HolderSessionStore)?.archivedSession(id)
        }
        cleanupMode.project = { id in store.project(id) }
    }

    /// Shows the Cleanup page (the tab when given).
    func showCleanupMode(tab: CleanupTab? = nil) {
        guard let cleanupMode else { return }
        closeAnnotateKeepingEdits()
        if let tab { cleanupMode.select(tab: tab) }
        guard mode != .cleanup else { return }
        if mode == .files { filesMode?.setActive(false) }
        pickerPresenter.dismiss()
        chrome.closeMenu()
        mode = .cleanup
        rootView?.showsCleanup = true
        cleanupMode.setActive(isActive)
        rootView?.layoutSubtreeIfNeeded()
        // The page takes the keyboard (space, ⌘A, ⌫, esc); never activates the app.
        cleanupMode.focus()
        Task { await editor.flush() }
        onDumpNeeded?()
    }

    /// The Cleanup page goes away (the caller sets the next mode).
    func leaveCleanupMode() {
        cleanupMode?.setActive(false)
        rootView?.showsCleanup = false
    }
}
