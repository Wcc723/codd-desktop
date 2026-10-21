import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CoddNotes

@Suite struct AssetTests {
    func library() async throws -> (TempRoot, NotesLibrary, NoteID) {
        let root = TempRoot()
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let doc = try await lib.create(NewNote(title: "截圖筆記", body: "# 截圖筆記\n"))
        return (root, lib, doc.metadata.id)
    }

    @Test func resizeKeepOriginalDedupe() async throws {
        let (root, lib, id) = try await library()
        let big = makeImage(width: 4000, height: 3000)
        let ref = try await lib.saveAsset(big, typeHint: "public.png", for: id, resizeLongEdge: 2576, keepOriginal: true)
        #expect(ref.resized && !ref.reused)
        #expect(ref.pixelSize == CGSize(width: 2576, height: 1932))
        #expect(ref.relativePath.hasPrefix("assets/\(id.rawValue)/") && ref.relativePath.hasSuffix(".png"))
        #expect(ref.markdownPath == ref.relativePath)
        let stored = try Data(contentsOf: root.notes.appendingPathComponent(ref.relativePath))
        #expect(pixelSize(stored) == CGSize(width: 2576, height: 1932))
        #expect(imageType(stored) == UTType.png.identifier)
        let hash6 = String(Hashing.sha256Hex(stored).prefix(6))
        #expect(ref.relativePath == "assets/\(id.rawValue)/\(hash6).png")
        let orig = try #require(ref.originalPath)
        #expect(orig == "assets/\(id.rawValue)/\(hash6).orig.png")
        #expect(try Data(contentsOf: root.notes.appendingPathComponent(orig)) == big)
        let mode = try FileManager.default.attributesOfItem(atPath: root.notes.appendingPathComponent(ref.relativePath).path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // The same image again is reused.
        let again = try await lib.saveAsset(big, typeHint: nil, for: id, resizeLongEdge: 2576, keepOriginal: true)
        #expect(again.reused && again.relativePath == ref.relativePath)
        // Without resizing, a PNG is stored byte for byte.
        let small = makeImage(width: 300, height: 200)
        let s = try await lib.saveAsset(small, typeHint: nil, for: id, resizeLongEdge: 2576, keepOriginal: true)
        #expect(!s.resized && s.originalPath == nil)
        #expect(try Data(contentsOf: root.notes.appendingPathComponent(s.relativePath)) == small)
        #expect(try await lib.summary(id).assetCount == 2)
        await lib.close()
    }

    @Test func collisionLengthensTheName() async throws {
        let (root, lib, id) = try await library()
        let img = makeImage(width: 64, height: 48)
        let hash = Hashing.sha256Hex(img)
        let dir = root.notes.appendingPathComponent("assets/\(id.rawValue)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("other bytes".utf8).write(to: dir.appendingPathComponent("\(hash.prefix(6)).png"))
        let ref = try await lib.saveAsset(img, typeHint: nil, for: id, resizeLongEdge: nil, keepOriginal: false)
        #expect(ref.relativePath == "assets/\(id.rawValue)/\(hash.prefix(8)).png")
        await lib.close()
    }

    @Test func refusalsAndFormats() async throws {
        let (root, lib, id) = try await library()
        await #expect(throws: NotesError.tooLarge("圖片超過 20 MiB，無法貼上")) {
            _ = try await lib.saveAsset(Data(count: 20 * 1024 * 1024 + 1), typeHint: nil, for: id, resizeLongEdge: 2576, keepOriginal: false)
        }
        await #expect(throws: NotesError.self) {
            _ = try await lib.saveAsset(Data("not an image".utf8), typeHint: nil, for: id, resizeLongEdge: 2576, keepOriginal: false)
        }
        // HEIC → JPEG (Claude reads PNG / JPEG / GIF / WebP only).
        let heic = makeImage(width: 640, height: 480, type: UTType.heic.identifier)
        #expect(imageType(heic) == UTType.heic.identifier)
        let h = try await lib.saveAsset(heic, typeHint: "public.heic", for: id, resizeLongEdge: 2576, keepOriginal: true)
        #expect(h.relativePath.hasSuffix(".jpg"))
        #expect(imageType(try Data(contentsOf: root.notes.appendingPathComponent(h.relativePath))) == UTType.jpeg.identifier)
        #expect(h.originalPath?.hasSuffix(".orig.heic") == true)
        // TIFF → PNG.
        let tiff = makeImage(width: 100, height: 80, type: UTType.tiff.identifier)
        let t = try await lib.saveAsset(tiff, typeHint: nil, for: id, resizeLongEdge: 2576, keepOriginal: false)
        #expect(t.relativePath.hasSuffix(".png"))
        // A large JPEG stays JPEG when downscaled.
        let jpeg = makeImage(width: 3000, height: 1000, type: UTType.jpeg.identifier)
        let j = try await lib.saveAsset(jpeg, typeHint: nil, for: id, resizeLongEdge: 2576, keepOriginal: false)
        #expect(j.relativePath.hasSuffix(".jpg") && j.resized && j.pixelSize == CGSize(width: 2576, height: 859))
        await lib.close()
    }

    @Test func subFolderNoteLinkAndListing() async throws {
        let root = TempRoot()
        root.write("sub/n.md", "---\nid: sub-note\n---\n# 子資料夾\n\n![a](../assets/sub-note/PLACEHOLDER)\n")
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let ref = try await lib.saveAsset(makeImage(width: 50, height: 50), typeHint: nil, for: .of("sub-note"), resizeLongEdge: 2576, keepOriginal: false)
        #expect(ref.markdownPath == "../" + ref.relativePath)
        let name = (ref.relativePath as NSString).lastPathComponent
        let doc = try await lib.document(.of("sub-note"))
        _ = try await lib.save(.of("sub-note"), body: doc.body.replacingOccurrences(of: "PLACEHOLDER", with: name), basedOn: doc.contentHash)
        let list = try await lib.assets(of: .of("sub-note"))
        #expect(list.count == 1 && list[0].referenced && !list[0].isOriginalCopy && list[0].pixelSize == CGSize(width: 50, height: 50))
        await lib.close()
    }

    @Test func aiImageFitsTheBudget() async throws {
        let root = TempRoot()
        let url = root.base.appendingPathComponent("big.png")
        try makeImage(width: 2576, height: 1932).write(to: url)
        let lib = makeLibrary(root)
        let (data, mime, size) = try await lib.aiImage(url, maxLongEdge: 1568, maxBytes: 900_000)
        #expect(max(size.width, size.height) <= 1568)
        #expect(data.count <= 900_000)
        #expect(["image/png", "image/jpeg"].contains(mime))
        #expect(pixelSize(data) == size)
        // A small PNG goes unchanged.
        let small = root.base.appendingPathComponent("small.png")
        let smallData = makeImage(width: 300, height: 200)
        try smallData.write(to: small)
        let (d2, m2, _) = try await lib.aiImage(small, maxLongEdge: 1568, maxBytes: 900_000)
        #expect(d2 == smallData && m2 == "image/png")
        // Noise does not fit as PNG: JPEG under the budget.
        let noisy = root.base.appendingPathComponent("noise.png")
        try makeNoise(width: 1800, height: 1400).write(to: noisy)
        let (d3, m3, s3) = try await lib.aiImage(noisy, maxLongEdge: 1568, maxBytes: 900_000)
        #expect(d3.count <= 900_000 && m3 == "image/jpeg" && s3.width <= 1568 && pixelSize(d3) == s3)
    }
}
