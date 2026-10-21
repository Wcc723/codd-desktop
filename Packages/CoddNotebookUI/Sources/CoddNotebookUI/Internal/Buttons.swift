import AppKit
import CoddUI

// Buttons of the Notebook artboard that CoddUI's `CoddButton` does not draw: `.btn.sm.plain`,
// the 20 px `.pillbtn.nb-sm` with an icon and a normal-case `.nm` part, the COPY REF split button,
// the dashed `.nb-addl` row and amber text links. Candidates to move into CoddUI.

/// `.btn.sm.plain` (`最近更新 ▾`): a `.btn.sm` without the brackets.
final class PlainSmallButton: HoverControl, NotebookTextProviding {
    var label: String { didSet { if label != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(label) } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }

    init(_ label: String) {
        self.label = label
        super.init(frame: .zero)
        setAccessibilityLabel(label)
    }

    private var style: TextStyle { TextStyle(font: Typeface.mono(10.5, .medium), color: Palette.cream, tracking: 0.08, uppercase: true) }

    var drawnTexts: [String] { [label.uppercased()] }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(Draw.width(style.string(label)) + zp(16)), height: zp(22)) }

    override func draw(_ dirtyRect: NSRect) {
        let hot = isHot || isOn
        if hot { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06)) }
        if isPressed { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.12)) }
        Draw.strokeRect(bounds, color: hot ? Palette.amber : Palette.lineBright)
        let text = style.with(color: hot ? Palette.amber : Palette.cream).string(label)
        Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
    }
}

/// `.pillbtn` in the Notebook sizes: `.nb-sm` (20 px, 10 px, `padding: 0 7px`, gap 5, 13 px icon)
/// for the AI and scope pills, and the regular 24 px pill with a lamp for the footer target.
/// Parts: caps text (`Project:`) and `.nm` names (normal case, cream).
final class NotebookPillButton: HoverControl, NotebookTextProviding {
    enum Tone: Equatable { case normal, cyan, dim }
    enum Part: Equatable {
        case caps(String)
        case name(String)
    }

    struct Content: Equatable {
        var icon: NotebookIcon?
        var lamp: NotebookSessionState?
        var parts: [Part]
        var tone: Tone = .normal
        var chevron = true
    }

    var content: Content { didSet { if content != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateAccessibility() } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    let small: Bool

    init(_ content: Content, small: Bool) {
        self.content = content
        self.small = small
        super.init(frame: .zero)
        setAccessibilityRole(.popUpButton)
        updateAccessibility()
    }

    private var fontSize: CGFloat { small ? 10 : 11 }
    private var padding: CGFloat { zp(small ? 7 : 8) }
    /// Design points (`InlineLayout` reads them at the zoom).
    private var gap: CGFloat { small ? 5 : 6 }
    private var height: CGFloat { zp(small ? 20 : 24) }

    private var textColor: NSColor {
        switch content.tone {
        case .cyan: Palette.cyan
        case .dim: (isHot || isOn) ? Palette.amber : Palette.dim
        case .normal: (isHot || isOn) ? Palette.amber : Palette.bone
        }
    }

    private var borderColor: NSColor {
        switch content.tone {
        case .cyan: Palette.cyan.withAlphaComponent(0.4)
        case .dim, .normal: (isHot || isOn) ? Palette.amberDim : Palette.lineBright
        }
    }

    private func pieces() -> [InlinePiece] {
        var out: [InlinePiece] = []
        if let icon = content.icon { out.append(.icon(icon, size: 13, color: textColor)) }
        if let lamp = content.lamp { out.append(.lamp(lamp, size: 10)) }
        for part in content.parts {
            switch part {
            case .caps(let text):
                out.append(.text(text, TextStyle.caps(fontSize, textColor, tracking: 0.08)))
            case .name(let text):
                out.append(.text(text, TextStyle.mono(fontSize, Palette.cream, tracking: 0.01), shrink: true))
            }
        }
        if content.chevron { out.append(.text("▾", TextStyle.mono(fontSize, textColor))) }
        return out
    }

    var drawnTexts: [String] {
        var parts: [String] = content.parts.map { part in
            switch part {
            case .caps(let text): text.uppercased()
            case .name(let text): text
            }
        }
        if content.chevron { parts.append("▾") }
        return [parts.joined(separator: " ")]
    }

    private func updateAccessibility() { setAccessibilityLabel(drawnTexts.first) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: InlineLayout.width(pieces(), gap: gap) + padding * 2 + zp(2), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.08)) }
        Draw.strokeRect(bounds, color: borderColor)
        let items = pieces()
        let rect = bounds.insetBy(dx: padding + 1, dy: 0)
        InlineLayout.draw(items, InlineLayout.layout(items, in: rect, gap: gap))
    }
}

/// The COPY REF split button (`.nb-split`): `[ ⧉ COPY REF | ▾ ]`, 24 px, --amber-dim border. The
/// left part copies form 1, the right part opens the reference menu (`.on` while it is open).
final class CopyRefSplitButton: CanvasView, NotebookTextProviding {
    let mainPart = SplitPart(kind: .main)
    let menuPart = SplitPart(kind: .menu)
    var isEnabled = true {
        didSet {
            mainPart.isEnabled = isEnabled
            menuPart.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.4
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mainPart.dimsWhenDisabled = false
        menuPart.dimsWhenDisabled = false
        addSubview(mainPart)
        addSubview(menuPart)
        mainPart.setAccessibilityLabel("複製引用 codd://note")
        menuPart.setAccessibilityLabel("選擇引用格式")
        setAccessibilityElement(false)
    }

    var drawnTexts: [String] { [] }

    override var intrinsicContentSize: NSSize {
        NSSize(width: mainPart.intrinsicContentSize.width + menuPart.intrinsicContentSize.width, height: zp(24))
    }

    override func layout() {
        super.layout()
        let w = mainPart.intrinsicContentSize.width
        mainPart.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        menuPart.frame = CGRect(x: w, y: 0, width: bounds.width - w, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.strokeRect(bounds, color: Palette.amberDim)
    }

    final class SplitPart: HoverControl, NotebookTextProviding {
        enum Kind { case main, menu }
        let kind: Kind
        var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }

        init(kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
        }

        private var color: NSColor { isHot ? Palette.cream : Palette.amber }
        private var labelStyle: TextStyle { TextStyle(font: Typeface.mono(10.5, .medium), color: color, tracking: 0.08, uppercase: true) }
        private var bracketStyle: TextStyle { TextStyle(font: Typeface.mono(10.5, .medium), color: Palette.amberDim) }

        private func pieces() -> [InlinePiece] {
            switch kind {
            case .main:
                [.text("[", bracketStyle), .icon(.copy, size: 13, color: color), .text("Copy ref", labelStyle)]
            case .menu:
                [.text("▾", labelStyle), .text("]", bracketStyle)]
            }
        }

        var drawnTexts: [String] { [kind == .main ? "[ COPY REF" : "▾ ]"] }

        override var intrinsicContentSize: NSSize {
            let pad: CGFloat = kind == .main ? zp(8) : zp(7)
            return NSSize(width: InlineLayout.width(pieces(), gap: 5) + pad * 2 + (kind == .main ? 1 : 1), height: zp(24))
        }

        override func draw(_ dirtyRect: NSRect) {
            if isOn {
                Draw.fill(bounds, Palette.amber.withAlphaComponent(0.14))
                Draw.strokeRect(bounds.insetBy(dx: 1, dy: 1), color: Palette.amberGlow)
            }
            if isPressed { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.1)) }
            if kind == .menu { Draw.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height), Palette.amberDim) }
            let pad: CGFloat = kind == .main ? zp(9) : zp(8)
            let items = pieces()
            InlineLayout.draw(items, InlineLayout.layout(items, in: bounds.insetBy(dx: pad, dy: 0), gap: 5))
        }
    }
}

/// `.nb-addl` (`+ 連結 session / 專案`): 24 px dashed row, dim 10.5 px .06em, normal case.
final class DashedAddButton: HoverControl, NotebookTextProviding {
    var label: String { didSet { needsDisplay = true; setAccessibilityLabel(label) } }

    init(_ label: String) {
        self.label = label
        super.init(frame: .zero)
        setAccessibilityLabel(label)
    }

    var drawnTexts: [String] { [label] }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: zp(24)) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.dashedRect(bounds, color: isHot ? Palette.amberDim : Palette.lineBright)
        Draw.text(TextStyle.mono(10.5, isHot ? Palette.amber : Palette.dim, tracking: 0.06).string(label), x: zp(9), centerY: bounds.midY,
                  maxWidth: bounds.width - zp(18))
    }
}

/// A row-sized clickable custom-drawn area whose look comes from a closure (crumb links, the
/// cleanup line, drawer card titles, info rows).
final class DrawnControl: HoverControl, NotebookTextProviding {
    var drawer: ((DrawnControl, CGRect) -> Void)? { didSet { needsDisplay = true } }
    var texts: [String] = [] { didSet { setAccessibilityLabel(texts.joined(separator: " ")) } }
    var preferredSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) {
        didSet { invalidateIntrinsicContentSize() }
    }

    var drawnTexts: [String] { texts }
    override var intrinsicContentSize: NSSize { preferredSize }

    override func draw(_ dirtyRect: NSRect) {
        drawer?(self, bounds)
    }
}
