import AppKit
import CoddUI

/// Made-up design data for the demo and the tests (SPEC §8 R6, M4 §3.3 / §3.7): the 750 × 1334
/// iPhone SE punch-page screenshot drawn with CoreGraphics, its three canonical annotations and
/// stand-ins for the app's CoddNotes formatter and codec. Nothing here reads or writes files.
public enum ImageAnnotateSamples {
    public static let pixelSize = CGSize(width: 750, height: 1334)

    /// R6 ① rect, ② point, ③ arrow; send options at their defaults.
    public static var document: AnnotationDocument {
        AnnotationDocument(pixelSize: pixelSize, items: [
            .rect(1, x: 20, y: 1150, w: 710, h: 120, note: "上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"),
            .point(2, x: 375, y: 330, note: "時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"),
            .arrow(3, x: 600, y: 760, x2: 700, y2: 1080, note: "打卡紀錄卡片離按鈕太近，間距加到 16px"),
        ])
    }

    public static var header: ImageAnnotateHeader {
        ImageAnnotateHeader(crumbs: ["INBOX", "打卡頁 RWD 跑版紀錄"], fileName: "9f3a1c.png",
                            meta: ["assets/rwd-punch-k7x2/9f3a1c.png", "750×1334 px", "iPhone SE @2x", "截圖 2026-10-15 09:32"],
                            originalFileName: "9f3a1c.png")
    }

    /// The asset folder of the sample note under a made-up data root in the home folder.
    public static var assetFolder: String { NSHomeDirectory() + "/Library/Application Support/CODD/notes/assets/rwd-punch-k7x2" }

    /// A §3.7-shaped `AI 會收到` text (the app passes CoddNotes' real formatter instead).
    public static func previewText(_ document: AnnotationDocument) -> String {
        let w = Int(document.pixelSize.width), h = Int(document.pixelSize.height)
        var lines: [String] = []
        if document.send.original { lines.append("[image] \(assetFolder)/9f3a1c.png (\(w)×\(h))") }
        if document.send.annotated { lines.append("[image] \(assetFolder)/9f3a1c.annotated.png (\(w)×\(h))") }
        if document.send.list {
            lines.append("annotations（原圖像素，左上為原點）:")
            for item in document.items {
                let type = item.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
                let coordinates: String = switch item.kind {
                case .rect: "x=\(item.x) y=\(item.y) w=\(item.width) h=\(item.height)"
                case .point, .text: "x=\(item.x) y=\(item.y)"
                case .arrow: "\(item.x),\(item.y) → \(item.endX),\(item.endY)"
                }
                lines.append("  \(item.n) \(type) \(coordinates)" + (item.note.isEmpty ? "" : "  \(item.note)"))
            }
        }
        return lines.isEmpty ? "（只送出筆記文字，不附圖片與標註）" : lines.joined(separator: "\n")
    }

    /// A §3.3-shaped `codd-annotations` block (the app passes CoddNotes' real codec instead).
    public static func markdownSource(_ document: AnnotationDocument) -> String {
        func json(_ text: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        let items = document.items.map { item -> String in
            var fields = ["\"n\":\(item.n)", "\"type\":\"\(item.kind.rawValue)\"", "\"x\":\(item.x)", "\"y\":\(item.y)"]
            switch item.kind {
            case .rect: fields += ["\"w\":\(item.width)", "\"h\":\(item.height)"]
            case .arrow: fields += ["\"x2\":\(item.endX)", "\"y2\":\(item.endY)"]
            case .point, .text: break
            }
            fields.append("\"note\":\(json(item.note))")
            if item.color != .amber { fields.append("\"color\":\"\(item.color.rawValue)\"") }
            return "  {" + fields.joined(separator: ",") + "}"
        }
        let send = document.send
        return """
        ```codd-annotations
        {"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[\(Int(document.pixelSize.width)),\(Int(document.pixelSize.height))],
         "items":[
        \(items.joined(separator: ",\n"))],
         "send":{"original":\(send.original),"annotated":\(send.annotated),"list":\(send.list)}}
        ```
        """
    }

    /// The made-up punch page at 750 × 1334 px (the artboard's CSS mock at 2×, with its
    /// `brightness(.86)` baked in): status bar, header `打卡`, `09:32`, the shift and record cards,
    /// the blue `上班打卡` button half under the bottom nav.
    @MainActor
    public static func placeholderImage() -> CGImage {
        let width = 750, height = 1334
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("cannot create the placeholder bitmap") }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        PlaceholderPainter.paint(width: CGFloat(width), height: CGFloat(height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { fatalError("cannot make the placeholder image") }
        return image
    }
}

/// Draws the placeholder in a flipped 750 × 1334 context.
@MainActor
private enum PlaceholderPainter {
    static func cjk(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "PingFangTC-Semibold" : "PingFangTC-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    static func text(_ string: String, _ font: NSFont, _ color: UInt32, x: CGFloat? = nil, right: CGFloat? = nil, centerX: CGFloat? = nil,
                     centerY: CGFloat, kern: CGFloat = 0) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: color)]
        if kern != 0 { attributes[.kern] = kern }
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.size()
        let originX = x ?? (right.map { $0 - size.width } ?? ((centerX ?? 0) - size.width / 2))
        attributed.draw(at: CGPoint(x: originX, y: centerY - size.height / 2))
    }

    static func fill(_ rect: CGRect, _ color: UInt32, alpha: CGFloat = 1) {
        NSColor(hex: color, alpha: alpha).setFill()
        rect.fill(using: .sourceOver)
    }

    static func box(_ rect: CGRect, fill color: UInt32, border: UInt32, width: CGFloat = 2) {
        fill(rect, color)
        NSColor(hex: border).setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }

    static func paint(width: CGFloat, height: CGFloat) {
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0xECEBE6)
        // Status bar (20 px at 1×).
        fill(CGRect(x: 0, y: 0, width: width, height: 40), 0xFFFFFF)
        text("9:32", Typeface.mono(24, .semibold), 0x111111, x: 24, centerY: 20)
        box(CGRect(x: 682, y: 9, width: 48, height: 22), fill: 0xFFFFFF, border: 0x111111)
        fill(CGRect(x: 686, y: 13, width: 28, height: 14), 0x111111)
        // Header `打卡` with its back chevron.
        fill(CGRect(x: 0, y: 40, width: width, height: 88), 0xFFFFFF)
        fill(CGRect(x: 0, y: 126, width: width, height: 2), 0xD9D6CE)
        text("打卡", cjk(34, bold: true), 0x1D1D1D, centerX: width / 2, centerY: 84)
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: 46, y: 67.9))
        chevron.line(to: CGPoint(x: 31.9, y: 82))
        chevron.line(to: CGPoint(x: 46, y: 96.1))
        chevron.lineWidth = 4
        NSColor(hex: 0x555555).setStroke()
        chevron.stroke()
        // Clock and date.
        text("09:32", Typeface.mono(128, .medium), 0x1D1D1D, centerX: width / 2, centerY: 330)
        text("10/15（四）· 台北辦公室", cjk(24), 0x6B6760, centerX: width / 2, centerY: 424)
        // Today's shift card.
        box(CGRect(x: 32, y: 472, width: 686, height: 128), fill: 0xFFFFFF, border: 0xDCD8CF)
        text("今日班別", cjk(22), 0x8A857C, x: 62, centerY: 510)
        text("09:00 – 18:00", Typeface.mono(30, .semibold), 0x1D1D1D, x: 62, centerY: 555)
        let gps = NSAttributedString(string: "GPS 已定位", attributes: [.font: cjk(22), .foregroundColor: NSColor(hex: 0x2E8B57)])
        let gpsWidth = ceil(gps.size().width) + 28
        box(CGRect(x: 688 - gpsWidth, y: 516, width: gpsWidth, height: 40), fill: 0xFFFFFF, border: 0x9FD0B4)
        gps.draw(at: CGPoint(x: 688 - gpsWidth + 14, y: 536 - gps.size().height / 2))
        // Punch records card.
        box(CGRect(x: 32, y: 632, width: 686, height: 492), fill: 0xFFFFFF, border: 0xDCD8CF)
        text("打卡紀錄", cjk(28, bold: true), 0x1D1D1D, x: 62, centerY: 676)
        text("本週", cjk(24), 0x8A857C, right: 688, centerY: 676)
        let rows = [("10/14（三）", "08:57", "18:12"), ("10/13（二）", "09:02", "18:30"), ("10/12（一）", "08:49", "18:05"),
                    ("10/09（五）", "09:10", "17:58")]
        for (index, row) in rows.enumerated() {
            let top = 632 + 2 + 84 + CGFloat(index) * 101
            fill(CGRect(x: 62, y: top, width: 626, height: 2), 0xEBE8E1)
            let mid = top + 51
            text(row.0, cjk(25), 0x6B6760, x: 62, centerY: mid)
            text("上班", cjk(25), 0x3A3833, x: 262, centerY: mid)
            text(row.1, Typeface.mono(25, .medium), 0x1D1D1D, x: 320, centerY: mid)
            text("下班", cjk(25), 0x3A3833, x: 444, centerY: mid)
            text(row.2, Typeface.mono(25, .medium), 0x1D1D1D, x: 502, centerY: mid)
        }
        // The `上班打卡` button, half hidden by the bottom nav (annotation ①).
        fill(CGRect(x: 24, y: 1144, width: 702, height: 120), 0x2F6FE0)
        text("上班打卡", cjk(34, bold: true), 0xFFFFFF, centerX: width / 2 + 4, centerY: 1186, kern: 4)
        // Bottom nav.
        fill(CGRect(x: 0, y: 1222, width: width, height: 112), 0xFFFFFF, alpha: 0.97)
        fill(CGRect(x: 0, y: 1222, width: width, height: 2), 0xD6D2C8)
        for (index, label) in ["首頁", "打卡", "紀錄", "我的"].enumerated() {
            let color: UInt32 = index == 1 ? 0x2F6FE0 : 0x77736B
            let cx = width * CGFloat(2 * index + 1) / 8
            NSColor(hex: color).setStroke()
            let icon = NSBezierPath(rect: CGRect(x: cx - 18, y: 1240, width: 36, height: 36))
            icon.lineWidth = 4
            icon.stroke()
            text(label, cjk(21), color, centerX: cx, centerY: 1302)
        }
        // `filter: brightness(.86)`
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0x000000, alpha: 0.14)
    }
}
