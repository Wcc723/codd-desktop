import CoddAnnotateUI
import CoddNotes
import CoreGraphics
import Foundation

/// D10 / §3.3: CoddNotes' `ImageAnnotations` (the `codd-annotations` block) ⇄ C8's
/// `AnnotationDocument`, the ImageAnnotate top bar, and the panel's `AI 會收到` / Markdown texts.
/// Pure (unit-tested): the block's unknown keys survive a round trip through the screen.
enum NoteAnnotateMapping {
    /// The screen's document for `annotations` (nil: an image without a block yet).
    static func document(_ annotations: ImageAnnotations?, imageSize: CGSize) -> AnnotationDocument {
        guard let annotations else { return AnnotationDocument(pixelSize: imageSize) }
        let size = annotations.size.width > 0 && annotations.size.height > 0
            ? CGSize(width: annotations.size.width, height: annotations.size.height) : imageSize
        let items = annotations.items.sorted { $0.n < $1.n }.map { item in
            AnnotationDraft(n: item.n, kind: kind(item.type), x: item.x, y: item.y, w: item.w, h: item.h, x2: item.x2, y2: item.y2,
                            note: item.note, color: item.color.flatMap(AnnotationColor.init(rawValue:)) ?? .amber)
        }
        let send = AnnotationSendOptions(original: annotations.send.original, annotated: annotations.send.annotated,
                                         list: annotations.send.list)
        return AnnotationDocument(pixelSize: size, items: items, send: send)
    }

    /// The block for the screen's document. `previous` (the block before editing) gives back its
    /// unknown keys: the top level and `send` always, an item's when the same item (same kind and
    /// geometry, else the same number and kind) is still there. `image` is the path the block
    /// names (§3.3: relative to the notes folder).
    static func annotations(_ document: AnnotationDocument, image: String, previous: ImageAnnotations?) -> ImageAnnotations {
        let old = previous?.items ?? []
        let items = document.items.map { draft -> ImageAnnotations.Item in
            let kind = itemKind(draft.kind)
            let match = old.first { $0.type == kind && $0.x == draft.x && $0.y == draft.y && $0.w == draft.w && $0.h == draft.h
                && $0.x2 == draft.x2 && $0.y2 == draft.y2 } ?? old.first { $0.n == draft.n && $0.type == kind }
            var item = ImageAnnotations.Item(n: draft.n, type: kind, x: draft.x, y: draft.y, note: draft.note)
            switch draft.kind {
            case .rect:
                item.w = draft.width
                item.h = draft.height
            case .arrow:
                item.x2 = draft.endX
                item.y2 = draft.endY
            case .point, .text:
                break
            }
            item.color = draft.color == .amber ? nil : draft.color.rawValue
            item.extra = match?.extra ?? [:]
            return item
        }
        let send = ImageAnnotations.SendOptions(original: document.send.original, annotated: document.send.annotated,
                                                list: document.send.list, extra: previous?.send.extra ?? [:])
        let size = ImageAnnotations.PixelSize(width: max(1, Int(document.pixelSize.width.rounded())),
                                              height: max(1, Int(document.pixelSize.height.rounded())))
        return ImageAnnotations(v: previous?.v ?? 1, image: image, size: size, items: items, send: send, extra: previous?.extra ?? [:])
    }

    /// The block's JSON after `完成`, or nil when the block should go (no items and the default
    /// send options: the image then simply goes to the AI as it is).
    static func blockJSON(_ annotations: ImageAnnotations) -> String? {
        let defaults = ImageAnnotations.SendOptions()
        if annotations.items.isEmpty, annotations.send.original == defaults.original, annotations.send.annotated == defaults.annotated,
           annotations.send.list == defaults.list, annotations.extra.isEmpty, annotations.send.extra.isEmpty {
            return nil
        }
        return annotations.encoded()
    }

    /// The panel's `Markdown 原始碼（codd-annotations 區塊）`.
    static func markdownSource(_ annotations: ImageAnnotations) -> String {
        "```codd-annotations\n" + annotations.encoded() + "\n```"
    }

    /// The ImageAnnotate top bar (artboard: `INBOX / 打卡頁 RWD 跑版紀錄 /`, `9f3a1c.png`,
    /// `assets/rwd-punch-k7x2/9f3a1c.png · 750×1334 px · iPhone SE · 截圖 2026-10-15 09:32`): the
    /// meta is the path, the size and the image's alt text, the screenshot stamp last.
    static func header(listTitle: String, noteTitle: String, path: String, pixelSize: CGSize, alt: String) -> ImageAnnotateHeader {
        let name = (path as NSString).lastPathComponent
        var meta = [path, "\(Int(pixelSize.width))×\(Int(pixelSize.height)) px"]
        let parts = alt.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        meta += parts.filter { !$0.hasPrefix("截圖") } + parts.filter { $0.hasPrefix("截圖") }
        return ImageAnnotateHeader(crumbs: [listTitle.uppercased(), noteTitle], fileName: name, meta: meta, originalFileName: name)
    }

    /// The block's `image` value for an image line: relative to the notes folder when the file is
    /// inside it (§3.3 `assets/<id>/<hash6>.png`, also for a note in a sub-folder), else as written.
    static func blockImagePath(_ path: String, resolved: URL?, notesRoot: URL) -> String {
        guard let resolved else { return path }
        let root = notesRoot.standardizedFileURL.path + "/"
        let file = resolved.standardizedFileURL.path
        return file.hasPrefix(root) ? String(file.dropFirst(root.count)) : path
    }

    private static func kind(_ type: ImageAnnotations.Item.Kind) -> AnnotationKind {
        switch type {
        case .rect: .rect
        case .point: .point
        case .arrow: .arrow
        case .text: .text
        }
    }

    private static func itemKind(_ kind: AnnotationKind) -> ImageAnnotations.Item.Kind {
        switch kind {
        case .rect: .rect
        case .point: .point
        case .arrow: .arrow
        case .text: .text
        }
    }
}

/// D15 / §3.6: the five COPY REF forms of a note with the app's port and per-note URL token, the
/// chrome's display strings, and the dump's masked text (the URL token never leaves the copy).
struct NoteReferenceSet: Equatable {
    var forms: [NoteReferenceForm]
    /// The note's AI access (an OFF note offers no URL, D15).
    var ai: NoteAIAccess

    init(id: NoteID, fileURL: URL, port: Int?, urlToken: String?, ai: NoteAIAccess, serverName: String = "codd") {
        forms = NoteReferences.forms(id: id, fileURL: fileURL, port: port, urlToken: urlToken, serverName: serverName)
        self.ai = ai
    }

    func form(_ kind: NoteReferenceForm.Kind) -> NoteReferenceForm? { forms.first { $0.kind == kind } }

    /// What the chrome shows (the token as `••••`).
    var displayTexts: (uri: String, mention: String, path: String, url: String) {
        (form(.uri)?.display ?? "", form(.mcpResource)?.display ?? "", form(.filePath)?.display ?? "", form(.url)?.display ?? "")
    }

    /// Why a form cannot be copied (nil: it can). The Markdown form's text comes from the library.
    func refusal(_ kind: NoteReferenceForm.Kind) -> String? {
        switch kind {
        case .url:
            if ai == .off { return "AI 存取為 OFF，不提供網址" }
            return form(.url)?.text == nil ? "本機網址目前無法使用（MCP token 尚未建立）" : nil
        case .markdown:
            return nil
        default:
            return form(kind)?.text == nil ? "這個引用目前無法使用" : nil
        }
    }

    /// The dump's text of a copy: the URL token replaced by `••••`.
    static func masked(_ text: String, kind: NoteReferenceForm.Kind) -> String {
        guard kind == .url, let range = text.range(of: "?t=") else { return text }
        return String(text[..<range.upperBound]) + "••••"
    }
}
