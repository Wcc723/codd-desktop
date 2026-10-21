import AppKit
import CoddUI

/// `.ia-stage`: the grid background (fixed, like the artboard's stage background), the scrolling
/// canvas and the hint line pinned to its top-left corner.
final class AnnotateStageView: FlippedView {
    let scrollView = NSScrollView()
    let canvas: AnnotateCanvasView
    let hintLine = RunLineView([
        .text("拖曳控制點調整大小", AnnotateTheme.stageHint), .gap(8), .text("·", AnnotateTheme.faint), .gap(8),
        .kbd("⇧"), .gap(8), .text("鎖定比例", AnnotateTheme.stageHint), .gap(8), .text("·", AnnotateTheme.faint), .gap(8),
        .kbd("Del"), .gap(8), .text("刪除", AnnotateTheme.stageHint), .gap(8), .text("·", AnnotateTheme.faint), .gap(8),
        .kbd("⎋"), .gap(8), .text("結束標註", AnnotateTheme.stageHint),
    ])

    init(image: CGImage) {
        canvas = AnnotateCanvasView(image: image)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = canvas
        addSubview(scrollView)
        addSubview(hintLine)
        setAccessibilityElement(false)
        canvas.setAccessibilityLabel("標註畫布")
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(canvasScrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    /// The hint gets a backing while the zoomed image passes under it (it stays readable); on the
    /// grid it is drawn bare like the artboard.
    @objc func canvasScrolled() { updateHintPlate() }

    func updateHintPlate() {
        let frame = convert(canvas.frameRect, from: canvas)
        hintLine.plate = frame.intersects(hintLine.frame.insetBy(dx: -4, dy: -4)) ? AnnotateTheme.stageBackground.withAlphaComponent(0.88) : nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        // Views do not clip to their bounds since macOS 14, and the dirty rect may reach outside.
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty else { return }
        Draw.fill(rect, AnnotateTheme.stageBackground)
        let step = AnnotateTheme.gridStep
        var x = floor(rect.minX / step) * step
        while x < rect.maxX {
            Draw.fill(CGRect(x: x, y: rect.minY, width: 1, height: rect.height), AnnotateTheme.gridLine)
            x += step
        }
        var y = floor(rect.minY / step) * step
        while y < rect.maxY {
            Draw.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 1), AnnotateTheme.gridLine)
            y += step
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // `.ia-shint{top:12px;left:16px}`, one 18 pt line (the kbd boxes).
        hintLine.frame = CGRect(x: 16, y: 12, width: min(hintLine.naturalWidth, max(0, bounds.width - 32)), height: 18)
        canvas.relayout(keepCenter: false)
        updateHintPlate()
    }

    /// The visible part of the stage in canvas coordinates.
    var visibleCanvasRect: CGRect { scrollView.contentView.documentVisibleRect }
}

/// The scrolling document of the stage: the `.ia-frame` (black plate, 8 pt padding, line-bright
/// border, drop shadow), the origin labels `0,0` / `<w>,<h>` and the caption; the image and the
/// overlay are subviews. It is the canvas the tool keys and the mouse gestures go to.
final class AnnotateCanvasView: FlippedView {
    weak var owner: ImageAnnotateView?
    let imagePlate: ImagePlateView
    let overlay = OverlayView()
    private(set) var mapping = CanvasMapping(scale: 1, imageOrigin: .zero, pixelWidth: 1, pixelHeight: 1)
    private(set) var frameRect = CGRect.zero
    /// The text tool's inline field while it is open.
    private(set) var inlineEditor: InlineTextEditor?
    private var gesture: Gesture = .none

    private enum Gesture {
        var isNone: Bool { if case .none = self { true } else { false } }

        case none
        case drawRect(start: CGPoint, before: AnnotationDocument)
        case drawPoint(before: AnnotationDocument)
        case drawArrow(start: (x: Int, y: Int), before: AnnotationDocument)
        case move(AnnotationDraft, from: CGPoint, before: AnnotationDocument)
        case resize(AnnotationDraft, RectCorner, before: AnnotationDocument)
        case endpoint(AnnotationDraft, head: Bool, before: AnnotationDocument)
    }

    /// The item being drawn (not in the document yet).
    private(set) var provisional: AnnotationDraft?
    private var downPoint = CGPoint.zero
    private var dragStarted = false

    init(image: CGImage) {
        imagePlate = ImagePlateView(image: image)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(imagePlate)
        addSubview(overlay)
        overlay.canvas = self
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var overlayLayout: OverlayLayout {
        OverlayLayout(mapping: mapping, pixelWidth: mapping.pixelWidth, pixelHeight: mapping.pixelHeight)
    }

    // MARK: Layout

    private var captionText: String {
        let w = mapping.pixelWidth, h = mapping.pixelHeight
        return "原圖 \(w)×\(h) · 顯示 \(Int((mapping.scale * 100).rounded()))% · 座標以原圖像素、左上為原點"
    }

    private static var captionHeight: CGFloat { az(17) }

    /// Room for the origin labels outside the frame (label + 16 pt gap + a little air).
    private var labelRoom: CGFloat {
        let w = owner?.document.pixelWidth ?? 1, h = owner?.document.pixelHeight ?? 1
        return max(Draw.width(AnnotateTheme.originLabel.string("0,0")), Draw.width(AnnotateTheme.originLabel.string("\(w),\(h)")))
            + AnnotateTheme.originLabelGap + az(8)
    }

    /// The air left and right of the block: `fitMargin`, or 12 on a narrow stage (a small window
    /// at zoom 20), where the 40 pt margins and the origin labels would leave the image a few
    /// percent of its size.
    private func marginX(stageWidth: CGFloat) -> CGFloat {
        stageWidth >= az(560) ? AnnotateTheme.fitMargin : az(12)
    }

    /// The scale Fit picks for the current stage.
    func fitScale(stage: CGSize) -> CGFloat {
        let w = owner?.document.pixelWidth ?? 1, h = owner?.document.pixelHeight ?? 1
        let margin = AnnotateTheme.fitMargin * 2
        let available = CGSize(width: stage.width - marginX(stageWidth: stage.width) * 2 - AnnotateTheme.frameInset * 2 - labelRoom * 2,
                               height: stage.height - margin - AnnotateTheme.frameInset * 2 - AnnotateTheme.captionGap - Self.captionHeight)
        return AnnotationGeometry.fitScale(available: available, width: w, height: h)
    }

    /// Recomputes the scale and the document size for the stage's size and the zoom; `keepCenter`
    /// keeps the pixel under the visible center where it was (zoom changes).
    func relayout(keepCenter: Bool) {
        guard let owner, let scroll = enclosingScrollView else { return }
        let stage = scroll.contentSize
        guard stage.width > 0, stage.height > 0 else { return }
        let center = keepCenter ? mapping.pixel(CGPoint(x: visibleRect.midX, y: visibleRect.midY)) : nil
        let w = owner.document.pixelWidth, h = owner.document.pixelHeight
        let scale: CGFloat = switch owner.zoom {
        case .fit: fitScale(stage: stage)
        case .actual: 1
        case .double: 2
        }
        let imageSize = CGSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
        let frameSize = CGSize(width: imageSize.width + AnnotateTheme.frameInset * 2, height: imageSize.height + AnnotateTheme.frameInset * 2)
        let blockHeight = frameSize.height + AnnotateTheme.captionGap + Self.captionHeight
        let contentWidth = frameSize.width + (marginX(stageWidth: stage.width) + labelRoom) * 2
        let contentHeight = blockHeight + AnnotateTheme.fitMargin * 2
        let size = CGSize(width: max(stage.width, ceil(contentWidth)), height: max(stage.height, ceil(contentHeight)))
        frameRect = CGRect(x: round((size.width - frameSize.width) / 2), y: round((size.height - blockHeight) / 2),
                           width: frameSize.width, height: frameSize.height)
        let newMapping = CanvasMapping(scale: scale, imageOrigin: CGPoint(x: frameRect.minX + AnnotateTheme.frameInset,
                                                                         y: frameRect.minY + AnnotateTheme.frameInset),
                                       pixelWidth: w, pixelHeight: h)
        let changed = newMapping != mapping || frame.size != size
        mapping = newMapping
        if frame.size != size { setFrameSize(size) }
        imagePlate.frame = mapping.imageRect
        imagePlate.scale = scale
        overlay.frame = bounds
        if changed {
            needsDisplay = true
            overlay.needsDisplay = true
            positionInlineEditor()
        }
        if let center { scrollToCenter(pixel: center) }
        (enclosingScrollView?.superview as? AnnotateStageView)?.updateHintPlate()
    }

    /// Scrolls so `pixel` is in the middle of the visible stage (clamped to the document).
    func scrollToCenter(pixel: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        let point = mapping.view(pixel.x, pixel.y)
        let visible = scroll.contentSize
        let origin = CGPoint(x: min(max(0, point.x - visible.width / 2), max(0, bounds.width - visible.width)),
                             y: min(max(0, point.y - visible.height / 2), max(0, bounds.height - visible.height)))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard frameRect.width > 0 else { return }
        // `.ia-frame`: shadow 0 18px 50px rgba(0,0,0,.65), #000 plate, 1 px line-bright border.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 50
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.set()
        Draw.fill(frameRect, .black)
        NSGraphicsContext.restoreGraphicsState()
        Draw.strokeRect(frameRect, color: Palette.lineBright)
        // `.ia-o.tl{right:calc(100% + 16px);top:-7px}` / `.ia-o.br{left:calc(100% + 16px);bottom:-7px}`
        // around the image (`.ann-wrap`); one 15.75 pt line each.
        let image = mapping.imageRect
        let tl = AnnotateTheme.originLabel.string("0,0")
        Draw.text(tl, x: image.minX - AnnotateTheme.originLabelGap - Draw.width(tl), centerY: image.minY - 7 + 7.875)
        let br = AnnotateTheme.originLabel.string("\(mapping.pixelWidth),\(mapping.pixelHeight)")
        Draw.text(br, x: image.maxX + AnnotateTheme.originLabelGap, centerY: image.maxY + 7 - 7.875)
        // `.ia-cap`, centered under the frame after the 12 pt gap.
        let caption = AnnotateTheme.stageHint.string(captionText)
        Draw.text(caption, x: round(frameRect.midX - Draw.width(caption) / 2),
                  centerY: frameRect.maxY + AnnotateTheme.captionGap + Self.captionHeight / 2)
    }

    /// The caption as drawn (tests).
    var displayedCaption: String { captionText }

    // MARK: Tools and keys

    override func resetCursorRects() {
        super.resetCursorRects()
        if owner?.tool != .select { addCursorRect(visibleRect, cursor: .crosshair) }
    }

    override func keyDown(with event: NSEvent) {
        // Keys count only while the canvas itself has focus (never while a field edits).
        guard let owner, window?.firstResponder === self else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117:
            // ⌫ / Del
            owner.deleteSelection()
            return
        case 53:
            cancelOperation(nil)
            return
        case 36, 76:
            // ⏎ with a drawing tool: a new item at the visible center (D21, no mouse needed).
            if flags.isEmpty { addAtCenter() }
            return
        case 123, 124, 125, 126:
            // Arrows move the selected item by one pixel (⇧: ten).
            if flags.isEmpty { nudgeSelection(keyCode: event.keyCode, step: event.modifierFlags.contains(.shift) ? 10 : 1) }
            return
        default:
            break
        }
        guard flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
              let tool = AnnotateTool.allCases.first(where: { $0.key.lowercased() == key })
        else { return super.keyDown(with: event) }
        owner.setTool(tool)
    }

    /// The image pixel under the middle of the visible stage (clamped to the image).
    private var visibleCenterPixel: (x: Int, y: Int) {
        let doc = owner?.document
        let p = mapping.pixel(CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        return AnnotationGeometry.clampedPixel(p, width: doc?.pixelWidth ?? 1, height: doc?.pixelHeight ?? 1)
    }

    /// ⏎: the current drawing tool's item at the visible center, selected, one undo step (the
    /// text tool opens its field there). A box is a fifth of the image, an arrow points right.
    func addAtCenter() {
        guard let owner, gesture.isNone else { return }
        let doc = owner.document
        let w = doc.pixelWidth, h = doc.pixelHeight
        let c = visibleCenterPixel
        let n = doc.items.count + 1
        let color = owner.currentColor
        let draft: AnnotationDraft
        switch owner.tool {
        case .select:
            return
        case .text:
            openInlineEditor(atPixel: c)
            return
        case .rect:
            let bw = max(1, w / 5), bh = max(1, h / 5)
            let x = AnnotationGeometry.clamp(c.x - bw / 2, 0, w - bw), y = AnnotationGeometry.clamp(c.y - bh / 2, 0, h - bh)
            draft = .rect(n, x: x, y: y, w: bw, h: bh, color: color)
        case .point:
            draft = .point(n, x: c.x, y: c.y, color: color)
        case .arrow:
            let length = max(1, w / 8)
            let x = AnnotationGeometry.clamp(c.x - length / 2, 0, w), x2 = AnnotationGeometry.clamp(c.x + length / 2, 0, w)
            guard x2 != x else { return }
            draft = .arrow(n, x: x, y: c.y, x2: x2, y2: c.y, color: color)
        }
        let (next, added) = AnnotationEditing.appending(draft, to: doc)
        owner.canvasCommit(next, selection: added, actionName: "新增標註", before: doc)
        overlay.needsDisplay = true
    }

    /// ← → ↑ ↓ on the canvas: moves the selected item by `step` pixels, one undo step per press.
    func nudgeSelection(keyCode: UInt16, step: Int) {
        guard let owner, gesture.isNone, let n = owner.selection, let item = owner.document.item(n) else { return }
        let doc = owner.document
        let (dx, dy): (Int, Int) = switch keyCode {
        case 123: (-step, 0)
        case 124: (step, 0)
        case 125: (0, step)
        default: (0, -step)
        }
        let moved = AnnotationGeometry.moved(item, dx: dx, dy: dy, width: doc.pixelWidth, height: doc.pixelHeight)
        guard moved != item else { return }
        owner.canvasCommit(AnnotationEditing.replacing(moved, in: doc), selection: n, actionName: "移動標註", before: doc)
        overlay.needsDisplay = true
    }

    // MARK: VoiceOver (D21)

    /// Each annotation as an image with its description (number, kind, note, coordinates),
    /// selected or not; pressing one selects it. Rebuilt when the items change.
    private var pinElements: [AnnotationPinElement] = []

    override func accessibilityChildren() -> [Any]? {
        let items = owner?.document.items ?? []
        if pinElements.map(\.n) != items.map(\.n) {
            pinElements = items.map { AnnotationPinElement(canvas: self, n: $0.n) }
        }
        return (super.accessibilityChildren() ?? []) + pinElements
    }

    fileprivate func pinDescription(_ n: Int) -> String? {
        guard let item = owner?.document.item(n) else { return nil }
        let note = item.note.isEmpty ? "（沒有說明）" : item.note
        return "標註 \(n) · \(item.kind.title)：\(note)，\(item.coordinateText)"
    }

    fileprivate func pinIsSelected(_ n: Int) -> Bool { owner?.selection == n }

    fileprivate func pinFrame(_ n: Int) -> CGRect {
        guard let item = owner?.document.item(n), let window else { return .zero }
        let rect = overlayLayout.bounds(item, selected: owner?.selection == n)
        return window.convertToScreen(convert(rect, to: nil))
    }

    fileprivate func selectPin(_ n: Int) {
        owner?.canvasSelect(n)
        overlay.needsDisplay = true
    }

    /// ⎋: a gesture in progress is cancelled; otherwise the owner deselects or finishes.
    override func cancelOperation(_ sender: Any?) {
        if cancelGesture() { return }
        owner?.escape()
    }

    /// Drops an unfinished gesture (the document goes back to where it started). True if there was one.
    @discardableResult
    func cancelGesture() -> Bool {
        let before: AnnotationDocument?
        switch gesture {
        case .none: before = nil
        case .drawRect(_, let b), .drawPoint(let b), .drawArrow(_, let b): before = b
        case .move(_, _, let b), .resize(_, _, let b), .endpoint(_, _, let b): before = b
        }
        gesture = .none
        provisional = nil
        guard let before else { return false }
        owner?.canvasPreview(before)
        overlay.needsDisplay = true
        return true
    }

    // MARK: Mouse

    private func pixel(of event: NSEvent) -> CGPoint { mapping.pixel(convert(event.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        if inlineEditor != nil {
            // A click outside the open text field commits it and does nothing else.
            commitInlineEditor()
            window?.makeFirstResponder(self)
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        dragStarted = false
        let p = mapping.pixel(point)
        let doc = owner.document
        let w = doc.pixelWidth, h = doc.pixelHeight
        let color = owner.currentColor
        switch owner.tool {
        case .select:
            switch overlayLayout.hit(point, items: doc.items, selected: owner.selection) {
            case .none:
                owner.canvasSelect(nil)
            case .item(let n):
                owner.canvasSelect(n)
                if let item = doc.item(n) { gesture = .move(item, from: point, before: doc) }
            case .corner(let n, let corner):
                if let item = doc.item(n) { gesture = .resize(item, corner, before: doc) }
            case .arrowStart(let n):
                if let item = doc.item(n) { gesture = .endpoint(item, head: false, before: doc) }
            case .arrowEnd(let n):
                if let item = doc.item(n) { gesture = .endpoint(item, head: true, before: doc) }
            }
        case .rect:
            gesture = .drawRect(start: p, before: doc)
            provisional = nil
        case .point:
            let c = AnnotationGeometry.clampedPixel(p, width: w, height: h)
            gesture = .drawPoint(before: doc)
            provisional = .point(doc.items.count + 1, x: c.x, y: c.y, color: color)
        case .arrow:
            gesture = .drawArrow(start: AnnotationGeometry.clampedPixel(p, width: w, height: h), before: doc)
            provisional = nil
        case .text:
            let c = AnnotationGeometry.clampedPixel(p, width: w, height: h)
            openInlineEditor(atPixel: c)
        }
        overlay.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let p = mapping.pixel(point)
        let doc = owner.document
        let w = doc.pixelWidth, h = doc.pixelHeight
        let shift = event.modifierFlags.contains(.shift)
        let color = owner.currentColor
        // A click on an item or a handle that jitters by a point is not an edit.
        if hypot(point.x - downPoint.x, point.y - downPoint.y) >= 2 { dragStarted = true }
        switch gesture {
        case .none:
            return
        case .move, .resize, .endpoint:
            if !dragStarted { return }
        default:
            break
        }
        switch gesture {
        case .none:
            return
        case .drawRect(let start, _):
            provisional = hypot(point.x - downPoint.x, point.y - downPoint.y) < 3 ? nil
                : AnnotationGeometry.rect(from: start, to: p, square: shift, width: w, height: h)
                    .map { .rect(doc.items.count + 1, x: $0.x, y: $0.y, w: $0.w, h: $0.h, color: color) }
        case .drawPoint:
            let c = AnnotationGeometry.clampedPixel(p, width: w, height: h)
            provisional = .point(doc.items.count + 1, x: c.x, y: c.y, color: color)
        case .drawArrow(let start, _):
            if hypot(point.x - downPoint.x, point.y - downPoint.y) < 3 {
                provisional = nil
            } else {
                let end = AnnotationGeometry.arrowEnd(from: start, toward: p, snap: shift, width: w, height: h)
                provisional = (end.x, end.y) == (start.x, start.y) ? nil
                    : .arrow(doc.items.count + 1, x: start.x, y: start.y, x2: end.x, y2: end.y, color: color)
            }
        case .move(let original, let from, let before):
            let moved = AnnotationGeometry.moved(original, dx: mapping.pixels(point.x - from.x), dy: mapping.pixels(point.y - from.y),
                                                 width: w, height: h)
            owner.canvasPreview(AnnotationEditing.replacing(moved, in: before))
        case .resize(let original, let corner, let before):
            let resized = AnnotationGeometry.resized(original, corner: corner, to: p, lockAspect: shift, width: w, height: h)
            owner.canvasPreview(AnnotationEditing.replacing(resized, in: before))
        case .endpoint(let original, let head, let before):
            let moved = AnnotationGeometry.movedEndpoint(original, head: head, to: p, snap: shift, width: w, height: h)
            owner.canvasPreview(AnnotationEditing.replacing(moved, in: before))
        }
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return }
        let current = gesture
        gesture = .none
        let draft = provisional
        provisional = nil
        switch current {
        case .none:
            break
        case .drawRect(_, let before), .drawPoint(let before), .drawArrow(_, let before):
            if let draft {
                let (doc, n) = AnnotationEditing.appending(draft, to: before)
                owner.canvasCommit(doc, selection: n, actionName: "新增標註", before: before)
            }
        case .move(_, _, let before):
            owner.canvasFinish(before: before, actionName: "移動標註")
        case .resize(_, _, let before):
            owner.canvasFinish(before: before, actionName: "調整標註大小")
        case .endpoint(_, _, let before):
            owner.canvasFinish(before: before, actionName: "移動箭頭端點")
        }
        overlay.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event) ?? super.scrollWheel(with: event)
    }

    // MARK: Text tool

    func openInlineEditor(atPixel pixel: (x: Int, y: Int)) {
        let editor = InlineTextEditor(pixel: pixel)
        editor.onCommit = { [weak self] text in self?.finishInlineEditor(text: text) }
        editor.onCancel = { [weak self] in self?.finishInlineEditor(text: nil) }
        inlineEditor = editor
        addSubview(editor)
        positionInlineEditor()
        window?.makeFirstResponder(editor.textView)
    }

    private func positionInlineEditor() {
        guard let editor = inlineEditor else { return }
        let origin = mapping.view(editor.pixel.x, editor.pixel.y)
        editor.frame = CGRect(x: round(origin.x), y: round(origin.y), width: 240, height: InlineTextEditor.height)
    }

    /// Commits the open text field (if any) as a text annotation; empty text creates nothing.
    func commitInlineEditor() {
        guard let editor = inlineEditor else { return }
        editor.commit()
    }

    private func finishInlineEditor(text: String?) {
        guard let editor = inlineEditor, let owner else { return }
        inlineEditor = nil
        let refocus = window?.firstResponder === editor.textView
        editor.removeFromSuperview()
        if refocus { window?.makeFirstResponder(self) }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let before = owner.document
        let draft = AnnotationDraft.text(before.items.count + 1, x: editor.pixel.x, y: editor.pixel.y, note: text, color: owner.currentColor)
        let (doc, n) = AnnotationEditing.appending(draft, to: before)
        owner.canvasCommit(doc, selection: n, actionName: "新增標註", before: before)
    }
}

/// The image inside the frame; redrawn only when the zoom changes (the overlay is its own view).
final class ImagePlateView: NSView {
    let image: CGImage
    var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Crisp pixels from 100 % up (coordinates are read off them); smooth when shrunk.
        context.interpolationQuality = scale >= 1 ? .none : .high
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// The annotations over the image (the whole canvas, so pins, handles and the tooltip can reach
/// outside the picture). Never takes the mouse: the canvas handles every gesture.
final class OverlayView: NSView {
    weak var canvas: AnnotateCanvasView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let owner = canvas.owner else { return }
        OverlayRenderer.draw(items: owner.document.items, selected: owner.selection, provisional: canvas.provisional,
                             layout: canvas.overlayLayout)
    }
}

/// An annotation on the canvas as VoiceOver sees it (D21): an image described by its number, kind,
/// note and coordinates, selected or not; pressing it selects the item. The canvas draws the pins
/// itself, so these elements carry what the drawing shows. NSAccessibilityElement's methods are not
/// isolated; accessibility asks on the main thread.
final class AnnotationPinElement: NSAccessibilityElement {
    private weak var canvas: AnnotateCanvasView?
    let n: Int

    @MainActor
    init(canvas: AnnotateCanvasView, n: Int) {
        self.canvas = canvas
        self.n = n
        super.init()
        setAccessibilityParent(canvas)
        setAccessibilityRole(.image)
    }

    override func accessibilityLabel() -> String? {
        let canvas = canvas, n = n
        return MainActor.assumeIsolated { canvas?.pinDescription(n) }
    }

    override func isAccessibilitySelected() -> Bool {
        let canvas = canvas, n = n
        return MainActor.assumeIsolated { canvas?.pinIsSelected(n) ?? false }
    }

    override func accessibilityFrame() -> NSRect {
        let canvas = canvas, n = n
        return MainActor.assumeIsolated { canvas?.pinFrame(n) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let canvas = canvas, n = n
        return MainActor.assumeIsolated {
            guard let canvas else { return false }
            canvas.selectPin(n)
            return true
        }
    }
}
