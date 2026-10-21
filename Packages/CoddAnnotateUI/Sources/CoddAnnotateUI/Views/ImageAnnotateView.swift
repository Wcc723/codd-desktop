import AppKit
import CoddUI

/// The ImageAnnotate screen (ImageAnnotate artboard; SPEC §8 R6, M4 D10): the 52 pt top bar, the
/// 48 pt tool strip, the canvas with the image in its frame, and the 380 pt panel (annotation list,
/// send options, AI preview, Markdown source). Every coordinate is an integer in ORIGINAL image
/// pixels, clamped to the image.
///
/// Every create / move / resize / delete / field edit / color / send-option change is one step on
/// the view's own undo manager and is followed by `onChange`. `完成` (or ⎋ with nothing selected)
/// commits pending text edits and calls `onDone`; `取消` calls `onCancel` (the app discards).
/// Tool keys (V R P A T), Del / ⌫ and ⎋ work only while the canvas has focus, so typing in a field
/// (注音 included) never switches tools. The view never activates the app or orders a window front.
public final class ImageAnnotateView: NSView {
    public private(set) var document: AnnotationDocument
    public let header: ImageAnnotateHeader

    public var tool: AnnotateTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .text { stage.canvas.commitInlineEditor() }
            stage.canvas.cancelGesture()
            toolStrip.update(tool: tool, zoom: zoom, color: currentColor)
            window?.invalidateCursorRects(for: stage.canvas)
        }
    }

    public var zoom: AnnotateZoom = .fit {
        didSet {
            guard zoom != oldValue else { return }
            stage.canvas.commitInlineEditor()
            stage.canvas.cancelGesture()
            toolStrip.update(tool: tool, zoom: zoom, color: currentColor)
            stage.canvas.relayout(keepCenter: true)
        }
    }

    /// The selected item's `n` (nil: none). Setting it commits pending field / comment edits first.
    public var selection: Int? {
        get { selectedN }
        set { select(newValue) }
    }

    /// The color new items get (the strip's color button); picking one also recolors the selection.
    public var currentColor: AnnotationColor = .amber {
        didSet { toolStrip.update(tool: tool, zoom: zoom, color: currentColor) }
    }

    /// `AI 會收到`: the app passes CoddNotes' §3.7 formatter (the view shows `~` for the home folder).
    public var previewText: ((AnnotationDocument) -> String)? { didSet { refresh() } }
    /// The `codd-annotations` block text for the Markdown disclosure (CoddNotes' codec).
    public var markdownSource: ((AnnotationDocument) -> String)? { didSet { refresh() } }
    public var onChange: ((AnnotationDocument) -> Void)?
    public var onDone: ((AnnotationDocument) -> Void)?
    public var onCancel: (() -> Void)?

    /// `標註模式 · 3 個標註` (the app's status bar adds `· ● 已儲存 10:46`).
    public var statusText: String { "標註模式 · \(document.items.count) 個標註" }

    /// The canvas scale in points per image pixel (0.5 = `顯示 50%`).
    public var canvasScale: CGFloat { stage.canvas.mapping.scale }

    public override var undoManager: UndoManager? { history }

    let topBar: AnnotateTopBarView
    let toolStrip = ToolStripView()
    let stage: AnnotateStageView
    let panel = AnnotationPanelView()
    private let history = UndoManager()
    private var selectedN: Int?
    private var isRestoring = false

    public init(image: CGImage, document: AnnotationDocument, header: ImageAnnotateHeader) {
        var document = document
        if document.pixelSize.width < 1 || document.pixelSize.height < 1 {
            document.pixelSize = CGSize(width: image.width, height: image.height)
        }
        document.items = AnnotationEditing.renumbered(document.items)
        self.document = document
        self.header = header
        topBar = AnnotateTopBarView(header: header)
        stage = AnnotateStageView(image: image)
        super.init(frame: CGRect(x: 0, y: 0, width: 1368, height: az(876)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        history.groupsByEvent = false
        history.levelsOfUndo = 200
        stage.canvas.owner = self
        panel.owner = self
        for view in [topBar, toolStrip, stage, panel] as [NSView] { addSubview(view) }
        wire()
        toolStrip.update(tool: tool, zoom: zoom, color: currentColor)
        refresh(force: true)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("圖片標註 · \(header.fileName)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    private func wire() {
        topBar.undoButton.onPress = { [weak self] in self?.undo() }
        topBar.redoButton.onPress = { [weak self] in self?.redo() }
        topBar.cancelButton.target = self
        topBar.cancelButton.action = #selector(cancelPressed)
        topBar.doneButton.target = self
        topBar.doneButton.action = #selector(donePressed)
        toolStrip.onTool = { [weak self] tool in self?.setTool(tool) }
        toolStrip.onZoom = { [weak self] zoom in self?.zoom = zoom }
        toolStrip.colorButton.onPress = { [weak self] in self?.showColorMenu() }
        let content = panel.content
        content.onSelect = { [weak self] n in self?.select(n) }
        content.onDelete = { [weak self] in self?.deleteSelection() }
        content.onField = { [weak self] n, field, text in self?.commitField(field, of: n, text: text) }
        content.onRevertField = { [weak self] n, field in self?.revertField(field, of: n) }
        content.onComment = { [weak self] n, text in self?.commitComment(text, of: n) }
        content.onCommentEscape = { [weak self] in self?.focusCanvas() }
        content.onSend = { [weak self] send in self?.setSend(send) }
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        topBar.frame = CGRect(x: 0, y: 0, width: width, height: AnnotateTheme.topBarHeight)
        let bodyY = AnnotateTheme.topBarHeight
        let bodyHeight = max(0, height - bodyY)
        toolStrip.frame = CGRect(x: 0, y: bodyY, width: AnnotateTheme.toolStripWidth, height: bodyHeight)
        let panelWidth = Self.panelWidth(width: width)
        panel.frame = CGRect(x: width - panelWidth, y: bodyY, width: panelWidth, height: bodyHeight)
        stage.frame = CGRect(x: AnnotateTheme.toolStripWidth, y: bodyY,
                             width: max(0, width - AnnotateTheme.toolStripWidth - panelWidth), height: bodyHeight)
    }

    /// The panel's width in a page `width` wide: 380, narrowed (down to 260) so the image keeps
    /// 260 of its own (a small window at zoom 20), never wider than the page beside the tools.
    static func panelWidth(width: CGFloat) -> CGFloat {
        let room = max(0, width - AnnotateTheme.toolStripWidth)
        return min(room, AnnotateTheme.panelWidth, max(az(260), room - az(260)))
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Start with the canvas focused (tool keys work at once) unless something else has focus.
        if window.firstResponder == nil || window.firstResponder === window { focusCanvas() }
    }

    /// Gives the canvas keyboard focus (tool keys, Del, ⎋). Never activates the app.
    public func focusCanvas() {
        window?.makeFirstResponder(stage.canvas)
    }

    /// Scrolls the canvas so the selected item (else the image's center) is in the middle.
    public func centerOnSelection() {
        layoutSubtreeIfNeeded()
        let pixel: CGPoint
        if let n = selectedN, let item = document.item(n) {
            switch item.kind {
            case .rect: pixel = CGPoint(x: CGFloat(item.x) + CGFloat(item.width) / 2, y: CGFloat(item.y) + CGFloat(item.height) / 2)
            case .arrow: pixel = CGPoint(x: CGFloat(item.x + item.endX) / 2, y: CGFloat(item.y + item.endY) / 2)
            case .point, .text: pixel = CGPoint(x: item.x, y: item.y)
            }
        } else {
            pixel = CGPoint(x: document.pixelSize.width / 2, y: document.pixelSize.height / 2)
        }
        stage.canvas.scrollToCenter(pixel: pixel)
    }

    // MARK: State

    private func refresh(force: Bool = false) {
        stage.canvas.overlay.needsDisplay = true
        stage.canvas.setAccessibilityValue(statusText)
        panel.update(document: document, selection: selectedN, header: header, preview: previewText?(document),
                     markdown: markdownSource?(document), force: force)
        updateUndoButtons()
    }

    private func updateUndoButtons() {
        topBar.undoButton.isEnabled = history.canUndo
        topBar.redoButton.isEnabled = history.canRedo
    }

    private func select(_ n: Int?) {
        let target = n.flatMap { document.item($0) == nil ? nil : $0 }
        guard target != selectedN else { return }
        commitPendingEdits(inlineEditor: false)
        selectedN = target
        refresh()
        // A field of the item that was expanded had focus and is gone: the canvas takes it back.
        if let window, window.firstResponder === window { focusCanvas() }
    }

    func setTool(_ tool: AnnotateTool) { self.tool = tool }

    /// Applies `new` as one undo step (named `actionName`) and reports it; no step when nothing changed.
    private func apply(_ new: AnnotationDocument, selection newSelection: Int?, actionName: String,
                       before: AnnotationDocument? = nil) {
        let old = before ?? document
        let oldSelection = selectedN
        document = new
        selectedN = newSelection.flatMap { new.item($0) == nil ? nil : $0 }
        if new != old {
            record(document: old, selection: oldSelection, actionName: actionName)
            refresh()
            onChange?(document)
        } else {
            refresh()
        }
    }

    private func record(document old: AnnotationDocument, selection oldSelection: Int?, actionName: String) {
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { view in
            view.restore(old, selection: oldSelection, actionName: actionName)
        }
        history.setActionName(actionName)
        history.endUndoGrouping()
    }

    /// Undo / redo: puts `target` back and registers the way back (the redo / undo step).
    private func restore(_ target: AnnotationDocument, selection targetSelection: Int?, actionName: String) {
        let current = document, currentSelection = selectedN
        history.registerUndo(withTarget: self) { view in
            view.restore(current, selection: currentSelection, actionName: actionName)
        }
        history.setActionName(actionName)
        stage.canvas.cancelGesture()
        document = target
        selectedN = targetSelection.flatMap { target.item($0) == nil ? nil : $0 }
        isRestoring = true
        refresh(force: true)
        isRestoring = false
        onChange?(document)
    }

    // MARK: Canvas gestures

    func canvasSelect(_ n: Int?) { select(n) }

    /// A drag in progress: the document follows the pointer (no undo step, no `onChange` yet).
    func canvasPreview(_ preview: AnnotationDocument) {
        document = preview
        refresh()
    }

    /// The end of a move / resize drag that started from `before`.
    func canvasFinish(before: AnnotationDocument, actionName: String) {
        apply(document, selection: selectedN, actionName: actionName, before: before)
    }

    /// A new item drawn on the canvas.
    func canvasCommit(_ new: AnnotationDocument, selection n: Int, actionName: String, before: AnnotationDocument) {
        apply(new, selection: n, actionName: actionName, before: before)
    }

    /// Del / ⌫ / `[刪除]`: removes the selected item and renumbers the rest.
    func deleteSelection() {
        guard let n = selectedN else { return }
        commitPendingEdits()
        apply(AnnotationEditing.deleting(n, from: document), selection: nil, actionName: "刪除標註")
    }

    /// ⎋ on the canvas: deselects, else finishes like `完成`.
    func escape() {
        if selectedN != nil { select(nil) } else { done() }
    }

    // MARK: Panel edits

    private func commitField(_ field: CoordinateField, of n: Int, text: String) {
        guard !isRestoring, let item = document.item(n), let expanded = panel.content.expanded, expanded.item.n == n,
              let view = expanded.field(field) else { return }
        guard let value = CoordinateInput.parse(text) else {
            // Invalid input: the stored value comes back.
            view.show(field.value(of: item), force: true)
            return
        }
        let updated = AnnotationEditing.setting(field, to: value, of: item, width: document.pixelWidth, height: document.pixelHeight)
        view.show(field.value(of: updated), force: true)
        guard updated != item else { return }
        apply(AnnotationEditing.replacing(updated, in: document), selection: selectedN, actionName: "修改標註座標")
    }

    private func revertField(_ field: CoordinateField, of n: Int) {
        guard let item = document.item(n), let expanded = panel.content.expanded, expanded.item.n == n else { return }
        expanded.field(field)?.show(field.value(of: item), force: true)
    }

    private func commitComment(_ text: String, of n: Int) {
        guard !isRestoring, var item = document.item(n), item.note != text else { return }
        item.note = text
        apply(AnnotationEditing.replacing(item, in: document), selection: selectedN, actionName: "修改標註說明")
    }

    private func setSend(_ send: AnnotationSendOptions) {
        var new = document
        new.send = send
        apply(new, selection: selectedN, actionName: "修改送出選項")
    }

    /// The color menu's pick: new items get it, and the selected item is recolored (one step).
    func pickColor(_ color: AnnotationColor) {
        currentColor = color
        guard let n = selectedN, var item = document.item(n), item.color != color else { return }
        item.color = color
        apply(AnnotationEditing.replacing(item, in: document), selection: n, actionName: "修改標註顏色")
    }

    /// The five colors with swatches; the current one checked.
    func colorMenu() -> NSMenu {
        let menu = NSMenu(title: "標註顏色")
        menu.autoenablesItems = false
        for color in AnnotationColor.allCases {
            let item = ClosureMenuItem(title: color.title) { [weak self] in self?.pickColor(color) }
            item.state = color == currentColor ? .on : .off
            item.image = Self.swatch(color)
            menu.addItem(item)
        }
        return menu
    }

    private static func swatch(_ color: AnnotationColor) -> NSImage {
        NSImage(size: NSSize(width: az(12), height: az(12)), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            AnnotateTheme.color(color).setFill()
            rect.insetBy(dx: 1, dy: 1).fill()
            return true
        }
    }

    private func showColorMenu() {
        let button = toolStrip.colorButton
        // A menu pops up in this window's event loop; it never activates the app.
        colorMenu().popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX + az(4), y: 0), in: button)
    }

    // MARK: Undo, done, cancel

    /// Commits every pending text edit: the text tool's field, a coordinate field being typed in and
    /// the comment (never a composing range).
    public func commitPendingEdits() { commitPendingEdits(inlineEditor: true) }

    private func commitPendingEdits(inlineEditor: Bool) {
        if inlineEditor { stage.canvas.commitInlineEditor() }
        guard let expanded = panel.content.expanded else { return }
        for (_, field) in expanded.fields { field.commitIfEditing() }
        // The comment area's text (without a composing range) when it differs from the note.
        commitComment(expanded.comment.committedText, of: expanded.item.n)
    }

    /// The text view inside this screen that has focus, if any (its own typing undo applies).
    private var focusedTextView: NSTextView? {
        guard let text = window?.firstResponder as? NSTextView else { return nil }
        if text.isDescendant(of: self) { return text }
        // The field editor of a coordinate field lives outside the view tree until it is placed.
        if let delegate = text.delegate as? NSView, delegate.isDescendant(of: self) { return text }
        return nil
    }

    public func undo() {
        if let text = focusedTextView {
            if !text.hasMarkedText() { text.undoManager?.undo() }
            return
        }
        commitPendingEdits()
        guard history.canUndo else { return }
        history.undo()
        updateUndoButtons()
    }

    public func redo() {
        if let text = focusedTextView {
            if !text.hasMarkedText() { text.undoManager?.redo() }
            return
        }
        guard history.canRedo else { return }
        history.redo()
        updateUndoButtons()
    }

    /// The app's Edit menu (`undo:` / `redo:` through the responder chain).
    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }

    @objc private func donePressed() { done() }
    @objc private func cancelPressed() { cancel() }

    /// `完成`: commits pending edits and hands the document to the app.
    public func done() {
        commitPendingEdits()
        stage.canvas.cancelGesture()
        onDone?(document)
    }

    /// `取消`: the app discards the session's edits.
    public func cancel() {
        stage.canvas.cancelGesture()
        onCancel?()
    }

    /// ⌘Z / ⌘⇧Z while focus is inside this screen (no main menu needed): document undo on the
    /// canvas, the text's own undo in a field; nothing while an input method composes.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let responder = window?.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) || focusedTextView != nil
        else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.charactersIgnoringModifiers?.lowercased() == "z", flags == [.command] || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        if focusedTextView?.hasMarkedText() == true { return false }
        if flags.contains(.shift) { redo() } else { undo() }
        return true
    }
}

extension ImageAnnotateView: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            if let text = focusedTextView { return text.undoManager?.canUndo ?? false }
            return history.canUndo
        case #selector(redo(_:)):
            if let text = focusedTextView { return text.undoManager?.canRedo ?? false }
            return history.canRedo
        default:
            return true
        }
    }
}
