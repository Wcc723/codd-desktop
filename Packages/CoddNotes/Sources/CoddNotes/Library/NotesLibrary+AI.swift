import Foundation

extension NotesLibrary {
    /// The §3.7 text of a note, one page from `offset` (characters). Annotated copies the text
    /// points at are generated first. Access rules (OFF, scope) are the caller's (the MCP backend);
    /// the user's own 插入全文 / 送出 may render any note. An AI caller passes its `imageScope`
    /// (CODE-4): images outside it are named only, never measured, attached or burned in.
    public func aiText(_ id: NoteID, offset: Int = 0, maxChars: Int = NoteAIText.defaultPage,
                       imageScope: NoteAIText.ImageScope = .unrestricted) async throws -> NoteAIText.Rendered {
        let row = try requireRow(id)
        if row.isTrashed { throw NotesError.trashed(id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
        let doc = try await document(id)
        await ensureAnnotatedCopies(doc, scope: imageScope)
        let titles = sessionTitles
        return NoteAIText.render(doc, root: rootURL, annotatedFolder: annotatedFolder,
                                 links: (sessionTitle: { titles[$0] }, project: { $0 }),
                                 offset: offset, maxChars: maxChars, timeZone: timeZone, imageScope: imageScope)
    }

    /// Post-M4 (review attachments-6): renders again the annotated copies of the notes `ids` (a
    /// composer draft or history entry made with 插入全文 names a copy that is gone from the cache).
    /// Unknown and trashed notes are skipped; a copy whose image is gone stays missing.
    public func renderAnnotatedCopies(of ids: [NoteID]) async {
        for id in ids {
            guard let row = try? requireRow(id), !row.isTrashed, let doc = try? await document(id) else { continue }
            await ensureAnnotatedCopies(doc)
        }
    }

    /// Renders the annotated copies the note's AI text names; for an AI caller only those of
    /// images inside its `scope` (``annotatedImage(for:image:scope:)`` checks the image it found).
    func ensureAnnotatedCopies(_ doc: NoteDocument, scope: NoteAIText.ImageScope = .unrestricted) async {
        for block in FencedBlocks.find(info: "codd-annotations", in: doc.body) {
            guard let path = block.imagePath, let a = ImageAnnotations.decode(block.content), !a.items.isEmpty,
                  a.send.annotated else { continue }
            _ = try? await annotatedImage(for: doc.metadata.id, image: path, scope: scope)
        }
    }

    /// 複製全文 Markdown / the `/n/<id>.md` route: the body, image links absolute.
    public func copyMarkdown(_ id: NoteID) async throws -> String {
        let doc = try await document(id)
        return NoteAIText.copyMarkdown(doc, root: rootURL)
    }

    /// D19 prompt expansion: at most 5 distinct refs (each element is a ref, or text containing
    /// refs), the §3.7 text of every visible note wrapped in `<codd-note …>` under the header line,
    /// ≤ `maxChars` in total (cut with a pointer to `notes_read` / the file), one line per OFF,
    /// unknown, trashed or purged ref (an OFF note's line never names it), plus the `systemMessage`.
    /// The caller records the `expand` activity (it knows the session) and passes the session's
    /// `imageScope` (CODE-4; the notes root only by default). A body can neither close its
    /// `<codd-note>` wrapper nor open another (``wrapperSafe(_:)``, CODE-6).
    public func expansion(for references: [String], maxChars: Int,
                          imageScope: NoteAIText.ImageScope = .notesRoot) async -> NoteAIText.Expansion {
        var ids: [NoteID] = []
        for r in references {
            let found = NoteReferences.parseRef(r).map { [$0] } ?? NoteReferences.parse(r, limit: 5)
            for id in found where !ids.contains(id) { ids.append(id) }
        }
        ids = Array(ids.prefix(5))
        guard !ids.isEmpty else { return NoteAIText.Expansion(context: nil, systemMessage: nil, noteIDs: [], refused: []) }

        struct Candidate {
            var id: NoteID
            var title: String
            var text: String
            var path: String
            var images: Int
        }
        var notes: [Candidate] = []
        var refused: [String] = []
        var refusedMessages: [String] = []
        func refuse(_ id: NoteID, _ reason: String) {
            refused.append("\(id.uri) 無法展開（\(reason)）")
            refusedMessages.append("codd：\(id.uri) 無法展開（\(reason)）")
        }
        for id in ids {
            guard let row = try? index?.row(id: id) else {
                refuse(id, tombstones.contains(id) ? "這則筆記已永久刪除" : "找不到這則筆記")
                continue
            }
            if row.isTrashed {
                refuse(id, "這則筆記在 CODD 垃圾桶")
                continue
            }
            if (row.ai ?? defaultAccess) == .off {
                refuse(id, "AI 存取為 OFF")
                continue
            }
            guard let doc = try? await document(id) else {
                refuse(id, "找不到這則筆記")
                continue
            }
            await ensureAnnotatedCopies(doc, scope: imageScope)
            let titles = sessionTitles
            let (text, marks) = NoteAIText.fullText(doc, root: rootURL, annotatedFolder: annotatedFolder,
                                                    links: (sessionTitle: { titles[$0] }, project: { $0 }), timeZone: timeZone,
                                                    imageScope: imageScope)
            notes.append(Candidate(id: id, title: doc.metadata.title, text: Self.wrapperSafe(text), path: doc.fileURL.path,
                                   images: marks.count))
        }

        var parts: [String] = [NoteAIText.expansionHeader]
        var used = NoteAIText.expansionHeader.count + 1
        let refusedText = refused.joined(separator: "\n")
        let reserve = refused.isEmpty ? 0 : refusedText.count + 1
        var expanded: [Candidate] = []
        for note in notes {
            let open = "<codd-note ref=\"\(note.id.uri)\" title=\"\(Self.attributeEscaped(note.title))\">"
            let close = "</codd-note>"
            let budget = maxChars - used - reserve - open.count - close.count - 2
            let cutMessage = "…（內容過長已截斷；完整內容請用 notes_read 讀取 \(note.id.uri)，或讀檔 \(note.path)）"
            var body = note.text.hasSuffix("\n") ? String(note.text.dropLast()) : note.text
            if body.count > budget {
                let keep = budget - cutMessage.count - 1
                guard keep > 80 else {
                    // No room left: point at the note instead of a useless fragment.
                    let line = "（篇幅不足，請用 notes_read 讀取 \(note.id.uri)）"
                    if used + line.count + 1 + reserve <= maxChars {
                        parts.append(line)
                        used += line.count + 1
                        expanded.append(note)
                    }
                    continue
                }
                body = String(body.prefix(keep)) + "\n" + cutMessage
            }
            let block = open + "\n" + body + "\n" + close
            parts.append(block)
            used += block.count + 1
            expanded.append(note)
        }
        if !refused.isEmpty { parts.append(refusedText) }
        var messages: [String] = []
        if expanded.count == 1, let n = expanded.first {
            messages.append("codd：已展開 \(n.id.uri)（\(n.title)\(n.images > 0 ? " · \(n.images) 張圖片" : "")）")
        } else if expanded.count > 1 {
            messages.append("codd：已展開 \(expanded.count) 則筆記（\(expanded.map(\.title).joined(separator: "、"))）")
        }
        messages.append(contentsOf: refusedMessages)
        var counts: [NoteID: Int] = [:]
        for n in expanded { counts[n.id] = n.images }
        return NoteAIText.Expansion(
            context: parts.joined(separator: "\n"), systemMessage: messages.isEmpty ? nil : messages.joined(separator: "\n"),
            noteIDs: expanded.map(\.id), refused: refused, imageCounts: counts)
    }

    /// CODE-6: a note's text as it may sit inside `<codd-note …>` … `</codd-note>`: the `<` of
    /// every `<codd-note` / `</codd-note` lookalike becomes `＜`, so the text can neither end its
    /// wrapper early nor open one that seems to come from CODD. A lookalike is what reads as the
    /// tag once ``opensWrapperLookalike(_:)`` folds it: any case, fullwidth forms, blanks and
    /// invisible format characters (zero-width space, word joiner, soft hyphen, BOM) anywhere after
    /// the `<`, any dash (or none) between `codd` and `note`. Scalars, not characters: a format
    /// character right after the `<` would otherwise hide it inside one grapheme. The length in
    /// characters stays the same; nothing else changes.
    static func wrapperSafe(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains("<") else { return text }
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            out.append(scalar == "<" && opensWrapperLookalike(scalars[(i + 1)...].prefix(64)) ? "＜" : scalar)
        }
        return String(out)
    }

    /// The scalars after a `<` read as `codd-note` or `/codd-note` once folded the way a model reads
    /// them: NFKC (fullwidth `／ｃｏｄｄ` → `/codd`), lowercased, blanks, format characters
    /// (`\p{Cf}`) and dashes (`\p{Pd}`, `_`) dropped, slash lookalikes as `/`. Stops at the first
    /// scalar that rules both out, so an ordinary `<b>` costs one step.
    static func opensWrapperLookalike(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool {
        var folded: [Unicode.Scalar] = []
        for scalar in scalars.prefix(64) {
            for part in foldedForWrapper(scalar) {
                folded.append(part)
                guard wrapperTargets.contains(where: { $0.starts(with: folded) }) else { return false }
                if wrapperTargets.contains(folded) { return true }
            }
        }
        return false
    }

    private static let wrapperTargets: [[Unicode.Scalar]] = [Array("coddnote".unicodeScalars), Array("/coddnote".unicodeScalars)]

    private static func foldedForWrapper(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        let category = scalar.properties.generalCategory
        if scalar.properties.isWhitespace || category == .format || category == .dashPunctuation || scalar == "_" { return [] }
        if ["\u{2044}", "\u{2215}", "\u{29F8}"].contains(scalar) { return ["/"] }
        if scalar.isASCII {
            let byte = UInt8(scalar.value)
            return [Unicode.Scalar((65...90).contains(byte) ? byte + 32 : byte)]
        }
        let mapped = String(scalar).precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
        return mapped.count == 1 && mapped.first == scalar ? [scalar] : mapped.flatMap(foldedForWrapper)
    }

    static func attributeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static let maxAIMarkdown = 20_000

    func checkAIWrite(_ row: IndexRow, verb: String) throws {
        if row.isTrashed { throw NotesError.trashed(row.id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
        switch row.ai ?? defaultAccess {
        case .append: return
        case .read: throw NotesError.accessDenied("這則筆記的 AI 存取是 READ，不能\(verb)")
        case .off: throw NotesError.accessDenied("這則筆記的 AI 存取是 OFF，不能\(verb)")
        }
    }

    /// `notes_append` (§3.10): only for APPEND notes; the app's editor is flushed first, a snapshot
    /// is taken, the block `<!-- codd:ai-append session="…" at="…" -->` + `### <heading>` + the
    /// Markdown is appended, the activity recorded. The frontmatter is not touched (an AI write is
    /// never user activity for retention).
    public func appendFromAI(_ id: NoteID, markdown: String, heading: String?, actor: AIActor) async throws -> NoteDocument {
        try checkAIWrite(try requireRow(id), verb: "附加")
        guard markdown.count <= Self.maxAIMarkdown else { throw NotesError.tooLarge("附加內容超過 20,000 字") }
        await coordinator?.flushPendingEdits(of: id)
        let (row, parsed, data) = try load(id)
        try checkAIWrite(row, verb: "附加")
        let now = clock()
        _ = try? historyStore.take(id, data: data, reason: "ai-append", force: true, now: now)
        let who = Self.commentSafe(actor.sessionTitle ?? actor.client ?? "AI")
        let h = heading?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let title = (h?.isEmpty == false) ? h! : "AI 附加 · \(calendar.time(now))"
        var md = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        while md.hasSuffix("\n") { md.removeLast() }
        var body = parsed.body
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        body += "\n<!-- codd:ai-append session=\"\(who)\" at=\"\(iso(now))\" -->\n### \(title)\n\(md)\n"
        let text = NoteFile.compose(frontmatter: parsed.frontmatter, body: body, lineEnding: parsed.lineEnding)
        try commit(row, text: text, updatedHint: now.timeIntervalSince1970)
        recordAIActivity(id, action: "append", actor: actor, at: now)
        channel.yield(.changed([id]))
        log("notes ai-append id=\(id.rawValue) via=\(actor.via) chars=\(markdown.count)")
        let written = try await document(id)
        await coordinator?.didWriteFromAI(written)
        return written
    }

    /// `notes_write`: replaces the body after the H1 line of an APPEND note (snapshot first).
    public func replaceBodyFromAI(_ id: NoteID, markdown: String, actor: AIActor) async throws -> NoteDocument {
        try checkAIWrite(try requireRow(id), verb: "改寫")
        guard markdown.count <= 200_000 else { throw NotesError.tooLarge("內容過長") }
        await coordinator?.flushPendingEdits(of: id)
        let (row, parsed, data) = try load(id)
        try checkAIWrite(row, verb: "改寫")
        let now = clock()
        _ = try? historyStore.take(id, data: data, reason: "ai-write", force: true, now: now)
        let lines = BodyLines.split(parsed.body)
        var md = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var body: String
        if let h1 = MarkdownText.firstH1(lines) {
            let head = lines[...h1.line].map(\.text).joined(separator: "\n")
            // Drop a repeated H1 the AI put at the top of its text.
            let mdLines = BodyLines.split(md)
            if let first = mdLines.first, MarkdownText.h1Text(first.text) == h1.title {
                md = String((md as NSString).substring(from: first.end))
            }
            while md.hasPrefix("\n") { md.removeFirst() }
            body = head + "\n\n" + md
        } else {
            body = md
        }
        if !body.hasSuffix("\n") { body += "\n" }
        let text = NoteFile.compose(frontmatter: parsed.frontmatter, body: body, lineEnding: parsed.lineEnding)
        try commit(row, text: text, updatedHint: now.timeIntervalSince1970)
        recordAIActivity(id, action: "write", actor: actor, at: now)
        channel.yield(.changed([id]))
        log("notes ai-write id=\(id.rawValue) via=\(actor.via) chars=\(markdown.count)")
        let written = try await document(id)
        await coordinator?.didWriteFromAI(written)
        return written
    }

    func recordAIActivity(_ id: NoteID, action: String, actor: AIActor, at: Date) {
        activityLog.append(NoteActivityEvent(at: at, note: id, action: action, client: actor.client,
                                             session: actor.sessionID?.lowercased(), sessionTitle: actor.sessionTitle,
                                             via: actor.via))
        channel.yield(.activity(id))
    }

    /// Text that can sit inside `<!-- … session="…" -->`.
    static func commentSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "--", with: "—").replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
