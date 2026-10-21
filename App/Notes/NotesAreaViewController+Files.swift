import AppKit
import CoddFiles
import CoddNotes

/// M4 I3: the Files mode of the NOTES area (D12): the C6 tree, tab strip, toolbar and banner with
/// the C5 code view, the app status bar with the editor's items, and the way back to the Notebook.
/// Note tabs move I1a's note editor into the Files slot and back.
extension NotesAreaViewController {
    func wireFiles() {
        lists.onOpenFile = { [weak self] path in self?.openRecentFile(path) }
        lists.onOpenFolder = { [weak self] in self?.onOpenFolder?() }
        guard let files else { return }
        files.noteEditor = editor
        filesMode?.noteEditor = editor
        files.onNoteTabShown = { [weak self] id in
            guard let self else { return }
            Task {
                if self.editor.noteID != id { await self.editor.show(id) }
                self.filesMode?.refreshSlot()
            }
        }
    }

    /// Shows the Files mode (the workspace the caller opened is the current one).
    func showFilesMode() {
        guard let filesMode else { return }
        closeAnnotateKeepingEdits()
        guard mode != .files else { return }
        if mode == .cleanup { leaveCleanupMode() }
        pickerPresenter.dismiss()
        chrome.closeMenu()
        mode = .files
        rootView?.showsFiles = true
        filesMode.setActive(isActive)
        filesMode.refreshSlot()
        rootView?.layoutSubtreeIfNeeded()
        onDumpNeeded?()
    }

    /// Back to the Notebook: the note editor returns to the chrome's document slot.
    func showNotebookMode() {
        guard mode == .files || mode == .cleanup else { return }
        if mode == .cleanup { leaveCleanupMode() }
        filesMode?.setActive(false)
        mode = .notebook
        rootView?.showsFiles = false
        chrome.documentView = editor.documentView
        rootView?.layoutSubtreeIfNeeded()
        autoSelect()
        onDumpNeeded?()
    }

    /// A LOCAL FILES row: the file in the Files mode, in the workspace it was opened in.
    func openRecentFile(_ path: String) {
        guard let files else { return }
        let root = files.recent.first { $0.path == path }.map { URL(fileURLWithPath: $0.root, isDirectory: true) }
        Task {
            let tab = await files.open(URL(fileURLWithPath: path), preview: false, root: root)
            if tab != nil { self.showFilesMode() }
        }
    }

    /// ⌘P while Files shows: the tree's filter field.
    func focusFilesFilter() {
        filesMode?.focusFilter()
    }
}
