import AppKit
import CoddUI

/// Styles the `AI 會收到` text (§3.7 lines) like the artboard's `.term.ia-term`: `[image]` and the
/// size dim, paths and types cyan, numbers amber, comments cream; every line hangs at 4 ch
/// (`[image]` lines at 8 ch), and a comment that does not fit after its coordinates starts on the
/// next line (the artboard's inline-block `.ia-cm`). Unknown lines are drawn plain.
@MainActor
enum PreviewStyler {
    static var font: NSFont { Typeface.mono(11) }
    static var lineHeight: CGFloat { az(16.5) }

    /// One `ch` of the term font.
    static var ch: CGFloat { Draw.width(NSAttributedString(string: "0", attributes: [.font: font])) }

    private static let itemPattern = try? NSRegularExpression(
        pattern: #"^(\s*)(\d+)(\s+)(rect|point|arrow|text)((?:\s+(?:[a-z]\d?=-?\d+|-?\d+,-?\d+|→))*)(?:(\s+)(.*))?$"#)

    static func attributed(_ text: String, width: CGFloat, home: String = NSHomeDirectory()) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let styled = styledLine(line, width: width, home: home)
            result.append(styled)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: styled.length > 0 ? styled.attributes(at: 0, effectiveRange: nil) : base(indent: 4))) }
        }
        return result
    }

    private static func base(indent: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.headIndent = indent * ch
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: Palette.termForeground, .paragraphStyle: paragraph, .ligature: 0,
                .baselineOffset: max(0, (lineHeight - Typeface.lineHeight(font)) / 2)]
    }

    private static func run(_ text: String, _ color: NSColor, indent: CGFloat) -> NSAttributedString {
        var attributes = base(indent: indent)
        attributes[.foregroundColor] = color
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func styledLine(_ line: String, width: CGFloat, home: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if line.hasPrefix("[image] ") {
            var rest = String(line.dropFirst("[image] ".count))
            var size = ""
            if let open = rest.range(of: " (", options: .backwards), rest.hasSuffix(")") {
                size = String(rest[open.lowerBound...])
                rest = String(rest[..<open.lowerBound])
            }
            out.append(run("[image]", Palette.termDim, indent: 8))
            out.append(run(" " + displayPath(rest, home: home), Palette.cyan, indent: 8))
            out.append(run(size, Palette.termDim, indent: 8))
            return out
        }
        if line.hasPrefix("annotations"), let open = line.firstIndex(of: "（"), let close = line.firstIndex(of: "）"), open < close {
            out.append(run(String(line[..<open]), Palette.termForeground, indent: 4))
            out.append(run(String(line[open...close]), Palette.termDim, indent: 4))
            out.append(run(String(line[line.index(after: close)...]), Palette.termForeground, indent: 4))
            return out
        }
        let ns = line as NSString
        guard let match = itemPattern?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return run(line, Palette.termForeground, indent: 4)
        }
        func group(_ i: Int) -> String {
            let range = match.range(at: i)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        let prefix = NSMutableAttributedString()
        prefix.append(run(group(1), Palette.termForeground, indent: 4))
        prefix.append(run(group(2), Palette.amber, indent: 4))
        prefix.append(run(group(3), Palette.termForeground, indent: 4))
        prefix.append(run(group(4), Palette.cyan, indent: 4))
        prefix.append(run(group(5), Palette.termForeground, indent: 4))
        out.append(prefix)
        let note = group(7)
        guard !note.isEmpty else { return out }
        let separator = run(group(6), Palette.termForeground, indent: 4)
        let comment = run(note, Palette.cream, indent: 4)
        if Draw.width(prefix) + Draw.width(separator) + Draw.width(comment) > width {
            // The comment block drops to the next line at the 4 ch hang.
            out.append(run("\u{2028}", Palette.termForeground, indent: 4))
        } else {
            out.append(separator)
        }
        out.append(comment)
        return out
    }

    /// The home folder shown as `~` (display only) with break chances after each `/`.
    static func displayPath(_ path: String, home: String) -> String {
        var shown = path
        if !home.isEmpty, shown.hasPrefix(home + "/") { shown = "~" + shown.dropFirst(home.count) }
        return shown.replacingOccurrences(of: "/", with: "/\u{200B}")
    }
}

/// `.term.ia-term`: #000 box with a line-bright border, 11 px text, `padding: 8px 10px`.
final class PreviewTermView: NSView, AnnotateTextShowing {
    private(set) var text = ""
    private let content = WrappedTextView()
    /// Drawn without the §3.7 styling (the Markdown source).
    var plain = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        content.inset = NSEdgeInsets(top: az(9), left: az(11), bottom: az(9), right: az(11))
        addSubview(content)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var displayedText: String { text }

    func set(_ text: String, width: CGFloat) {
        self.text = text
        setAccessibilityValue(text)
        let inner = max(1, width - az(22))
        if plain {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = PreviewStyler.lineHeight
            paragraph.maximumLineHeight = PreviewStyler.lineHeight
            paragraph.lineBreakMode = .byCharWrapping
            content.attributed = NSAttributedString(string: text, attributes: [
                .font: PreviewStyler.font, .foregroundColor: Palette.termForeground, .paragraphStyle: paragraph, .ligature: 0,
            ])
        } else {
            content.attributed = PreviewStyler.attributed(text, width: inner)
        }
        needsDisplay = true
    }

    func height(for width: CGFloat) -> CGFloat {
        content.height(for: width) + 0.5
    }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.termBackground)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }
}

/// `.ia-md`: `▸ Markdown 原始碼（codd-annotations 區塊）`; hover turns it cream with an amber caret.
final class DisclosureButton: KeyFocusView, AnnotateTextShowing {
    var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true; setAccessibilityExpanded(isOpen) } } }
    var onToggle: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(displayedText)
        setAccessibilityExpanded(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    var displayedText: String { "Markdown 原始碼（codd-annotations 區塊）" }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { toggle() }

    func toggle() {
        isOpen.toggle()
        onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.caret(open: isOpen, at: CGPoint(x: 0, y: bounds.midY), color: isHovered ? Palette.amber : Palette.dimmer)
        // `.caret{width:10px}` + `gap:6px`
        var x: CGFloat = az(16)
        x += Draw.text(AnnotateTheme.disclosure.with(color: isHovered ? Palette.cream : Palette.dim).string("Markdown 原始碼"),
                       x: x, centerY: bounds.midY)
        Draw.text(AnnotateTheme.disclosureFaint.string("（codd-annotations 區塊）"), x: x, centerY: bounds.midY,
                  maxWidth: max(0, bounds.width - x))
    }
}
