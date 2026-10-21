import AppKit
import CoddNotes
import CoddUI

/// The toast for a note an AI made with `notes_create` (user feedback 2026-10-19):
/// `Claude 建立了筆記：<title>` with `[開啟]`, which opens the note in the Notebook. Showing it never
/// activates CODD or moves the key window: the toast is a subview of the window it lands in.
enum MCPNoteToast {
    /// The toast's button (it replaces ToastView's `Undo` title; the button keeps its look).
    static let actionTitle = "開啟"
    /// Titles longer than this are cut with `…` (the toast wraps at most three lines).
    static let titleLimit = 60

    /// `Claude 建立了筆記：<title>`.
    static func text(title: String, clientKind: String) -> String {
        let oneLine = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let shown = oneLine.isEmpty ? "未命名筆記" : oneLine
        let clipped = shown.count <= titleLimit ? shown : String(shown.prefix(titleLimit)) + "…"
        return "\(who(clientKind)) 建立了筆記：\(clipped)"
    }

    /// The client as the toast names it: `Claude` for Claude Code (and a CODD session that has
    /// not said its name), `Codex` for Codex CLI, `AI` for anything else (a client-chosen name is
    /// never shown).
    static func who(_ clientKind: String) -> String {
        let lower = clientKind.lowercased()
        if lower.contains("claude") { return "Claude" }
        if lower.contains("codex") { return "Codex" }
        return "AI"
    }

    /// Renames the toast's action button (ToastView offers only its UNDO title).
    @MainActor
    static func relabel(_ toast: ToastView?, to title: String = actionTitle) {
        guard let toast else { return }
        var stack: [NSView] = [toast]
        while let view = stack.popLast() {
            if let button = view as? CoddButton, button.label.lowercased() == "undo" {
                button.label = title
                button.setAccessibilityLabel(title)
                return
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}

extension AppDelegate {
    /// Real mode, once after `MCPService.start()`: every `notes_create` shows its toast.
    func wireMCPNoteCreatedToast() {
        mcpService?.onNoteCreated = { [weak self] note in self?.showMCPNoteCreatedToast(note) }
    }

    /// On NOTES the toast sits at the document's bottom edge (like the Notebook's own toasts),
    /// elsewhere over the visible sidebar. `[開啟]` is the user's click: the window comes forward
    /// on NOTES with the note selected (⌘K NOTES' path). An AI's create arrives at any time, so it
    /// never replaces a toast the user may still undo there (``PoliteToast``): it waits for it.
    func showMCPNoteCreatedToast(_ note: MCPService.CreatedNote) {
        guard let id = NoteID(rawValue: note.id) else { return }
        let text = MCPNoteToast.text(title: note.title, clientKind: note.clientKind)
        PoliteToast.whenFree(current: { [weak self] in self?.mcpToastHostToast() }, show: { [weak self] in
            self?.presentMCPNoteCreatedToast(text, id: id)
        })
    }

    /// The toast where the MCP toast would land now (the host is looked up again at every try).
    private func mcpToastHostToast() -> ToastView? {
        shell.area == .notes && notesArea != nil ? noteEditor.documentView.toast : mainWindow?.currentToast
    }

    private func presentMCPNoteCreatedToast(_ text: String, id: NoteID) {
        let open: @MainActor () -> Void = { [weak self] in self?.openNoteFromPalette(id.rawValue) }
        let toast: ToastView?
        if shell.area == .notes, let notesArea {
            notesArea.showToast(text, undo: open)
            toast = noteEditor.documentView.toast
        } else {
            toast = mainWindow?.showToast(text, undo: open)
        }
        MCPNoteToast.relabel(toast)
        PoliteToast.mark(toast)
    }
}
