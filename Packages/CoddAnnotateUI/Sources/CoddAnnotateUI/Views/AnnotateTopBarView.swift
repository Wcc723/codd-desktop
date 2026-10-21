import AppKit
import CoddUI

/// The 52 pt `.sh` top bar: crumb `INBOX / <note> /`, the file name (`.ttl`), the `標註模式 ⌘⇧A`
/// chip, the meta line joined with ` · `; undo / redo, `[取消]` and the primary `[完成]` on the right.
final class AnnotateTopBarView: FlippedView {
    let identLine = RunLineView()
    let metaLine = RunLineView()
    let undoButton = BoardButton(.icon(.undo, size: 16), accessibilityLabel: "復原 ⌘Z")
    let redoButton = BoardButton(.icon(.redo, size: 16), accessibilityLabel: "重做 ⌘⇧Z")
    let cancelButton = CoddButton("取消", style: .bracket(.normal, small: false))
    let doneButton = CoddButton("完成", style: .bracket(.primary, small: false))
    private let rule = PanelView(fill: Palette.lineBright)

    init(header: ImageAnnotateHeader) {
        super.init(frame: .zero)
        wantsLayer = true
        for view in [identLine, metaLine, undoButton, redoButton, rule, cancelButton, doneButton] as [NSView] {
            addSubview(view)
        }
        update(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ header: ImageAnnotateHeader) {
        var pieces: [RunLineView.Piece] = []
        for (index, crumb) in header.crumbs.enumerated() {
            // The first crumb is the list (`Inbox` in caps); the next ones are note titles (`.cj`).
            pieces.append(.text(crumb, index == 0 ? AnnotateTheme.crumb : AnnotateTheme.crumbNote))
            pieces.append(.gap(7))
            pieces.append(.text("/", AnnotateTheme.crumbSlash))
            pieces.append(.gap(7))
        }
        if !header.crumbs.isEmpty { pieces.removeLast(); pieces.append(.gap(9)) }
        pieces.append(.text(header.fileName, AnnotateTheme.title))
        pieces.append(.gap(9))
        pieces.append(.chip("標註模式 ⌘⇧A", .chip(.amber)))
        identLine.set(pieces)

        var meta: [RunLineView.Piece] = []
        for (index, item) in header.meta.enumerated() {
            if index > 0 { meta += [.gap(7), .text("·", AnnotateTheme.metaSeparator), .gap(7)] }
            meta.append(.text(item, AnnotateTheme.meta))
        }
        metaLine.set(meta)
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Palette.lineBright)
    }

    override func layout() {
        super.layout()
        // `.acts{gap:4px}` from the right padding 10: [完成] [取消] | redo undo.
        var x = bounds.width - az(10)
        let mid = (bounds.height - 1) / 2
        func place(_ view: NSView, _ size: CGSize) {
            x -= size.width
            view.frame = CGRect(x: x, y: round(mid - size.height / 2), width: size.width, height: size.height)
        }
        place(doneButton, doneButton.intrinsicContentSize)
        x -= az(4)
        place(cancelButton, cancelButton.intrinsicContentSize)
        // `.ia-vr{margin:0 4px}` inside the 4 pt gaps.
        x -= az(8)
        place(rule, CGSize(width: 1, height: az(18)))
        x -= az(8)
        place(redoButton, CGSize(width: az(28), height: az(28)))
        x -= az(4)
        place(undoButton, CGSize(width: az(28), height: az(28)))
        // `.ident{gap:2px}`: the 20 pt l1 line and the 15.75 pt meta line, centered as a block.
        let identWidth = max(0, x - az(12) - az(16))
        let top = round(mid - (az(20) + az(2) + az(15.75)) / 2)
        identLine.frame = CGRect(x: az(16), y: top, width: identWidth, height: az(20))
        metaLine.frame = CGRect(x: az(16), y: top + az(22), width: identWidth, height: az(16))
    }
}
