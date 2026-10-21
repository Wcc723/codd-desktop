import Foundation

/// One COPY REF menu entry (plan §3.6, the Notebook artboard's order and hints).
public struct NoteReferenceForm: Sendable, Equatable {
    public enum Kind: Int, Sendable, CaseIterable {
        case uri = 1, mcpResource, filePath, markdown, url
    }

    public var kind: Kind
    /// What is copied; nil for 複製全文 Markdown (the app copies `NotesLibrary.copyMarkdown`) and for
    /// the URL when no port / token is known.
    public var text: String?
    /// What the menu shows (`~` for the home folder, `?t=••••` for the token).
    public var display: String
    public var hint: String
    /// The `推薦` chip (form 1).
    public var recommended: Bool

    public init(kind: Kind, text: String?, display: String, hint: String, recommended: Bool = false) {
        self.kind = kind
        self.text = text
        self.display = display
        self.hint = hint
        self.recommended = recommended
    }
}

public enum NoteReferences {
    /// Note refs in free text: `codd://note/<id>` (also inside `@<server>:codd://note/<id>`) and
    /// `[[note:<id>]]`, in order of appearance, deduplicated, at most `limit`.
    public static func parse(_ text: String, limit: Int) -> [NoteID] {
        guard limit > 0 else { return [] }
        var out: [NoteID] = []
        let u = Array(text.utf8)
        let scheme = Array("codd://note/".utf8)
        let wiki = Array("[[note:".utf8)
        var i = 0
        while i < u.count {
            var start: Int?
            var wikiForm = false
            if u[i] == UInt8(ascii: "c"), i + scheme.count <= u.count, Array(u[i..<(i + scheme.count)]) == scheme {
                start = i + scheme.count
            } else if u[i] == UInt8(ascii: "["), i + wiki.count <= u.count, Array(u[i..<(i + wiki.count)]) == wiki {
                start = i + wiki.count
                wikiForm = true
            }
            guard let s = start else {
                i += 1
                continue
            }
            var j = s
            while j < u.count, isIDByte(u[j]) { j += 1 }
            var end = j
            while end > s, u[end - 1] == UInt8(ascii: "-") { end -= 1 }
            if wikiForm {
                // `[[note:<id>]]` must close right after the id.
                guard j + 1 < u.count, j == end, u[j] == UInt8(ascii: "]"), u[j + 1] == UInt8(ascii: "]") else {
                    i = max(j, i + 1)
                    continue
                }
            }
            if end > s, let id = NoteID(rawValue: String(decoding: u[s..<end], as: UTF8.self)), !out.contains(id) {
                out.append(id)
                if out.count >= limit { return out }
            }
            i = max(j, i + 1)
        }
        return out
    }

    /// One reference as the MCP `ref` argument takes it: any form of ``parse(_:limit:)`` or a bare id.
    public static func parseRef(_ ref: String) -> NoteID? {
        let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = NoteID(rawValue: t) { return id }
        var core = Substring(t)
        if core.hasPrefix("@"), let colon = core.firstIndex(of: ":") {
            // `@codd:codd://note/<id>`: drop the server prefix.
            let after = core[core.index(after: colon)...]
            if after.hasPrefix("codd://") { core = after }
        }
        if core.hasPrefix("codd://note/") {
            var rest = core.dropFirst("codd://note/".count)
            while rest.hasSuffix("/") { rest = rest.dropLast() }
            return NoteID(rawValue: String(rest))
        }
        if core.hasPrefix("[[note:"), core.hasSuffix("]]") {
            return NoteID(rawValue: String(core.dropFirst(7).dropLast(2)))
        }
        return nil
    }

    /// The five COPY REF forms in the artboard's order. `urlToken` is the 24-hex
    /// `MCPAuth.noteURLToken`; without it (or without a port) the URL form has no copy text.
    public static func forms(id: NoteID, fileURL: URL, port: Int?, urlToken: String?, serverName: String = "codd")
        -> [NoteReferenceForm]
    {
        let path = fileURL.path
        var urlText: String?
        var urlDisplay = "http://127.0.0.1:—/n/\(id.rawValue).md"
        if let port {
            urlDisplay = "http://127.0.0.1:\(port)/n/\(id.rawValue).md?t=••••"
            if let urlToken { urlText = "http://127.0.0.1:\(port)/n/\(id.rawValue).md?t=\(urlToken)" }
        }
        return [
            NoteReferenceForm(kind: .uri, text: id.uri, display: id.uri,
                              hint: "CODD 啟動的 session 會由 UserPromptSubmit hook 自動展開內容", recommended: true),
            NoteReferenceForm(kind: .mcpResource, text: "@\(serverName):\(id.uri)", display: "@\(serverName):\(id.uri)",
                              hint: "在 Claude Code 輸入框用 @ 附加（MCP resource）"),
            NoteReferenceForm(kind: .filePath, text: path, display: HomePath.abbreviate(path),
                              hint: "檔案路徑 · 任何 agent 都能用 Read 讀取"),
            NoteReferenceForm(kind: .markdown, text: nil, display: "複製全文 Markdown", hint: "貼到任何地方；圖片改寫成絕對路徑"),
            NoteReferenceForm(kind: .url, text: urlText, display: urlDisplay, hint: "瀏覽器 / curl 用；Claude 的 WebFetch 讀不到 localhost"),
        ]
    }

    private static func isIDByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: "-")
    }
}
