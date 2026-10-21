import AppKit
import CoddCodeEditor
import CoddDialogsUI
import CoddFileEditorUI
import CoddFiles
import CoddNotes
import CoddUI

/// The FileEditor artboard in the NOTES area (D12): the tree (264) and the main column with the
/// tab strip, the toolbar, the disk banner, the editor slot and the app status bar (the editor's
/// status items between `● MCP …` and ⌘K while Files shows).
final class FilesModeView: FlippedView {
    let tree: FileTreeView
    let tabs = EditorTabStripView(model: EditorTabStripModel(tabs: [], selectedID: nil))
    let toolbar = EditorToolbarView(model: EditorToolbarModel(crumbs: []))
    let banner = DiskChangeBannerView(model: .fileChanged(aiSession: nil, time: nil))
    let slot = FilesEditorSlotView()
    let statusBar: StatusBarView
    private(set) var toast: ToastView?

    init(statusBar: StatusBarView) {
        tree = FileTreeView(model: FileTreeModelView(project: "—", footPath: ""))
        self.statusBar = statusBar
        super.init(frame: NSRect(x: 0, y: 0, width: 1368, height: 900))
        banner.isHidden = true
        toolbar.isHidden = true
        for view in [tree, tabs, toolbar, banner, slot, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var showsBanner: Bool {
        get { !banner.isHidden }
        set {
            guard newValue == banner.isHidden else { return }
            banner.isHidden = !newValue
            needsLayout = true
        }
    }

    var showsToolbar: Bool {
        get { !toolbar.isHidden }
        set {
            guard newValue == toolbar.isHidden else { return }
            toolbar.isHidden = !newValue
            needsLayout = true
        }
    }

    /// A refusal or a save near the editor's bottom edge.
    func showToast(_ text: String) {
        toast?.removeFromSuperview()
        let view = ToastView(text: text, undo: nil, countdown: nil)
        addSubview(view)
        toast = view
        needsLayout = true
        view.dismiss(after: 6)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        tree.frame = CGRect(x: 0, y: 0, width: FileTreeView.width, height: height)
        let x = FileTreeView.width
        let width = max(0, bounds.width - x)
        var y: CGFloat = 0
        tabs.frame = CGRect(x: x, y: y, width: width, height: EditorTabStripView.height)
        y += EditorTabStripView.height
        if !toolbar.isHidden {
            toolbar.frame = CGRect(x: x, y: y, width: width, height: EditorToolbarView.height)
            y += EditorToolbarView.height
        }
        if !banner.isHidden {
            banner.frame = CGRect(x: x, y: y, width: width, height: DiskChangeBannerView.height)
            y += DiskChangeBannerView.height
        }
        let bar = Metrics.statusBarHeight
        slot.frame = CGRect(x: x, y: y, width: width, height: max(0, height - bar - y))
        statusBar.frame = CGRect(x: x, y: height - bar, width: width, height: bar)
        if let toast, toast.superview === self {
            let fitting = toast.fittingSize
            let toastWidth = min(max(fitting.width, 200), max(0, width - 32))
            toast.frame = CGRect(x: x + 16, y: height - bar - 16 - fitting.height, width: toastWidth, height: fitting.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }
}

/// The editor slot: the selected tab's code view, the note editor for a note tab, or a comment
/// line (no tab, a binary file).
final class FilesEditorSlotView: FlippedView {
    private(set) var content: NSView?
    private let message = Label.make(style: TextStyle.comment)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        message.isHidden = true
        addSubview(message)
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600)) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `view` (nil: the comment).
    func show(_ view: NSView?, message text: String?) {
        if content !== view {
            if let content, content.superview === self { content.removeFromSuperview() }
            content = view
            if let view {
                view.removeFromSuperview()
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view, positioned: .below, relativeTo: message)
            }
        } else if let view, view.superview !== self {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: message)
        }
        Label.set(message, text ?? "", style: TextStyle.comment)
        message.isHidden = text == nil
        needsLayout = true
    }

    /// The comment shown, if any (tests, the dump).
    var messageText: String? { message.isHidden ? nil : message.stringValue }

    override func layout() {
        super.layout()
        content?.frame = bounds
        let size = message.sizeThatFits(NSSize(width: max(0, bounds.width - 88), height: 200))
        message.frame = CGRect(x: 44, y: 28, width: max(0, bounds.width - 88), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, .black)
    }
}

/// Binds the Files mode's views to `FileEditorService` (M4 I3): observation loops map the
/// service onto the C6 models while the mode shows, and the views' callbacks drive the service.
/// A dirty tab's ⌘W / ✕ asks with C6's `DirtyCloseSheetView` as a sheet.
@MainActor
final class FilesModeController {
    let service: FileEditorService
    let view: FilesModeView
    let statusItems = EditorStatusItemsView(model: EditorStatusModel())
    /// The note tabs' editor (I1a's binding; its document view moves into the slot).
    weak var noteEditor: NoteEditorController?
    var onOpenSession: ((SessionID) -> Void)?
    /// Something the dump shows changed.
    var onDumpNeeded: (() -> Void)?
    private var loops: [ObservationLoop] = []
    private(set) var isActive = false
    /// The dirty-close sheet while it shows.
    private(set) var dirtySheet: (window: NSWindow, tabID: String)?

    init(service: FileEditorService, store: any SessionStore) {
        self.service = service
        let bar = StatusBarView(store: store)
        view = FilesModeView(statusBar: bar)
        bar.setAccessory(statusItems)
        service.onToast = { [weak self] text in self?.view.showToast(text) }
        wire()
    }

    /// The models follow the service only while the mode shows (a hidden Files mode costs nothing).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        service.setActive(active)
        if active {
            startLoops()
        } else {
            loops.forEach { $0.cancel() }
            loops.removeAll()
        }
    }

    private func startLoops() {
        guard loops.isEmpty else { return }
        let service = self.service
        loops.append(ObservationLoop(track: { service.treeModel() }, apply: { [weak self] model in
            self?.view.tree.update(model ?? FileTreeModelView(project: "—", footPath: ""))
        }))
        loops.append(ObservationLoop(track: { service.tabsModel() }, apply: { [weak self] model in
            self?.view.tabs.update(model ?? EditorTabStripModel(tabs: [], selectedID: nil))
        }))
        loops.append(ObservationLoop(track: { service.toolbarModel() }, apply: { [weak self] model in
            guard let self else { return }
            self.view.showsToolbar = model != nil
            if let model { self.view.toolbar.update(model) }
        }))
        loops.append(ObservationLoop(track: { service.bannerModel() }, apply: { [weak self] model in
            guard let self else { return }
            self.view.showsBanner = model != nil
            if let model { self.view.banner.update(model) }
        }))
        loops.append(ObservationLoop(track: { service.statusModel() }, apply: { [weak self] model in
            self?.statusItems.update(model ?? EditorStatusModel())
        }))
        loops.append(ObservationLoop(track: { [weak self] () -> String in
            guard let tab = service.selectedTab else { return "none" }
            _ = self?.noteEditor?.noteID
            return "\(tab.id)|\(tab.state != nil)|\(tab.failure ?? "")"
        }, apply: { [weak self] _ in self?.refreshSlot() }))
        loops.append(ObservationLoop(track: { () -> String in
            FilesDump.signature(service)
        }, apply: { [weak self] _ in self?.onDumpNeeded?() }))
    }

    /// The slot shows the selected tab's editor (or the note editor, or a comment).
    func refreshSlot() {
        guard let tab = service.selectedTab else {
            view.slot.show(nil, message: service.current == nil ? nil : FileEditorService.noTabText)
            return
        }
        if tab.noteID != nil {
            view.slot.show(noteEditor?.documentView, message: nil)
        } else if let editor = tab.editor {
            view.slot.show(editor, message: nil)
        } else {
            view.slot.show(nil, message: tab.failure)
        }
    }

    // MARK: Callbacks

    private func wire() {
        let tree = view.tree
        tree.onOpen = { [weak self] id, preview in self?.openRow(id, preview: preview) }
        tree.onToggle = { [weak self] id in self?.service.toggleFolder(id) }
        tree.onFilter = { [weak self] text in self?.service.setFilter(text) }
        tree.onFilterCommand = { [weak self] selector in self?.service.filterCommand(selector) ?? false }
        tree.onCollapseAll = { [weak self] in self?.service.collapseAll() }
        tree.onToggleSection = { [weak self] section in self?.service.toggleSection(section) }
        let tabs = view.tabs
        tabs.onSelect = { [weak self] id in self?.service.select(id) }
        tabs.onClose = { [weak self] id in self?.close(id) }
        tabs.onPin = { [weak self] id in self?.service.pin(id) }
        tabs.onOpenSession = { [weak self] in
            guard let self, let workspace = self.service.current, let session = self.service.session(for: workspace) else { return }
            self.onOpenSession?(session.id)
        }
        let toolbar = view.toolbar
        toolbar.onCrumb = { [weak self] index in self?.revealCrumb(index) }
        toolbar.onPreviousChange = { [weak self] in self?.withTab { $0.service.stepChange($1, forward: false) } }
        toolbar.onNextChange = { [weak self] in self?.withTab { $0.service.stepChange($1, forward: true) } }
        toolbar.onShowAIChanges = { [weak self] on in self?.withTab { $0.service.setShowAI($1, on: on) } }
        toolbar.onBaseline = { [weak self] index in
            self?.withTab { controller, tab in
                let options = controller.service.baselines(of: tab)
                if options.indices.contains(index) { controller.service.setBaseline(tab, options[index]) }
            }
        }
        toolbar.onFind = { [weak self] in self?.showFind(query: nil) }
        view.banner.onReload = { [weak self] in self?.withTab { $0.service.reload($1) } }
        view.banner.onKeepMine = { [weak self] in self?.withTab { $0.service.keepMine($1) } }
        view.banner.onCompare = { [weak self] in self?.withTab { $0.service.compare($1) } }
        statusItems.onItem = { [weak self] item in
            if item == .position { self?.focusEditor() }
        }
    }

    private func withTab(_ body: (FilesModeController, FileTab) -> Void) {
        guard let tab = service.selectedTab else { return }
        body(self, tab)
    }

    /// A tree row: a file (single click = preview tab), a RECENT note row, or `…` (nothing).
    func openRow(_ id: String, preview: Bool) {
        guard let workspace = service.current else { return }
        if id.hasPrefix("note:") {
            if workspace.tabs.contains(where: { $0.id == id }) {
                service.select(id)
                if !preview { service.pin(id) }
            }
            return
        }
        guard !id.hasPrefix("…") else { return }
        let url = workspace.url(of: id)
        // D27: a row with an AI badge opens with SHOW AI CHANGES on.
        let fromAI = workspace.touches[id] != nil
        Task { await self.service.open(url, preview: preview, showAI: fromAI, root: workspace.root) }
    }

    /// A crumb: its folder expanded in the tree (the file's own crumb does nothing).
    private func revealCrumb(_ index: Int) {
        guard let workspace = service.current, let url = service.selectedTab?.url, let relative = workspace.relativePath(url.path) else { return }
        let parts = relative.split(separator: "/").map(String.init)
        guard index < parts.count - 1 else { return }
        let folder = parts.prefix(index + 1).joined(separator: "/")
        service.reveal(folder + "/x", in: workspace)
    }

    /// ⌘F / the toolbar's ⌘F: the C5 find widget in the selected file.
    func showFind(query: String?) {
        guard let tab = service.selectedTab, let editor = tab.editor else { return }
        editor.showFind(replace: false, query: query)
        tab.findQuery = editor.findQuery
    }

    func focusEditor() {
        guard let tab = service.selectedTab else { return }
        if tab.noteID != nil {
            noteEditor?.focus()
        } else if let editor = tab.editor, let window = view.window {
            window.makeFirstResponder(editor.textViewForTesting)
        }
    }

    /// ⌘P: the filter field.
    func focusFilter() {
        view.tree.focusFilter()
    }

    /// ⌘W / ✕: a clean tab closes; a dirty one asks first (`[儲存] [不儲存] [取消]`).
    func close(_ id: String) {
        switch service.requestClose(id) {
        case .closed, .none:
            return
        case .needsConfirmation:
            presentDirtyClose(id)
        }
    }

    private func presentDirtyClose(_ id: String) {
        guard dirtySheet == nil, let tab = service.tab(id) else { return }
        guard let window = view.window else {
            // No window to attach the sheet to: nothing closes (never a silent discard).
            return
        }
        let sheet = DirtyCloseSheetView(fileName: tab.title)
        sheet.onChoice = { [weak self] choice in
            guard let self, let shown = self.dirtySheet else { return }
            DialogPresenter.dismiss(shown.window)
            self.dirtySheet = nil
            Task { await self.service.close(shown.tabID, choice: choice) }
        }
        dirtySheet = (DialogPresenter.presentSheet(sheet, on: window), id)
        onDumpNeeded?()
    }

    /// The dirty-close sheet's answer from outside (DEBUG, tests).
    func answerDirtyClose(_ choice: DirtyCloseChoice) async {
        guard let shown = dirtySheet else { return }
        DialogPresenter.dismiss(shown.window)
        dirtySheet = nil
        await service.close(shown.tabID, choice: choice)
    }
}
