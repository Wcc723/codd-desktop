import CoreGraphics
import Foundation

extension NotesLibrary {
    static let maxAssetBytes = 20 * 1024 * 1024
    static let annotationKeyAttribute = "com.codd.notes.annotations-sha256"
    /// On an annotated copy: the standardized path of the image it was burned from.
    static let annotatedSourceAttribute = "com.codd.notes.annotated-source"
    /// On an annotated copy: the id of the note that last asked for it.
    static let annotatedNoteAttribute = "com.codd.notes.annotated-note"

    /// D9: stores a pasted / dropped image as `assets/<id>/<hash6>.<ext>` (6 hex of the SHA-256 of
    /// the written bytes, lengthened by 2 while another file holds the name; identical bytes reuse
    /// the file), downscaled to `resizeLongEdge` when larger, re-encoded to a format Claude reads,
    /// the original kept as `<hash6>.orig.<ext>` when asked. Refused over 20 MiB.
    public func saveAsset(_ data: Data, typeHint: String?, for id: NoteID, resizeLongEdge: Int?, keepOriginal: Bool) async throws -> AssetRef {
        let row = try requireRow(id)
        if row.isTrashed { throw NotesError.trashed(id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
        guard data.count <= Self.maxAssetBytes else { throw NotesError.tooLarge("圖片超過 20 MiB，無法貼上") }
        let processed = try ImageProcessing.process(data, longEdge: resizeLongEdge)
        let folder = assetFolder(id, trashed: false)
        let fm = FileManager.default
        let hash = Hashing.sha256Hex(processed.data)
        var length = 6
        var name = ""
        var reused = false
        while length <= hash.count {
            name = "\(hash.prefix(length)).\(processed.ext)"
            let candidate = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: candidate.path) else { break }
            if let existing = try? Data(contentsOf: candidate), existing == processed.data {
                reused = true
                break
            }
            length += 2
        }
        let target = folder.appendingPathComponent(name)
        var originalPath: String?
        do {
            if !reused { try writer.write(processed.data, to: target, mode: 0o600) }
            if keepOriginal, processed.changed {
                let stem = (name as NSString).deletingPathExtension
                let origName = "\(stem).orig.\(processed.originalExt)"
                let origURL = folder.appendingPathComponent(origName)
                if !fm.fileExists(atPath: origURL.path) { try writer.write(data, to: origURL, mode: 0o600) }
                originalPath = "assets/\(id.rawValue)/\(origName)"
            }
        } catch {
            throw NotesError.io("無法儲存圖片：\(error)")
        }
        let (count, bytes) = assetStat(folder: folder)
        try? index?.updateAssets(id: id, count: count, bytes: bytes)
        let rel = "assets/\(id.rawValue)/\(name)"
        let depth = row.path.split(separator: "/").count - 1
        let markdownPath = String(repeating: "../", count: max(0, depth)) + rel
        log("notes asset id=\(id.rawValue) name=\(name) resized=\(processed.resized) reused=\(reused) bytes=\(processed.data.count)")
        channel.yield(.changed([id]))
        return AssetRef(relativePath: rel, pixelSize: CGSize(width: processed.width, height: processed.height),
                        bytes: processed.data.count, resized: processed.resized, reused: reused, markdownPath: markdownPath,
                        originalPath: originalPath)
    }

    public func assets(of id: NoteID) async throws -> [AssetInfo] {
        let (row, parsed, _) = try load(id)
        let folder = assetFolder(id, trashed: row.isTrashed)
        let fm = FileManager.default
        var out: [AssetInfo] = []
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".tmp") }
        for name in names.sorted() {
            let u = folder.appendingPathComponent(name)
            guard let st = FileFacts.info(u.path), !st.isDirectory else { continue }
            let isOrig = name.contains(".orig.")
            out.append(AssetInfo(
                relativePath: (row.isTrashed ? Self.trashPrefix : "") + "assets/\(id.rawValue)/\(name)", url: u, bytes: st.size,
                pixelSize: ImageProcessing.pixelSize(of: u), isOriginalCopy: isOrig,
                referenced: Self.isReferenced(name, in: parsed.body), modified: Date(timeIntervalSince1970: st.mtime)))
        }
        return out
    }

    /// The body links the image (a `.orig` copy counts when its image is linked).
    static func isReferenced(_ name: String, in text: String) -> Bool {
        var main = name
        if let r = name.range(of: ".orig.") { main = String(name[..<r.lowerBound]) + "." }
        return text.contains(main)
    }

    /// The burned-in copy of an image that has a `codd-annotations` block with items (D10,
    /// DERIVED): always `annotatedFolder/<hash12>-<stem>.annotated.png`
    /// (``NoteAIText/annotatedURL(for:in:)``), never beside the image, never in the notes folder.
    /// Regenerated when the block's JSON changed (its SHA-256 rides in an xattr) or, without the
    /// attribute, when the note is newer. The source image's path and the note's id ride along in
    /// xattrs so ``collectStaleAnnotatedCopies()`` can drop copies nothing needs any more. Nil when
    /// the image has no annotations.
    public func annotatedImage(for id: NoteID, image relativePath: String) async throws -> URL? {
        try await annotatedImage(for: id, image: relativePath, scope: .unrestricted)
    }

    /// ``annotatedImage(for:image:)`` for an AI path (CODE-4): nil, with nothing read or written,
    /// when the image the block names is outside `scope` (checked on the image found, so a block
    /// matched by its file name alone cannot lead elsewhere).
    func annotatedImage(for id: NoteID, image relativePath: String, scope: NoteAIText.ImageScope) async throws -> URL? {
        let (row, parsed, _) = try load(id)
        let noteDir = url(row.path).deletingLastPathComponent()
        let wanted = imageURL(relativePath, noteDir: noteDir)
        var found: (URL, ImageAnnotations)?
        for block in FencedBlocks.find(info: "codd-annotations", in: parsed.body) {
            guard let path = block.imagePath, let a = ImageAnnotations.decode(block.content) else { continue }
            let u = imageURL(path, noteDir: noteDir)
            if PathText.clean(u).path == PathText.clean(wanted).path
                || (u.lastPathComponent == wanted.lastPathComponent && relativePath.contains("/") == false) {
                found = (u, a)
                break
            }
        }
        guard let (image, annotations) = found, !annotations.items.isEmpty else { return nil }
        switch scope.place(of: image, root: rootURL) {
        case .allowed: break
        case .missing: throw NotesError.io("找不到圖片 \(image.lastPathComponent)")
        case .outside: return nil
        }
        guard FileManager.default.fileExists(atPath: image.path) else { throw NotesError.io("找不到圖片 \(image.lastPathComponent)") }
        let out = NoteAIText.annotatedURL(for: image, in: annotatedFolder)
        let key = annotations.cacheKey
        if FileManager.default.fileExists(atPath: out.path) {
            var fresh = false
            if let stored = FileFacts.xattr(Self.annotationKeyAttribute, of: out) {
                fresh = stored == key
            } else if let st = FileFacts.info(out.path), st.mtime >= row.mtime {
                fresh = true
            }
            if fresh {
                if FileFacts.xattr(Self.annotatedNoteAttribute, of: out) != id.rawValue {
                    FileFacts.setXattr(Self.annotatedNoteAttribute, id.rawValue, on: out)
                }
                return out
            }
        }
        let png: Data
        do {
            png = try AnnotatedImageRenderer.render(image: image, annotations: annotations)
        } catch {
            throw NotesError.io("無法產生標註圖：\(error)")
        }
        do {
            try annotatedWriter.write(png, to: out, mode: 0o600)
        } catch {
            throw NotesError.io("無法寫入標註圖：\(error)")
        }
        FileFacts.setXattr(Self.annotationKeyAttribute, key, on: out)
        FileFacts.setXattr(Self.annotatedSourceAttribute, PathText.clean(image).path, on: out)
        FileFacts.setXattr(Self.annotatedNoteAttribute, id.rawValue, on: out)
        return out
    }

    /// Run by `open()` (inside the actor, never on the main actor): removes the files in
    /// `annotatedFolder` nothing needs any more, cheaply (one listing, an xattr read and a stat per
    /// file): copies whose source image is gone (a trashed or purged note's assets moved away),
    /// copies whose note is no longer indexed (purged), files without a source attribute (not a
    /// copy CODD made) and temp files of an interrupted write. A removed copy is rendered again the
    /// next time a note needs it. Returns how many files went.
    @discardableResult
    func collectStaleAnnotatedCopies() -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: annotatedFolder.path) else { return 0 }
        var removed = 0
        for name in names {
            let u = annotatedFolder.appendingPathComponent(name, isDirectory: false)
            guard let st = FileFacts.info(u.path), !st.isDirectory else { continue }
            var stale = true
            if !name.hasSuffix(".tmp"), let source = FileFacts.xattr(Self.annotatedSourceAttribute, of: u) {
                stale = !fm.fileExists(atPath: source)
                if !stale, let raw = FileFacts.xattr(Self.annotatedNoteAttribute, of: u), let note = NoteID(rawValue: raw) {
                    stale = (try? index?.hasID(note)) == false
                }
            }
            if stale, (try? fm.removeItem(at: u)) != nil { removed += 1 }
        }
        return removed
    }

    /// A link target (relative to the note, or to the notes root) as a file URL. Any path, `/…`,
    /// `~/…` and `../…` included: the user's editor shows local images; AI paths check the result
    /// against their ``NoteAIText/ImageScope``.
    func imageURL(_ path: String, noteDir: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return NoteAIText.resolve(path, noteDir: noteDir, root: rootURL) ?? noteDir.appendingPathComponent(path)
    }

    /// An image for an MCP image block (D17): ≤ `maxLongEdge` px, ≤ `maxBytes`, PNG / JPEG / WebP.
    public func aiImage(_ url: URL, maxLongEdge: Int, maxBytes: Int) async throws -> (data: Data, mimeType: String, pixelSize: CGSize) {
        let (d, m, s) = try ImageProcessing.aiImage(url, maxLongEdge: maxLongEdge, maxBytes: maxBytes)
        return (d, m, s)
    }

    // MARK: - History (D8)

    public func history(of id: NoteID) async throws -> [NoteSnapshotInfo] {
        _ = try requireRow(id)
        return historyStore.list(id)
    }

    /// The snapshot's body (frontmatter dropped, LF), what the compare view shows next to the editor.
    public func snapshotText(_ snapshot: NoteSnapshotInfo, of id: NoteID) async throws -> String {
        let data = try historyStore.data(id, snapshot: snapshot.id)
        return NoteFile.parse(data: data, timeZone: timeZone).body
    }

    /// `還原這一版`: the current file is snapshotted first, then the snapshot's body replaces the
    /// current body. The current frontmatter stays (access, links and state are not rolled back).
    public func restoreSnapshot(_ snapshot: NoteSnapshotInfo, of id: NoteID) async throws -> NoteDocument {
        let snapshotData = try historyStore.data(id, snapshot: snapshot.id)
        let (row, parsed, data) = try load(id)
        if row.isTrashed { throw NotesError.trashed(id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
        let now = clock()
        _ = try? historyStore.take(id, data: data, reason: "restore", force: true, now: now)
        let old = NoteFile.parse(data: snapshotData, timeZone: timeZone)
        var fm = parsed.frontmatter
        if !parsed.flags.contains(.unparsableFrontmatter), var f = fm {
            if let h1 = MarkdownText.firstH1(BodyLines.split(old.body))?.title { f.set("title", scalar: h1) }
            f.set("updated", scalar: iso(now))
            fm = f
        }
        let text = NoteFile.compose(frontmatter: fm, body: old.body, lineEnding: parsed.lineEnding)
        try commit(row, text: text, updatedHint: now.timeIntervalSince1970)
        recordUserActivity(id, at: now)
        channel.yield(.changed([id]))
        return try await document(id)
    }

    /// A forced snapshot (condense, applying an external change over a dirty editor, D8).
    @discardableResult
    /// D8: a HISTORY version of the note with `body` instead of its file's (the current
    /// frontmatter kept): the editor's unsaved text when the user leaves a note whose disk-change
    /// banner holds it back (reason `unsaved`), so 還原這一版 brings it back.
    public func snapshot(_ id: NoteID, body: String, reason: String) async throws -> NoteSnapshotInfo? {
        let (_, parsed, _) = try load(id)
        let text = NoteFile.compose(frontmatter: parsed.frontmatter, body: body, lineEnding: parsed.lineEnding)
        do {
            return try historyStore.take(id, data: Data(text.utf8), reason: reason, force: true, now: clock())
        } catch {
            throw NotesError.io("無法建立版本：\(error)")
        }
    }

    public func snapshot(_ id: NoteID, reason: String) async throws -> NoteSnapshotInfo? {
        let (_, _, data) = try load(id)
        do {
            return try historyStore.take(id, data: data, reason: reason, force: true, now: clock())
        } catch {
            throw NotesError.io("無法建立版本：\(error)")
        }
    }
}
