import Foundation

/// A `tools/call` result (`CallToolResult`).
struct ToolResult: Sendable, Equatable {
    var content: [JSON]
    var structuredContent: JSON?
    var isError = false

    static func text(_ text: String) -> ToolResult { ToolResult(content: [textBlock(text)]) }

    static func error(_ text: String) -> ToolResult { ToolResult(content: [textBlock(text)], isError: true) }

    static func textBlock(_ text: String) -> JSON { ["type": "text", "text": .string(text)] }

    var json: JSON {
        var object: JSONObject = ["content": .array(content)]
        if let structuredContent { object["structuredContent"] = structuredContent }
        if isError { object["isError"] = true }
        return .object(object)
    }
}

/// How results read to the model (§3.10 shapes; framing lines in 繁體中文 like the notes).
struct ToolOutput {
    let dates: MCPDateText
    let now: Date

    /// `1. 打卡頁 RWD 跑版紀錄 · codd://note/rwd-punch-k7x2 · NOTE · updated 10/15 10:05` and the
    /// snippet indented below; non-active notes say so (`· ARCHIVED`).
    func hitList(_ hits: [MCPNoteHit], empty: String) -> String {
        guard !hits.isEmpty else { return empty }
        var lines: [String] = []
        for (i, hit) in hits.enumerated() {
            var line = "\(i + 1). \(MCPText.oneLine(hit.title)) · \(hit.uri) · \(hit.kind.uppercased())"
                + " · updated \(dates.short(hit.updated, now: now))"
            let state = hit.state.lowercased()
            if !state.isEmpty, state != "active" { line += " · \(state.uppercased())" }
            lines.append(line)
            let snippet = MCPText.oneLine(hit.snippet)
            if !snippet.isEmpty { lines.append("   " + snippet) }
        }
        return lines.joined(separator: "\n")
    }

    func structured(_ hits: [MCPNoteHit]) -> JSON {
        let results: [JSON] = hits.map { hit in
            [
                "id": .string(hit.id), "uri": .string(hit.uri), "title": .string(hit.title),
                "kind": .string(hit.kind), "tags": .array(hit.tags.map { .string($0) }),
                "updated": .string(dates.iso(hit.updated)), "snippet": .string(hit.snippet),
                "path": .string(hit.path), "state": .string(hit.state),
            ]
        }
        return ["results": .array(results)]
    }

    func hits(_ hits: [MCPNoteHit], empty: String, structured: Bool) -> ToolResult {
        ToolResult(content: [ToolResult.textBlock(hitList(hits, empty: empty))],
                   structuredContent: structured ? self.structured(hits) : nil)
    }

    /// The §3.7 text (+ the paging line when cut), up to four image blocks, then one text block
    /// naming the images that were not attached.
    func note(_ content: MCPNoteContent, request: MCPReadRequest) -> ToolResult {
        var text = content.text
        if content.truncated {
            let first = request.offset + 1
            if let next = content.nextOffset {
                let total = content.totalChars.map { "，共 \($0) 字" } ?? ""
                text += "\n\n（第 \(first)–\(next) 字\(total)；下一段 offset=\(next)）"
            } else {
                text += "\n\n（第 \(first) 字起，內容已截斷）"
            }
        }
        var blocks: [JSON] = [ToolResult.textBlock(text)]
        var extra: [String] = []
        var attached = 0, bytes = 0
        for image in content.images {
            let fits = request.includeImages && attached < MCPLimits.maxImageBlocks
                && bytes + image.data.count <= MCPLimits.maxImageBytesPerResult
            guard fits, !image.data.isEmpty else {
                extra.append(image.path)
                continue
            }
            blocks.append([
                "type": "image", "data": .string(image.data.base64EncodedString()),
                "mimeType": .string(image.mimeType),
            ])
            attached += 1
            bytes += image.data.count
        }
        for path in content.extraImagePaths where !extra.contains(path) { extra.append(path) }
        extra.removeAll { $0.isEmpty }
        if !extra.isEmpty {
            blocks.append(ToolResult.textBlock(
                "其他圖片（未附上，需要時用 Read 開啟）：\n" + extra.joined(separator: "\n")))
        }
        return ToolResult(content: blocks)
    }

    func written(_ result: MCPWriteResult, verb: String) -> ToolResult {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .text(text.isEmpty ? "\(verb) \(result.uri)" : text)
    }

    /// `notes_create`: the new ref and title, the file, and how to add to it.
    ///
    /// ```
    /// 已建立筆記 codd://note/<id>「<title>」（INBOX · AI APPEND）
    /// file: /…/notes/2026-10-19-<title>.md
    /// 之後可以用 notes_append 附加內容到這則筆記。
    /// ```
    func created(_ result: MCPCreateResult) -> ToolResult {
        var lines = ["已建立筆記 \(result.uri)「\(MCPText.oneLine(result.title))」（INBOX · AI APPEND）"]
        if !result.path.isEmpty { lines.append("file: \(result.path)") }
        lines.append("之後可以用 notes_append 附加內容到這則筆記。")
        return .text(lines.joined(separator: "\n"))
    }
}
