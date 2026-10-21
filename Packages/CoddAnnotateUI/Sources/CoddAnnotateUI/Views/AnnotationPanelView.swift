import AppKit
import CoddUI

/// The 380 pt `.ia-panel`: `ANNOTATIONS n` with the list (the selected item expanded, the others
/// collapsed), `送給 AI 時` with the three send options, `AI 會收到` with the preview term box and the
/// Markdown source disclosure. Scrolls when the list is long.
final class AnnotationPanelView: FlippedView {
    weak var owner: ImageAnnotateView?
    let scrollView = NSScrollView()
    let content = PanelContentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = content
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("標註清單與送出設定")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height), Palette.line)
    }

    override func layout() {
        super.layout()
        scrollView.frame = CGRect(x: 1, y: 0, width: max(0, bounds.width - 1), height: bounds.height)
        content.layoutContent(width: scrollView.contentSize.width, minHeight: scrollView.contentSize.height)
    }

    /// Rebuilds the list for a new document / selection and refreshes the previews.
    func update(document: AnnotationDocument, selection: Int?, header: ImageAnnotateHeader, preview: String?, markdown: String?,
                force: Bool = false) {
        content.update(document: document, selection: selection, header: header, preview: preview, markdown: markdown, force: force)
        content.layoutContent(width: scrollView.contentSize.width, minHeight: scrollView.contentSize.height)
    }
}

/// The panel's scrolling document; frame-laid-out so heights follow the artboard's padding and gaps.
final class PanelContentView: FlippedView {
    weak var panel: AnnotationPanelView?
    let listTitle = RunLineView()
    let listHint = RunLineView([.text("依建立順序編號", AnnotateTheme.hint)])
    let emptyLine = RunLineView([.text("// 還沒有標註 · 選工具後在圖上點按或拖曳", AnnotateTheme.hint)])
    private(set) var expanded: ExpandedItemView?
    private(set) var rows: [CollapsedItemRow] = []
    let sendTitle = RunLineView([.text("送給 AI 時", AnnotateTheme.section)])
    let sendOriginal = SendOptionRow(title: "附上原圖", isOn: false)
    let sendAnnotated = SendOptionRow(title: "附上標註後的圖（燒進框線與編號）", isOn: true)
    let sendList = SendOptionRow(title: "附上座標清單", isOn: true)
    let receiveTitle = RunLineView([.text("AI 會收到", AnnotateTheme.section)])
    let receiveHint = RunLineView([.text("notes_read · 送到 session", AnnotateTheme.hint)])
    let term = PreviewTermView()
    let disclosure = DisclosureButton()
    let markdownBox = PreviewTermView()
    private var items: [AnnotationDraft] = []
    private var selection: Int?
    private var previewText = ""
    private var markdownText = ""
    /// Section bottoms (dashed rules are drawn there).
    private var rules: [CGFloat] = []

    var onSelect: ((Int?) -> Void)?
    var onDelete: (() -> Void)?
    var onField: ((Int, CoordinateField, String) -> Void)?
    var onRevertField: ((Int, CoordinateField) -> Void)?
    var onComment: ((Int, String) -> Void)?
    var onCommentEscape: (() -> Void)?
    var onSend: ((AnnotationSendOptions) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        markdownBox.plain = true
        markdownBox.isHidden = true
        for view in [listTitle, listHint, emptyLine, sendTitle, sendOriginal, sendAnnotated, sendList, receiveTitle, receiveHint, term,
                     disclosure, markdownBox] as [NSView] {
            addSubview(view)
        }
        listHint.alignRight = true
        receiveHint.alignRight = true
        sendOriginal.onToggle = { [weak self] _ in self?.sendChanged() }
        sendAnnotated.onToggle = { [weak self] _ in self?.sendChanged() }
        sendList.onToggle = { [weak self] _ in self?.sendChanged() }
        disclosure.onToggle = { [weak self] in
            guard let self else { return }
            self.markdownBox.isHidden = !self.disclosure.isOpen
            self.relayoutInScroll()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var sendOptions: AnnotationSendOptions {
        AnnotationSendOptions(original: sendOriginal.isOn, annotated: sendAnnotated.isOn, list: sendList.isOn)
    }

    private func sendChanged() { onSend?(sendOptions) }

    func update(document: AnnotationDocument, selection: Int?, header: ImageAnnotateHeader, preview: String?, markdown: String?,
                force: Bool) {
        items = document.items
        self.selection = selection
        listTitle.set([.text("Annotations", AnnotateTheme.section), .gap(8), .text("\(items.count)", AnnotateTheme.sectionCount)])
        emptyLine.isHidden = !items.isEmpty
        sendOriginal.hint = header.originalFileName
        sendOriginal.isOn = document.send.original
        sendAnnotated.isOn = document.send.annotated
        sendList.isOn = document.send.list
        previewText = preview ?? "—"
        markdownText = markdown ?? "—"

        // The expanded item: kept (and updated in place) while the same item stays selected, so a
        // field being typed in survives a canvas drag.
        let selected = selection.flatMap { n in items.first { $0.n == n } }
        if let selected {
            if let expanded, expanded.item.n == selected.n {
                expanded.update(selected, force: force)
            } else {
                expanded?.detach()
                let view = ExpandedItemView(item: selected)
                view.collapseButton.onPress = { [weak self] in self?.onSelect?(nil) }
                view.deleteButton.target = self
                view.deleteButton.action = #selector(deletePressed)
                view.onField = { [weak self] n, field, text in self?.onField?(n, field, text) }
                view.onRevertField = { [weak self] n, field in self?.onRevertField?(n, field) }
                view.onComment = { [weak self] n, text in self?.onComment?(n, text) }
                view.onCommentEscape = { [weak self] in self?.onCommentEscape?() }
                addSubview(view)
                expanded = view
            }
        } else if let expanded {
            self.expanded = nil
            expanded.detach()
        }

        let others = items.filter { $0.n != selection }
        while rows.count > others.count { rows.removeLast().removeFromSuperview() }
        for (index, item) in others.enumerated() {
            if index < rows.count {
                rows[index].update(item)
            } else {
                let row = CollapsedItemRow(item: item)
                addSubview(row)
                rows.append(row)
            }
            let n = item.n
            rows[index].onSelect = { [weak self] in self?.onSelect?(n) }
        }
        needsLayout = true
    }

    @objc private func deletePressed() { onDelete?() }

    private func relayoutInScroll() {
        guard let scroll = enclosingScrollView else { return }
        layoutContent(width: scroll.contentSize.width, minHeight: scroll.contentSize.height)
    }

    /// Lays the sections out at `width` (`.ia-sec{padding:12px 16px 14px;gap:10px}`) and sizes the
    /// document to the content (at least the visible height).
    func layoutContent(width: CGFloat, minHeight: CGFloat) {
        guard width > 0 else { return }
        let x: CGFloat = az(16)
        let inner = max(0, width - az(32))
        var y: CGFloat = az(12)
        rules = []

        // ANNOTATIONS n · hint
        listTitle.frame = CGRect(x: x, y: y, width: inner * 0.6, height: az(17))
        listHint.frame = CGRect(x: x + inner * 0.6, y: y, width: inner * 0.4, height: az(17))
        y += az(17) + az(10)
        if items.isEmpty {
            emptyLine.frame = CGRect(x: x, y: y, width: inner, height: az(17))
            y += az(17)
        }
        var rowIndex = 0
        for item in items {
            if item.n == selection, let expanded {
                let height = ExpandedItemView.height(for: item.kind)
                expanded.frame = CGRect(x: x, y: y, width: inner, height: height)
                y += height + az(6)
            } else if rowIndex < rows.count {
                rows[rowIndex].frame = CGRect(x: x, y: y, width: inner, height: CollapsedItemRow.height)
                rowIndex += 1
                y += CollapsedItemRow.height + az(6)
            }
        }
        if !items.isEmpty { y -= az(6) }
        y += az(14)
        rules.append(y)

        // 送給 AI 時
        y += az(12)
        sendTitle.frame = CGRect(x: x, y: y, width: inner, height: az(16))
        y += az(16) + az(10)
        for row in [sendOriginal, sendAnnotated, sendList] {
            row.frame = CGRect(x: x, y: y, width: inner, height: SendOptionRow.height)
            y += SendOptionRow.height + az(10)
        }
        y += az(14) - az(10)
        rules.append(y)

        // AI 會收到 · hint, the term box, the disclosure (no rule under the last section)
        y += az(12)
        receiveTitle.frame = CGRect(x: x, y: y, width: inner * 0.5, height: az(17))
        receiveHint.frame = CGRect(x: x + inner * 0.5, y: y, width: inner * 0.5, height: az(17))
        y += az(17) + az(10)
        term.set(previewText, width: inner)
        let termHeight = term.height(for: inner)
        term.frame = CGRect(x: x, y: y, width: inner, height: termHeight)
        y += termHeight + az(10)
        disclosure.frame = CGRect(x: x, y: y, width: inner, height: az(24))
        y += az(24)
        if disclosure.isOpen {
            y += az(10)
            markdownBox.set(markdownText, width: inner)
            let height = markdownBox.height(for: inner)
            markdownBox.frame = CGRect(x: x, y: y, width: inner, height: height)
            y += height
        }
        y += az(14)
        let size = CGSize(width: width, height: max(minHeight, ceil(y)))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        relayoutInScroll()
    }

    override func draw(_ dirtyRect: NSRect) {
        for y in rules { Draw.dashedLine(from: CGPoint(x: 0, y: y - 1), to: CGPoint(x: bounds.width, y: y - 1), color: Palette.line) }
    }
}
