import AppKit

/// StatusDialogs `.sd-diff` (the Hook diff dialog's `settings.json` preview): monospaced 11 px lines on
/// the terminal's black, each with a line-number column (`.no`, 34 px, right-aligned, dimmer), a sign
/// column (`.sg`, 14 px) and the text (`.tx`, truncated with `…`, 12 px right padding). Kinds:
/// hunk (`@@ … @@` in cyan), context (#9c978a), added (green tint, `+`), removed (red tint, `-`) and
/// elided (a dimmer gap marker). Inside the text, `.el` spans (`…`) are dimmer and `.ev` spans
/// (event names) white 600. Framed (default): 1 px --line-bright border and `padding: 8px 0`.
/// Line height: `line-height:1.45` of 11 px, rounded to 16 pt. Redraws only when the lines change.
public final class DiffLinesView: FlippedView {
    /// One diff line. Named inside the view so it never clashes with a model type of the same name
    /// in another package (CoddClaudeSettings has its own `DiffLine`).
    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable, Equatable, CaseIterable {
            case hunk, context, added, removed, elided
        }

        /// A run of text inside a line.
        public struct Span: Equatable, Sendable {
            public enum Style: Sendable, Equatable {
                case plain
                /// `.el`: elided content (`…`), dimmer.
                case ellipsis
                /// `.ev`: an event name, white 600.
                case emphasis
            }

            public var text: String
            public var style: Style

            public init(_ text: String, style: Style = .plain) {
                self.text = text
                self.style = style
            }
        }

        public var kind: Kind
        public var oldNumber: Int?
        public var newNumber: Int?
        public var spans: [Span]

        public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, spans: [Span]) {
            self.kind = kind
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.spans = spans
        }

        /// Plain text; every `…` becomes an `.el` span.
        public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String) {
            self.init(kind: kind, oldNumber: oldNumber, newNumber: newNumber, spans: Self.splitEllipses(text))
        }

        public var text: String { spans.map(\.text).joined() }

        /// The number shown in the `.no` column: the old line for a removal, the new line otherwise
        /// (falling back to the old one); none for hunk headers and elided gaps.
        public var displayedNumber: Int? {
            switch kind {
            case .hunk, .elided: nil
            case .removed: oldNumber ?? newNumber
            case .added, .context: newNumber ?? oldNumber
            }
        }

        /// `.sg`: `+` / `-` (ASCII, as in the artboard) or empty.
        public var sign: String {
            switch kind {
            case .added: "+"
            case .removed: "-"
            default: ""
            }
        }

        static func splitEllipses(_ text: String) -> [Span] {
            var spans: [Span] = []
            var buffer = ""
            for character in text {
                if character == "…" {
                    if !buffer.isEmpty { spans.append(Span(buffer)); buffer = "" }
                    spans.append(Span("…", style: .ellipsis))
                } else {
                    buffer.append(character)
                }
            }
            if !buffer.isEmpty || spans.isEmpty { spans.append(Span(buffer)) }
            return spans
        }
    }

    /// `11px × 1.45` rounded.
    public static let defaultLineHeight: CGFloat = 16
    /// `.no` width, `.sg` width, `.tx` right padding.
    public static let numberWidth: CGFloat = 34
    public static let signWidth: CGFloat = 14
    public static let textRightPadding: CGFloat = 12

    public var lines: [Line] {
        didSet {
            guard lines != oldValue else { return }
            if lines.count != oldValue.count { invalidateIntrinsicContentSize() }
            needsDisplay = true
            updateAccessibility()
        }
    }

    /// The line height in design points (the column widths too): laid out at the interface zoom.
    public var lineHeight: CGFloat = DiffLinesView.defaultLineHeight {
        didSet { if lineHeight != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    /// `lineHeight` at the current zoom (the height every line takes).
    public var zoomedLineHeight: CGFloat { UIZoom.pt(lineHeight) }

    /// Border + vertical padding + black background (`.term.sd-diff`). Off: the lines only, on a clear
    /// background (the owner draws the box).
    public var framed = true { didSet { if framed != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    /// VoiceOver label of the region (`settings.json 差異`).
    public var accessibilityText: String { didSet { setAccessibilityLabel(accessibilityText) } }

    public init(lines: [Line] = [], accessibilityLabel: String = "差異") {
        self.lines = lines
        self.accessibilityText = accessibilityLabel
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(accessibilityLabel)
        updateAccessibility()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `lines.count × lineHeight` (at the zoom).
    public var contentHeight: CGFloat { CGFloat(lines.count) * zoomedLineHeight }

    /// Border (1 + 1) and padding (8 + 8, at the zoom) when framed.
    public var verticalChrome: CGFloat { framed ? 2 + UIZoom.pt(16) : 0 }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight + verticalChrome)
    }

    /// The rectangle of line `index` (full width inside the border).
    public func lineRect(_ index: Int) -> CGRect {
        let inset: CGFloat = framed ? 1 : 0
        let top: CGFloat = framed ? 1 + UIZoom.pt(8) : 0
        let height = zoomedLineHeight
        return CGRect(x: inset, y: top + CGFloat(index) * height, width: max(0, bounds.width - inset * 2), height: height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        if framed {
            Draw.fill(bounds, Palette.termBackground)
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
        for (index, line) in lines.enumerated() {
            let rect = lineRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            draw(line, in: rect)
        }
    }

    private func draw(_ line: Line, in rect: CGRect) {
        let colors = Self.colors(line.kind)
        let numberWidth = UIZoom.pt(Self.numberWidth)
        if let background = colors.background { Draw.fill(rect, background) }
        if let number = line.displayedNumber {
            let text = TextStyle.mono(11, colors.gutter).string(String(number))
            Draw.text(text, x: rect.minX + numberWidth - UIZoom.pt(8) - Draw.width(text), centerY: rect.midY)
        }
        if !line.sign.isEmpty {
            Draw.text(TextStyle.mono(11, colors.gutter).string(line.sign), x: rect.minX + numberWidth, centerY: rect.midY)
        }
        let x = rect.minX + numberWidth + UIZoom.pt(Self.signWidth)
        let text = NSMutableAttributedString()
        for span in line.spans {
            let style: TextStyle
            switch (line.kind, span.style) {
            case (.elided, _), (_, .ellipsis): style = TextStyle.mono(11, Palette.dimmer)
            case (_, .emphasis): style = TextStyle.mono(11, Palette.termWhite, .semibold)
            case (_, .plain): style = TextStyle.mono(11, colors.text)
            }
            text.append(style.string(span.text, lineBreak: .byTruncatingTail))
        }
        Draw.text(text, x: x, centerY: rect.midY, maxWidth: max(0, rect.maxX - UIZoom.pt(Self.textRightPadding) - x))
    }

    /// Per-kind colors (`.sd-ln.is-*`).
    public static func colors(_ kind: Line.Kind) -> (text: NSColor, gutter: NSColor, background: NSColor?) {
        switch kind {
        case .hunk: (Palette.cyan, Palette.dimmer, nil)
        case .context: (NSColor(hex: 0x9C978A), Palette.dimmer, nil)
        case .added: (Palette.termAddText, Palette.successDim, Palette.success.withAlphaComponent(0.08))
        case .removed: (Palette.termDelText, Palette.danger, Palette.termDelBackground)
        case .elided: (Palette.dimmer, Palette.dimmer, nil)
        }
    }

    private func updateAccessibility() {
        setAccessibilityValue(lines.map { line in
            [line.displayedNumber.map(String.init) ?? "", line.sign, line.text].filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: "\n"))
    }
}
