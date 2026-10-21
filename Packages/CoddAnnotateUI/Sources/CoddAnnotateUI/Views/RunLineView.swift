import AppKit
import CoddUI

/// One custom-drawn line of mixed pieces (texts, fixed gaps, `.kbd` boxes, chips), vertically
/// centered and drawn left to right; the last text piece is truncated when the line is too narrow,
/// and a `.kbd` box or chip that does not fit whole is left out.
/// Cheaper than a stack of labels and with the artboard's exact gaps.
final class RunLineView: NSView, AnnotateTextShowing {
    enum Piece {
        case text(String, TextStyle)
        case gap(CGFloat)
        case kbd(String)
        case chip(String, ChipStyle)
    }

    private(set) var pieces: [Piece] = []
    /// Right-aligns the line inside the bounds.
    var alignRight = false { didSet { needsDisplay = true } }
    /// A backing behind the whole line (the stage hint over a zoomed image).
    var plate: NSColor? { didSet { if plate != oldValue { needsDisplay = true } } }

    init(_ pieces: [Piece] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        set(pieces)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ pieces: [Piece]) {
        self.pieces = pieces
        setAccessibilityLabel(displayedText)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var displayedText: String {
        pieces.compactMap { piece -> String? in
            switch piece {
            case .text(let text, let style): style.uppercase ? text.uppercased() : text
            case .kbd(let text), .chip(let text, _): text
            case .gap: nil
            }
        }.joined(separator: " ")
    }

    private func width(of piece: Piece) -> CGFloat {
        switch piece {
        case .text(let text, let style): Draw.width(style.string(text))
        case .gap(let gap): gap
        case .kbd(let text): AnnotateTheme.kbd.size(for: text).width
        case .chip(let text, let style): style.size(for: text).width
        }
    }

    var naturalWidth: CGFloat { ceil(pieces.reduce(0) { $0 + width(of: $1) }) }

    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        if let plate { Draw.fill(bounds, plate) }
        var x: CGFloat = alignRight ? max(0, bounds.width - naturalWidth) : 0
        let mid = bounds.midY
        for piece in pieces {
            let room = bounds.width - x
            guard room > 0 else { break }
            switch piece {
            case .text(let text, let style):
                x += Draw.text(style.string(text), x: x, centerY: mid, maxWidth: room)
            case .gap(let gap):
                x += gap
            case .kbd(let text):
                // A box that does not fit whole is left out (a narrow bar: zoom 20), never drawn
                // over the views beside the line.
                guard width(of: piece) <= room + 0.5 else { return }
                x += AnnotateTheme.kbd.draw(text, x: x, centerY: mid)
            case .chip(let text, let style):
                guard width(of: piece) <= room + 0.5 else { return }
                x += style.draw(text, x: x, centerY: mid)
            }
        }
    }
}

/// Wrapping text drawn from an attributed string (`.ann-item` notes, the term box): `height(for:)`
/// gives the laid-out height at a width.
final class WrappedTextView: NSView, AnnotateTextShowing {
    var attributed = NSAttributedString() { didSet { needsDisplay = true } }
    var inset = NSEdgeInsets()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var displayedText: String { attributed.string }

    func height(for width: CGFloat) -> CGFloat {
        let inner = max(1, width - inset.left - inset.right)
        let rect = attributed.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(rect.height) + inset.top + inset.bottom
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = CGRect(x: inset.left, y: inset.top, width: max(1, bounds.width - inset.left - inset.right),
                          height: max(1, bounds.height - inset.top - inset.bottom))
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// M4 interface zoom: the text built at the old zoom is made again at the new one.
extension WrappedTextView: ZoomRefreshing {
    func zoomDidChange() {
        if let scaled = Typeface.rescaled(attributed) { attributed = scaled }
    }
}
