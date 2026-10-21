import CoreGraphics
import Foundation

/// Canvas points ⇄ original image pixels for one zoom level. `imageOrigin` is the canvas point of
/// pixel (0, 0); `scale` is points per pixel (0.5 at the artboard's `顯示 50%`).
struct CanvasMapping: Equatable {
    var scale: CGFloat
    var imageOrigin: CGPoint
    var pixelWidth: Int
    var pixelHeight: Int

    /// The pixel under a canvas point (fractional, not clamped).
    func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageOrigin.x) / scale, y: (point.y - imageOrigin.y) / scale)
    }

    /// The canvas point of a pixel coordinate.
    func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: imageOrigin.x + x * scale, y: imageOrigin.y + y * scale)
    }

    func view(_ x: Int, _ y: Int) -> CGPoint { view(CGFloat(x), CGFloat(y)) }

    /// The image on the canvas.
    var imageRect: CGRect {
        CGRect(x: imageOrigin.x, y: imageOrigin.y, width: CGFloat(pixelWidth) * scale, height: CGFloat(pixelHeight) * scale)
    }

    /// A rect draft on the canvas.
    func viewRect(_ item: AnnotationDraft) -> CGRect {
        let origin = view(item.x, item.y)
        return CGRect(x: origin.x, y: origin.y, width: CGFloat(item.width) * scale, height: CGFloat(item.height) * scale)
    }

    /// Converts a pixel distance on screen (a drag delta) to whole pixels.
    func pixels(_ points: CGFloat) -> Int { Int((points / scale).rounded()) }
}

/// The four corner handles of a selected rect (`.ia-hdl.tl/.tr/.bl/.br`).
enum RectCorner: CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// +1 when the corner is on the rect's right / bottom side.
    var dirX: Int { self == .topRight || self == .bottomRight ? 1 : -1 }
    var dirY: Int { self == .bottomLeft || self == .bottomRight ? 1 : -1 }
}

/// The coordinate fields of the expanded list item.
enum CoordinateField: Sendable, Equatable {
    case x, y, w, h, x2, y2

    /// The fields an item of `kind` shows, with their labels (rect X / Y / W / H, arrow X1 / Y1 /
    /// X2 / Y2, point and text X / Y).
    static func fields(for kind: AnnotationKind) -> [(CoordinateField, String)] {
        switch kind {
        case .rect: [(.x, "X"), (.y, "Y"), (.w, "W"), (.h, "H")]
        case .arrow: [(.x, "X1"), (.y, "Y1"), (.x2, "X2"), (.y2, "Y2")]
        case .point, .text: [(.x, "X"), (.y, "Y")]
        }
    }

    func value(of item: AnnotationDraft) -> Int {
        switch self {
        case .x: item.x
        case .y: item.y
        case .w: item.width
        case .h: item.height
        case .x2: item.endX
        case .y2: item.endY
        }
    }
}

/// Pure geometry of the drawing and editing gestures. Every result is in integer ORIGINAL pixels and
/// clamped to the image (`0…width` × `0…height`; a rect stays inside it and is at least 1 × 1).
enum AnnotationGeometry {
    static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), max(low, high)) }

    static func round(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(value.rounded())
    }

    /// The clamped integer pixel of a fractional one (point and text clicks, arrow ends).
    static func clampedPixel(_ p: CGPoint, width: Int, height: Int) -> (x: Int, y: Int) {
        (clamp(round(p.x), 0, width), clamp(round(p.y), 0, height))
    }

    /// The rect drawn by a drag from `start` to `end` (fractional pixels). `square` (⇧) makes it a
    /// square in pixels, as large as the pointer allows inside the image. Nil when it would be empty.
    static func rect(from start: CGPoint, to end: CGPoint, square: Bool, width: Int, height: Int)
        -> (x: Int, y: Int, w: Int, h: Int)? {
        let s = clampedPixel(start, width: width, height: height)
        var dx = round(end.x) - s.x
        var dy = round(end.y) - s.y
        if square {
            let dirX = dx >= 0 ? 1 : -1
            let dirY = dy >= 0 ? 1 : -1
            let roomX = dirX > 0 ? width - s.x : s.x
            let roomY = dirY > 0 ? height - s.y : s.y
            let side = min(max(abs(dx), abs(dy)), roomX, roomY)
            dx = dirX * side
            dy = dirY * side
        }
        let x0 = clamp(min(s.x, s.x + dx), 0, width)
        let x1 = clamp(max(s.x, s.x + dx), 0, width)
        let y0 = clamp(min(s.y, s.y + dy), 0, height)
        let y1 = clamp(max(s.y, s.y + dy), 0, height)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// The arrow's head for a drag from the (already clamped) start toward `end`. `snap` (⇧) keeps
    /// the direction on 45° steps; the head is then pulled back along that ray into the image, so
    /// the angle survives the clamping.
    static func arrowEnd(from start: (x: Int, y: Int), toward end: CGPoint, snap: Bool, width: Int, height: Int) -> (x: Int, y: Int) {
        guard snap else { return clampedPixel(end, width: width, height: height) }
        let fx = end.x - CGFloat(start.x)
        let fy = end.y - CGFloat(start.y)
        let length = hypot(fx, fy)
        guard length > 0 else { return start }
        let step = CGFloat.pi / 4
        let k = Int((atan2(fy, fx) / step).rounded())
        // Unit steps per axis for the eight directions (k = 0 is +x, k = 2 is +y on the y-down canvas).
        let directions: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        let (ux, uy) = directions[((k % 8) + 8) % 8]
        // Steps per axis = the pointer's projection on the snapped direction (a diagonal step
        // moves both axes), so the head follows the pointer along the ray.
        let projection = fx * CGFloat(ux) + fy * CGFloat(uy)
        var d = ux != 0 && uy != 0 ? round(projection / 2) : round(projection)
        if ux != 0 { d = min(d, ux > 0 ? width - start.x : start.x) }
        if uy != 0 { d = min(d, uy > 0 ? height - start.y : start.y) }
        d = max(0, d)
        return (start.x + ux * d, start.y + uy * d)
    }

    /// `item` moved by whole pixels, kept entirely inside the image.
    static func moved(_ item: AnnotationDraft, dx: Int, dy: Int, width: Int, height: Int) -> AnnotationDraft {
        var moved = item
        switch item.kind {
        case .rect:
            moved.x = clamp(item.x + dx, 0, width - item.width)
            moved.y = clamp(item.y + dy, 0, height - item.height)
        case .arrow:
            let minX = min(item.x, item.endX), maxX = max(item.x, item.endX)
            let minY = min(item.y, item.endY), maxY = max(item.y, item.endY)
            let cdx = clamp(dx, -minX, width - maxX)
            let cdy = clamp(dy, -minY, height - maxY)
            moved.x = item.x + cdx
            moved.y = item.y + cdy
            moved.x2 = item.endX + cdx
            moved.y2 = item.endY + cdy
        case .point, .text:
            moved.x = clamp(item.x + dx, 0, width)
            moved.y = clamp(item.y + dy, 0, height)
        }
        return moved
    }

    /// `original` (a rect) resized by dragging `corner` to `pointer` (fractional pixels); the
    /// opposite corner stays. `lockAspect` (⇧) keeps the original's width : height.
    static func resized(_ original: AnnotationDraft, corner: RectCorner, to pointer: CGPoint, lockAspect: Bool,
                        width: Int, height: Int) -> AnnotationDraft {
        let w0 = max(1, original.width), h0 = max(1, original.height)
        let ax = corner.dirX > 0 ? original.x : original.x + w0
        let ay = corner.dirY > 0 ? original.y : original.y + h0
        var result = original
        if lockAspect {
            let fx = pointer.x - CGFloat(ax), fy = pointer.y - CGFloat(ay)
            let dirX = fx > 0 ? 1 : (fx < 0 ? -1 : corner.dirX)
            let dirY = fy > 0 ? 1 : (fy < 0 ? -1 : corner.dirY)
            var s = max(abs(fx) / CGFloat(w0), abs(fy) / CGFloat(h0))
            let roomX = CGFloat(dirX > 0 ? width - ax : ax) / CGFloat(w0)
            let roomY = CGFloat(dirY > 0 ? height - ay : ay) / CGFloat(h0)
            s = min(s, roomX, roomY)
            let nw = max(1, round(CGFloat(w0) * s)), nh = max(1, round(CGFloat(h0) * s))
            result.w = min(nw, dirX > 0 ? width - ax : ax)
            result.h = min(nh, dirY > 0 ? height - ay : ay)
            result.x = dirX > 0 ? ax : ax - (result.w ?? 1)
            result.y = dirY > 0 ? ay : ay - (result.h ?? 1)
        } else {
            let e = clampedPixel(pointer, width: width, height: height)
            (result.x, result.w) = span(anchor: ax, end: e.x, limit: width)
            (result.y, result.h) = span(anchor: ay, end: e.y, limit: height)
        }
        return result
    }

    /// One axis of a rect from a fixed anchor to a moving end, at least 1 px and inside `0…limit`.
    private static func span(anchor: Int, end: Int, limit: Int) -> (Int, Int?) {
        if end == anchor { return anchor >= limit ? (max(0, limit - 1), 1) : (anchor, 1) }
        return (min(anchor, end), abs(end - anchor))
    }

    /// The arrow with one endpoint (`head` true = x2 / y2) dragged to `pointer`; ⇧ snaps it to 45°
    /// around the other endpoint.
    static func movedEndpoint(_ item: AnnotationDraft, head: Bool, to pointer: CGPoint, snap: Bool,
                              width: Int, height: Int) -> AnnotationDraft {
        var result = item
        let fixed = head ? (x: item.x, y: item.y) : (x: item.endX, y: item.endY)
        let end = arrowEnd(from: fixed, toward: pointer, snap: snap, width: width, height: height)
        if head {
            result.x2 = end.x
            result.y2 = end.y
        } else {
            result.x = end.x
            result.y = end.y
        }
        return result
    }

    /// The largest scale ≤ 1 that fits `available` points, floored to 5 % steps (1 % steps under
    /// 10 %), so the caption reads a round `顯示 50%` and pixels map to round fractions of a point.
    static func fitScale(available: CGSize, width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let raw = min(available.width / CGFloat(width), available.height / CGFloat(height), 1)
        guard raw.isFinite, raw > 0 else { return 0.01 }
        if raw >= 1 { return 1 }
        if raw >= 0.1 { return floor(raw * 20 + 1e-9) / 20 }
        return max(0.01, floor(raw * 100 + 1e-9) / 100)
    }

    /// Distance from `p` to the segment `a`–`b` (arrow hit testing).
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Document edits shared by the canvas and the panel.
enum AnnotationEditing {
    /// Numbers the items 1…n in their order (`依建立順序編號`).
    static func renumbered(_ items: [AnnotationDraft]) -> [AnnotationDraft] {
        items.enumerated().map { index, item in
            var item = item
            item.n = index + 1
            return item
        }
    }

    /// `document` with `draft` appended as item `count + 1`.
    static func appending(_ draft: AnnotationDraft, to document: AnnotationDocument) -> (AnnotationDocument, Int) {
        var document = document
        var draft = draft
        draft.n = document.items.count + 1
        document.items.append(draft)
        return (document, draft.n)
    }

    /// `document` without item `n`; the rest renumbered.
    static func deleting(_ n: Int, from document: AnnotationDocument) -> AnnotationDocument {
        var document = document
        document.items = renumbered(document.items.filter { $0.n != n })
        return document
    }

    /// `document` with the item of `item.n` replaced.
    static func replacing(_ item: AnnotationDraft, in document: AnnotationDocument) -> AnnotationDocument {
        var document = document
        if let index = document.items.firstIndex(where: { $0.n == item.n }) { document.items[index] = item }
        return document
    }

    /// `item` with one coordinate field set to `value`, clamped to the image (a rect keeps inside
    /// it: X / Y move it, W / H are at least 1 and end at the image's edge).
    static func setting(_ field: CoordinateField, to value: Int, of item: AnnotationDraft, width: Int, height: Int) -> AnnotationDraft {
        var item = item
        let clamp = AnnotationGeometry.clamp
        switch (item.kind, field) {
        case (.rect, .x): item.x = clamp(value, 0, width - item.width)
        case (.rect, .y): item.y = clamp(value, 0, height - item.height)
        case (.rect, .w): item.w = clamp(value, 1, width - item.x)
        case (.rect, .h): item.h = clamp(value, 1, height - item.y)
        case (_, .x): item.x = clamp(value, 0, width)
        case (_, .y): item.y = clamp(value, 0, height)
        case (.arrow, .x2): item.x2 = clamp(value, 0, width)
        case (.arrow, .y2): item.y2 = clamp(value, 0, height)
        default: break
        }
        return item
    }
}

/// Parsing of the X / Y / W / H fields: an integer (full-width digits and a trailing `px` allowed).
enum CoordinateInput {
    static func parse(_ text: String) -> Int? {
        var value = text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix("px") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty, value.count <= 9 else { return nil }
        return Int(value)
    }
}
