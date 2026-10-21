import AppKit
import CoddOnboarding
import CoddUI

/// A step body below the head: it reports its height for a width and lists its focusable controls
/// in Tab order.
@MainActor
protocol StepBodyView: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
    var keyViews: [NSView] { get }
}

/// `.panel`-like box with dashed --line separators between rows.
@MainActor
enum RowsPanel {
    static func draw(in bounds: CGRect, separators: [CGFloat]) {
        Panel.draw(bounds)
        for y in separators {
            Draw.dashedLine(from: CGPoint(x: 1, y: y), to: CGPoint(x: bounds.width - 1, y: y), color: Palette.line)
        }
    }
}

// MARK: - Step 1

/// Step 1: one line per item that needs attention with its button, or `// 一切正常，按 下一步 繼續`.
final class DetectStepView: NSView, StepBodyView {
    private(set) var items: [DetectItem] = []
    private var texts: [RichTextView] = []
    private var buttons: [PressButton?] = []
    let allFine = TextLine()
    var onButton: (DetectItem) -> Void = { _ in }
    private var separators: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(allFine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var keyViews: [NSView] { buttons.compactMap { $0?.button } }

    private var problems: [DetectItem] { items.filter { $0.tone != "comment" } }

    func apply(_ items: [DetectItem]) {
        guard items != self.items else { return }
        self.items = items
        for text in texts { text.removeFromSuperview() }
        for button in buttons { button?.button.removeFromSuperview() }
        texts = []
        buttons = []
        for item in problems {
            let text = RichTextView(look: RichLook(size: 12.5, color: Palette.bone, lineHeight: 12.5 * 1.5))
            text.set(item.text)
            addSubview(text)
            texts.append(text)
            if let label = item.button {
                let button = PressButton(label, style: .bracket(.normal, small: true)) { [weak self] in self?.onButton(item) }
                addSubview(button.button)
                buttons.append(button)
            } else {
                buttons.append(nil)
            }
        }
        if let fine = items.first(where: { $0.tone == "comment" }) {
            allFine.set("// " + fine.text, style: TextStyle.comment)
            allFine.isHidden = false
        } else {
            allFine.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Row padding 10, glyph column 34, text, the button 10 px from the right.
    private func textWidth(_ width: CGFloat, button: PressButton?) -> CGFloat {
        let buttonWidth = button.map { $0.button.intrinsicContentSize.width + dz(20) } ?? dz(14)
        return max(dz(40), width - dz(34) - buttonWidth)
    }

    private func rowHeight(_ index: Int, width: CGFloat) -> CGFloat {
        max(dz(40), texts[index].height(forWidth: textWidth(width, button: buttons[index])) + dz(20))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if !texts.isEmpty { height += 2 + (0..<texts.count).map { rowHeight($0, width: width) }.reduce(0, +) }
        if !allFine.isHidden { height += (height > 0 ? dz(12) : 0) + dz(20) }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 1
        separators = []
        for index in texts.indices {
            let height = rowHeight(index, width: bounds.width)
            let textW = textWidth(bounds.width, button: buttons[index])
            let textH = texts[index].height(forWidth: textW)
            texts[index].place(CGRect(x: dz(34), y: y + (height - textH) / 2, width: textW, height: textH))
            if let button = buttons[index]?.button {
                let size = button.intrinsicContentSize
                button.place(CGRect(x: bounds.width - dz(10) - size.width, y: y + (height - size.height) / 2, width: size.width, height: size.height))
            }
            y += height
            if index < texts.count - 1 { separators.append(y) }
        }
        if !texts.isEmpty { y += 1 + dz(12) }
        allFine.place(CGRect(x: 0, y: texts.isEmpty ? 0 : y, width: bounds.width, height: dz(20)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !texts.isEmpty else { return }
        let height = (0..<texts.count).map { rowHeight($0, width: bounds.width) }.reduce(0, +) + 2
        let panel = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        RowsPanel.draw(in: panel, separators: separators)
        for (index, item) in problems.enumerated() where texts.indices.contains(index) {
            let text = texts[index]
            let glyph = TextStyle.mono(12.5, ToneColor.color(item.tone)).string(item.glyph)
            let lineMid = text.frame.minY + UIZoom.scaled(12.5 * 1.5) / 2
            Draw.text(glyph, x: dz(14), centerY: lineMid)
        }
    }
}

// MARK: - Step 3

/// Step 3: the `~/.CLAUDE · SETTINGS.JSON` card, `[預覽變更]` with its hint, and the applied line.
final class HooksStepView: NSView, StepBodyView {
    private(set) var model: HooksStepModel?
    let preview = PressButton("預覽變更", style: .bracket(.primary, small: false), accessibility: "預覽 settings.json 的變更")
    let hint = RichTextView("按下 套用並備份 前不會寫入；寫入前會先備份成 `settings.json.codd-bak-<時間>`。",
                            look: RichLook(size: 11.5, color: Palette.dimmer, lineHeight: 11.5 * 1.5, codeSize: 11.5))
    let applied = TextLine()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(preview.button)
        addSubview(hint)
        addSubview(applied)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("~/.claude/settings.json")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var keyViews: [NSView] { [preview.button] }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = rowElements
        children.append(contentsOf: [preview.button, hint] as [Any])
        if !applied.isHidden { children.append(applied) }
        return children
    }

    private var rowElements: [NSAccessibilityElement] = []

    static let cardTitle = "~/.CLAUDE · SETTINGS.JSON"

    func apply(_ model: HooksStepModel) {
        guard model != self.model else { return }
        self.model = model
        let primary = model.pending > 0
        preview.button.style = .bracket(primary ? .primary : .normal, small: false)
        preview.button.isEnabled = model.canPreview
        if let backup = model.appliedBackup {
            applied.set { runs([("● ", TextStyle.mono(12, Palette.success)), ("已套用 · 備份 \(backup)", TextStyle.mono(12, Palette.bone))]) }
            applied.isHidden = false
        } else {
            applied.isHidden = true
        }
        rowElements = model.rows.map { row in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel("\(row.label) \(row.state) \(row.detail)".trimmingCharacters(in: .whitespaces))
            element.setAccessibilityParent(self)
            return element
        }
        needsLayout = true
        needsDisplay = true
    }

    var rowTexts: [String] { model?.rows.map { "\($0.label) \($0.state) \($0.detail)" } ?? [] }

    // Card: padding 16 18; title 18 + padding-bottom 6 + rule + margin 12; rows 28.
    private var titleBlock: CGFloat { ceil(UIZoom.scaled(18)) + dz(6) + 1 + dz(12) }
    private var cardHeight: CGFloat { dz(16) + titleBlock + dz(28) * CGFloat(model?.rows.count ?? 0) + dz(16) }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height = dz(7) + cardHeight + dz(7) + dz(14) + dz(28)
        if !applied.isHidden { height += dz(10) + dz(20) }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        let top = dz(7) + cardHeight + dz(7) + dz(14)
        let size = preview.button.intrinsicContentSize
        preview.button.place(CGRect(x: 0, y: top, width: size.width, height: size.height))
        let hintX = preview.button.frame.maxX + dz(12)
        let hintWidth = max(0, bounds.width - hintX)
        let hintHeight = hint.height(forWidth: hintWidth)
        hint.place(CGRect(x: hintX, y: top + (dz(28) - min(hintHeight, dz(28))) / 2, width: hintWidth, height: hintHeight))
        applied.place(CGRect(x: 0, y: top + dz(28) + dz(10), width: bounds.width, height: dz(20)))
        for (index, element) in rowElements.enumerated() {
            let y = dz(7) + dz(16) + titleBlock + dz(28) * CGFloat(index)
            element.setAccessibilityFrameInParentSpace(CGRect(x: 0, y: y, width: bounds.width, height: dz(28)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let card = CGRect(x: 0, y: dz(7), width: bounds.width, height: cardHeight)
        Panel.draw(card, corners: true)
        let inner = card.insetBy(dx: dz(18), dy: 0)
        let titleTop = card.minY + dz(16)
        let titleHeight = ceil(UIZoom.scaled(18))
        Draw.text(TextStyle.cardTitle.string(Self.cardTitle), x: inner.minX, centerY: titleTop + titleHeight / 2, maxWidth: inner.width)
        let ruleY = titleTop + titleHeight + dz(6)
        Draw.dashedLine(from: CGPoint(x: inner.minX, y: ruleY), to: CGPoint(x: inner.maxX, y: ruleY), color: Palette.lineBright)
        var y = ruleY + 1 + dz(12)
        let labelWidth = dz(150)
        for row in model.rows {
            let mid = y + dz(14)
            Draw.text(TextStyle.caps(10.5, Palette.dim, tracking: 0.16).string(row.label), x: inner.minX, centerY: mid, maxWidth: labelWidth - dz(8))
            var x = inner.minX + labelWidth
            if row.tone == "code" {
                x += ChipStyle.code.draw(row.state, x: x, centerY: mid) + dz(10)
            } else {
                x += Draw.text(TextStyle.mono(12, ToneColor.color(row.tone)).string(row.state), x: x, centerY: mid, maxWidth: inner.maxX - x) + dz(12)
            }
            if !row.detail.isEmpty, x < inner.maxX {
                Draw.text(TextStyle.mono(11.5, Palette.dimmer).string(row.detail), x: x, centerY: mid, maxWidth: inner.maxX - x)
            }
            y += dz(28)
        }
    }
}

// MARK: - Step 4

/// Step 4: NOTEBOOK (the fixed path, `[在 Finder 中顯示]`, hint), MCP, CLAUDE CODE (`[註冊…]`, hint),
/// CODEX (`[複製設定…]`).
final class NotebookStepView: NSView, StepBodyView {
    private(set) var model: NotebookStepModel?
    let reveal = PressButton("在 Finder 中顯示", style: .bracket(.normal, small: true), accessibility: "在 Finder 中顯示筆記資料夾")
    let register = PressButton("註冊…", style: .bracket(.normal, small: true), accessibility: "向 Claude Code 註冊 CODD 的 MCP")
    let codex = PressButton("複製設定…", style: .bracket(.normal, small: true), accessibility: "複製 Codex 的 MCP 設定")
    let notesHint = RichTextView("位置固定在 CODD 的資料夾，不另外搬動；更新 CODD 時保留。",
                                 look: RichLook(size: 11.5, color: Palette.dimmer, lineHeight: 11.5 * 1.5))
    let claudeHint = RichTextView("選用：註冊後，CODD 以外開的 claude 也能讀筆記。會先顯示 `~/.claude.json` 的差異，按 套用並備份 才寫入。",
                                  look: RichLook(size: 11.5, color: Palette.dimmer, lineHeight: 11.5 * 1.5, codeSize: 11.5))
    private let path = TextLine()
    private let mcp = TextLine()
    private let claudeState = TextLine()
    private let codexNone = TextLine()
    static let labels = ["NOTEBOOK", "MCP", "CLAUDE CODE", "CODEX"]
    private var rowTops: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [reveal.button, register.button, codex.button, notesHint, claudeHint, path, mcp, claudeState, codexNone] { addSubview(view) }
        codexNone.set("—", style: TextStyle.mono(12, Palette.dimmer))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var keyViews: [NSView] {
        [reveal.button, register.button, codex.button].filter { !$0.isHidden }
    }

    func apply(_ model: NotebookStepModel) {
        guard model != self.model else { return }
        self.model = model
        path.set(model.notesPath, style: TextStyle.mono(12, Palette.cream))
        path.setAccessibilityLabel("筆記資料夾")
        let mcpGlyphColor = model.mcpRunning ? Palette.success : Palette.dim
        mcp.set { Self.glyphRuns(model.mcpLine, glyphColor: mcpGlyphColor) }
        mcp.setAccessibilityLabel("MCP")
        let registered = model.claudeCodeState.hasPrefix("●")
        claudeState.set { Self.glyphRuns(model.claudeCodeState, glyphColor: registered ? Palette.success : Palette.dim) }
        claudeState.setAccessibilityLabel("Claude Code")
        register.button.isHidden = model.claudeCodeButton == nil
        if let label = model.claudeCodeButton { register.button.label = label }
        codex.button.isHidden = !model.codexAvailable
        codexNone.isHidden = model.codexAvailable
        needsLayout = true
        needsDisplay = true
    }

    /// `● 運作中` inside a line: the glyph in its tone, the rest --bone.
    static func glyphRuns(_ text: String, glyphColor: NSColor) -> NSAttributedString {
        let base = TextStyle.mono(12, Palette.bone)
        var parts: [(String, TextStyle)] = []
        for (index, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { parts.append((" ", base)) }
            let word = String(piece)
            parts.append((word, (word == "●" || word == "○" || word == "◆") ? base.with(color: glyphColor) : base))
        }
        return runs(parts)
    }

    private var labelWidth: CGFloat { dz(130) }
    private func contentWidth(_ width: CGFloat) -> CGFloat { max(dz(80), width - dz(18) * 2 - labelWidth) }

    private func rowHeights(_ width: CGFloat) -> [CGFloat] {
        let content = contentWidth(width)
        let line = dz(36)
        return [line + notesHint.height(forWidth: content) + dz(4), line, line + claudeHint.height(forWidth: content) + dz(4), line]
    }

    func height(forWidth width: CGFloat) -> CGFloat { ceil(rowHeights(width).reduce(0, +) + 2) }

    override func layout() {
        super.layout()
        let heights = rowHeights(bounds.width)
        let x = dz(18) + labelWidth
        let content = contentWidth(bounds.width)
        var y: CGFloat = 1
        rowTops = []
        for (index, height) in heights.enumerated() {
            rowTops.append(y)
            let lineMid = y + dz(18)
            switch index {
            case 0:
                let size = reveal.button.intrinsicContentSize
                let pathWidth = min(path.textWidth, max(0, content - size.width - dz(12)))
                path.place(CGRect(x: x, y: lineMid - dz(10), width: pathWidth, height: dz(20)))
                reveal.button.place(CGRect(x: x + pathWidth + dz(12), y: lineMid - size.height / 2, width: size.width, height: size.height))
                notesHint.place(CGRect(x: x, y: y + dz(32), width: content, height: notesHint.height(forWidth: content)))
            case 1:
                mcp.place(CGRect(x: x, y: lineMid - dz(10), width: content, height: dz(20)))
            case 2:
                let stateWidth = min(claudeState.textWidth, content)
                claudeState.place(CGRect(x: x, y: lineMid - dz(10), width: stateWidth, height: dz(20)))
                let size = register.button.intrinsicContentSize
                register.button.place(CGRect(x: x + stateWidth + dz(12), y: lineMid - size.height / 2, width: size.width, height: size.height))
                claudeHint.place(CGRect(x: x, y: y + dz(32), width: content, height: claudeHint.height(forWidth: content)))
            default:
                let size = codex.button.intrinsicContentSize
                codex.button.place(CGRect(x: x, y: lineMid - size.height / 2, width: size.width, height: size.height))
                codexNone.place(CGRect(x: x, y: lineMid - dz(10), width: content, height: dz(20)))
            }
            y += height
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let heights = rowHeights(bounds.width)
        let separators = rowTops.dropFirst().map { $0 }
        RowsPanel.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: heights.reduce(0, +) + 2), separators: separators)
        for (index, top) in rowTops.enumerated() where Self.labels.indices.contains(index) {
            Draw.text(TextStyle.caps(10.5, Palette.dim, tracking: 0.16).string(Self.labels[index]), x: dz(18), centerY: top + dz(18),
                      maxWidth: labelWidth - dz(8))
        }
    }
}

// MARK: - Step 5

/// Step 5: `ACCOUNTS · 依每週重置排序 · 越快重置越上面`, the accounts in R7 order (slot + alias, plan,
/// 5h / 1w bars, `1w 重置 1d12h後`, `✓ ACTIVE` with the amber bar), `[+ 加入帳號]` (the wording of Settings and STATUS); or the cswap note
/// and (FB) the install guide.
final class AccountsStepView: NSView, StepBodyView {
    private(set) var model: AccountsStepModel?
    let add = PressButton("+ 加入帳號", style: .bracket(.normal, small: false), accessibility: "加入帳號")
    let note = TextLine()
    let detail = RichTextView(look: RichLook(size: 12.5, color: Palette.bone, lineHeight: 12.5 * 1.5))
    /// FB: how to install (or update) cswap, under the note while cswap cannot be used.
    let guide = CswapGuideBlock()
    private var rowElements: [NSAccessibilityElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(add.button)
        addSubview(note)
        addSubview(detail)
        guide.isHidden = true
        addSubview(guide)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("帳號")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var keyViews: [NSView] { (guide.isHidden ? [] : guide.buttons) + (add.button.isHidden ? [] : [add.button]) }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if !note.isHidden { children.append(note) }
        if !detail.isHidden { children.append(detail) }
        if !guide.isHidden { children.append(guide) }
        children.append(contentsOf: rowElements as [Any])
        if !add.button.isHidden { children.append(add.button) }
        return children
    }

    static let header = "ACCOUNTS"
    static let headerHint = " · 依每週重置排序 · 越快重置越上面"

    func apply(_ model: AccountsStepModel) {
        guard model != self.model else { return }
        self.model = model
        if let text = model.availabilityNote {
            note.set("// " + text, style: TextStyle.comment)
            note.isHidden = false
        } else {
            note.isHidden = true
        }
        if let text = model.availabilityDetail {
            detail.set(text)
            detail.isHidden = false
        } else {
            detail.isHidden = true
        }
        if let installGuide = model.installGuide { guide.apply(installGuide) }
        guide.isHidden = model.installGuide == nil
        add.button.isHidden = !model.canAdd && model.rows.isEmpty
        add.button.isEnabled = model.canAdd
        rowElements = model.rows.map { row in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            var label = "帳號 \(row.slot) \(row.alias)"
            if row.active { label += "，使用中" }
            label += "，5 小時剩 \(Self.percent(row.fiveHourRemaining))，1 週剩 \(Self.percent(row.weeklyRemaining))，\(row.weeklyReset)"
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            return element
        }
        needsLayout = true
        needsDisplay = true
    }

    static func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }

    private var headerHeight: CGFloat { dz(20) }
    private var rowHeight: CGFloat { dz(44) }
    private var rowsTop: CGFloat {
        var y: CGFloat = 0
        if !note.isHidden { y += dz(20) + dz(8) }
        if !detail.isHidden { y += detail.height(forWidth: min(bounds.width, dz(820))) + dz(12) }
        if !guide.isHidden { y += guide.height(forWidth: min(bounds.width, dz(820))) + dz(12) }
        return y
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        if !note.isHidden { y += dz(20) + dz(8) }
        if !detail.isHidden { y += detail.height(forWidth: min(width, dz(820))) + dz(12) }
        if !guide.isHidden { y += guide.height(forWidth: min(width, dz(820))) + dz(12) }
        let rows = model?.rows.count ?? 0
        if rows > 0 { y += headerHeight + dz(8) + rowHeight * CGFloat(rows) + 2 }
        if !add.button.isHidden { y += dz(14) + dz(28) }
        return ceil(y)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if !note.isHidden {
            note.place(CGRect(x: 0, y: 0, width: bounds.width, height: dz(20)))
            y += dz(20) + dz(8)
        }
        if !detail.isHidden {
            let width = min(bounds.width, dz(820))
            let height = detail.height(forWidth: width)
            detail.place(CGRect(x: 0, y: y, width: width, height: height))
            y += height + dz(12)
        }
        if !guide.isHidden {
            let width = min(bounds.width, dz(820))
            let height = guide.height(forWidth: width)
            guide.place(CGRect(x: 0, y: y, width: width, height: height))
            y += height + dz(12)
        }
        let rows = model?.rows.count ?? 0
        if rows > 0 {
            y += headerHeight + dz(8)
            for index in 0..<rows {
                rowElements[index].setAccessibilityFrameInParentSpace(CGRect(x: 0, y: y + 1 + rowHeight * CGFloat(index), width: bounds.width,
                                                                              height: rowHeight))
            }
            y += rowHeight * CGFloat(rows) + 2
        }
        let size = add.button.intrinsicContentSize
        add.button.place(CGRect(x: 0, y: y + dz(14), width: size.width, height: size.height))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, !model.rows.isEmpty else { return }
        var y = rowsTop
        let header = runs([(Self.header, TextStyle.sectionLabel), (Self.headerHint, TextStyle.hint)])
        Draw.text(header, x: 0, centerY: y + headerHeight / 2, maxWidth: bounds.width)
        y += headerHeight + dz(8)
        let panel = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight * CGFloat(model.rows.count) + 2)
        RowsPanel.draw(in: panel, separators: (1..<model.rows.count).map { y + 1 + rowHeight * CGFloat($0) })
        for (index, row) in model.rows.enumerated() {
            drawRow(row, in: CGRect(x: 1, y: y + 1 + rowHeight * CGFloat(index), width: bounds.width - 2, height: rowHeight))
        }
    }

    private func drawRow(_ row: AccountsStepModel.Row, in rect: CGRect) {
        if row.active {
            Draw.fill(rect, Palette.bgLift)
            Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: dz(2), height: rect.height), Palette.amber)
        }
        let mid = rect.midY
        var x = rect.minX + dz(14)
        let alias = TextStyle(font: Typeface.display(13), color: row.active ? Palette.amber : Palette.cyan)
        x += Draw.text(alias.string("\(row.slot) \(row.alias)"), x: x, centerY: mid, maxWidth: dz(110))
        x = max(x + dz(12), rect.minX + dz(130))
        if let plan = row.plan {
            x += ChipStyle.chip(.plain, mini: true).draw(plan, x: x, centerY: mid) + dz(16)
        }
        var right = rect.maxX - dz(14)
        if row.active {
            let chip = ChipStyle.chip(.amber, caps: true)
            let width = chip.size(for: "✓ ACTIVE").width
            chip.draw("✓ ACTIVE", x: right - width, centerY: mid)
            right -= width + dz(16)
        }
        let reset = TextStyle.mono(11, Palette.bone).string(row.weeklyReset)
        let resetWidth = Draw.width(reset)
        Draw.text(reset, x: right - resetWidth, centerY: mid)
        right -= resetWidth + dz(16)
        let barWidth = max(dz(90), (right - x - dz(16)) / 2)
        let five = QuotaBarRow(key: "5h", remainingPercent: row.fiveHourRemaining)
        let week = QuotaBarRow(key: "1w", remainingPercent: row.weeklyRemaining)
        let barHeight = QuotaBarRowRenderer.height
        QuotaBarRowRenderer.draw(five, in: CGRect(x: x, y: mid - barHeight / 2, width: barWidth, height: barHeight))
        QuotaBarRowRenderer.draw(week, in: CGRect(x: x + barWidth + dz(16), y: mid - barHeight / 2, width: barWidth, height: barHeight))
    }
}

// MARK: - Step 6

/// Step 6: the boot-style summary, NOTIFICATIONS (`[允許通知]` or its state), `按 ⌘N 開第一個 session`.
final class DoneStepView: NSView, StepBodyView {
    private(set) var model: DoneStepModel?
    let term = BootTermView()
    let notifyText = RichTextView("允許通知：session 需要你回覆或出錯，而你不在 CODD 畫面前時，CODD 會發通知提醒你。",
                                  look: RichLook(size: 12.5, color: Palette.bone, lineHeight: 12.5 * 1.5))
    let allow = PressButton("允許通知", style: .bracket(.accent, small: false), accessibility: "允許 CODD 發通知")
    let state = TextLine()
    let hint = TextLine()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [term, notifyText, allow.button, state, hint] { addSubview(view) }
        hint.set("按 ⌘N 開第一個 session", style: TextStyle.hint)
        term.setAccessibilityElement(true)
        term.setAccessibilityRole(.group)
        term.setAccessibilityLabel("設定摘要")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var keyViews: [NSView] { allow.button.isHidden ? [] : [allow.button] }

    static let notificationsLabel = "NOTIFICATIONS"

    func apply(_ model: DoneStepModel) {
        guard model != self.model else { return }
        self.model = model
        term.apply(model.summary)
        switch model.notifications {
        case .notAsked, .asking:
            allow.button.isHidden = false
            allow.button.isEnabled = model.notifications == .notAsked
            state.isHidden = true
        case .granted:
            allow.button.isHidden = true
            state.set { runs([("● ", TextStyle.mono(12, Palette.success)), ("已允許", TextStyle.mono(12, Palette.bone))]) }
            state.isHidden = false
        case .denied:
            allow.button.isHidden = true
            state.set { runs([("○ ", TextStyle.mono(12, Palette.dim)), ("未允許 · 可在 系統設定 › 通知 開啟", TextStyle.mono(12, Palette.bone))]) }
            state.isHidden = false
        case .suppressed:
            allow.button.isHidden = true
            state.set { runs([("○ ", TextStyle.mono(12, Palette.dim)), ("這次執行不發通知", TextStyle.mono(12, Palette.bone))]) }
            state.isHidden = false
        }
        needsLayout = true
        needsDisplay = true
    }

    private var termHeight: CGFloat { 2 + term.height() }
    private func notifyHeight(_ width: CGFloat) -> CGFloat {
        dz(14) + dz(20) + dz(8) + notifyText.height(forWidth: textWidth(width)) + dz(12) + dz(28) + dz(14)
    }
    private func textWidth(_ width: CGFloat) -> CGFloat { min(dz(820), max(dz(80), width - dz(36))) }

    func height(forWidth width: CGFloat) -> CGFloat {
        ceil(termHeight + dz(16) + notifyHeight(width) + dz(16) + dz(20))
    }

    override func layout() {
        super.layout()
        term.place(CGRect(x: 1, y: 1, width: bounds.width - 2, height: term.height()))
        let top = termHeight + dz(16)
        let textTop = top + dz(14) + dz(20) + dz(8)
        let width = textWidth(bounds.width)
        let textHeight = notifyText.height(forWidth: width)
        notifyText.place(CGRect(x: dz(18), y: textTop, width: width, height: textHeight))
        let controlsTop = textTop + textHeight + dz(12)
        let size = allow.button.intrinsicContentSize
        allow.button.place(CGRect(x: dz(18), y: controlsTop, width: size.width, height: size.height))
        state.place(CGRect(x: dz(18), y: controlsTop + (dz(28) - dz(20)) / 2, width: width, height: dz(20)))
        hint.place(CGRect(x: 0, y: top + notifyHeight(bounds.width) + dz(16), width: bounds.width, height: dz(20)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let termRect = CGRect(x: 0, y: 0, width: bounds.width, height: termHeight)
        Draw.fill(termRect, .black)
        Draw.strokeRect(termRect, color: Palette.lineBright)
        let top = termHeight + dz(16)
        let block = CGRect(x: 0, y: top, width: bounds.width, height: notifyHeight(bounds.width))
        Panel.draw(block)
        Draw.text(TextStyle.sectionLabel.string(Self.notificationsLabel), x: dz(18), centerY: top + dz(14) + dz(10))
    }
}
