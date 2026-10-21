import AppKit
import CoddNotebookUI
import CoddNotes
import CoddTextKit
import ImageIO

/// What the live preview needs for each image line of a body (D9, D10): its caption (the alt
/// text) and the `codd-annotations` block that follows it. Pure, so the editor can recompute it
/// after a committed change and redraw only the figures whose overlay changed.
struct NoteFigureFacts: Equatable {
    struct Figure: Equatable {
        var alt: String
        var annotations: ImageAnnotations?
    }

    /// By the image line's path as written (`assets/<id>/9f3a1c.png`).
    var figures: [String: Figure] = [:]
    /// The image paths in body order (⌘⇧A without an image at the caret takes the first, I1b).
    var order: [String] = []

    static func parse(_ body: String) -> NoteFigureFacts {
        var facts = NoteFigureFacts()
        guard body.contains("](") else { return facts }
        for line in FencedBlocks.imageLines(in: body) where facts.figures[line.path] == nil {
            facts.figures[line.path] = Figure(alt: line.alt, annotations: nil)
            facts.order.append(line.path)
        }
        guard body.contains("codd-annotations") else { return facts }
        for block in FencedBlocks.find(info: "codd-annotations", in: body) {
            guard let path = block.imagePath, facts.figures[path] != nil,
                  let annotations = ImageAnnotations.decode(block.content) else { continue }
            facts.figures[path]?.annotations = annotations
        }
        return facts
    }

    /// The editor's overlay (original image pixels) for an image's annotations.
    static func overlay(_ annotations: ImageAnnotations?) -> [ImageOverlayShape] {
        guard let annotations else { return [] }
        return annotations.items.sorted { $0.n < $1.n }.map { item in
            let color = item.color.flatMap { $0 == "amber" ? nil : $0 }
            switch item.type {
            case .rect:
                return .rect(n: item.n, CGRect(x: item.x, y: item.y, width: item.w ?? 0, height: item.h ?? 0), color: color)
            case .point:
                return .point(n: item.n, CGPoint(x: item.x, y: item.y), color: color)
            case .arrow:
                return .arrow(n: item.n, from: CGPoint(x: item.x, y: item.y), to: CGPoint(x: item.x2 ?? item.x, y: item.y2 ?? item.y),
                              color: color)
            case .text:
                return .text(n: item.n, CGPoint(x: item.x, y: item.y), item.note, color: color)
            }
        }
    }

    /// The `.nb-annp` panel next to an annotated figure (Notebook artboard).
    static func summary(_ annotations: ImageAnnotations) -> ImageAnnotationSummaryModel {
        let items = annotations.items.sorted { $0.n < $1.n }.map { item -> ImageAnnotationSummaryItem in
            let coordinates: String
            switch item.type {
            case .rect: coordinates = "rect · x \(item.x) y \(item.y) · \(item.w ?? 0)×\(item.h ?? 0)"
            case .point: coordinates = "point · x \(item.x) y \(item.y)"
            case .arrow: coordinates = "arrow · x \(item.x) y \(item.y) → x \(item.x2 ?? item.x) y \(item.y2 ?? item.y)"
            case .text: coordinates = "text · x \(item.x) y \(item.y)"
            }
            return ImageAnnotationSummaryItem(number: item.n, note: item.note, coordinates: coordinates)
        }
        return ImageAnnotationSummaryModel(items: items, hint: sendHint(annotations.send))
    }

    /// What the AI gets for this image (D10 send options; the artboard's line for the default).
    static func sendHint(_ send: ImageAnnotations.SendOptions) -> String {
        var parts: [String] = []
        if send.original { parts.append("原圖") }
        if send.annotated { parts.append("標註後的圖") }
        if send.list { parts.append("座標清單") }
        switch parts.count {
        case 0: return "AI 不會收到這張圖"
        case 1: return "AI 會收到\(parts[0])"
        case 2: return "AI 會收到\(parts[0])與\(parts[1])"
        default: return "AI 會收到\(parts[0])、\(parts[1])與\(parts[2])"
        }
    }
}

/// A decoded image crossing from a detached decode back to the main actor.
private struct DecodedImage: @unchecked Sendable {
    var image: CGImage
}

/// Pixel sizes and display images of the open note's image files, read off the main actor (D9:
/// the editor's resolver runs during layout and must only look things up). A size is known
/// before the editor lays the note out (`prepare`), so figures never jump; the image itself
/// follows and the editor redraws that figure (`onChange`).
@MainActor
final class NoteImageCache {
    /// The note file's folder: image paths in the body are relative to it.
    private(set) var folder: URL?
    private var sizes: [String: CGSize] = [:]
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var pending: Set<String> = []
    private var generation = 0
    /// A path's size or image arrived (the editor's `reloadImage(path:)`).
    var onChange: ((String) -> Void)?

    /// Display copies are downsampled to this long edge (figures are at most 220 pt high).
    static let displayLongEdge = 1600

    /// A different note: forget everything.
    func reset(folder: URL?) {
        self.folder = folder
        sizes = [:]
        images = [:]
        missing = []
        pending = []
        generation += 1
    }

    func url(for path: String) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let folder, !path.contains("://") else { return nil }
        return URL(fileURLWithPath: folder.appendingPathComponent(path).path).standardizedFileURL
    }

    func size(for path: String) -> CGSize? { sizes[path] }
    func image(for path: String) -> NSImage? { images[path] }
    func isMissing(_ path: String) -> Bool { missing.contains(path) }

    /// A file CODD just wrote (a paste): its size is known without reading it.
    func register(path: String, size: CGSize) {
        sizes[path] = size
        missing.remove(path)
        decode(path)
    }

    /// Reads the sizes of `paths` (headers only) off the main actor, then decodes the images in
    /// the background. Returns once the sizes are known.
    func prepare(_ paths: [String]) async {
        let wanted = paths.filter { sizes[$0] == nil && !missing.contains($0) && !pending.contains($0) }
        guard !wanted.isEmpty else { return }
        let token = generation
        let jobs = wanted.compactMap { path in url(for: path).map { (path, $0) } }
        for path in wanted where !jobs.contains(where: { $0.0 == path }) { missing.insert(path) }
        pending.formUnion(jobs.map(\.0))
        let found = await Task.detached(priority: .userInitiated) { () -> [(String, CGSize?)] in
            jobs.map { ($0.0, Self.pixelSize(of: $0.1)) }
        }.value
        guard token == generation else { return }
        for (path, size) in found {
            pending.remove(path)
            if let size {
                sizes[path] = size
                decode(path)
            } else {
                missing.insert(path)
            }
        }
    }

    /// Asks for a path the resolver met before `prepare` saw it (an image line just typed).
    func request(_ path: String) {
        guard sizes[path] == nil, !missing.contains(path), !pending.contains(path) else { return }
        Task { [weak self] in
            await self?.prepare([path])
            self?.onChange?(path)
        }
    }

    private func decode(_ path: String) {
        guard images[path] == nil, let url = url(for: path) else { return }
        let token = generation
        let edge = Self.displayLongEdge
        Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { Self.decodeImage(url, longEdge: edge) }.value
            guard let self, token == self.generation, let decoded else { return }
            self.images[path] = NSImage(cgImage: decoded.image, size: .zero)
            self.onChange?(path)
        }
    }

    /// The whole image for the ImageAnnotate canvas (I1b): decoded off the main actor at its full
    /// size with the EXIF rotation applied, so canvas pixels are the file's upright pixels.
    static func fullImage(at url: URL) async -> CGImage? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            guard let size = pixelSize(of: url) else { return nil }
            return decodeImage(url, longEdge: Int(max(size.width, size.height)))
        }.value
        return decoded?.image
    }

    /// A small upright copy (the drawer's card thumbnails, I2b), decoded off the main actor.
    static func thumbnail(at url: URL, longEdge: Int) async -> CGImage? {
        await Task.detached(priority: .utility) { decodeImage(url, longEdge: longEdge) }.value?.image
    }

    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5–8 swap the axes (C1 writes upright files; others may not).
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    fileprivate nonisolated static func decodeImage(_ url: URL, longEdge: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedImage(image: image)
    }
}

/// C4 asks its accessories for their height at a width (C7's views answer through `height(for:)`).
extension NoteChipsRowView: @retroactive MarkdownAccessorySizing {
    public func markdownAccessoryHeight(forWidth width: CGFloat) -> CGFloat { height(for: width) }
}

extension ImageAnnotationSummaryView: @retroactive MarkdownAccessorySizing {
    public func markdownAccessoryHeight(forWidth width: CGFloat) -> CGFloat { height(for: width) }
}
