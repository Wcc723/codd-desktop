import AppKit
import CoddTextKit
import CoddUI

// codd-markdown-demo: the Notebook artboard's document column (SPEC §5 n1) in the live-preview
// editor, with the generated 750 × 1334 screenshot, its three R6 annotations, a chips-row title
// accessory and an annotation panel next to the figure.
//
//   codd-markdown-demo --fonts <repo>/App/Fonts --snapshot <dir>
//       renders offscreen at 760 × 820 (2x) and exits: notebook-live.png (caret on the raw
//       `**Safari 底部工具列展開時**` line), notebook-source.png (⌘E source mode),
//       notebook-folded.png (問題 folded), notebook-empty.png (a new note: the 標題 placeholder).
//   codd-markdown-demo --fonts <dir>
//       opens a window for a manual 注音 try (a manual tool only: it activates; never automated).

@MainActor
enum Demo {
    static let size = NSSize(width: 760, height: 820)

    static func makeEditor(text: String, mode: MarkdownEditorMode, caret: Int?, fold: Bool = false) -> MarkdownEditorView {
        let editor = MarkdownEditorView()
        // Offscreen boards have no first responder; show the caret paragraph as if focused.
        editor.revealsCaretLineWhenInactive = caret != nil
        let screenshot = MarkdownSamples.placeholderScreenshot()
        editor.imageResolver = { path in
            path == MarkdownSamples.n1ImagePath ? MarkdownSamples.n1ImageInfo(image: screenshot) : nil
        }
        editor.imageAccessoryProvider = { info in AnnotationPanelView(info: info) }
        editor.titleAccessory = ChipsRowView()
        editor.load(text, selection: caret.map { NSRange(location: $0, length: 0) })
        editor.mode = mode
        editor.onTextChange = { print("TEXT \(($0 as NSString).length) units") }
        editor.onCaretChange = { print("CARET Ln \($0.line), Col \($0.column) sel \($0.selectionLength)") }
        editor.onOpenLink = { print("OPEN \($0)") }
        editor.onEditImageAnnotations = { print("ANNOTATE \($0)") }
        editor.onCommandReturn = { print("SEND ⌘⏎") }
        editor.onPasteImage = { image in
            print("PASTE IMAGE \(image.typeIdentifier) \(image.data.count) bytes")
            return false
        }
        if fold { editor.foldForDemo(heading: "問題") }
        return editor
    }

    static func snapshot(to directory: URL) -> Bool {
        let boards: [(String, () -> NSView)] = [
            ("notebook-live", { SnapshotHost(editor: makeEditor(text: MarkdownSamples.n1, mode: .livePreview,
                                                                caret: MarkdownSamples.n1CaretLocation), showsCaret: true) }),
            ("notebook-source", { SnapshotHost(editor: makeEditor(text: MarkdownSamples.n1, mode: .source,
                                                                  caret: MarkdownSamples.n1CaretLocation), showsCaret: true) }),
            ("notebook-folded", { SnapshotHost(editor: makeEditor(text: MarkdownSamples.n1, mode: .livePreview, caret: nil, fold: true),
                                               showsCaret: false) }),
            ("notebook-empty", { SnapshotHost(editor: makeEditor(text: "# ", mode: .livePreview, caret: 2), showsCaret: true) }),
        ]
        var ok = true
        for (name, make) in boards {
            let view = make()
            view.needsLayout = true
            guard let rep = ViewSnapshot.render(view, size: size, background: Palette.bgSoft) else {
                FileHandle.standardError.write(Data("codd-markdown-demo: could not render \(name)\n".utf8))
                ok = false
                continue
            }
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try ViewSnapshot.writePNG(rep, to: url)
                print("WROTE \(url.path) \(Int(rep.size.width))x\(Int(rep.size.height))")
            } catch {
                FileHandle.standardError.write(Data("codd-markdown-demo: \(url.path): \(error)\n".utf8))
                ok = false
            }
        }
        return ok
    }
}

extension MarkdownEditorView {
    /// Folds the H2 whose text is `heading` (the demo's folded board).
    func foldForDemo(heading: String) {
        guard let range = text.range(of: "## \(heading)") else { return }
        setFolded(true, headingAt: NSRange(range, in: text).location)
    }
}

/// The editor plus a static caret (an offscreen window never shows AppKit's insertion point).
final class SnapshotHost: NSView {
    let editor: MarkdownEditorView
    let caret = StaticCaretView()
    let showsCaret: Bool

    init(editor: MarkdownEditorView, showsCaret: Bool) {
        self.editor = editor
        self.showsCaret = showsCaret
        super.init(frame: NSRect(origin: .zero, size: Demo.size))
        addSubview(editor)
        addSubview(caret)
        caret.isHidden = !showsCaret
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        editor.frame = bounds
        editor.layoutSubtreeIfNeeded()
        if showsCaret, let rect = editor.caretRect() {
            caret.frame = rect.insetBy(dx: -8, dy: -4)
        }
    }
}

final class StaticCaretView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: bounds.midX - 1, y: bounds.minY + 4, width: 2, height: bounds.height - 8)
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(Palette.amberGlow, radius: 6).set()
        Palette.amber.setFill()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// `.nb-meta`: NOTE · #rwd · #punch · ● 打卡頁 RWD 調整 · ■ orb-toolkit-frontend · updated 10:05.
final class ChipsRowView: NSView, MarkdownAccessorySizing {
    override var isFlipped: Bool { true }

    func markdownAccessoryHeight(forWidth width: CGFloat) -> CGFloat { 20 }

    override func draw(_ dirtyRect: NSRect) {
        let chip = ChipStyle(text: TextStyle.mono(10.5, Palette.bone, tracking: 0.03), border: Palette.lineBright, height: 20, padding: 5)
        let caps = ChipStyle(text: TextStyle.caps(10, Palette.bone, tracking: 0.1), border: Palette.lineBright, height: 20, padding: 5)
        var x: CGFloat = 0
        let y = bounds.midY
        x += caps.draw("Note", x: x, centerY: y) + 5
        x += chip.draw("#rwd", x: x, centerY: y) + 5
        x += chip.draw("#punch", x: x, centerY: y) + 5
        x += lampChip("●", Palette.success, "打卡頁 RWD 調整", x: x, y: y) + 5
        x += lampChip("■", NSColor(hex: 0x5B8DEF), "orb-toolkit-frontend", x: x, y: y) + 5
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string("updated 10:05"), x: x, centerY: y)
    }

    private func lampChip(_ glyph: String, _ color: NSColor, _ label: String, x: CGFloat, y: CGFloat) -> CGFloat {
        let lamp = TextStyle.mono(9, color).string(glyph)
        let text = TextStyle.mono(10.5, Palette.bone).string(label)
        let width = Draw.width(lamp) + 5 + Draw.width(text) + 10
        let rect = CGRect(x: x, y: (y - 10).rounded(), width: width, height: 20)
        Draw.strokeRect(rect, color: Palette.lineBright)
        Draw.text(lamp, x: x + 5, centerY: y)
        Draw.text(text, x: x + 5 + Draw.width(lamp) + 5, centerY: y)
        return width
    }
}

/// `.nb-annp`: 標註 3 · ⌘⇧A [編輯標註], the numbered list with coordinates, and the send hint.
final class AnnotationPanelView: NSView, MarkdownAccessorySizing {
    let info: MarkdownImageInfo
    private let padding = NSEdgeInsets(top: 8, left: 12, bottom: 9, right: 10)

    init(info: MarkdownImageInfo) {
        self.info = info
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    private var items: [(Int, String, String)] {
        info.overlay.enumerated().map { index, shape in
            let note = index < MarkdownSamples.n1AnnotationNotes.count ? MarkdownSamples.n1AnnotationNotes[index] : ""
            let xy: String
            switch shape {
            case let .rect(_, r, _): xy = "rect · x \(Int(r.minX)) y \(Int(r.minY)) · \(Int(r.width))×\(Int(r.height))"
            case let .point(_, p, _): xy = "point · x \(Int(p.x)) y \(Int(p.y))"
            case let .arrow(_, a, b, _): xy = "arrow · x \(Int(a.x)) y \(Int(a.y)) → x \(Int(b.x)) y \(Int(b.y))"
            case let .text(_, p, _, _): xy = "text · x \(Int(p.x)) y \(Int(p.y))"
            }
            return (shape.number, note, xy)
        }
    }

    private func noteString(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 17.4
        paragraph.maximumLineHeight = 17.4
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: Typeface.mono(12), .foregroundColor: Palette.bone, .paragraphStyle: paragraph])
    }

    func markdownAccessoryHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = width - padding.left - padding.right - 28
        var height = padding.top + 22 + 8
        for (_, note, _) in items {
            let noteHeight = noteString(note).boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin]).height
            height += ceil(noteHeight) + 15 + 6
        }
        height += 2 + 16 + padding.bottom
        return ceil(height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        Draw.fill(CGRect(x: 1, y: 1, width: 2, height: bounds.height - 2), Palette.amberDim)
        var y = padding.top
        let x = padding.left
        let header = y + 11
        var cursor = x + Draw.text(TextStyle.mono(11, Palette.bone).string("標註"), x: x, centerY: header) + 7
        cursor += Draw.text(TextStyle.mono(11, Palette.amber, .bold).string("\(info.overlay.count)"), x: cursor, centerY: header) + 7
        cursor += Draw.text(TextStyle.mono(11, Palette.dimmer).string("·"), x: cursor, centerY: header) + 7
        let kbd = ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 5)
        _ = kbd.draw("⌘⇧A", x: cursor, centerY: header)
        let label = TextStyle.mono(10.5, Palette.cream, tracking: 0.08, .medium).string("編輯標註")
        let bracket = TextStyle.mono(10.5, Palette.dim).string("[")
        let close = TextStyle.mono(10.5, Palette.dim).string("]")
        let buttonWidth = Draw.width(label) + Draw.width(bracket) + Draw.width(close) + 8 + 14
        let button = CGRect(x: bounds.width - padding.right - buttonWidth, y: y, width: buttonWidth, height: 22)
        Draw.strokeRect(button, color: Palette.lineBright)
        var bx = button.minX + 7
        bx += Draw.text(bracket, x: bx, centerY: button.midY) + 4
        bx += Draw.text(label, x: bx, centerY: button.midY) + 4
        Draw.text(close, x: bx, centerY: button.midY)
        y += 22 + 8
        let textWidth = bounds.width - padding.left - padding.right - 28
        for (number, note, xy) in items {
            let square = CGRect(x: x, y: y, width: 18, height: 18)
            Draw.fill(square, Palette.amber)
            let digit = TextStyle.mono(10.5, .black, .bold).string("\(number)")
            Draw.text(digit, x: square.midX - Draw.width(digit) / 2, centerY: square.midY)
            let string = noteString(note)
            let noteHeight = ceil(string.boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin]).height)
            string.draw(with: CGRect(x: x + 28, y: y, width: textWidth, height: noteHeight), options: [.usesLineFragmentOrigin])
            Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(xy), x: x + 28, centerY: y + noteHeight + 8, maxWidth: textWidth)
            y += noteHeight + 15 + 6
        }
        y += 2
        Draw.text(TextStyle.mono(11, Palette.dimmer, tracking: 0.02).string("AI 會收到標註後的圖與座標清單"), x: x, centerY: y + 8)
    }
}

// MARK: - Entry

func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

@MainActor
final class WindowDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let editor = Demo.makeEditor(text: MarkdownSamples.n1, mode: .livePreview, caret: MarkdownSamples.n1CaretLocation)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Demo.size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "codd-markdown-demo · 注音 manual check"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = editor
        window.center()
        window.makeKeyAndOrderFront(nil)
        editor.focus()
        NSApp.activate()
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: .darkAqua)
    if let fonts = argument(after: "--fonts") {
        if !Typeface.registerFonts(in: URL(fileURLWithPath: fonts, isDirectory: true)) {
            FileHandle.standardError.write(Data("codd-markdown-demo: JetBrains Mono / Space Mono not found in \(fonts)\n".utf8))
        }
    } else {
        FileHandle.standardError.write(Data("codd-markdown-demo: no --fonts; using the system monospaced font\n".utf8))
    }
    if let snapshot = argument(after: "--snapshot") {
        app.setActivationPolicy(.prohibited)
        exit(Demo.snapshot(to: URL(fileURLWithPath: snapshot, isDirectory: true)) ? 0 : 1)
    }
    app.setActivationPolicy(.regular)
    let delegate = WindowDelegate()
    app.delegate = delegate
    app.run()
}
