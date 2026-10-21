import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CoddNotes

@Suite struct AnnotationTests {
    static let withText = """
    {"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[{"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},{"n":2,"type":"point","x":375,"y":330,"note":"時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},{"n":3,"type":"arrow","x":600,"y":760,"x2":700,"y2":1080,"note":"打卡紀錄卡片離按鈕太近，間距加到 16px"},{"n":4,"type":"text","x":40,"y":80,"note":"這段文字直接畫在圖上","color":"cyan"}],"send":{"original":false,"annotated":true,"list":true}}
    """

    @Test func codecRoundTrip() throws {
        let a = try #require(ImageAnnotations.decode(specAnnotationsJSON))
        #expect(a.size == .init(width: 750, height: 1334))
        #expect(a.items.map(\.type) == [.rect, .point, .arrow])
        #expect(a.items[2].x2 == 700 && a.items[2].y2 == 1080)
        #expect(a.send == .init(original: false, annotated: true, list: true))
        #expect(a.encoded() == specAnnotationsJSON)
        let b = try #require(ImageAnnotations.decode(Self.withText))
        #expect(b.items[3].color == "cyan" && b.items[3].type == .text)
        #expect(b.encoded() == Self.withText)
        // Pretty-printed input, unknown keys at every level, floats rounded.
        let messy = """
        {
          "send": {"list": false, "future": 1},
          "items": [{"type": "point", "n": 2, "x": 10.6, "y": 20, "note": "a", "z": [1, 2]}],
          "v": 1, "image": "x.png", "size": [10, 20], "extra": {"k": "中文"}
        }
        """
        let c = try #require(ImageAnnotations.decode(messy))
        #expect(c.items[0].x == 11)
        #expect(c.encoded() == "{\"v\":1,\"image\":\"x.png\",\"size\":[10,20],\"items\":[{\"n\":2,\"type\":\"point\",\"x\":11,\"y\":20,\"note\":\"a\",\"z\":[1,2]}],\"send\":{\"original\":false,\"annotated\":true,\"list\":false,\"future\":1},\"extra\":{\"k\":\"中文\"}}")
        #expect(ImageAnnotations.decode("[1,2]") == nil)
        #expect(ImageAnnotations.decode("{\"items\":[{\"type\":\"circle\"}]}") == nil)
    }

    @Test func formattedListMatchesSection37() throws {
        let a = try #require(ImageAnnotations.decode(Self.withText))
        #expect(a.formattedList() == """
            annotations（原圖像素，左上為原點）:
              1 rect  x=20 y=1150 w=710 h=120  上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)
              2 point x=375 y=330  時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px
              3 arrow 600,760 → 700,1080  打卡紀錄卡片離按鈕太近，間距加到 16px
              4 text  x=40 y=80  這段文字直接畫在圖上
            """)
    }

    @Test func imagePreviewText() throws {
        let a = try #require(ImageAnnotations.decode(specAnnotationsJSON))
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/no-such-dir/cache/annotated", isDirectory: true)
        let image = URL(fileURLWithPath: NSHomeDirectory() + "/no-such-dir/notes/assets/rwd-punch-k7x2/9f3a1c.png")
        let copy = HomePath.abbreviate(NoteAIText.annotatedURL(for: image, in: folder).path)
        #expect(copy.hasPrefix("~/no-such-dir/cache/annotated/") && copy.hasSuffix("-9f3a1c.annotated.png"))
        #expect(NoteAIText.imagePreview(image: image, annotations: a, annotatedFolder: folder) == """
            [image] \(copy) (750×1334)
            annotations（原圖像素，左上為原點）:
              1 rect  x=20 y=1150 w=710 h=120  上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)
              2 point x=375 y=330  時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px
              3 arrow 600,760 → 700,1080  打卡紀錄卡片離按鈕太近，間距加到 16px
            """)
    }

    @Test func fencedBlocks() throws {
        let body = Frontmatter.split(specNote1()).body
        let blocks = FencedBlocks.find(info: "codd-annotations", in: body)
        #expect(blocks.count == 1)
        let b = try #require(blocks.first)
        #expect(b.imagePath == "assets/rwd-punch-k7x2/9f3a1c.png")
        #expect(b.content == specAnnotationsJSON)
        #expect((body as NSString).substring(with: b.range).hasPrefix("```codd-annotations\n"))
        let imageLine = try #require(b.imageLine)
        #expect(FencedBlocks.imageLines(in: body).map(\.line) == [imageLine])

        // Replace, remove, insert.
        let replaced = FencedBlocks.replacingBlock(after: imageLine, info: "codd-annotations", with: "{\"v\":1}", in: body)
        #expect(replaced == body.replacingOccurrences(of: specAnnotationsJSON, with: "{\"v\":1}"))
        let removed = FencedBlocks.replacingBlock(after: imageLine, info: "codd-annotations", with: nil, in: body)
        #expect(!removed.contains("codd-annotations"))
        #expect(removed == Frontmatter.split(specNote1(withAnnotations: false)).body)
        let inserted = FencedBlocks.replacingBlock(after: imageLine, info: "codd-annotations", with: specAnnotationsJSON, in: removed)
        #expect(inserted == body)
        // A block not after an image is a plain code block.
        #expect(FencedBlocks.find(info: "css", in: body).first?.imageLine == nil)
    }

    @Test func rendererBurnsIn() throws {
        let root = TempRoot()
        let url = root.base.appendingPathComponent("phone.png")
        try makeImage(width: 750, height: 1334).write(to: url)
        let a = try #require(ImageAnnotations.decode(Self.withText))
        let png = try AnnotatedImageRenderer.render(image: url, annotations: a)
        #expect(pixelSize(png) == CGSize(width: 750, height: 1334))
        let (r, g, b) = pixel(png, x: 375, y: 1150)  // on box 1's top edge
        #expect(r > 220 && g > 150 && g < 210 && b < 120)
        // Inside the box (10 % amber over the image) is not the pure stroke color.
        let inside = pixel(png, x: 375, y: 1210)
        #expect(!(inside.0 > 220 && inside.2 < 120))
        // Pin 2 is drawn at the point.
        let pin = pixel(png, x: 375 - 10, y: 330 - 10)
        #expect(pin.0 > 200 && pin.2 < 140)
    }

    @Test func annotatedCopyIsCached() async throws {
        let root = TempRoot()
        root.write("n.md", specNote1())
        let dir = root.notes.appendingPathComponent("assets/rwd-punch-k7x2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeImage(width: 750, height: 1334).write(to: dir.appendingPathComponent("9f3a1c.png"))
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let id = NoteID.of("rwd-punch-k7x2")
        let u = try #require(try await lib.annotatedImage(for: id, image: "assets/rwd-punch-k7x2/9f3a1c.png"))
        #expect(u.lastPathComponent.hasSuffix("-9f3a1c.annotated.png") && u.deletingLastPathComponent().path == root.annotated.path)
        let first = try Data(contentsOf: u)
        let m1 = FileFacts.info(u.path)!.mtime
        try await Task.sleep(for: .milliseconds(20))
        _ = try await lib.annotatedImage(for: id, image: "9f3a1c.png")
        #expect(FileFacts.info(u.path)!.mtime == m1)
        // Changing the block regenerates it.
        let doc = try await lib.document(id)
        _ = try await lib.save(id, body: doc.body.replacingOccurrences(of: "\"x\":20,\"y\":1150", with: "\"x\":30,\"y\":1100"), basedOn: doc.contentHash)
        _ = try await lib.annotatedImage(for: id, image: "assets/rwd-punch-k7x2/9f3a1c.png")
        #expect(try Data(contentsOf: u) != first)
        // The copy is derived data in the cache folder: never one of the note's assets.
        let assets = try await lib.assets(of: id)
        #expect(assets.count == 1 && assets.allSatisfy(\.referenced) && assets.first?.url.lastPathComponent == "9f3a1c.png")
        #expect(try await lib.summary(id).assetCount == 1)
        // No block → nil.
        let plain = specNote1(withAnnotations: false)
        _ = try await lib.save(id, body: Frontmatter.split(plain).body, basedOn: nil)
        #expect(try await lib.annotatedImage(for: id, image: "assets/rwd-punch-k7x2/9f3a1c.png") == nil)
        await lib.close()
    }

    /// Post-M4: stale renders are collected at open: the source image gone (the note trashed or
    /// purged moved its assets), no source attribute (not CODD's), a temp file left by a crash.
    @Test func staleAnnotatedCopiesAreCollectedAtOpen() async throws {
        let root = TempRoot()
        root.write("n.md", specNote1())
        let dir = root.notes.appendingPathComponent("assets/rwd-punch-k7x2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeImage(width: 750, height: 1334).write(to: dir.appendingPathComponent("9f3a1c.png"))
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let id = NoteID.of("rwd-punch-k7x2")
        let u = try #require(try await lib.annotatedImage(for: id, image: "assets/rwd-punch-k7x2/9f3a1c.png"))
        await lib.close()
        try Data("x".utf8).write(to: root.annotated.appendingPathComponent("foreign.png"))
        try Data("x".utf8).write(to: root.annotated.appendingPathComponent("abc-9f3a1c.annotated.png.1.2.tmp"))
        // Reopened with the image in place: only the copy stays.
        let again = makeLibrary(root)
        _ = try await again.open()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.annotated.path) == [u.lastPathComponent])
        await again.close()
        // The image gone: the copy goes at the next open.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("9f3a1c.png"))
        let third = makeLibrary(root)
        _ = try await third.open()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.annotated.path).isEmpty)
        await third.close()
    }

    func pixel(_ png: Data, x: Int, y: Int) -> (Int, Int, Int) {
        let src = CGImageSourceCreateWithData(png as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that image pixel (x, y) (top-left origin) lands on the 1×1 context.
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
    }
}
