import CoreGraphics
import Testing
@testable import CoddAnnotateUI

/// The pure pixel math behind the gestures and the fields.
@Suite("Geometry")
struct GeometryTests {
    let w = 750, h = 1334

    @Test func rectFromADragInEveryDirection() throws {
        let down = try #require(AnnotationGeometry.rect(from: CGPoint(x: 20, y: 1150), to: CGPoint(x: 730, y: 1270), square: false, width: w, height: h))
        #expect(down == (20, 1150, 710, 120))
        let up = try #require(AnnotationGeometry.rect(from: CGPoint(x: 730, y: 1270), to: CGPoint(x: 20, y: 1150), square: false, width: w, height: h))
        #expect(up == (20, 1150, 710, 120))
        // Fractions round to the nearest pixel.
        let fractional = try #require(AnnotationGeometry.rect(from: CGPoint(x: 10.4, y: 10.6), to: CGPoint(x: 20.5, y: 30.2), square: false,
                                                              width: w, height: h))
        #expect(fractional == (10, 11, 11, 19))
        #expect(AnnotationGeometry.rect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5.2, y: 80), square: false, width: w, height: h) == nil)
    }

    @Test func shiftMakesASquareThatFitsTheImage() throws {
        let square = try #require(AnnotationGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 130), square: true, width: w, height: h))
        #expect(square == (100, 100, 60, 60))
        let leftUp = try #require(AnnotationGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 70, y: 0), square: true, width: w, height: h))
        #expect(leftUp == (0, 0, 100, 100))
        // Near the right edge the side is limited by the room on that side.
        let edge = try #require(AnnotationGeometry.rect(from: CGPoint(x: 700, y: 100), to: CGPoint(x: 900, y: 400), square: true, width: w, height: h))
        #expect(edge == (700, 100, 50, 50))
    }

    @Test func rectsAreClampedToTheImage() throws {
        let rect = try #require(AnnotationGeometry.rect(from: CGPoint(x: -40, y: 1300), to: CGPoint(x: 900, y: 1500), square: false, width: w, height: h))
        #expect(rect == (0, 1300, 750, 34))
        #expect(AnnotationGeometry.clampedPixel(CGPoint(x: -3, y: 2000), width: w, height: h) == (0, 1334))
    }

    @Test func arrowsSnapToFortyFiveDegrees() {
        let start = (x: 100, y: 100)
        // A shallow drag snaps to horizontal, a steep one to vertical, a diagonal to an exact 45°.
        #expect(AnnotationGeometry.arrowEnd(from: start, toward: CGPoint(x: 200, y: 110), snap: true, width: w, height: h) == (200, 100))
        #expect(AnnotationGeometry.arrowEnd(from: start, toward: CGPoint(x: 110, y: 300), snap: true, width: w, height: h) == (100, 300))
        let diagonal = AnnotationGeometry.arrowEnd(from: start, toward: CGPoint(x: 160, y: 150), snap: true, width: w, height: h)
        #expect(diagonal.x - start.x == diagonal.y - start.y)
        #expect(diagonal.x - start.x == 55)
        let upLeft = AnnotationGeometry.arrowEnd(from: start, toward: CGPoint(x: 40, y: 45), snap: true, width: w, height: h)
        #expect(start.x - upLeft.x == start.y - upLeft.y)
        // Clamping pulls the head back along the snapped ray (the angle survives).
        let clamped = AnnotationGeometry.arrowEnd(from: (x: 700, y: 100), toward: CGPoint(x: 900, y: 300), snap: true, width: w, height: h)
        #expect(clamped == (750, 150))
        // Without ⇧ each axis is clamped on its own.
        #expect(AnnotationGeometry.arrowEnd(from: start, toward: CGPoint(x: 900, y: 50.4), snap: false, width: w, height: h) == (750, 50))
    }

    @Test func movesKeepItemsInsideTheImage() {
        let rect = AnnotationDraft.rect(1, x: 20, y: 1150, w: 710, h: 120)
        #expect(AnnotationGeometry.moved(rect, dx: -100, dy: 500, width: w, height: h).x == 0)
        #expect(AnnotationGeometry.moved(rect, dx: -100, dy: 500, width: w, height: h).y == 1214)
        let arrow = AnnotationDraft.arrow(2, x: 600, y: 760, x2: 700, y2: 1080)
        let moved = AnnotationGeometry.moved(arrow, dx: 100, dy: -1000, width: w, height: h)
        #expect((moved.x, moved.y, moved.endX, moved.endY) == (650, 0, 750, 320))
        let point = AnnotationDraft.point(3, x: 375, y: 330)
        #expect(AnnotationGeometry.moved(point, dx: 1000, dy: -1000, width: w, height: h).x == 750)
        #expect(AnnotationGeometry.moved(point, dx: 1000, dy: -1000, width: w, height: h).y == 0)
    }

    @Test func cornersResizeAndShiftKeepsTheRatio() {
        let rect = AnnotationDraft.rect(1, x: 100, y: 100, w: 200, h: 100)
        let br = AnnotationGeometry.resized(rect, corner: .bottomRight, to: CGPoint(x: 250, y: 260), lockAspect: false, width: w, height: h)
        #expect((br.x, br.y, br.width, br.height) == (100, 100, 150, 160))
        let tl = AnnotationGeometry.resized(rect, corner: .topLeft, to: CGPoint(x: 50, y: 20), lockAspect: false, width: w, height: h)
        #expect((tl.x, tl.y, tl.width, tl.height) == (50, 20, 250, 180))
        // Dragging past the opposite corner flips the rect around it.
        let flipped = AnnotationGeometry.resized(rect, corner: .bottomRight, to: CGPoint(x: 60, y: 80), lockAspect: false, width: w, height: h)
        #expect((flipped.x, flipped.y, flipped.width, flipped.height) == (60, 80, 40, 20))
        let locked = AnnotationGeometry.resized(rect, corner: .bottomRight, to: CGPoint(x: 500, y: 150), lockAspect: true, width: w, height: h)
        #expect((locked.x, locked.y, locked.width, locked.height) == (100, 100, 400, 200))
        let lockedEdge = AnnotationGeometry.resized(rect, corner: .bottomRight, to: CGPoint(x: 2000, y: 150), lockAspect: true, width: w, height: h)
        #expect((lockedEdge.width, lockedEdge.height) == (650, 325))
        let tiny = AnnotationGeometry.resized(rect, corner: .topRight, to: CGPoint(x: 100, y: 200), lockAspect: false, width: w, height: h)
        #expect(tiny.width >= 1 && tiny.height >= 1)
    }

    @Test func endpointsMoveAndSnap() {
        let arrow = AnnotationDraft.arrow(3, x: 600, y: 760, x2: 700, y2: 1080)
        let head = AnnotationGeometry.movedEndpoint(arrow, head: true, to: CGPoint(x: 650, y: 900.4), snap: false, width: w, height: h)
        #expect((head.x, head.y, head.endX, head.endY) == (600, 760, 650, 900))
        let tail = AnnotationGeometry.movedEndpoint(arrow, head: false, to: CGPoint(x: 680, y: 700), snap: true, width: w, height: h)
        #expect((tail.x, tail.y) == (700, 700))
    }

    @Test func fitPicksRoundPercentages() {
        // The demo's stage at 1368 × 876: 940 × 824 minus margins, frame, caption and labels → 50 %.
        #expect(AnnotationGeometry.fitScale(available: CGSize(width: 690, height: 697.5), width: 750, height: 1334) == 0.5)
        #expect(AnnotationGeometry.fitScale(available: CGSize(width: 2000, height: 2000), width: 750, height: 1334) == 1)
        #expect(AnnotationGeometry.fitScale(available: CGSize(width: 600, height: 600), width: 2576, height: 2576) == 0.2)
        #expect(AnnotationGeometry.fitScale(available: CGSize(width: 100, height: 100), width: 2576, height: 2576) == 0.03)
    }

    @Test func fieldInputParsing() {
        #expect(CoordinateInput.parse("20") == 20)
        #expect(CoordinateInput.parse(" 1150 ") == 1150)
        #expect(CoordinateInput.parse("１２０") == 120)
        #expect(CoordinateInput.parse("710px") == 710)
        #expect(CoordinateInput.parse("-5") == -5)
        #expect(CoordinateInput.parse("abc") == nil)
        #expect(CoordinateInput.parse("") == nil)
        #expect(CoordinateInput.parse("12.5") == nil)
    }

    @Test func fieldValuesAreClamped() {
        let rect = AnnotationDraft.rect(1, x: 20, y: 1150, w: 710, h: 120)
        #expect(AnnotationEditing.setting(.w, to: 9999, of: rect, width: w, height: h).w == 730)
        #expect(AnnotationEditing.setting(.x, to: 100, of: rect, width: w, height: h).x == 40)
        #expect(AnnotationEditing.setting(.h, to: 0, of: rect, width: w, height: h).h == 1)
        #expect(AnnotationEditing.setting(.y, to: -3, of: rect, width: w, height: h).y == 0)
        let arrow = AnnotationDraft.arrow(2, x: 600, y: 760, x2: 700, y2: 1080)
        #expect(AnnotationEditing.setting(.y2, to: 5000, of: arrow, width: w, height: h).y2 == 1334)
    }

    @Test func deletingRenumbersInCreationOrder() {
        let document = ImageAnnotateSamples.document
        let deleted = AnnotationEditing.deleting(1, from: document)
        #expect(deleted.items.map(\.n) == [1, 2])
        #expect(deleted.items.map(\.kind) == [.point, .arrow])
        let (appended, n) = AnnotationEditing.appending(.point(99, x: 1, y: 2), to: deleted)
        #expect(n == 3 && appended.items.last?.n == 3)
    }

    @Test func coordinateTexts() {
        let items = ImageAnnotateSamples.document.items
        #expect(items.map(\.coordinateText) == ["x 20 · y 1150 · 710×120", "x 375 · y 330", "x 600 · y 760 → x 700 · y 1080"])
        #expect(AnnotationDraft.text(4, x: 40, y: 80, note: "這段文字").coordinateText == "x 40 · y 80")
        #expect(AnnotationKind.allCases.map(\.chipLabel) == ["RECT", "POINT", "ARROW", "TEXT"])
        #expect(AnnotationKind.allCases.map(\.title) == ["框選", "點", "箭頭", "文字"])
    }
}
