import AppKit
import CoddUI

// Custom-drawn rows are built from `InlinePiece`s laid out like the artboard's
// `display:flex; align-items:center; gap:…` lines: text runs, chips, icons, lamps, tag squares and
// one optional flexible gap. Rows compute the layout once per size / model and draw it; keyed
// pieces keep their rectangles for hit testing (a chip that opens the session, a ▾ part).

/// A chip box (helmet `.chip` and the boards' variants) with an optional leading lamp, tag square
/// or icon.
@MainActor
struct NotebookChip {
    enum Lead {
        case lamp(NotebookSessionState, size: CGFloat)
        case tag(NotebookTag?, size: CGFloat)
        case icon(NotebookIcon, size: CGFloat, color: NSColor)
    }

    var text: String
    var style: TextStyle
    var border: NSColor?
    var fill: NSColor?
    var dashed = false
    // Height, padding, gap and the lead's size are given in design points and read at the
    // interface zoom (like CoddUI's `ChipStyle`), so a chip grows with its text.
    private var designHeight: CGFloat
    private var designPadding: CGFloat
    private var designGap: CGFloat
    var lead: Lead?
    var strikethrough = false

    init(text: String, style: TextStyle, border: NSColor? = nil, fill: NSColor? = nil, dashed: Bool = false, height: CGFloat,
         padding: CGFloat, gap: CGFloat = 5, lead: Lead? = nil, strikethrough: Bool = false) {
        self.text = text
        self.style = style
        self.border = border
        self.fill = fill
        self.dashed = dashed
        designHeight = height
        designPadding = padding
        designGap = gap
        self.lead = lead
        self.strikethrough = strikethrough
    }

    /// Box height at the current zoom.
    var height: CGFloat {
        get { zp(designHeight) }
        set { designHeight = newValue }
    }
    /// CSS horizontal padding at the current zoom; the 1 px border is drawn inside the width on top of it.
    var padding: CGFloat {
        get { zp(designPadding) }
        set { designPadding = newValue }
    }
    var gap: CGFloat {
        get { zp(designGap) }
        set { designGap = newValue }
    }

    var attributed: NSAttributedString { style.string(text) }

    var leadWidth: CGFloat {
        switch lead {
        case .lamp(let state, let size): Draw.width(TextStyle.mono(size, state.color).string(state.glyph))
        case .tag(_, let size): zp(size)
        case .icon(_, let size, _): zp(size)
        case nil: 0
        }
    }

    var width: CGFloat {
        let content = Draw.width(attributed) + (lead == nil ? 0 : leadWidth + (text.isEmpty ? 0 : gap))
        return ceil(content + (padding + 1) * 2)
    }

    func draw(in rect: CGRect) {
        let box = CGRect(x: rect.minX, y: round(rect.midY - height / 2), width: rect.width, height: height)
        if let fill { Draw.fill(box, fill) }
        if let border {
            if dashed { Draw.dashedRect(box, color: border) } else { Draw.strokeRect(box, color: border) }
        }
        var x = box.minX + padding + 1
        switch lead {
        case .lamp(let state, let size):
            x += NotebookDraw.lamp(state, x: x, centerY: box.midY, size: size) + gap
        case .tag(let tag, let design):
            let size = zp(design)
            NotebookDraw.tagSquare(tag, in: CGRect(x: x, y: round(box.midY - size / 2), width: size, height: size))
            x += size + gap
        case .icon(let icon, let design, let color):
            let size = zp(design)
            NotebookIconRenderer.draw(icon, in: CGRect(x: x, y: round(box.midY - size / 2), width: size, height: size), color: color)
            x += size + gap
        case nil:
            break
        }
        let string = attributed
        let drawn = Draw.text(string, x: x, centerY: box.midY, maxWidth: max(0, box.maxX - padding - 1 - x))
        if strikethrough {
            Draw.fill(CGRect(x: x, y: round(box.midY), width: drawn, height: 1), style.color)
        }
    }

    // MARK: Board variants

    /// `.chip.nb-xs` (note rows): 17 px, 9.5 px, `padding: 0 5px`, gap 4, .04em (`.caps` .12em).
    static func xs(_ text: String, caps: Bool = false, color: NSColor = Palette.bone, border: NSColor = Palette.lineBright,
                   fill: NSColor? = nil, dashed: Bool = false, bold: Bool = false, lead: Lead? = nil) -> NotebookChip {
        let style = TextStyle(font: Typeface.mono(9.5, bold ? .bold : .regular), color: color, tracking: caps ? 0.12 : 0.04, uppercase: caps)
        return NotebookChip(text: text, style: style, border: border, fill: fill, dashed: dashed, height: 17, padding: 5, gap: 4, lead: lead)
    }

    /// The kind chip of a note row.
    static func kind(_ kind: NotebookKindBadge) -> NotebookChip {
        xs(kind.text, caps: true, color: kind.amber ? Palette.amber : Palette.bone, border: kind.amber ? Palette.amberDim : Palette.lineBright,
           dashed: kind.dashed)
    }

    /// `.nb-meta .chip` (the chips row): 20 px, 10.5 px, `padding: 0 5px`; caps keep `.1em`.
    static func meta(_ text: String, caps: Bool = false, color: NSColor = Palette.bone, border: NSColor = Palette.lineBright,
                     dashed: Bool = false, lead: Lead? = nil) -> NotebookChip {
        let style = TextStyle(font: Typeface.mono(10.5), color: color, tracking: caps ? 0.1 : 0.03, uppercase: caps)
        return NotebookChip(text: text, style: style, border: border, dashed: dashed, height: 20, padding: 5, gap: 5, lead: lead)
    }

    /// `.chip.caps.sp-kind` (drawer cards): 16 px, 9.5 px, `padding: 0 4px`.
    static func drawerKind(_ kind: NotebookKindBadge) -> NotebookChip {
        let style = TextStyle(font: Typeface.mono(9.5), color: kind.amber ? Palette.amber : Palette.bone, tracking: 0.1, uppercase: true)
        return NotebookChip(text: kind.text, style: style, border: kind.amber ? Palette.amberDim : Palette.lineBright, dashed: kind.dashed,
                            height: 16, padding: 4)
    }

    /// `.chip.fill.nb-xs` (`推薦`).
    static func recommended(_ text: String) -> NotebookChip {
        xs(text, color: .black, border: Palette.amber, fill: Palette.amber, bold: true)
    }

    /// helmet `code` inside text (`position: sticky`): amber on --bg, 1 px --line border.
    static func code(_ text: String, size: CGFloat = 11, padding: CGFloat = 4, height: CGFloat = 17) -> NotebookChip {
        NotebookChip(text: text, style: TextStyle.mono(size, Palette.amber), border: Palette.line, fill: Palette.bg, height: height,
                     padding: padding)
    }
}

@MainActor
struct InlinePiece {
    enum Content {
        case text(NSAttributedString)
        case chip(NotebookChip)
        case icon(NotebookIcon, size: CGFloat, color: NSColor, filled: Bool)
        /// A lamp glyph; `width` fixes its box (`.nb-irow .lamp{width:13px}`), nil = the glyph.
        case lamp(NotebookSessionState, size: CGFloat, width: CGFloat?)
        case tag(NotebookTag?, size: CGFloat)
        case box(CGSize, draw: (CGRect) -> Void)
        case flex
    }

    var content: Content
    /// Gives up width (truncates) when the line is too narrow (`min-width:0` + ellipsis).
    var shrink = false
    /// Among shrinking pieces, these give up their width before the others (a dim detail before
    /// the title it explains).
    var shrinksFirst = false
    /// Gap before this piece instead of the line's gap.
    var gapBefore: CGFloat?
    /// Hit-test key.
    var key: String?
    /// Plain text for the tests and VoiceOver.
    var plain: String?

    static func text(_ string: NSAttributedString, shrink: Bool = false, gapBefore: CGFloat? = nil, key: String? = nil) -> InlinePiece {
        InlinePiece(content: .text(string), shrink: shrink, gapBefore: gapBefore, key: key, plain: string.string)
    }

    static func text(_ text: String, _ style: TextStyle, shrink: Bool = false, gapBefore: CGFloat? = nil, key: String? = nil,
                     lineBreak: NSLineBreakMode = .byTruncatingTail) -> InlinePiece {
        let string = style.string(text, lineBreak: lineBreak)
        return InlinePiece(content: .text(string), shrink: shrink, gapBefore: gapBefore, key: key, plain: string.string)
    }

    static func chip(_ chip: NotebookChip, gapBefore: CGFloat? = nil, key: String? = nil) -> InlinePiece {
        InlinePiece(content: .chip(chip), gapBefore: gapBefore, key: key, plain: chip.attributed.string)
    }

    static func icon(_ icon: NotebookIcon, size: CGFloat, color: NSColor, filled: Bool = false, gapBefore: CGFloat? = nil) -> InlinePiece {
        InlinePiece(content: .icon(icon, size: size, color: color, filled: filled), gapBefore: gapBefore)
    }

    static func lamp(_ state: NotebookSessionState, size: CGFloat, width: CGFloat? = nil, gapBefore: CGFloat? = nil) -> InlinePiece {
        InlinePiece(content: .lamp(state, size: size, width: width), gapBefore: gapBefore)
    }

    static func tag(_ tag: NotebookTag?, size: CGFloat = 8, gapBefore: CGFloat? = nil) -> InlinePiece {
        InlinePiece(content: .tag(tag, size: size), gapBefore: gapBefore)
    }

    static var flex: InlinePiece { InlinePiece(content: .flex) }

    /// A fixed-size box drawn by a closure (timeline dots, a tag square in a lamp column).
    static func box(_ size: CGSize, gapBefore: CGFloat? = nil, draw: @escaping (CGRect) -> Void) -> InlinePiece {
        InlinePiece(content: .box(size, draw: draw), gapBefore: gapBefore)
    }

    /// Icon and tag sizes, a lamp's box and `gapBefore` are design points (read at the zoom);
    /// a box's size is the caller's (already at the zoom).
    var naturalWidth: CGFloat {
        switch content {
        case .text(let string): Draw.width(string)
        case .chip(let chip): chip.width
        case .icon(_, let size, _, _): zp(size)
        case .lamp(let state, let size, let width): width.map(zp) ?? Draw.width(TextStyle.mono(size, state.color).string(state.glyph))
        case .tag(_, let size): zp(size)
        case .box(let size, _): size.width
        case .flex: 0
        }
    }

    /// The gap before this piece at the zoom (nil: the line's).
    var zoomedGapBefore: CGFloat? { gapBefore.map(zp) }

    var isFlex: Bool { if case .flex = content { true } else { false } }

    func draw(in rect: CGRect) {
        switch content {
        case .text(let string):
            Draw.text(string, x: rect.minX, centerY: rect.midY, maxWidth: rect.width)
        case .chip(let chip):
            chip.draw(in: rect)
        case .icon(let icon, let design, let color, let filled):
            let size = zp(design)
            NotebookIconRenderer.draw(icon, in: CGRect(x: rect.minX, y: round(rect.midY - size / 2), width: size, height: size), color: color,
                                      filled: filled)
        case .lamp(let state, let size, let width):
            let glyph = TextStyle.mono(size, state.color).string(state.glyph)
            let x = width.map { rect.minX + (zp($0) - Draw.width(glyph)) / 2 } ?? rect.minX
            NotebookDraw.lamp(state, x: x, centerY: rect.midY, size: size)
        case .tag(let tag, let design):
            let size = zp(design)
            NotebookDraw.tagSquare(tag, in: CGRect(x: rect.minX, y: round(rect.midY - size / 2), width: size, height: size))
        case .box(_, let draw):
            draw(rect)
        case .flex:
            break
        }
    }
}

@MainActor
enum InlineLayout {
    /// Lays `pieces` out left to right inside `rect` (each piece's rect spans the line height).
    /// `gap` is in design points (read at the interface zoom).
    static func layout(_ pieces: [InlinePiece], in rect: CGRect, gap designGap: CGFloat) -> [CGRect] {
        guard !pieces.isEmpty else { return [] }
        let gap = zp(designGap)
        var widths = pieces.map(\.naturalWidth)
        let gaps = pieces.indices.dropFirst().reduce(CGFloat(0)) { $0 + (pieces[$1].zoomedGapBefore ?? gap) }
        var remaining = rect.width - widths.reduce(0, +) - gaps
        if remaining > 0, let flex = pieces.firstIndex(where: \.isFlex) {
            widths[flex] += remaining
            remaining = 0
        }
        for first in [true, false] where remaining < 0 {
            let shrinkable = pieces.indices.filter { pieces[$0].shrink && pieces[$0].shrinksFirst == first }
            let total = shrinkable.reduce(CGFloat(0)) { $0 + widths[$1] }
            if total > 0 {
                let cut = min(total, -remaining)
                for i in shrinkable { widths[i] -= cut * widths[i] / total }
                remaining += cut
            }
        }
        var x = rect.minX
        var rects: [CGRect] = []
        for (index, piece) in pieces.enumerated() {
            if index > 0 { x += piece.zoomedGapBefore ?? gap }
            let width = max(0, min(widths[index], rect.maxX - x))
            rects.append(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
            x += widths[index]
        }
        return rects
    }

    static func draw(_ pieces: [InlinePiece], _ rects: [CGRect]) {
        for (piece, rect) in zip(pieces, rects) where rect.width > 0 { piece.draw(in: rect) }
    }

    /// The width the pieces need on one line.
    static func width(_ pieces: [InlinePiece], gap designGap: CGFloat) -> CGFloat {
        let gap = zp(designGap)
        let gaps = pieces.indices.dropFirst().reduce(CGFloat(0)) { $0 + (pieces[$1].zoomedGapBefore ?? gap) }
        return ceil(pieces.map(\.naturalWidth).reduce(0, +) + gaps)
    }
}

/// A design length (a CSS px of the boards) at the current interface zoom: the views are laid out
/// by hand, so their offsets, row heights and column widths follow the zoom like their fonts.
/// Exact at UI 字級 13 (`UIZoom.pt`).
func zp(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// Small drawing helpers shared by the views.
@MainActor
enum NotebookDraw {
    /// A lamp glyph (busy lamps glow, `.st-busy .lamp{text-shadow:0 0 6px rgba(124,255,154,.55)}`).
    /// Returns the drawn width.
    @discardableResult
    static func lamp(_ state: NotebookSessionState, x: CGFloat, centerY: CGFloat, size: CGFloat) -> CGFloat {
        var style = TextStyle.mono(size, state.color)
        if state.glows { style.shadow = Draw.glow(Palette.success.withAlphaComponent(0.55), radius: 6) }
        return Draw.text(style.string(state.glyph), x: x, centerY: centerY)
    }

    /// `.tag` square (nil: dashed outline, "no color").
    static func tagSquare(_ tag: NotebookTag?, in rect: CGRect) {
        if let tag { Draw.fill(rect, tag.color) } else { Draw.dashedRect(rect, color: Palette.dimmer) }
    }

    /// A 1 px rule at `y` (dashed or solid) across `[x0, x1)`.
    static func rule(y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: NSColor, dashed: Bool) {
        if dashed {
            Draw.dashedLine(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), color: color)
        } else {
            Draw.fill(CGRect(x: x0, y: y, width: x1 - x0, height: 1), color)
        }
    }

    /// A vertical 1 px line.
    static func vline(x: CGFloat, from y0: CGFloat, to y1: CGFloat, color: NSColor, dashed: Bool = false) {
        if dashed {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x + 0.5, y: y0))
            path.line(to: CGPoint(x: x + 0.5, y: y1))
            path.lineWidth = 1
            let dash: [CGFloat] = [3, 2]
            dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: dash.count, phase: 0) }
            color.setStroke()
            path.stroke()
        } else {
            Draw.fill(CGRect(x: x, y: y0, width: 1, height: y1 - y0), color)
        }
    }

    /// Text with highlighted ranges (search mode): the ranges in amber on a faint amber wash.
    static func highlighted(_ text: String, style: TextStyle, ranges: [NSRange], lineBreak: NSLineBreakMode = .byTruncatingTail)
        -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: style.string(text, lineBreak: lineBreak))
        let length = out.length
        for range in ranges where range.location != NSNotFound && range.location < length {
            let clipped = NSRange(location: range.location, length: min(range.length, length - range.location))
            out.addAttributes([.foregroundColor: Palette.amber, .backgroundColor: Palette.amber.withAlphaComponent(0.16)], range: clipped)
        }
        return out
    }

    /// Splits `` `code` `` spans out of `text` (drawer tasks).
    static func codeSpans(_ text: String) -> [(String, Bool)] {
        var parts: [(String, Bool)] = []
        var buffer = ""
        var inCode = false
        for ch in text {
            if ch == "`" {
                if !buffer.isEmpty { parts.append((buffer, inCode)) }
                buffer = ""
                inCode.toggle()
            } else {
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty { parts.append((buffer, inCode)) }
        return parts
    }

    /// The artboard's portrait screenshot placeholder (`.nb-thumb .pt`, `.sp-ph`) or landscape one
    /// (`.ls`, `.sp-ls`) when no image is given; otherwise the image aspect-fit in `rect`.
    static func thumbnail(_ image: NSImage?, orientation: NotebookImageOrientation, in rect: CGRect, schematic: ThumbSchematic) {
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(rect.width / image.size.width, rect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        switch schematic {
        case .infoPanel:
            // `.nb-thumb i`: #d9d7d0 at brightness .82, a white 3 px top bar, a blue 4 px button.
            Draw.fill(rect, NSColor(hex: 0xB2B0AA))
            Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3), NSColor(hex: 0xD1D1D1))
            Draw.fill(CGRect(x: rect.minX + 3, y: rect.maxY - 7, width: rect.width - 6, height: 4), NSColor(hex: 0x275BB8))
        case .drawer:
            drawDrawerSchematic(orientation, in: rect)
        }
    }

    enum ThumbSchematic { case infoPanel, drawer }

    /// `.sp-ph` / `.sp-ls`: the dark wireframe phone screens of the Split artboard.
    private static func drawDrawerSchematic(_ orientation: NotebookImageOrientation, in rect: CGRect) {
        Draw.fill(rect, Palette.bgSoft)
        Draw.strokeRect(rect, color: Palette.lineBright)
        let inner = rect.insetBy(dx: 1, dy: 1)
        Draw.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 7), Palette.bgRaise)
        Draw.fill(CGRect(x: inner.minX, y: inner.minY + 7, width: inner.width, height: 1), Palette.lineBright)
        let hit = Palette.danger
        switch orientation {
        case .portrait:
            for (top, width) in [(13.0, 28.0), (20, 24), (27, 30), (34, 20), (41, 27)] {
                Draw.fill(CGRect(x: inner.minX + 4, y: inner.minY + top - 1, width: CGFloat(width), height: 3), Palette.lineBright)
            }
            let button = CGRect(x: inner.minX + 4, y: inner.maxY - 9 - 11 + 1, width: inner.width - 8, height: 11)
            Draw.fill(button, Palette.amber.withAlphaComponent(0.18))
            Draw.strokeRect(button, color: Palette.amberDim)
            let nav = CGRect(x: inner.minX, y: inner.maxY - 13, width: inner.width, height: 13)
            Draw.fill(nav, NSColor(hex: 0x1E1E1E))
            Draw.fill(CGRect(x: nav.minX, y: nav.minY, width: nav.width, height: 1), Palette.lineBright)
            Draw.dashedRect(CGRect(x: inner.minX + 1, y: inner.maxY - 3 - 19, width: inner.width - 2, height: 19), color: hit)
        case .landscape:
            for (index, top) in [13.0, 21, 29, 37, 45].enumerated() {
                var x = inner.minX + 4
                let color = index == 0 ? Palette.dim.withAlphaComponent(0.6) : Palette.lineBright
                while x < inner.maxX {
                    Draw.fill(CGRect(x: x, y: inner.minY + CGFloat(top) - 1, width: min(24, inner.maxX - x), height: 4), color)
                    x += 28
                }
            }
            Draw.dashedRect(CGRect(x: inner.maxX - 2 - 16, y: inner.minY + 10, width: 16, height: inner.height - 10 - 4), color: hit)
        }
    }
}
