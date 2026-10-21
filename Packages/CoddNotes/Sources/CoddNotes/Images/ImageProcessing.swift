import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO work for pasted images (D9) and the images the AI receives (D17). No AppKit.
enum ImageProcessing {
    struct Facts {
        var type: String
        var width: Int
        var height: Int
        var hasAlpha: Bool
        var orientation: Int
    }

    struct Processed {
        var data: Data
        var ext: String
        var width: Int
        var height: Int
        var resized: Bool
        /// The written bytes differ from the input (re-encoded or resized).
        var changed: Bool
        var originalExt: String
    }

    static let png = UTType.png.identifier
    static let jpeg = UTType.jpeg.identifier
    static let gif = UTType.gif.identifier
    static let webp = UTType.webP.identifier
    static let heic = UTType.heic.identifier
    static let heif = UTType.heif.identifier
    static let tiff = UTType.tiff.identifier

    static func ext(for type: String) -> String {
        switch type {
        case png: "png"
        case jpeg: "jpg"
        case gif: "gif"
        case webp: "webp"
        case heic: "heic"
        case heif: "heif"
        case tiff: "tiff"
        default: UTType(type)?.preferredFilenameExtension ?? "img"
        }
    }

    static func mimeType(forExtension e: String) -> String {
        switch e.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }

    static func facts(_ source: CGImageSource) -> Facts? {
        guard let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let alpha = (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Width / height as displayed (EXIF orientations 5–8 swap them).
        let swapped = (5...8).contains(orientation)
        return Facts(type: type, width: swapped ? h : w, height: swapped ? w : h, hasAlpha: alpha, orientation: orientation)
    }

    static func pixelSize(of url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let f = facts(src) else { return .zero }
        return CGSize(width: f.width, height: f.height)
    }

    /// D9: keep PNG / JPEG / GIF / WebP as they are; re-encode TIFF (→ PNG), HEIC / HEIF (→ JPEG,
    /// or PNG with alpha) and anything else ImageIO decodes (→ PNG); downscale to `longEdge` when
    /// larger (written as PNG, JPEG stays JPEG at quality 0.9); apply an EXIF rotation so the
    /// pixels match what the user sees (annotation coordinates are in these pixels).
    static func process(_ data: Data, longEdge: Int?) throws -> Processed {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let f = facts(src) else { throw NotesError.io("無法讀取這張圖片") }
        let originalExt = ext(for: f.type)
        let kept = [png, jpeg, gif, webp].contains(f.type)
        let needsResize = longEdge.map { max(f.width, f.height) > $0 } ?? false
        if kept, !needsResize, f.orientation == 1 {
            return Processed(data: data, ext: originalExt, width: f.width, height: f.height, resized: false, changed: false,
                             originalExt: originalExt)
        }
        let target = needsResize ? longEdge! : max(f.width, f.height)
        guard let image = render(src, facts: f, longEdge: target) else { throw NotesError.io("無法轉換這張圖片") }
        let outType: String
        if f.type == jpeg || ((f.type == heic || f.type == heif) && !f.hasAlpha) {
            outType = jpeg
        } else {
            outType = png
        }
        guard let out = encode(image, type: outType, quality: 0.9) else { throw NotesError.io("無法寫入這張圖片") }
        return Processed(data: out, ext: ext(for: outType), width: image.width, height: image.height, resized: needsResize,
                         changed: true, originalExt: originalExt)
    }

    /// The first frame, oriented, scaled so its long edge is `longEdge`, drawn with high quality.
    static func render(_ src: CGImageSource, facts f: Facts, longEdge: Int) -> CGImage? {
        guard let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let scale = Double(longEdge) / Double(max(f.width, f.height))
        let w = max(1, Int((Double(f.width) * min(1, scale)).rounded()))
        let h = max(1, Int((Double(f.height) * min(1, scale)).rounded()))
        let alpha = f.hasAlpha || raw.alphaInfo != .none && raw.alphaInfo != .noneSkipLast && raw.alphaInfo != .noneSkipFirst
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        // EXIF orientation → a transform in the bottom-left-origin context.
        let W = CGFloat(w), H = CGFloat(h)
        switch f.orientation {
        case 2: ctx.translateBy(x: W, y: 0); ctx.scaleBy(x: -1, y: 1)
        case 3: ctx.translateBy(x: W, y: H); ctx.rotate(by: .pi)
        case 4: ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
        case 5: ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: H); ctx.rotate(by: -.pi / 2)
        case 6: ctx.translateBy(x: 0, y: H); ctx.rotate(by: -.pi / 2)
        case 7: ctx.translateBy(x: W, y: 0); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: 0, y: H); ctx.rotate(by: -.pi / 2)
        case 8: ctx.translateBy(x: W, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        let swapped = (5...8).contains(f.orientation)
        let drawRect = swapped ? CGRect(x: 0, y: 0, width: H, height: W) : CGRect(x: 0, y: 0, width: W, height: H)
        ctx.draw(raw, in: drawRect)
        return ctx.makeImage()
    }

    static func encode(_ image: CGImage, type: String, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if type == jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// An image for the AI (D17): long edge ≤ `maxLongEdge`, bytes ≤ `maxBytes`, PNG / JPEG / GIF /
    /// WebP only. An image that already fits goes unchanged (a GIF as its first frame in PNG);
    /// otherwise PNG when it has alpha and fits, else JPEG with falling quality and size.
    static func aiImage(_ url: URL, maxLongEdge: Int, maxBytes: Int) throws -> (Data, String, CGSize) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NotesError.io("無法讀取圖片 \(url.lastPathComponent)")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let f = facts(src) else { throw NotesError.io("無法讀取圖片 \(url.lastPathComponent)") }
        let fits = max(f.width, f.height) <= maxLongEdge && data.count <= maxBytes && f.orientation == 1
        if fits, [png, jpeg, webp].contains(f.type) {
            return (data, f.type == png ? "image/png" : (f.type == jpeg ? "image/jpeg" : "image/webp"),
                    CGSize(width: f.width, height: f.height))
        }
        var edge = min(maxLongEdge, max(f.width, f.height))
        for _ in 0..<8 {
            guard let image = render(src, facts: f, longEdge: edge) else { break }
            let size = CGSize(width: image.width, height: image.height)
            if f.hasAlpha || f.type == png || f.type == gif, let p = encode(image, type: png, quality: 1), p.count <= maxBytes {
                return (p, "image/png", size)
            }
            for q in [0.85, 0.75, 0.6, 0.45] {
                if let j = encode(flattened(image) ?? image, type: jpeg, quality: q), j.count <= maxBytes {
                    return (j, "image/jpeg", size)
                }
            }
            edge = Int(Double(edge) * 0.75)
            if edge < 64 { break }
        }
        throw NotesError.tooLarge("圖片無法壓到 \(maxBytes / 1000) KB 以下")
    }

    /// The image on white (JPEG has no alpha).
    static func flattened(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
