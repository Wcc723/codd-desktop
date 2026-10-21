import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A pasted or dropped image as the pasteboard had it (D4). The text view hands it over as is:
/// re-encoding a TIFF is slow (about 120 ms for a 5K screenshot), so the owner converts and saves
/// it off the main actor and inserts the path when the file exists (review concurrency-perf-3).
public enum ComposerPastedImage: Sendable, Equatable {
    case png(Data)
    /// What most apps put on the pasteboard for a copied image.
    case tiff(Data)

    /// PNG bytes: a PNG as is, a TIFF re-encoded (ImageIO, safe on any thread). nil when the data
    /// is not an image. Blocking: call it off the main actor.
    public func pngData() -> Data? {
        switch self {
        case .png(let data):
            return data.isEmpty ? nil : data
        case .tiff(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return out as Data
        }
    }
}
