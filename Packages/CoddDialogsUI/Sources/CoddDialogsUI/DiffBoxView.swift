import AppKit
import CoddUI

/// `.term.sd-diff` around CoddUI's `DiffLinesView`: the black box (1 px line-bright border,
/// padding 8 / 0) grows with the lines up to `HookDiffDialogView.maxDiffHeight`, then the lines
/// scroll inside it (the box stays put). Without lines it shows one dim `// …` line (no changes).
final class DiffBoxView: FlippedView {
    private let scroll = NSScrollView()
    private let lines = DiffLinesView(accessibilityLabel: "settings.json 差異")
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        lines.framed = false
        scroll.documentView = lines
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        addSubview(scroll)
        scroll.pinEdges(to: self, insets: NSEdgeInsets(top: dz(9), left: 1, bottom: dz(9), right: 1))
        let height = heightAnchor.constraint(equalToConstant: DiffLinesView.defaultLineHeight + 18)
        height.isActive = true
        heightConstraint = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The CoddUI view that draws the lines (tests).
    var linesView: DiffLinesView { lines }

    func set(_ model: [DiffLineModel], emptyText: String?) {
        let shown = model.isEmpty ? [DiffLinesView.Line(kind: .elided, text: emptyText ?? "")] : model.map(Self.line)
        lines.lines = shown
        let content = CGFloat(shown.count) * lines.zoomedLineHeight
        heightConstraint?.constant = min(content, HookDiffDialogView.maxDiffHeight) + 18
        scroll.hasVerticalScroller = content > HookDiffDialogView.maxDiffHeight
        needsLayout = true
    }

    override func layout() {
        super.layout()
        lines.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, lines.contentHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.termBackground)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    /// Model line → CoddUI line: emphasis substrings become `.emphasis` spans (first occurrence of
    /// each), every `…` in the rest an `.ellipsis` span.
    static func line(_ model: DiffLineModel) -> DiffLinesView.Line {
        DiffLinesView.Line(kind: kind(model.kind), oldNumber: model.oldNumber, newNumber: model.newNumber,
                           spans: spans(model.text, emphasis: model.emphasis))
    }

    static func kind(_ kind: DiffLineModel.Kind) -> DiffLinesView.Line.Kind {
        switch kind {
        case .hunk: .hunk
        case .context: .context
        case .added: .added
        case .removed: .removed
        case .elided: .elided
        }
    }

    static func spans(_ text: String, emphasis: [String]) -> [DiffLinesView.Line.Span] {
        var marks: [Range<String.Index>] = []
        for word in emphasis where !word.isEmpty {
            if let range = text.range(of: word), !marks.contains(where: { $0.overlaps(range) }) { marks.append(range) }
        }
        marks.sort { $0.lowerBound < $1.lowerBound }
        var spans: [DiffLinesView.Line.Span] = []
        var cursor = text.startIndex
        for mark in marks {
            spans += plainSpans(String(text[cursor ..< mark.lowerBound]))
            spans.append(.init(String(text[mark]), style: .emphasis))
            cursor = mark.upperBound
        }
        spans += plainSpans(String(text[cursor...]))
        return spans.isEmpty ? [.init("")] : spans
    }

    private static func plainSpans(_ text: String) -> [DiffLinesView.Line.Span] {
        var spans: [DiffLinesView.Line.Span] = []
        var buffer = ""
        for character in text {
            if character == "…" {
                if !buffer.isEmpty { spans.append(.init(buffer)); buffer = "" }
                spans.append(.init("…", style: .ellipsis))
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { spans.append(.init(buffer)) }
        return spans
    }
}
