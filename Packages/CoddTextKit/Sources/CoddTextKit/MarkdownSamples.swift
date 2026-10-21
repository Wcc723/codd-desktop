import AppKit
import CoddUI

/// SPEC §5 n1 (made-up design data) for demos, tests and snapshots: the note body as the Notebook
/// artboard shows it, its screenshot path, the three R6 annotations and a generated 750 × 1334
/// placeholder screenshot (the artboard's `.nb-ph` phone schematic).
public enum MarkdownSamples {
    public static let n1ImagePath = "assets/rwd-punch-k7x2/9f3a1c.png"
    public static let n1ImageCaption = "截圖 2026-10-15 09:32 · iPhone SE"
    public static let n1PixelSize = CGSize(width: 750, height: 1334)

    public static let n1Annotations: [ImageOverlayShape] = [
        .rect(n: 1, CGRect(x: 20, y: 1150, width: 710, height: 120), color: nil),
        .point(n: 2, CGPoint(x: 375, y: 330), color: nil),
        .arrow(n: 3, from: CGPoint(x: 600, y: 760), to: CGPoint(x: 700, y: 1080), color: nil),
    ]

    public static let n1AnnotationNotes = [
        "上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)",
        "時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px",
        "打卡紀錄卡片離按鈕太近，間距加到 16px",
    ]

    /// The note body (no frontmatter: the app strips it before loading).
    public static let n1 = """
    # 打卡頁 RWD 跑版紀錄

    ## 問題
    iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。
    - 影響頁面：`/punch`（打卡）與 `/punch/history`（打卡紀錄表格）
    - **Safari 底部工具列展開時**才會完全蓋住，收起後還露出上半截

    ![截圖 2026-10-15 09:32 · iPhone SE](assets/rwd-punch-k7x2/9f3a1c.png)
    ```codd-annotations
    {"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[{"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},{"n":2,"type":"point","x":375,"y":330,"note":"時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},{"n":3,"type":"arrow","x":600,"y":760,"x2":700,"y2":1080,"note":"打卡紀錄卡片離按鈕太近，間距加到 16px"}],"send":{"original":false,"annotated":true,"list":true}}
    ```

    ## 想請 AI 做的
    - [x] 先重現（Chrome DevTools 375 寬）
    - [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`
    - [ ] 表格改卡片式（<640px）

    ```css
    @media (max-width: 640px) {
      .punch-table { display: block; }
    }
    ```

    """

    /// The caret position of the artboard's raw line: the end of the `**Safari 底部工具列展開時**` item.
    public static var n1CaretLocation: Int {
        let text = n1 as NSString
        let line = text.range(of: "收起後還露出上半截")
        return NSMaxRange(line)
    }

    /// The resolver the demos use for n1's screenshot.
    @MainActor public static func n1ImageInfo(image: NSImage?) -> MarkdownImageInfo {
        MarkdownImageInfo(path: n1ImagePath, image: image, pixelSize: n1PixelSize, caption: n1ImageCaption, overlay: n1Annotations)
    }

    /// A 750 × 1334 px phone screenshot schematic (status bar, `打卡` header, the 09:32 clock, a card,
    /// three rows, the blue `上班打卡` button and the bottom navigation), drawn like the artboard's
    /// CSS placeholder with its `brightness(.86) saturate(.9)` already applied.
    @MainActor public static func placeholderScreenshot() -> NSImage {
        let width = 750
        let height = 1334
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSImage(size: NSSize(width: 375, height: 667)) }
        let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        let k: CGFloat = 750 / 124
        func dim(_ hex: UInt32) -> NSColor { NSColor(hex: hex).mixed(with: .black, fraction: 0.86) }
        func text(_ string: String, size: CGFloat, color: NSColor, bold: Bool = false, mono: Bool = false, centerX: CGFloat, y: CGFloat) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                : NSFont(name: bold ? "PingFangTC-Semibold" : "PingFangTC-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
            let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let size = attributed.size()
            attributed.draw(at: CGPoint(x: centerX - size.width / 2, y: y))
        }
        Draw.fill(CGRect(x: 0, y: 0, width: width, height: height), dim(0xECEBE6))
        // Status bar and header.
        Draw.fill(CGRect(x: 0, y: 0, width: 750, height: 12 * k), dim(0xFFFFFF))
        text("9:32", size: 6.5 * k, color: dim(0x111111), mono: true, centerX: 22 * k, y: 1.5 * k)
        Draw.strokeRect(CGRect(x: 750 - 22 * k, y: 3.5 * k, width: 12 * k, height: 5 * k), color: dim(0x111111))
        Draw.fill(CGRect(x: 750 - 21 * k, y: 4.5 * k, width: 8 * k, height: 3 * k), dim(0x111111))
        Draw.fill(CGRect(x: 0, y: 12 * k, width: 750, height: 20 * k), dim(0xFFFFFF))
        Draw.fill(CGRect(x: 0, y: 32 * k - 6, width: 750, height: 6), dim(0xD9D6CE))
        text("打卡", size: 8 * k, color: dim(0x2A2A2A), bold: true, centerX: 375, y: 15.5 * k)
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: 12 * k, y: 18 * k))
        chevron.line(to: CGPoint(x: 9 * k, y: 21 * k))
        chevron.line(to: CGPoint(x: 12 * k, y: 24 * k))
        chevron.lineWidth = 7
        dim(0x555555).setStroke()
        chevron.stroke()
        // Clock.
        text("09:32", size: 21 * k, color: dim(0x1D1D1D), bold: true, mono: true, centerX: 375, y: 41 * k)
        text("10/15（四）· 台北辦公室", size: 6.5 * k, color: dim(0x6B6760), centerX: 375, y: 66 * k)
        // Card.
        let card = CGRect(x: 8 * k, y: 80 * k, width: 108 * k, height: 26 * k)
        Draw.fill(card, dim(0xFFFFFF))
        Draw.strokeRect(card, color: dim(0xDCD8CF))
        Draw.fill(CGRect(x: card.minX + 6 * k, y: card.minY + 7 * k, width: (card.width - 12 * k) * 0.72, height: 4 * k), dim(0xCFCABF))
        Draw.fill(CGRect(x: card.minX + 6 * k, y: card.minY + 15 * k, width: (card.width - 12 * k) * 0.48, height: 4 * k), dim(0xCFCABF))
        // Rows.
        for row in 0 ..< 3 {
            let rect = CGRect(x: 8 * k, y: (113 + CGFloat(row) * 13) * k, width: 108 * k, height: 10 * k)
            Draw.fill(rect, dim(0xFFFFFF))
            Draw.strokeRect(rect, color: dim(0xE0DDD5))
        }
        // The button, partly under the navigation bar.
        let button = CGRect(x: 10 * k, y: CGFloat(height) - 13 * k - 30 * k, width: 104 * k, height: 30 * k)
        Draw.fill(button, dim(0x2F6FE0))
        text("上班打卡", size: 8 * k, color: dim(0xFFFFFF), bold: true, centerX: 375, y: button.minY + 4 * k)
        let nav = CGRect(x: 0, y: CGFloat(height) - 30 * k, width: 750, height: 30 * k)
        Draw.fill(nav, dim(0xFFFFFF).withAlphaComponent(0.97))
        Draw.fill(CGRect(x: 0, y: nav.minY, width: 750, height: 6), dim(0xD6D2C8))
        for (index, label) in ["首頁", "打卡", "紀錄", "我的"].enumerated() {
            let centerX = (CGFloat(index) + 0.5) * 750 / 4
            let color = index == 1 ? dim(0x2F6FE0) : dim(0x77736B)
            let icon = CGRect(x: centerX - 4.5 * k, y: nav.minY + 7 * k, width: 9 * k, height: 9 * k)
            let path = NSBezierPath(rect: icon)
            path.lineWidth = 1.2 * k
            color.setStroke()
            path.stroke()
            text(label, size: 6 * k, color: color, centerX: centerX, y: nav.minY + 18 * k)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 375, height: 667))
        image.addRepresentation(rep)
        return image
    }
}
