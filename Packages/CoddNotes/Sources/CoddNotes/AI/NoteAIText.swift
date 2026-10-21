import CoreGraphics
import Foundation

/// The text an AI receives for a note (§3.7): `notes_read`, prompt expansion (D19), 插入全文 / 送出.
public enum NoteAIText {
    public struct Rendered: Sendable {
        /// This page of the text.
        public var text: String
        /// More text follows (`nextOffset`).
        public var truncated: Bool
        public var nextOffset: Int?
        /// The images whose `[image]` lines are on this page, with what to attach.
        public var images: [ImagePart]
        /// Character offset of this page and the whole text's length (for `（第 n–m 字，共 N 字…）`).
        public var offset: Int
        public var totalChars: Int

        public init(text: String, truncated: Bool, nextOffset: Int?, images: [ImagePart], offset: Int = 0, totalChars: Int = 0) {
            self.text = text
            self.truncated = truncated
            self.nextOffset = nextOffset
            self.images = images
            self.offset = offset
            self.totalChars = totalChars
        }
    }

    public struct ImagePart: Sendable, Equatable {
        public var original: URL
        /// The annotated copy's location (it exists once `NotesLibrary.annotatedImage` made it).
        public var annotated: URL?
        public var pixelSize: CGSize
        public var includeOriginal: Bool
        public var includeAnnotated: Bool

        public init(original: URL, annotated: URL?, pixelSize: CGSize, includeOriginal: Bool, includeAnnotated: Bool) {
            self.original = original
            self.annotated = annotated
            self.pixelSize = pixelSize
            self.includeOriginal = includeOriginal
            self.includeAnnotated = includeAnnotated
        }
    }

    public struct Expansion: Sendable, Equatable {
        /// `hookSpecificOutput.additionalContext`; nil when no reference was found.
        public var context: String?
        /// The terminal line (`codd：已展開 codd://note/<id>（<title> · n 張圖片）`).
        public var systemMessage: String?
        /// Expanded notes, in prompt order.
        public var noteIDs: [NoteID]
        /// One line per reference that was not expanded (an OFF note's line never names it).
        public var refused: [String]
        /// Images per expanded note.
        public var imageCounts: [NoteID: Int]

        public init(context: String?, systemMessage: String?, noteIDs: [NoteID], refused: [String], imageCounts: [NoteID: Int] = [:]) {
            self.context = context
            self.systemMessage = systemMessage
            self.noteIDs = noteIDs
            self.refused = refused
            self.imageCounts = imageCounts
        }
    }

    /// Which images a note links may reach an AI caller (CODE-4): their pixels in `notes_read`, an
    /// annotated copy burned from them, the size on their `[image]` line. A note's text can name
    /// any path (`/…`, `~/…`, `../…`), and an AI may have written that text.
    public enum ImageScope: Sendable, Equatable {
        /// Every image, as the user's own 插入全文 / 送出 and condense input show them.
        case unrestricted
        /// Only an image whose real path (symlinks and `..` resolved) is a regular file inside the
        /// notes root or one of `folders` (a CODD session's project folder). Any other image keeps
        /// its `[image]` line with ``notAttachedNote`` instead of its size; nothing is read from it.
        case ai(folders: [String])

        /// The notes root only: external clients, a condense run's own `notes_read` calls (its
        /// transient caller has no folder), a session without a folder. The condense input CODD
        /// writes to that run's stdin is the user's own action and stays ``unrestricted``.
        public static let notesRoot = ImageScope.ai(folders: [])
    }

    /// Where one linked image stands for a scope.
    enum ImagePlace: Equatable {
        /// It may be measured, attached and burned into an annotated copy.
        case allowed
        /// Inside the scope but not a regular file (missing, a folder, a FIFO).
        case missing
        /// Outside the scope.
        case outside
    }

    /// The `[image]` line's tail for an image outside an AI caller's scope.
    public static let notAttachedNote = "（未附上：圖片不在筆記本或專案資料夾內）"
    static let missingNote = "（找不到圖片）"

    public static let defaultPage = 12_000
    public static let expansionHeader = "CODD 已展開使用者提到的筆記（不需要再呼叫 notes_read）："

    /// The full §3.7 text of a note, paged by characters from `offset` (`maxChars` per page; a page
    /// ends at a line break when one is within its last 20 %). `links` names linked sessions /
    /// projects (nil: the raw ids / paths). Image sizes are read from the files; annotated copies
    /// are named in `annotatedFolder` (``annotatedURL(for:in:)``). `imageScope` limits the images an
    /// AI caller receives (``ImageScope``).
    public static func render(
        _ document: NoteDocument, root: URL, annotatedFolder: URL,
        links: (sessionTitle: (String) -> String?, project: (String) -> String?)?,
        offset: Int, maxChars: Int, timeZone: TimeZone = .current, imageScope: ImageScope = .unrestricted
    ) -> Rendered {
        let (full, imageMarks) = fullText(document, root: root, annotatedFolder: annotatedFolder, links: links, timeZone: timeZone,
                                          imageScope: imageScope)
        return page(full, imageMarks: imageMarks, offset: offset, maxChars: maxChars)
    }

    static func page(_ full: String, imageMarks: [(Int, ImagePart)], offset: Int, maxChars: Int) -> Rendered {
        let chars = Array(full)
        let total = chars.count
        let start = min(max(0, offset), total)
        let size = max(1, maxChars)
        var end = min(total, start + size)
        if end < total {
            // Prefer to end the page after a line break in its last fifth.
            let floor = start + size * 4 / 5
            var k = end - 1
            while k > floor, chars[k] != "\n" { k -= 1 }
            if k > floor { end = k + 1 }
        }
        let text = String(chars[start..<end])
        let images = imageMarks.filter { $0.0 >= start && $0.0 < end }.map(\.1)
        return Rendered(text: text, truncated: end < total, nextOffset: end < total ? end : nil, images: images,
                        offset: start, totalChars: total)
    }

    /// The whole text plus, for each image, the character offset of its first `[image]` / list line.
    /// An image `imageScope` withholds has its line but no ``ImagePart``.
    static func fullText(
        _ document: NoteDocument, root: URL, annotatedFolder: URL,
        links: (sessionTitle: (String) -> String?, project: (String) -> String?)?, timeZone: TimeZone,
        imageScope: ImageScope = .unrestricted
    ) -> (String, [(Int, ImagePart)]) {
        let meta = document.metadata
        let cal = LocalCalendar(timeZone: timeZone)
        var out: [String] = ["# \(meta.title)"]
        var header = "\(meta.id.uri) · \(meta.kind.rawValue.uppercased())"
        if !meta.tags.isEmpty { header += " · " + meta.tags.map { "#\($0)" }.joined(separator: " ") }
        header += " · updated \(cal.dateTime(meta.updated)) · AI \(meta.ai.rawValue.uppercased())"
        switch meta.state {
        case .archived(let at, _): header += " · ARCHIVED \(cal.day(at))"
        case .trashed: header += " · TRASHED"
        case .active: break
        }
        out.append(header)
        out.append("file: \(document.fileURL.path)")
        var linkParts: [String] = []
        for s in meta.links.sessions {
            linkParts.append("session " + (links?.sessionTitle(s) ?? s))
        }
        for p in meta.links.projects {
            linkParts.append("project " + (links?.project(p) ?? p))
        }
        if !linkParts.isEmpty { out.append("links: " + linkParts.joined(separator: " · ")) }
        out.append("")

        let lines = BodyLines.split(document.body)
        let h1 = MarkdownText.firstH1(lines)?.line
        let noteDir = document.fileURL.deletingLastPathComponent()
        let blocks = FencedBlocks.find(info: "codd-annotations", in: document.body)
        let blockByImageLine = Dictionary(blocks.compactMap { b in b.imageLine.map { ($0, b) } }, uniquingKeysWith: { a, _ in a })
        var skip = Set<Int>()
        for b in blocks where b.imageLine != nil { skip.formUnion(b.startLine...b.endLine) }
        var imageMarks: [(Int, ImagePart)] = []
        var lengthSoFar = out.reduce(0) { $0 + $1.count + 1 }
        var bodyOut: [String] = []
        var k = 0
        var fence: Fence?
        // Skip the H1 and the blank lines right after it (the header replaces them).
        var startLine = 0
        if let h1, lines[0..<h1].allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            startLine = h1 + 1
            while startLine < lines.count, lines[startLine].text.trimmingCharacters(in: .whitespaces).isEmpty { startLine += 1 }
        }
        k = startLine
        while k < lines.count {
            let line = lines[k].text
            defer { k += 1 }
            if skip.contains(k) { continue }
            if let f = fence {
                if f.closes(line) { fence = nil }
                bodyOut.append(line)
                lengthSoFar += line.count + 1
                continue
            }
            if let f = Fence(opening: line) {
                fence = f
                bodyOut.append(line)
                lengthSoFar += line.count + 1
                continue
            }
            if k == h1 { continue }
            if let (_, path) = FencedBlocks.parseImage(line), let url = resolve(path, noteDir: noteDir, root: root) {
                let annotations = blockByImageLine[k].flatMap { ImageAnnotations.decode($0.content) }
                let emitted: [String]
                switch imageScope.place(of: url, root: root) {
                case .allowed:
                    let size = ImageProcessing.pixelSize(of: url)
                    let dims = size == .zero ? missingNote : "(\(Int(size.width))×\(Int(size.height)))"
                    let (lines, part) = imageLines(original: url, pixelSize: size, annotations: annotations, dims: dims,
                                                   annotatedFolder: annotatedFolder)
                    imageMarks.append((lengthSoFar, part))
                    emitted = lines
                case .missing:
                    emitted = withheldLines(url, annotations: annotations, note: missingNote)
                case .outside:
                    emitted = withheldLines(url, annotations: annotations, note: notAttachedNote)
                }
                for e in emitted {
                    bodyOut.append(e)
                    lengthSoFar += e.count + 1
                }
                continue
            }
            let rewritten = rewriteLinks(line, noteDir: noteDir, root: root)
            bodyOut.append(rewritten)
            lengthSoFar += rewritten.count + 1
        }
        while bodyOut.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { bodyOut.removeLast() }
        let text = (out + bodyOut).joined(separator: "\n") + "\n"
        return (text, imageMarks)
    }

    /// The §3.7 lines of one image: `[image] <path> (<w>×<h>)` for the original and / or the
    /// annotated copy and the coordinate list, as the image's send options say.
    static func imageLines(original url: URL, pixelSize size: CGSize, annotations: ImageAnnotations?, dims: String,
                           annotatedFolder: URL, displayPath: (String) -> String = { $0 }) -> ([String], ImagePart) {
        var part = ImagePart(original: url, annotated: nil, pixelSize: size, includeOriginal: true, includeAnnotated: false)
        var emitted: [String] = []
        if let a = annotations {
            let hasItems = !a.items.isEmpty
            let annotatedURL = annotatedURL(for: url, in: annotatedFolder)
            part.annotated = hasItems ? annotatedURL : nil
            part.includeOriginal = a.send.original || !hasItems
            part.includeAnnotated = a.send.annotated && hasItems
            if part.includeOriginal { emitted.append("[image] \(displayPath(url.path)) \(dims)") }
            if part.includeAnnotated { emitted.append("[image] \(displayPath(annotatedURL.path)) \(dims)") }
            if a.send.list, hasItems { emitted.append(a.formattedList()) }
        } else {
            emitted.append("[image] \(displayPath(url.path)) \(dims)")
        }
        return (emitted, part)
    }

    /// The lines of an image an AI caller does not receive: its path with `note` (never its size)
    /// and the coordinate list when asked, which is the note's own text, not the file's.
    static func withheldLines(_ url: URL, annotations: ImageAnnotations?, note: String) -> [String] {
        var lines = ["[image] \(url.path) \(note)"]
        if let a = annotations, a.send.list, !a.items.isEmpty { lines.append(a.formattedList()) }
        return lines
    }

    /// The ImageAnnotate screen's `AI 會收到` preview for one image: exactly the lines the AI text
    /// carries for it, with the home folder shown as `~` when `abbreviateHome` (display only).
    /// `annotatedFolder` is where the library keeps annotated copies (`NotesLibrary.annotatedFolder`).
    public static func imagePreview(image: URL, annotations: ImageAnnotations?, annotatedFolder: URL, abbreviateHome: Bool = true) -> String {
        var size = ImageProcessing.pixelSize(of: image)
        if size == .zero, let a = annotations { size = CGSize(width: a.size.width, height: a.size.height) }
        let dims = size == .zero ? "（找不到圖片）" : "(\(Int(size.width))×\(Int(size.height)))"
        let (lines, _) = imageLines(original: image, pixelSize: size, annotations: annotations, dims: dims,
                                    annotatedFolder: annotatedFolder, displayPath: abbreviateHome ? HomePath.abbreviate : { $0 })
        return lines.joined(separator: "\n")
    }

    /// Where the burned-in copy of `image` lives (D10, DERIVED): always in `folder` (the app passes
    /// `<dataRoot>/cache/annotated`), never beside the image and never in the notes folder, as
    /// `<12 hex of the SHA-256 of the image's standardized path>-<stem>.annotated.png`. The hash
    /// keeps copies of images with the same name apart; the stem (cut to 120 UTF-8 bytes, so the
    /// name stays within NAME_MAX) keeps the folder readable.
    static func annotatedURL(for image: URL, in folder: URL) -> URL {
        let key = String(Hashing.sha256Hex(PathText.clean(image).path).prefix(12))
        var stem = ""
        for c in image.deletingPathExtension().lastPathComponent {
            guard stem.utf8.count + c.utf8.count <= 120 else { break }
            stem.append(c)
        }
        return folder.appendingPathComponent("\(key)-\(stem).annotated.png", isDirectory: false)
    }

    /// A relative link target as an absolute file URL: relative to the note's folder first, then
    /// to the notes root (so `assets/…` from a sub-folder note still resolves). Nil for URLs with a
    /// scheme and for anchors.
    static func resolve(_ path: String, noteDir: URL, root: URL) -> URL? {
        let p = path.removingPercentEncoding ?? path
        if p.hasPrefix("#") || p.contains("://") || p.hasPrefix("mailto:") || p.hasPrefix("data:") { return nil }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
        if p.hasPrefix("~/") { return URL(fileURLWithPath: HomePath.expand(p)) }
        let local = PathText.clean(noteDir.appendingPathComponent(p))
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let fromRoot = PathText.clean(root.appendingPathComponent(p))
        if FileManager.default.fileExists(atPath: fromRoot.path) { return fromRoot }
        return local
    }

    /// Rewrites relative `[text](target)` / `![alt](target)` link targets in one line to absolute
    /// paths (`<…>` when they contain a blank); inline code spans are left alone.
    static func rewriteLinks(_ line: String, noteDir: URL, root: URL, imagesOnly: Bool = false) -> String {
        guard line.contains("](") else { return line }
        var out = ""
        let chars = Array(line)
        var i = 0
        var inCode = false
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                inCode.toggle()
                out.append(c)
                i += 1
                continue
            }
            if !inCode, c == "]", i + 1 < chars.count, chars[i + 1] == "(", let close = chars[(i + 2)...].firstIndex(of: ")") {
                // Is this the end of an image's alt text (`![…`)?
                var isImage = false
                if let open = chars[..<i].lastIndex(of: "["), open > 0 { isImage = chars[open - 1] == "!" }
                let target = String(chars[(i + 2)..<close])
                if !imagesOnly || isImage {
                    var dest = target
                    var title = ""
                    if dest.hasPrefix("<"), let gt = dest.firstIndex(of: ">") {
                        title = String(dest[dest.index(after: gt)...])
                        dest = String(dest[dest.index(after: dest.startIndex)..<gt])
                    } else if let space = dest.firstIndex(of: " ") {
                        title = String(dest[space...])
                        dest = String(dest[..<space])
                    }
                    if let url = resolve(dest, noteDir: noteDir, root: root), !dest.hasPrefix("/") {
                        let abs = url.path
                        out += "](" + (abs.contains(" ") ? "<\(abs)>" : abs) + title + ")"
                        i = close + 1
                        continue
                    }
                }
                out += "](" + target + ")"
                i = close + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// 複製全文 Markdown (§3.6 form 4, the `/n/<id>.md` route): the body without the frontmatter,
    /// image links rewritten to absolute paths, annotation blocks kept.
    static func copyMarkdown(_ document: NoteDocument, root: URL) -> String {
        let noteDir = document.fileURL.deletingLastPathComponent()
        let lines = BodyLines.split(document.body)
        var out: [String] = []
        var fence: Fence?
        for l in lines {
            if let f = fence {
                if f.closes(l.text) { fence = nil }
                out.append(l.text)
                continue
            }
            if let f = Fence(opening: l.text) {
                fence = f
                out.append(l.text)
                continue
            }
            out.append(rewriteLinks(l.text, noteDir: noteDir, root: root, imagesOnly: true))
        }
        var text = out.joined(separator: "\n")
        if document.body.hasSuffix("\n"), !text.hasSuffix("\n") { text += "\n" }
        return text
    }
}

extension NoteAIText.ImageScope {
    /// Where `image` stands: compared by real path with the real paths of the notes `root` and the
    /// scope's folders, so neither a symlink nor `..` leads out of them.
    func place(of image: URL, root: URL) -> NoteAIText.ImagePlace {
        guard case .ai(let folders) = self else { return .allowed }
        let real = RealPath.resolve(image.path)
        let inside = ([root.path] + folders).contains { !$0.isEmpty && RealPath.isInside(real, RealPath.resolve($0)) }
        guard inside else { return .outside }
        return RealPath.isRegularFile(real) ? .allowed : .missing
    }
}

/// Real paths for the AI image scope (CODE-4); no file is read through them.
enum RealPath {
    /// The absolute `path` with every symlink followed and `.` / `..` applied the way the kernel
    /// does, one component at a time (like `realpath(3)`). Unlike it, a missing component does not
    /// stop the walk: the rest is applied lexically, and a dangling symlink still leads to its
    /// target, so a missing file is placed where it would be, inside the scope or not.
    static func resolve(_ path: String) -> String {
        var real: [String] = []
        var rest = Array(path.split(separator: "/").map(String.init).reversed())
        var hops = 0
        while let part = rest.popLast() {
            if part == "." { continue }
            if part == ".." {
                _ = real.popLast()
                continue
            }
            let candidate = "/" + (real + [part]).joined(separator: "/")
            var info = stat()
            guard lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK, hops < 40,
                  let target = linkTarget(candidate) else {
                real.append(part)
                continue
            }
            hops += 1
            if target.hasPrefix("/") { real.removeAll() }
            rest.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return "/" + real.joined(separator: "/")
    }

    static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, Int(PATH_MAX))
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `path` is `folder` or inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
