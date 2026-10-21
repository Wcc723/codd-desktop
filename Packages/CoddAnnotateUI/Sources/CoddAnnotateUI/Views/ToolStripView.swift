import AppKit
import CoddUI

/// The 48 pt `.ia-tools` strip: the five tools with their key letters, a dashed separator, the
/// color button, and at the bottom `ZOOM` over the vertical Fit / 100% / 200% switch.
final class ToolStripView: FlippedView {
    private(set) var toolButtons: [(AnnotateTool, BoardButton)] = []
    let colorButton = ColorSwatchButton()
    let zoomLabel = RunLineView([.text("Zoom", TextStyle.caps(9, Palette.dim, tracking: 0.14))])
    let zoomSwitch = VerticalSegmentView(titles: AnnotateZoom.allCases.map(\.title))
    var onTool: ((AnnotateTool) -> Void)?
    var onZoom: ((AnnotateZoom) -> Void)?

    /// `padding: 10px 0`, 36 pt buttons with `gap: 4px`.
    static var toolSize: CGFloat { az(36) }
    /// The tool buttons' size and gap as laid out: a short strip (a small window at zoom 20)
    /// takes 30 pt buttons 2 apart and drops the `ZOOM` label, so the tools, the color button and
    /// the zoom switch never overlap; a strip too short even for that leaves the zoom switch out.
    private var layoutToolSize = ToolStripView.toolSize
    private var layoutToolGap = az(4)
    private(set) var isCompact = false
    private var separatorY: CGFloat {
        az(10) + CGFloat(AnnotateTool.allCases.count) * (layoutToolSize + layoutToolGap) + az(6) - az(4) + layoutToolGap
    }

    /// The strip's height with the given tool size and gap (`label`: with the `ZOOM` label).
    private func neededHeight(toolSize: CGFloat, gap: CGFloat, label: Bool) -> CGFloat {
        let tools = az(10) + CGFloat(AnnotateTool.allCases.count) * (toolSize + gap) - gap
        let color = az(6) + 1 + az(10) + az(36)
        let zoom = az(10) + (label ? az(14) + az(4) : 0) + zoomSwitch.preferredHeight + az(10)
        return tools + color + zoom
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for tool in AnnotateTool.allCases {
            let button = BoardButton(.icon(AnnotateIcon.tool(tool), size: 18), keyLetter: tool.key,
                                     accessibilityLabel: "\(tool.title) (\(tool.key))")
            button.onPress = { [weak self] in self?.onTool?(tool) }
            toolButtons.append((tool, button))
            addSubview(button)
        }
        addSubview(colorButton)
        addSubview(zoomLabel)
        addSubview(zoomSwitch)
        zoomSwitch.onSelect = { [weak self] index in
            guard AnnotateZoom.allCases.indices.contains(index) else { return }
            self?.onZoom?(AnnotateZoom.allCases[index])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("標註工具")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func button(_ tool: AnnotateTool) -> BoardButton? { toolButtons.first { $0.0 == tool }?.1 }

    func update(tool: AnnotateTool, zoom: AnnotateZoom, color: AnnotationColor) {
        for (candidate, button) in toolButtons { button.isOn = candidate == tool }
        zoomSwitch.selectedIndex = AnnotateZoom.allCases.firstIndex(of: zoom) ?? 0
        colorButton.color = color
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        // `.ia-tsep{width:24px;border-top:1px dashed var(--line-bright);margin:6px 0}`
        let x = round((bounds.width - 1 - az(24)) / 2)
        Draw.dashedLine(from: CGPoint(x: x, y: separatorY), to: CGPoint(x: x + az(24), y: separatorY), color: Palette.lineBright)
    }

    override func layout() {
        super.layout()
        // Centered in the 47 pt inside the right border.
        let column = bounds.width - 1
        let fits = neededHeight(toolSize: Self.toolSize, gap: az(4), label: true) <= bounds.height
        isCompact = !fits
        layoutToolSize = fits ? Self.toolSize : az(30)
        layoutToolGap = fits ? az(4) : az(2)
        zoomLabel.isHidden = !fits
        zoomSwitch.isHidden = !fits && neededHeight(toolSize: az(30), gap: az(2), label: false) > bounds.height
        needsDisplay = true
        var y: CGFloat = az(10)
        for (_, button) in toolButtons {
            button.frame = CGRect(x: round((column - layoutToolSize) / 2), y: y, width: layoutToolSize, height: layoutToolSize)
            y += layoutToolSize + layoutToolGap
        }
        colorButton.frame = CGRect(x: round((column - az(36)) / 2), y: separatorY + 1 + az(6) + az(4), width: az(36), height: az(36))
        let switchHeight = zoomSwitch.preferredHeight
        let switchY = bounds.height - az(10) - switchHeight
        zoomSwitch.frame = CGRect(x: round((column - az(40)) / 2), y: switchY, width: az(40), height: switchHeight)
        let labelWidth = zoomLabel.naturalWidth
        zoomLabel.frame = CGRect(x: round((column - labelWidth) / 2), y: switchY - az(4) - az(14), width: labelWidth, height: az(14))
    }
}
