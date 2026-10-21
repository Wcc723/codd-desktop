import AppKit

/// Phosphor Console tokens, copied from design/helmet.html (`.codd` custom properties).
/// All colors are sRGB; dark only (the app forces `.darkAqua`).
public enum Palette {
    public static let bg = NSColor(hex: 0x050505)
    public static let bgSoft = NSColor(hex: 0x0A0A0A)
    public static let bgLift = NSColor(hex: 0x111111)
    public static let bgRaise = NSColor(hex: 0x161616)
    public static let line = NSColor(hex: 0x1A1A1A)
    public static let lineBright = NSColor(hex: 0x2A2A2A)

    public static let amber = NSColor(hex: 0xFFB84A)
    public static let amberDim = NSColor(hex: 0xE09A2C)
    /// `--amber-glow: rgba(255,184,74,.22)`
    public static let amberGlow = NSColor(hex: 0xFFB84A, alpha: 0.22)

    public static let cream = NSColor(hex: 0xF5ECD6)
    public static let bone = NSColor(hex: 0xD4CDB8)
    public static let dim = NSColor(hex: 0xA8A298)
    /// Only on #050505 / #0a0a0a backgrounds and at ≥ 10.5 px (contrast rule, SPEC §1).
    public static let dimmer = NSColor(hex: 0x7A7468)

    public static let cyan = NSColor(hex: 0x6EE0F0)
    public static let danger = NSColor(hex: 0xFF7058)
    public static let success = NSColor(hex: 0x7CFF9A)
    public static let successDim = NSColor(hex: 0x52C472)

    // Terminal (`.term` spans)
    public static let termBackground = NSColor.black
    public static let termForeground = NSColor(hex: 0xE8E6D8)
    public static let termDim = NSColor(hex: 0x8A8578)
    public static let termWhite = NSColor.white
    public static let termClaude = NSColor(hex: 0xE0896A)
    public static let termAddBackground = NSColor(hex: 0x7CFF9A, alpha: 0.10)
    public static let termAddText = NSColor(hex: 0xB8F5C6)
    public static let termDelBackground = NSColor(hex: 0xFF7058, alpha: 0.10)
    public static let termDelText = NSColor(hex: 0xFFB1A3)
}

/// Fixed metrics (SPEC §2, §7.16 row anatomy). Row heights are fixed: no automatic heights.
/// Each value is its ``Design`` value at the current interface zoom (``UIZoom/pt(_:)``): the
/// same at the default UI 字級, taller rows and bars when the type grows.
public enum Metrics {
    /// The values at UI 字級 13 (helmet px), for ``NSLayoutConstraint/zoomed(_:)`` and tests.
    public enum Design {
        public static let railWidth: CGFloat = 72
        public static let sidebarWidth: CGFloat = 280
        public static let sidebarMinWidth: CGFloat = 220
        public static let sidebarMaxWidth: CGFloat = 400
        public static let mainMinWidth: CGFloat = 560
        public static let headerHeight: CGFloat = 52
        public static let tabStripHeight: CGFloat = 30
        public static let statusBarHeight: CGFloat = 24
        public static let sessionRowHeight: CGFloat = 38
        public static let doneRowHeight: CGFloat = 28
        public static let groupHeaderHeight: CGFloat = 22
        public static let groupGap: CGFloat = 5
        public static let projectRowHeight: CGFloat = 22
        public static let sectionHeaderHeight: CGFloat = 26
        public static let addGroupRowHeight: CGFloat = 38
        public static let emptyProjectRowHeight: CGFloat = 22
        public static let sidebarInset: CGFloat = 6
    }

    public static var railWidth: CGFloat { UIZoom.pt(Design.railWidth) }
    public static var sidebarWidth: CGFloat { UIZoom.pt(Design.sidebarWidth) }
    public static var sidebarMinWidth: CGFloat { UIZoom.pt(Design.sidebarMinWidth) }
    public static var sidebarMaxWidth: CGFloat { UIZoom.pt(Design.sidebarMaxWidth) }
    /// The pane's minimum width does not follow the zoom: a zoomed window must still fit a laptop
    /// screen (the pane's bars give way inside it).
    public static var mainMinWidth: CGFloat { Design.mainMinWidth }
    public static var headerHeight: CGFloat { UIZoom.pt(Design.headerHeight) }
    public static var tabStripHeight: CGFloat { UIZoom.pt(Design.tabStripHeight) }
    public static var statusBarHeight: CGFloat { UIZoom.pt(Design.statusBarHeight) }

    // Sidebar rows
    public static var sessionRowHeight: CGFloat { UIZoom.pt(Design.sessionRowHeight) }
    public static var doneRowHeight: CGFloat { UIZoom.pt(Design.doneRowHeight) }
    public static var groupHeaderHeight: CGFloat { UIZoom.pt(Design.groupHeaderHeight) }
    /// Gap above each group block (`.gblk{margin-top:5px}`), drawn inside the header row.
    public static var groupGap: CGFloat { UIZoom.pt(Design.groupGap) }
    public static var projectRowHeight: CGFloat { UIZoom.pt(Design.projectRowHeight) }
    public static var sectionHeaderHeight: CGFloat { UIZoom.pt(Design.sectionHeaderHeight) }
    public static var addGroupRowHeight: CGFloat { UIZoom.pt(Design.addGroupRowHeight) }
    public static var emptyProjectRowHeight: CGFloat { UIZoom.pt(Design.emptyProjectRowHeight) }
    /// Horizontal inset of blocks inside the sidebar (`.side-scroll{padding:8px 6px}`).
    public static var sidebarInset: CGFloat { UIZoom.pt(Design.sidebarInset) }
}

extension NSColor {
    /// sRGB color from `0xRRGGBB`.
    public convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// CSS `color-mix(in srgb, self f, other)`: linear blend of the sRGB components.
    public func mixed(with other: NSColor, fraction: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let f = max(0, min(1, fraction))
        return NSColor(srgbRed: a.redComponent * f + b.redComponent * (1 - f),
                       green: a.greenComponent * f + b.greenComponent * (1 - f),
                       blue: a.blueComponent * f + b.blueComponent * (1 - f),
                       alpha: a.alphaComponent * f + b.alphaComponent * (1 - f))
    }
}
