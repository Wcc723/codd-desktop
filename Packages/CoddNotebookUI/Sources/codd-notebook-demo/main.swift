import AppKit
import CoddNotebookUI
import CoddUI

// codd-notebook-demo: the Notebook chrome fed by `NotebookSamples` (SPEC §5).
//
//   codd-notebook-demo --fonts <repo>/App/Fonts --snapshot <dir>
//       renders offscreen (never ordered in, never activating) and exits:
//         notebook.png          1440 × 900: rail placeholder 72 + lists 220 + note list 300 +
//                               the editor chrome (document slot placeholder, info panel, doc
//                               status, prompt footer) with the COPY REF menu open + a status bar
//                               placeholder
//         notebook-unsaved.png  the same with an unsaved quick note (COPY REF menu disabled, D15)
//         drawer.png / drawer-nofiles.png / drawer-empty.png   300 × 900 notes drawer variants
//         drawer-editing.png    the drawer editing n1 in place (document slot placeholder)
//         history.png           the history compare sheet
//         menus.png             AI, scope, SEND (+ a session's actions), ⋯ and the OFF COPY REF menu
//         pickers.png           link picker and tag editor
//         list-search.png / list-empty.png   the note list in search mode and empty
//   codd-notebook-demo --fonts <dir>
//       opens a window with the composition (a manual tool; actions print to stdout).

@MainActor
struct Demo {
    static let size = CGSize(width: 1440, height: 900)

    let fontsDir: URL?
    let snapshotDir: URL?

    init(arguments: [String]) {
        var fonts: URL?
        var snapshot: URL?
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--fonts": fonts = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--snapshot": snapshot = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            default:
                print("usage: codd-notebook-demo [--fonts <dir>] [--snapshot <dir>]")
                exit(2)
            }
            index += 1
        }
        fontsDir = fonts
        snapshotDir = snapshot
    }

    func run() {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        if let fontsDir, !Typeface.registerFonts(in: fontsDir) { print("warning: CODD fonts not found in \(fontsDir.path)") }
        if let snapshotDir {
            app.setActivationPolicy(.prohibited)
            try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            write(Composition(chrome: NotebookSamples.n1Chrome, openMenu: .copyRef), size: Demo.size, name: "notebook.png", to: snapshotDir)
            write(Composition(chrome: NotebookSamples.unsavedChrome, openMenu: .copyRef, list: NotebookSamples.noteList), size: Demo.size,
                  name: "notebook-unsaved.png", to: snapshotDir)
            write(NotesDrawerView(model: NotebookSamples.drawer), size: CGSize(width: 300, height: 900), name: "drawer.png", to: snapshotDir)
            write(NotesDrawerView(model: NotebookSamples.drawerWithoutFiles), size: CGSize(width: 300, height: 900), name: "drawer-nofiles.png",
                  to: snapshotDir)
            write(NotesDrawerView(model: NotebookSamples.emptyDrawer), size: CGSize(width: 300, height: 900), name: "drawer-empty.png",
                  to: snapshotDir)
            let editing = NotesDrawerView(model: NotebookSamples.drawerEditing)
            let drawerDocument = DrawerDocumentPlaceholder()
            drawerDocument.title = NotebookSamples.drawerEditing.editing?.title ?? ""
            editing.documentView = drawerDocument
            write(editing, size: CGSize(width: 300, height: 900), name: "drawer-editing.png", to: snapshotDir)
            let history = HistoryCompareView(model: NotebookSamples.historyCompare)
            write(history, size: history.preferredSize, name: "history.png", to: snapshotDir)
            write(MenusBoard(), size: MenusBoard.size, name: "menus.png", to: snapshotDir)
            write(PickersBoard(), size: PickersBoard.size, name: "pickers.png", to: snapshotDir)
            write(NoteListView(model: NotebookSamples.searchList), size: CGSize(width: 300, height: 900), name: "list-search.png", to: snapshotDir)
            write(NoteListView(model: NotebookSamples.emptyList), size: CGSize(width: 300, height: 900), name: "list-empty.png", to: snapshotDir)
            exit(0)
        }
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Demo.size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "codd-notebook-demo"
        window.appearance = NSAppearance(named: .darkAqua)
        let composition = Composition(chrome: NotebookSamples.n1Chrome, openMenu: nil, presenter: PopoverMenuPresenter())
        composition.autoresizingMask = [.width, .height]
        window.contentView = composition
        window.center()
        window.makeKeyAndOrderFront(nil)
        Demo.keep = window
        app.activate()
        app.run()
    }

    private func write(_ view: NSView, size: CGSize, name: String, to dir: URL) {
        guard let rep = ViewSnapshot.render(view, size: size) else {
            print("cannot render \(name)")
            return
        }
        do {
            try ViewSnapshot.writePNG(rep, to: dir.appendingPathComponent(name))
            print("wrote \(name)")
        } catch {
            print("cannot write \(name): \(error)")
        }
    }

    static var keep: NSWindow?
}

/// Rail placeholder 72 + lists 220 + note list 300 + the chrome (+ the app status bar
/// placeholder under it), like the Notebook artboard.
@MainActor
final class Composition: FlippedView {
    let lists = NotebookListsView(model: NotebookSamples.lists)
    let list: NoteListView
    let chrome: NoteEditorChromeView
    let rail = RailPlaceholder()
    let statusBar = StatusBarPlaceholder()
    let placeholder = DocumentPlaceholder()
    private let openMenu: NoteChromeMenu?

    init(chrome model: NoteEditorChromeModel, openMenu: NoteChromeMenu?, list listModel: NoteListModel = NotebookSamples.noteList,
         presenter: NotebookMenuPresenting = InlineMenuPresenter()) {
        list = NoteListView(model: listModel)
        chrome = NoteEditorChromeView(model: model)
        self.openMenu = openMenu
        super.init(frame: CGRect(origin: .zero, size: Demo.size))
        wantsLayer = true
        chrome.menuPresenter = presenter
        chrome.documentView = placeholder
        placeholder.title = model.title
        if model.noteID == nil {
            placeholder.chips.update(NoteChipsRowModel(kind: .scratch, tags: [], session: NotebookSamples.s9, updated: "尚未儲存"))
            placeholder.showsFigure = false
        }
        for view in [rail, lists, list, chrome, statusBar] as [NSView] { addSubview(view) }
        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func wire() {
        lists.onSelect = { print("action select \($0)") }
        lists.onSearch = { print("action search \($0)") }
        lists.onNew = { print("action new") }
        list.onSelect = { print("action note \($0)") }
        list.onSort = { print("action sort \($0)") }
        chrome.onCopyRef = { print("action copy ref \($0)") }
        chrome.onAIAccess = { print("action ai \($0)") }
        chrome.onScope = { print("action scope \($0)") }
        chrome.onSend = { print("action send \($0) \($1)") }
        chrome.onMore = { print("action more \($0)") }
    }

    override func layout() {
        super.layout()
        rail.frame = CGRect(x: 0, y: 0, width: 72, height: bounds.height)
        lists.frame = CGRect(x: 72, y: 0, width: NotebookListsView.preferredWidth, height: bounds.height)
        list.frame = CGRect(x: lists.frame.maxX, y: 0, width: NoteListView.preferredWidth, height: bounds.height)
        let mainX = list.frame.maxX
        statusBar.frame = CGRect(x: mainX, y: bounds.height - 24, width: bounds.width - mainX, height: 24)
        chrome.frame = CGRect(x: mainX, y: 0, width: bounds.width - mainX, height: bounds.height - 24)
    }

    /// Opens the menu once the composition has its final frame (in the snapshot's window).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let openMenu, chrome.presentedMenu == nil else { return }
        layoutSubtreeIfNeeded()
        chrome.openMenu(openMenu)
    }
}

/// The app's rail (not part of this package): the 72 pt column with the traffic lights and the
/// NOTES item on, drawn dim so the composition compares with the artboard.
final class RailPlaceholder: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        for (index, color) in [NSColor(hex: 0xFF5F57), NSColor(hex: 0xFEBC2E), NSColor(hex: 0x28C840)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 18 + CGFloat(index) * 20, y: 19, width: 12, height: 12)).fill()
        }
        let items = ["SESSIONS", "NOTES", "STATUS", "SETTINGS"]
        for (index, item) in items.enumerated() {
            let y = 56 + CGFloat(index) * 54
            let on = item == "NOTES"
            if on {
                Draw.hGradient(CGRect(x: 6, y: y, width: 60, height: 50), from: Palette.amberGlow, to: .clear)
                Draw.fill(CGRect(x: 6, y: y, width: 2, height: 50), Palette.amber)
            }
            let text = TextStyle.caps(9, on ? Palette.amber : Palette.dim, tracking: 0.06).string(item)
            Draw.text(text, x: 36 - Draw.width(text) / 2, centerY: y + 38)
            Draw.strokeRect(CGRect(x: 26, y: y + 8, width: 20, height: 18), color: on ? Palette.amber : Palette.dim)
        }
        let label = TextStyle.mono(9, Palette.dimmer).string("// rail")
        Draw.text(label, x: 36 - Draw.width(label) / 2, centerY: bounds.height - 20)
    }
}

/// The app status bar (`.statusbar`, not part of this package), with the artboard's text.
final class StatusBarPlaceholder: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1), Palette.line)
        let base = TextStyle.mono(10.5, Palette.dim, tracking: 0.04)
        var x: CGFloat = 12
        x += Draw.text(TextStyle.mono(10.5, Palette.success).string("●"), x: x, centerY: bounds.midY)
        x += Draw.text(base.string(" MCP 127.0.0.1:47821 · 3 clients"), x: x, centerY: bounds.midY) + 14
        x += Draw.text(base.string("hooks "), x: x, centerY: bounds.midY)
        x += Draw.text(TextStyle.mono(10.5, Palette.success).string("●"), x: x, centerY: bounds.midY)
        Draw.text(base.string(" ok"), x: x, centerY: bounds.midY)
        let right = base.string("13 live · ◆ 3 · ● 4   ⌘K")
        Draw.text(right, x: bounds.width - 12 - Draw.width(right), centerY: bounds.midY)
    }
}

/// The document slot in the demo: C4 draws the note; here a title, the real chips row and
/// annotation summary (C4's accessories), and dim placeholders.
final class DocumentPlaceholder: FlippedView {
    var title = "" { didSet { needsDisplay = true } }
    let chips = NoteChipsRowView(model: NotebookSamples.n1ChipsRow)
    let annotations = ImageAnnotationSummaryView(model: NotebookSamples.n1Annotations)
    var showsFigure = true { didSet { annotations.isHidden = !showsFigure; needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chips)
        addSubview(annotations)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let width = bounds.width - 44 - 40
        chips.frame = CGRect(x: 44, y: 22 + 29 + 10, width: width, height: chips.height(for: width))
        let figureX: CGFloat = 44 + 138 + 18
        let annotationWidth = bounds.width - 40 - figureX
        annotations.frame = CGRect(x: figureX, y: 210, width: annotationWidth, height: annotations.height(for: annotationWidth))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.text(TextStyle(font: Typeface.display(22), color: Palette.cream, tracking: 0.01).string(title), x: 44, centerY: 22 + 14,
                  maxWidth: bounds.width - 84)
        let note = TextStyle.comment.string("// documentView：C4 MarkdownEditorView 在這裡繪製筆記內容")
        Draw.text(note, x: 44, centerY: 118)
        Draw.dashedRect(CGRect(x: 44, y: 140, width: bounds.width - 84, height: bounds.height - 160), color: Palette.lineBright)
        guard showsFigure else { return }
        let shot = CGRect(x: 44, y: 210, width: 138, height: 234)
        Draw.fill(shot, .black)
        Draw.strokeRect(shot, color: Palette.amberDim)
        Draw.fill(shot.insetBy(dx: 7, dy: 7), NSColor(hex: 0xCBCAC6))
        Draw.text(TextStyle.mono(11, Palette.dim).string("截圖 2026-10-15 09:32 · iPhone SE"), x: 44, centerY: 456)
    }
}

/// The drawer's document slot: the title line and a comment where the app's note editor draws.
final class DrawerDocumentPlaceholder: FlippedView {
    var title = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.text(TextStyle(font: Typeface.display(18), color: Palette.cream, tracking: 0.01).string(title), x: 22, centerY: 14 + 12,
                  maxWidth: bounds.width - 36)
        Draw.text(TextStyle.comment.string("// documentView：筆記編輯器"), x: 22, centerY: 70, maxWidth: bounds.width - 36)
        Draw.dashedRect(CGRect(x: 22, y: 90, width: bounds.width - 36, height: max(0, bounds.height - 110)), color: Palette.lineBright)
    }
}

/// The other menus side by side (each as the presenter would show it): AI, scope, SEND (+ one
/// session's actions), ⋯; COPY REF of an OFF note and of an unsaved note, the sort menu and the
/// footer's target menu.
final class MenusBoard: FlippedView {
    static let size = CGSize(width: 1700, height: 920)

    override init(frame frameRect: NSRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        let chrome = NoteEditorChromeView(model: NotebookSamples.n1Chrome)
        let off = NoteEditorChromeView(model: NotebookSamples.n1ChromeOff)
        let unsaved = NoteEditorChromeView(model: NotebookSamples.unsavedChrome)
        let actions = NotebookMenuView(model: chrome.menuModel(for: .send))
        actions.activate(id: "session.\(NotebookSamples.s9.id)")
        let footer = PromptFooterView(model: NotebookSamples.n1Footer)
        let rows: [(CGFloat, [(NSView, String)])] = [
            (16, [(NotebookMenuView(model: chrome.menuModel(for: .ai)), "AI 存取 ▾"),
                  (NotebookMenuView(model: chrome.menuModel(for: .scope)), "Project ▾"),
                  (NotebookMenuView(model: chrome.menuModel(for: .send)), "SEND TO SESSION ▾"),
                  (actions, "→ 打卡頁 RWD 調整"),
                  (NotebookMenuView(model: chrome.menuModel(for: .more)), "⋯")]),
            (400, [(NotebookMenuView(model: off.menuModel(for: .copyRef)), "COPY REF · AI OFF"),
                   (NotebookMenuView(model: unsaved.menuModel(for: .copyRef)), "COPY REF · 尚未儲存"),
                   (NotebookMenuView(model: NoteListView(model: NotebookSamples.noteList).sortMenuModel), "最近更新 ▾"),
                   (NotebookMenuView(model: footer.targetMenuModel), "送到 [● 打卡頁 RWD 調整 ▾]")]),
        ]
        for (top, items) in rows {
            var x: CGFloat = 20
            for (view, caption) in items {
                let size = (view as? NotebookMenuView)?.preferredSize ?? view.fittingSize
                view.frame = CGRect(x: x, y: top + 28, width: size.width, height: size.height)
                addSubview(view)
                let label = CaptionLabel(caption)
                label.frame = CGRect(x: x, y: top, width: size.width, height: 18)
                addSubview(label)
                x += size.width + 24
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) { Draw.fill(bounds, Palette.bgSoft) }
}

final class PickersBoard: FlippedView {
    static let size = CGSize(width: 720, height: 480)

    override init(frame frameRect: NSRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        let link = LinkPickerView(model: NotebookSamples.linkPicker)
        link.frame = CGRect(origin: CGPoint(x: 20, y: 44), size: link.preferredSize)
        addSubview(link)
        let tags = TagEditorView(model: NotebookSamples.tagEditor)
        tags.frame = CGRect(origin: CGPoint(x: 400, y: 44), size: tags.preferredSize)
        addSubview(tags)
        for (x, text) in [(CGFloat(20), "+ 連結 session / 專案"), (CGFloat(400), "#tag")] {
            let label = CaptionLabel(text)
            label.frame = CGRect(x: x, y: 16, width: 300, height: 18)
            addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) { Draw.fill(bounds, Palette.bgSoft) }
}

final class CaptionLabel: FlippedView {
    let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(TextStyle.comment.string("// \(text)"), x: 0, centerY: bounds.midY)
    }
}

MainActor.assumeIsolated {
    Demo(arguments: CommandLine.arguments).run()
}
