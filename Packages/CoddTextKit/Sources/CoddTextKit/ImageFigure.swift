import AppKit

/// The `.nb-figrow` of an image line: the framed screenshot (`.nb-shot`: #000 plate, 7 pt padding,
/// 1 px amber-dim border, 3 pt ring), its caption under it and the accessory to the right, top
/// aligned. Coordinates are relative to the row's top-left until `translate` places them.
struct FigureGeometry: Equatable {
    var rowHeight: CGFloat
    var plate: CGRect
    var image: CGRect
    var caption: CGRect
    var accessory: CGRect?
    var captionText: String

    mutating func translate(x: CGFloat, y: CGFloat) {
        plate = plate.offsetBy(dx: x, dy: y)
        image = image.offsetBy(dx: x, dy: y)
        caption = caption.offsetBy(dx: x, dy: y)
        accessory = accessory?.offsetBy(dx: x, dy: y)
    }

    /// Tall screenshots are shown at most `figureMaxHeight` high, a @2x image never larger than its
    /// point size, and the image leaves `accessoryMinWidth` + gap for the accessory when there is one.
    static func make(info: MarkdownImageInfo, contentWidth: CGFloat, style: MarkdownEditorStyle, accessoryHeight: CGFloat,
                     hasAccessory: Bool) -> FigureGeometry {
        let border: CGFloat = 1
        let padding = style.figurePadding
        let rowPadding = style.figureRowPadding
        let perPoint = max(0.1, style.figurePixelsPerPoint)
        let natural = CGSize(width: info.pixelSize.width / perPoint, height: info.pixelSize.height / perPoint)
        let reserved = hasAccessory ? style.accessoryMinWidth + style.accessoryGap : 0
        let maxImageWidth = max(24, contentWidth - reserved - 2 * (padding + border))
        let scale = min(1, style.figureMaxHeight / max(1, natural.height), maxImageWidth / max(1, natural.width))
        let imageSize = CGSize(width: max(1, (natural.width * scale).rounded()), height: max(1, (natural.height * scale).rounded()))
        let inset = padding + border
        let plate = CGRect(x: 0, y: rowPadding, width: imageSize.width + 2 * inset, height: imageSize.height + 2 * inset)
        let image = CGRect(x: inset, y: rowPadding + inset, width: imageSize.width, height: imageSize.height)
        let captionHeight = info.caption.isEmpty ? 0 : ceil(style.captionFont.pointSize * style.captionLineHeight)
        let captionLimit = max(plate.width, contentWidth - reserved)
        let captionAttributes: [NSAttributedString.Key: Any] = [.font: style.captionFont, .kern: style.bodyTracking * style.captionFont.pointSize]
        let measured = info.caption.isEmpty ? 0 : ceil((info.caption as NSString).size(withAttributes: captionAttributes).width)
        let captionWidth = min(captionLimit, measured)
        let caption = CGRect(x: 0, y: plate.maxY + (info.caption.isEmpty ? 0 : style.figureCaptionGap), width: captionWidth,
                             height: captionHeight)
        let figureWidth = max(plate.width, captionWidth)
        let figureHeight = caption.maxY - rowPadding
        var accessory: CGRect?
        if hasAccessory {
            let x = figureWidth + style.accessoryGap
            accessory = CGRect(x: x, y: rowPadding, width: max(0, contentWidth - x), height: accessoryHeight)
        }
        let rowHeight = rowPadding + max(figureHeight, hasAccessory ? accessoryHeight : 0) + rowPadding
        return FigureGeometry(rowHeight: rowHeight, plate: plate, image: image, caption: caption, accessory: accessory,
                              captionText: info.caption)
    }
}

/// Original image pixels (origin top-left) → view points over the drawn image.
enum ImageOverlayGeometry {
    static func point(_ point: CGPoint, pixelSize: CGSize, in image: CGRect) -> CGPoint {
        CGPoint(x: image.minX + point.x * image.width / max(1, pixelSize.width),
                y: image.minY + point.y * image.height / max(1, pixelSize.height))
    }

    static func rect(_ rect: CGRect, pixelSize: CGSize, in image: CGRect) -> CGRect {
        let origin = point(rect.origin, pixelSize: pixelSize, in: image)
        let end = point(CGPoint(x: rect.maxX, y: rect.maxY), pixelSize: pixelSize, in: image)
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
    }

    /// An arrow's shaft end and head triangle (tip, two base corners), the head in view points.
    static func arrow(from: CGPoint, to: CGPoint, headLength: CGFloat, headHalfWidth: CGFloat)
        -> (shaftEnd: CGPoint, head: [CGPoint]) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(0.001, hypot(dx, dy))
        let ux = dx / length
        let uy = dy / length
        let head = min(headLength, length)
        let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
        let left = CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth)
        let right = CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth)
        return (base, [to, left, right])
    }

    /// Where the numbered pin of a shape sits (rect: its top-left corner, arrow: its start).
    static func pinCenter(_ shape: ImageOverlayShape, pixelSize: CGSize, in image: CGRect) -> CGPoint {
        switch shape {
        case let .rect(_, rect, _): point(rect.origin, pixelSize: pixelSize, in: image)
        case let .point(_, point, _): self.point(point, pixelSize: pixelSize, in: image)
        case let .arrow(_, from, _, _): point(from, pixelSize: pixelSize, in: image)
        case let .text(_, point, _, _): self.point(point, pixelSize: pixelSize, in: image)
        }
    }
}
