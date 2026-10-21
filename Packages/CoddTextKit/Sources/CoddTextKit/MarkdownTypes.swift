import AppKit

/// Live preview hides the syntax off the caret's paragraph and draws block decorations; source
/// shows every character in one monospaced size (the app's ⌘E menu item switches).
public enum MarkdownEditorMode: Sendable {
    case livePreview, source
}

/// The caret for the doc status bar (`Ln 14, Col 38`): 1-based line and column (columns count
/// grapheme clusters, so 注 is one column), plus the selection length in UTF-16 units.
public struct MarkdownCaret: Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var selectionLength: Int

    public init(line: Int, column: Int, selectionLength: Int) {
        self.line = line
        self.column = column
        self.selectionLength = selectionLength
    }
}

/// An image the user pasted or dropped, as the pasteboard had it (never converted here: the app
/// re-encodes, hashes and writes it off the main actor, D9).
public struct MarkdownPastedImage: Sendable {
    public var data: Data
    /// A UTI such as `public.png`, `public.tiff`, `public.jpeg`, `public.heic`.
    public var typeIdentifier: String
    /// The file name when the image came as a file URL, else nil.
    public var suggestedName: String?
    /// The source file when the image came as a file URL (`data` is then memory-mapped from it,
    /// so the paste itself reads nothing up front).
    public var fileURL: URL?

    public init(data: Data, typeIdentifier: String, suggestedName: String? = nil, fileURL: URL? = nil) {
        self.data = data
        self.typeIdentifier = typeIdentifier
        self.suggestedName = suggestedName
        self.fileURL = fileURL
    }
}

/// One `codd-annotations` item drawn over an image, in ORIGINAL image pixels (origin top-left),
/// numbered `n`. `color` is one of `amber` (nil), `cyan`, `danger`, `success`, `cream`.
public enum ImageOverlayShape: Sendable, Equatable {
    case rect(n: Int, CGRect, color: String?)
    case point(n: Int, CGPoint, color: String?)
    case arrow(n: Int, from: CGPoint, to: CGPoint, color: String?)
    case text(n: Int, CGPoint, String, color: String?)

    public var number: Int {
        switch self {
        case let .rect(n, _, _), let .point(n, _, _), let .arrow(n, _, _, _), let .text(n, _, _, _): n
        }
    }

    public var colorName: String? {
        switch self {
        case let .rect(_, _, color), let .point(_, _, color), let .arrow(_, _, _, color), let .text(_, _, _, color): color
        }
    }
}

/// What the app knows about an image line's target: the editor never reads files itself. `image`
/// may be nil while the app still decodes it (the figure keeps its size; `reloadImage(path:)`
/// redraws it). `pixelSize` is the original size the overlay coordinates refer to.
public struct MarkdownImageInfo {
    public var path: String
    public var image: NSImage?
    public var pixelSize: CGSize
    public var caption: String
    public var overlay: [ImageOverlayShape]

    public init(path: String, image: NSImage?, pixelSize: CGSize, caption: String, overlay: [ImageOverlayShape] = []) {
        self.path = path
        self.image = image
        self.pixelSize = pixelSize
        self.caption = caption
        self.overlay = overlay
    }
}

/// An accessory view (the title's chips row, a figure's annotation panel) that knows its height at
/// a width. Without it the editor uses the view's Auto Layout fitting height at that width, else
/// its frame height. Call `invalidateAccessoryLayout()` when the answer changes.
@MainActor
public protocol MarkdownAccessorySizing: AnyObject {
    func markdownAccessoryHeight(forWidth width: CGFloat) -> CGFloat
}
