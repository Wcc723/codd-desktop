import Foundation
import Synchronization
import Testing
@testable import CoddNotes

final class FlushRecorder: OpenNoteCoordinator {
    let calls = Mutex<[NoteID]>([])
    /// The bodies `didWriteFromAI` handed over (the open editor reconciles with them).
    let written = Mutex<[String]>([])
    func flushPendingEdits(of id: NoteID) async { calls.withLock { $0.append(id) } }
    func didWriteFromAI(_ document: NoteDocument) async { written.withLock { $0.append(document.body) } }
}

@Suite struct AITextTests {
    static let session = "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"

    func library(_ note: String = specNote1(), clock: ManualClock? = nil) async throws -> (TempRoot, NotesLibrary) {
        let root = TempRoot()
        root.write("2026-10-15-打卡頁-rwd-跑版紀錄.md", note)
        let dir = root.notes.appendingPathComponent("assets/rwd-punch-k7x2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeImage(width: 750, height: 1334).write(to: dir.appendingPathComponent("9f3a1c.png"))
        let lib = makeLibrary(root, clock: clock)
        _ = try await lib.open()
        await lib.setSessionTitles([Self.session: "打卡頁 RWD 調整"])
        return (root, lib)
    }

    @Test func specNoteText() async throws {
        let (root, lib) = try await library()
        let r = try await lib.aiText(.of("rwd-punch-k7x2"), offset: 0, maxChars: 12_000)
        let notes = root.notes.path
        let copy = NoteAIText.annotatedURL(for: root.notes.appendingPathComponent("assets/rwd-punch-k7x2/9f3a1c.png"), in: root.annotated)
        let expected = """
            # 打卡頁 RWD 跑版紀錄
            codd://note/rwd-punch-k7x2 · NOTE · #rwd #punch · updated 2026-10-15 10:05 · AI READ
            file: \(notes)/2026-10-15-打卡頁-rwd-跑版紀錄.md
            links: session 打卡頁 RWD 調整 · project ~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend

            ## 問題
            iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。

            [image] \(copy.path) (750×1334)
            annotations（原圖像素，左上為原點）:
              1 rect  x=20 y=1150 w=710 h=120  上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)
              2 point x=375 y=330  時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px
              3 arrow 600,760 → 700,1080  打卡紀錄卡片離按鈕太近，間距加到 16px

            ## 想請 AI 做的
            - [x] 先重現（Chrome DevTools 375 寬）
            - [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`
            - [ ] 表格改卡片式（<640px）

            ```css
            @media (max-width: 640px) { .punch-table { display: block; } }
            ```

            """
        #expect(r.text == expected)
        #expect(!r.truncated && r.nextOffset == nil && r.totalChars == expected.count)
        #expect(r.images.count == 1)
        let img = try #require(r.images.first)
        #expect(img.original.lastPathComponent == "9f3a1c.png")
        #expect(img.annotated?.path == copy.path && copy.lastPathComponent.hasSuffix("-9f3a1c.annotated.png"))
        #expect(!img.includeOriginal && img.includeAnnotated)
        #expect(img.pixelSize == CGSize(width: 750, height: 1334))
        // aiText generated the annotated copy it points at, in the cache folder (not beside the asset).
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(!root.exists("assets/rwd-punch-k7x2/9f3a1c.annotated.png"))
        await lib.close()
    }

    @Test func sendOptionsDecideLines() async throws {
        let note = specNote1().replacingOccurrences(of: "\"send\":{\"original\":false,\"annotated\":true,\"list\":true}",
                                                    with: "\"send\":{\"original\":true,\"annotated\":false,\"list\":false}")
        let (root, lib) = try await library(note)
        let r = try await lib.aiText(.of("rwd-punch-k7x2"), offset: 0, maxChars: 12_000)
        #expect(r.text.contains("[image] \(root.notes.path)/assets/rwd-punch-k7x2/9f3a1c.png (750×1334)\n"))
        #expect(!r.text.contains("annotated.png"))
        #expect(!r.text.contains("annotations（"))
        #expect(r.images.first?.includeOriginal == true && r.images.first?.includeAnnotated == false)
        // Without a block, the image line is the original.
        let (root2, lib2) = try await library(specNote1(withAnnotations: false))
        let r2 = try await lib2.aiText(.of("rwd-punch-k7x2"), offset: 0, maxChars: 12_000)
        #expect(r2.text.contains("[image] \(root2.notes.path)/assets/rwd-punch-k7x2/9f3a1c.png (750×1334)\n"))
        #expect(!r2.text.contains("```codd-annotations"))
        await lib.close()
        await lib2.close()
    }

    @Test func paging() async throws {
        var long = "---\nid: long-note\n---\n# 很長\n\n"
        for k in 0..<400 { long += "第 \(k) 行：這是一段很長的中文內容，用來測試分頁。\n" }
        let root = TempRoot()
        root.write("long.md", long)
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let p1 = try await lib.aiText(.of("long-note"), offset: 0, maxChars: 1000)
        #expect(p1.truncated && p1.text.count <= 1000 && p1.text.hasSuffix("\n"))
        let p2 = try await lib.aiText(.of("long-note"), offset: p1.nextOffset!, maxChars: 1000)
        #expect(p2.offset == p1.nextOffset)
        var all = p1.text + p2.text
        var next = p2.nextOffset
        while let n = next {
            let p = try await lib.aiText(.of("long-note"), offset: n, maxChars: 1000)
            all += p.text
            next = p.nextOffset
        }
        let full = try await lib.aiText(.of("long-note"), offset: 0, maxChars: 1_000_000)
        #expect(all == full.text && !full.truncated)
        await lib.close()
    }

    @Test func copyMarkdownRewritesImages() async throws {
        let (root, lib) = try await library()
        let md = try await lib.copyMarkdown(.of("rwd-punch-k7x2"))
        #expect(md.hasPrefix("# 打卡頁 RWD 跑版紀錄\n"))
        #expect(!md.contains("id: rwd-punch-k7x2"))
        #expect(md.contains("![截圖 2026-10-15 09:32 · iPhone SE](\(root.notes.path)/assets/rwd-punch-k7x2/9f3a1c.png)"))
        #expect(md.contains("```codd-annotations\n{\"v\":1"))
        await lib.close()
    }

    @Test func expansion() async throws {
        let (root, lib) = try await library()
        root.write("off.md", "---\nid: ai-off-note\nai: off\n---\n# 機密筆記標題\n\nOFF-NOTE-SECRET-42\n")
        root.write("gone.md", "---\nid: trashed-note\n---\n# 要丟掉的\n")
        _ = try await lib.rebuildIndex()
        try await lib.trash([.of("trashed-note")])

        let one = await lib.expansion(for: ["看一下 codd://note/rwd-punch-k7x2"], maxChars: 9500)
        #expect(one.noteIDs == [.of("rwd-punch-k7x2")])
        #expect(one.systemMessage == "codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）")
        #expect(one.imageCounts[.of("rwd-punch-k7x2")] == 1)
        let ctx = try #require(one.context)
        #expect(ctx.hasPrefix("CODD 已展開使用者提到的筆記（不需要再呼叫 notes_read）：\n<codd-note ref=\"codd://note/rwd-punch-k7x2\" title=\"打卡頁 RWD 跑版紀錄\">\n# 打卡頁 RWD 跑版紀錄\n"))
        #expect(ctx.hasSuffix("```\n</codd-note>"))
        #expect(ctx.contains("annotations（原圖像素，左上為原點）:"))

        let mixed = await lib.expansion(for: ["codd://note/ai-off-note [[note:trashed-note]] codd://note/zz-unknown codd://note/rwd-punch-k7x2"], maxChars: 9500)
        #expect(mixed.noteIDs == [.of("rwd-punch-k7x2")])
        #expect(mixed.refused == [
            "codd://note/ai-off-note 無法展開（AI 存取為 OFF）",
            "codd://note/trashed-note 無法展開（這則筆記在 CODD 垃圾桶）",
            "codd://note/zz-unknown 無法展開（找不到這則筆記）",
        ])
        let all = (mixed.context ?? "") + (mixed.systemMessage ?? "")
        #expect(!all.contains("機密筆記標題") && !all.contains("OFF-NOTE-SECRET-42"))
        #expect(mixed.systemMessage?.contains("codd：codd://note/ai-off-note 無法展開（AI 存取為 OFF）") == true)

        // Two notes, and the 9,500 cap with a pointer to notes_read.
        var big = "---\nid: big-note\n---\n# 大筆記\n\n"
        for k in 0..<800 { big += "第 \(k) 行：很長的內容。\n" }
        root.write("big.md", big)
        _ = try await lib.rebuildIndex()
        let two = await lib.expansion(for: ["codd://note/rwd-punch-k7x2", "codd://note/big-note"], maxChars: 9500)
        #expect(two.noteIDs == [.of("rwd-punch-k7x2"), .of("big-note")])
        #expect(two.systemMessage == "codd：已展開 2 則筆記（打卡頁 RWD 跑版紀錄、大筆記）")
        let c2 = try #require(two.context)
        #expect(c2.count <= 9500)
        #expect(c2.contains("內容過長已截斷；完整內容請用 notes_read 讀取 codd://note/big-note"))

        // At most five refs; none → nil.
        let six = await lib.expansion(for: ["codd://note/a-1 codd://note/a-2 codd://note/a-3 codd://note/a-4 codd://note/a-5 codd://note/a-6"], maxChars: 9500)
        #expect(six.refused.count == 5)
        let none = await lib.expansion(for: ["沒有引用"], maxChars: 9500)
        #expect(none.context == nil && none.systemMessage == nil)
        // A purged note.
        let purged = await lib.expansion(for: ["codd://note/trashed-note"], maxChars: 9500)
        #expect(purged.refused == ["codd://note/trashed-note 無法展開（這則筆記在 CODD 垃圾桶）"])
        await lib.close()
    }

    @Test func appendFromAIRules() async throws {
        let clock = ManualClock(iso("2026-10-15T10:12:30+08:00"))
        let note = specNote1().replacingOccurrences(of: "ai: read", with: "ai: append")
        let (root, lib) = try await library(note, clock: clock)
        let flush = FlushRecorder()
        await lib.setOpenNoteCoordinator(flush)
        let id = NoteID.of("rwd-punch-k7x2")
        let before = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        let actor = AIActor(client: "Claude Code", sessionID: Self.session.uppercased(), sessionTitle: "打卡頁 RWD 調整", via: "mcp")
        let doc = try await lib.appendFromAI(id, markdown: "已改成 sticky。\n", heading: nil, actor: actor)
        let after = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        #expect(after == before + "\n<!-- codd:ai-append session=\"打卡頁 RWD 調整\" at=\"2026-10-15T10:12:30+08:00\" -->\n### AI 附加 · 10:12\n已改成 sticky。\n")
        #expect(doc.body.hasSuffix("### AI 附加 · 10:12\n已改成 sticky。\n"))
        #expect(flush.calls.withLock { $0 } == [id])
        #expect(flush.written.withLock { $0 } == [doc.body], "the open editor hears of the write (the watcher does not)")
        #expect(try await lib.history(of: id).contains { $0.reason == "ai-append" })
        let act = await lib.activity(of: id, limit: 5)
        #expect(act.first?.action == "append" && act.first?.session == Self.session && act.first?.via == "mcp")
        // A heading is used as given; the frontmatter is untouched (no `updated:` bump).
        _ = try await lib.appendFromAI(id, markdown: "x", heading: "結論", actor: actor)
        #expect(root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md").contains("\n### 結論\nx\n"))
        #expect(root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md").contains("updated: 2026-10-15T10:05:44+08:00\n"))
        // AI writes are not user activity for retention.
        #expect(try await lib.summary(id).lastActivity == iso("2026-10-15T10:05:44+08:00"))

        // replaceBodyFromAI keeps the H1.
        let replaced = try await lib.replaceBodyFromAI(id, markdown: "# 打卡頁 RWD 跑版紀錄\n\n## 新內容\n全部改寫\n", actor: actor)
        #expect(replaced.body == "# 打卡頁 RWD 跑版紀錄\n\n## 新內容\n全部改寫\n")
        #expect(try await lib.history(of: id).contains { $0.reason == "ai-write" })
        #expect(flush.written.withLock { $0.last } == replaced.body)

        // An editor's unsaved text (the banner held it back) goes into HISTORY with the file's
        // frontmatter; the file itself stays.
        let file = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        clock.advance(seconds: 1)
        let kept = try #require(try await lib.snapshot(id, body: "# 打卡頁 RWD 跑版紀錄\n\n沒存到的段落\n", reason: "unsaved"))
        #expect(kept.reason == "unsaved")
        #expect(try await lib.snapshotText(kept, of: id) == "# 打卡頁 RWD 跑版紀錄\n\n沒存到的段落\n")
        #expect(root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md") == file)
        await lib.close()
    }

    /// Post-M4 (user decision 2026-10-18): burned-in copies are DERIVED data. Every copy lands in
    /// the injected cache folder (the app: `<dataRoot>/cache/annotated`), never beside the image
    /// (in `assets/` or anywhere a note links, an MCP append can plant such a link) and never
    /// outside the data root; an older file of the user's with the old sibling name stays as it was.
    @Test func annotatedCopiesAlwaysLandInTheCacheFolder() async throws {
        let (root, lib) = try await library()
        let outside = root.base.appendingPathComponent("project/public", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let logo = outside.appendingPathComponent("logo.png")
        try makeImage(width: 40, height: 30).write(to: logo)
        let users = outside.appendingPathComponent("logo.annotated.png")
        try Data("the user's own file".utf8).write(to: users)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: users.path)
        let block = #"{"v":1,"image":"\#(logo.path)","size":[40,30],"items":[{"n":1,"type":"point","x":1,"y":1,"note":"x"}],"#
            + #""send":{"annotated":true,"original":false,"list":true}}"#
        root.write("2026-10-16-outside.md", """
            ---
            id: outside-img
            title: 外部圖片
            kind: note
            ai: append
            scope: global
            status: active
            created: 2026-10-16T10:00:00+08:00
            updated: 2026-10-16T10:00:00+08:00
            ---
            # 外部圖片

            ![a](\(logo.path))
            ```codd-annotations
            \(block)
            ```

            """)
        _ = try await lib.rebuildIndex()
        let text = try await lib.aiText(.of("outside-img")).text
        _ = try await lib.aiText(.of("rwd-punch-k7x2"))
        #expect(try Data(contentsOf: users) == Data("the user's own file".utf8), "never written beside the image")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == ["logo.annotated.png", "logo.png"])
        let cache = root.annotated
        let copies = try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted()
        #expect(copies.count == 2 && copies.contains { $0.hasSuffix("-logo.annotated.png") }
                && copies.contains { $0.hasSuffix("-9f3a1c.annotated.png") })
        let logoCopy = copies.first { $0.hasSuffix("-logo.annotated.png") } ?? "-"
        #expect(text.contains("[image] \(cache.path)/\(logoCopy)"), "the AI text points at the copy CODD made")
        #expect(cache.path.hasPrefix(root.data.path + "/"), "inside the data root")
        // Nothing burned-in anywhere in the notes folder, assets included.
        let inNotes = (FileManager.default.enumerator(atPath: root.notes.path)?.allObjects as? [String]) ?? []
        #expect(!inNotes.contains { $0.contains(".annotated.") }, "no copy in the notes folder")
        // The name rule: images in assets/, outside it, and `..` out of assets all map into the folder.
        let inAssets = root.notes.appendingPathComponent("assets/rwd-punch-k7x2/9f3a1c.png")
        let escaped = URL(fileURLWithPath: root.notes.path + "/assets/../../../project/public/logo.png")
        for image in [inAssets, logo, escaped] {
            #expect(NoteAIText.annotatedURL(for: image, in: cache).deletingLastPathComponent().path == cache.path)
        }
        #expect(NoteAIText.annotatedURL(for: escaped, in: cache) == NoteAIText.annotatedURL(for: logo, in: cache),
                "the standardized path names the copy")
        await lib.close()
    }

    @Test func appendRefusedForReadAndOff() async throws {
        let (root, lib) = try await library()
        root.write("off.md", "---\nid: ai-off-note\nai: off\n---\n# off\n")
        _ = try await lib.rebuildIndex()
        let actor = AIActor(client: "Claude Code", via: "mcp")
        await #expect(throws: NotesError.accessDenied("這則筆記的 AI 存取是 READ，不能附加")) {
            _ = try await lib.appendFromAI(.of("rwd-punch-k7x2"), markdown: "x", heading: nil, actor: actor)
        }
        await #expect(throws: NotesError.accessDenied("這則筆記的 AI 存取是 OFF，不能附加")) {
            _ = try await lib.appendFromAI(.of("ai-off-note"), markdown: "x", heading: nil, actor: actor)
        }
        await #expect(throws: NotesError.accessDenied("這則筆記的 AI 存取是 READ，不能改寫")) {
            _ = try await lib.replaceBodyFromAI(.of("rwd-punch-k7x2"), markdown: "x", actor: actor)
        }
        // A missing default access falls back to the library default.
        root.write("nokey.md", "---\nid: no-ai-key\n---\n# x\n")
        _ = try await lib.rebuildIndex()
        #expect(try await lib.summary(.of("no-ai-key")).metadata.ai == .read)
        await lib.setPolicy(.defaults, defaultAccess: .off)
        #expect(try await lib.summary(.of("no-ai-key")).metadata.ai == .off)
        await lib.close()
    }
}
