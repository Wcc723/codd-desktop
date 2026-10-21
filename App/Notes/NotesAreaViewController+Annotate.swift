import AppKit
import CoddAnnotateUI
import CoddNotebookUI
import CoddNotes
import CoddUI

/// One open ImageAnnotate screen: which note and image it edits, and the block as it was (its
/// unknown keys are written back at `完成`).
struct AnnotateSession {
    var noteID: NoteID
    /// The image line's path as written in the note (`assets/<id>/9f3a1c.png`).
    var path: String
    /// The block's `image` value (relative to the notes folder, §3.3).
    var blockImage: String
    var imageURL: URL
    var previous: ImageAnnotations?
    let screen: ImageAnnotateView
    let modeView: AnnotateModeView
}

/// M4 I1b, D10: the Annotate mode. `編輯標註`, ⌘⇧A or a double click on a figure opens C8's
/// `ImageAnnotateView` over the whole NOTES area; `完成` rewrites the image's `codd-annotations`
/// block as ONE undoable edit of the note text (the autosave writes it) and regenerates the
/// burned-in copy (DERIVED, in `<dataRoot>/cache/annotated/`) inside the notes actor; `取消` discards; both return to the
/// Notebook with the note still selected. The status bar shows `標註模式 · n 個標註 · ● 已儲存 HH:mm`.
extension NotesAreaViewController {
    /// Opens ImageAnnotate for `requested` (an image path as written; nil: the image at the caret,
    /// else the note's first). False (with a toast) when there is nothing to annotate.
    @discardableResult
    func annotate(_ requested: String? = nil) async -> Bool {
        guard mode == .notebook, annotateSession == nil, let id = editor.noteID, !editor.editor.isComposing else { return false }
        guard let path = requested ?? editor.editor.imagePathAtCaret ?? editor.imagePaths.first else {
            showToast("這則筆記沒有圖片")
            return false
        }
        guard let url = editor.images.url(for: path), FileManager.default.fileExists(atPath: url.path) else {
            showToast("找不到圖片 \((path as NSString).lastPathComponent)")
            return false
        }
        await editor.flush()
        let decoded = await NoteImageCache.fullImage(at: url)
        // Another request may have opened the screen or moved to another note meanwhile.
        guard editor.noteID == id, annotateSession == nil, mode == .notebook else { return false }
        guard let image = decoded else {
            showToast("無法開啟圖片 \(url.lastPathComponent)")
            return false
        }
        let previous = editor.annotations(of: path)
        let size = CGSize(width: image.width, height: image.height)
        let document = NoteAnnotateMapping.document(previous, imageSize: size)
        let blockImage = NoteAnnotateMapping.blockImagePath(path, resolved: url, notesRoot: service.notesRoot)
        let alt = FencedBlocks.imageLines(in: editor.text).first { $0.path == path }?.alt ?? ""
        let listTitle = presenter().listTitle(service.list, resolve: { self.resolve($0) })
        let title = editor.document?.metadata.title ?? ""
        let header = NoteAnnotateMapping.header(listTitle: listTitle, noteTitle: title, path: blockImage,
                                                pixelSize: document.pixelSize, alt: alt)
        let screen = ImageAnnotateView(image: image, document: document, header: header)
        let annotatedFolder = service.annotatedFolder
        screen.previewText = { document in
            NoteAIText.imagePreview(image: url, annotations: NoteAnnotateMapping.annotations(document, image: blockImage, previous: previous),
                                    annotatedFolder: annotatedFolder)
        }
        screen.markdownSource = { document in
            NoteAnnotateMapping.markdownSource(NoteAnnotateMapping.annotations(document, image: blockImage, previous: previous))
        }
        screen.onChange = { [weak self] document in self?.annotateChanged(document) }
        screen.onDone = { [weak self] document in Task { await self?.finishAnnotate(document) } }
        screen.onCancel = { [weak self] in self?.cancelAnnotate() }
        let modeView = AnnotateModeView(screen: screen, statusBar: StatusBarView(store: store))
        annotateSession = AnnotateSession(noteID: id, path: path, blockImage: blockImage, imageURL: url, previous: previous,
                                          screen: screen, modeView: modeView)
        pickerPresenter.dismiss()
        chrome.closeMenu()
        rootView?.annotate = modeView
        mode = .annotate
        annotateChanged(document)
        rootView?.layoutSubtreeIfNeeded()
        // The canvas takes the keyboard (V R P A T, ⎋); never activates the app.
        screen.focusCanvas()
        HolderSessionStore.printLog("notes annotate open id=\(id.rawValue) image=\(url.lastPathComponent) items=\(document.items.count)")
        onDumpNeeded?()
        return true
    }

    /// The status bar follows the screen (`標註模式`, `3 個標註 · ● 已儲存 10:46`).
    func annotateChanged(_ document: AnnotationDocument) {
        guard let session = annotateSession else { return }
        let detail = NSMutableAttributedString(attributedString: TextStyle.mono(10.5, Palette.bone).string("\(document.items.count) 個標註 · "))
        switch presenter().saveState(editor.saveState) {
        case .saved(let time):
            detail.append(TextStyle.mono(10.5, Palette.success).string("●"))
            detail.append(TextStyle.mono(10.5, Palette.bone).string(" 已儲存 \(time)"))
        case .unsaved:
            detail.append(TextStyle.mono(10.5, Palette.amber).string("●"))
            detail.append(TextStyle.mono(10.5, Palette.bone).string(" 未儲存"))
        case .saving:
            detail.append(TextStyle.mono(10.5, Palette.bone).string("◌ 儲存中…"))
        }
        session.modeView.statusBar.setMode("標註模式", detail: detail)
        onDumpNeeded?()
    }

    /// What is left of a `完成` once the block is in the editor text: saving and the burned-in copy.
    struct AnnotateCompletion {
        var session: AnnotateSession
        var annotations: ImageAnnotations
        var changed: Bool
        var burns: Bool
    }

    /// `完成` (and DEBUG `-codd-notes-annotate`): the block in the editor as one undoable edit,
    /// back to the Notebook, then the note saved and its annotated copy regenerated off the main
    /// actor (C1 renders it inside the notes actor).
    func finishAnnotate(_ document: AnnotationDocument) async {
        guard let completion = applyAnnotate(document) else { return }
        await complete(completion)
    }

    /// The synchronous half of `完成`: the screen closes and the block goes into the editor text
    /// now, so a note switch that follows at once (⌘K, ⌘⇧N, a link) never loses it.
    @discardableResult
    func applyAnnotate(_ document: AnnotationDocument) -> AnnotateCompletion? {
        guard let session = annotateSession else { return nil }
        let annotations = NoteAnnotateMapping.annotations(document, image: session.blockImage, previous: session.previous)
        let json = NoteAnnotateMapping.blockJSON(annotations)
        endAnnotate()
        guard editor.noteID == session.noteID else { return nil }
        let changed = editor.replaceAnnotationBlock(of: session.path, with: json)
        return AnnotateCompletion(session: session, annotations: annotations, changed: changed, burns: json != nil && !annotations.items.isEmpty)
    }

    /// The async half: the note saved (when the editor still shows it; a note switch saves it
    /// itself), then C1 regenerates the burned-in copy in the cache folder from the file.
    private func complete(_ completion: AnnotateCompletion) async {
        let session = completion.session
        var png: String?
        if completion.changed {
            if editor.noteID == session.noteID { await editor.flush() }
            if completion.burns {
                do {
                    png = try await service.annotatedImage(for: session.noteID, image: session.blockImage)?.lastPathComponent
                } catch {
                    showToast(Self.message(error))
                }
            }
        }
        lastAnnotate = (session.noteID.rawValue, session.blockImage, completion.annotations.items.count, png)
        HolderSessionStore.printLog("notes annotate done id=\(session.noteID.rawValue) image=\(session.imageURL.lastPathComponent) "
                                    + "items=\(completion.annotations.items.count) changed=\(completion.changed) annotated=\(png ?? "-")")
        onDumpNeeded?()
    }

    /// Another note is about to show while ImageAnnotate is open: its edits are kept, as ⎋ / `完成`
    /// keeps them.
    func closeAnnotateKeepingEdits() {
        guard let session = annotateSession else { return }
        session.screen.commitPendingEdits()
        guard let completion = applyAnnotate(session.screen.document) else { return }
        Task { await complete(completion) }
    }

    /// `取消`: nothing changes.
    func cancelAnnotate() {
        guard let session = annotateSession else { return }
        endAnnotate()
        HolderSessionStore.printLog("notes annotate cancel id=\(session.noteID.rawValue)")
        onDumpNeeded?()
    }

    /// Back to the Notebook with the note shown and the keyboard in its editor.
    private func endAnnotate() {
        annotateSession = nil
        rootView?.annotate = nil
        mode = .notebook
        rootView?.layoutSubtreeIfNeeded()
        editor.focus()
    }
}
