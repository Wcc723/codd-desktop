import Foundation
import Testing
@testable import CoddNotes

@Suite struct CleanupTests {
    static let now = RetentionTests.now
    static let backend = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    static func keynote(_ chapter: Int) -> String {
        var s = "# keynote 第 \(chapter) 章大綱\n\n"
        for k in 0..<12 { s += "- 重點 \(k)：投影片的段落說明，介紹第 \(k) 個主題與範例程式碼的展示方式。\n" }
        s += "- 第 \(chapter) 章結尾\n"
        return s
    }

    func fixture() async throws -> (TempRoot, NotesLibrary) {
        let root = TempRoot()
        let n = RetentionTests.note
        root.write("gear.md", n("gear3d-perf", 30, "projects: [~/Github/Gear3D]\n", "Gear3D 載入效能想法", "載入效能\n"))
        root.write("prompt.md", n("auth-prompt", 10, "kind: prompt\nsent: \(RetentionTests.ago(7))\nsentTo: \(Self.backend)\n", "給後端的 prompt：auth 測試範圍", "x\n"))
        root.write("scratch.md", n("scratch-1015", 1, "kind: scratch\n", "隨手記 10/15", "x\n"))
        let k2 = "---\nid: keynote-2\nkind: prompt\nprojects: [~/Github/keynote-deck]\ncreated: \(RetentionTests.ago(3))\nupdated: \(RetentionTests.ago(3))\n---\n" + Self.keynote(2)
        let k3 = "---\nid: keynote-3\nkind: prompt\nprojects: [~/Github/keynote-deck]\ncreated: \(RetentionTests.ago(2))\nupdated: \(RetentionTests.ago(2))\n---\n" + Self.keynote(3)
        root.write("k2.md", k2)
        root.write("k3.md", k3)
        var log = "# 每日工作日誌\n\n"
        for d in ["9/01", "9/02", "9/03", "9/04", "9/05", "9/08", "9/09", "9/10", "9/12"] { log += "## \(d) 工作\n做了一些事\n\n" }
        log += "## 10/10 最近\n最近的段落\n"
        root.write("log.md", n("daily-log", 2, "", "每日工作日誌", log.replacingOccurrences(of: "# 每日工作日誌\n\n", with: "")))
        root.write("draft.md", n("draft-18", 18, "kind: prompt\n", "keynote 草稿", "x\n"))
        root.write("idle.md", n("idle-27", 27, "", "閒置的筆記", "y\n"))
        root.write("img.md", n("img-note", 1, "", "有圖的筆記", "![a](assets/img-note/aaaaaa.png)\n"))
        let dir = root.notes.appendingPathComponent("assets/img-note")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["aaaaaa.png", "2b7e04.png", "cccccc.png", "dddddd.png"] {
            let u = dir.appendingPathComponent(name)
            try makeImage(width: 20, height: 20).write(to: u)
            // Old enough except dddddd.
            let days: Double = name == "dddddd.png" ? 2 : 12
            try FileManager.default.setAttributes([.modificationDate: Self.now.addingTimeInterval(-days * 86_400)], ofItemAtPath: u.path)
        }
        let clock = ManualClock(Self.now)
        let lib = makeLibrary(root, clock: clock)
        _ = try await lib.open()
        // cccccc.png is referenced by a kept snapshot only.
        let snapText = n("img-note", 5, "", "有圖的筆記", "![old](assets/img-note/cccccc.png)\n")
        try HistoryStore(root: root.notes.appendingPathComponent(".codd/history"), writer: AtomicWriter(tempDirectory: root.notes.appendingPathComponent(".codd/tmp")))
            .take(.of("img-note"), data: Data(snapText.utf8), reason: nil, force: true, now: Self.now.addingTimeInterval(-86_400))
        await lib.markOpened(.of("gear3d-perf"), at: iso("2026-09-24T10:00:00+08:00"))
        await lib.recordActivity(NoteActivityEvent(at: Self.now.addingTimeInterval(-2 * 86_400), note: .of("gear3d-perf"), action: "read", via: "mcp"))
        await lib.setSessionTitles([Self.backend: "auth middleware 單元測試"])
        return (root, lib)
    }

    @Test func artboardRows() async throws {
        let (_, lib) = try await fixture()
        let all = await lib.cleanupCandidates(liveSessions: [])
        func row(_ id: String) -> NoteCleanupCandidate? { all.first { $0.id.rawValue == id && !$0.rowKey.contains("#") } }

        let gear = try #require(row("gear3d-perf"))
        #expect(gear.why == "21 天未開啟" && gear.sub == "最後開啟 9/24" && gear.badge == "stale 21d")
        #expect(gear.reason == .stale(days: 21) && gear.aiHint == .keep(lastReadDaysAgo: 2))
        #expect(gear.aiHintText == "AI 2d 前讀取 → 建議保留")

        let prompt = try #require(row("auth-prompt"))
        #expect(prompt.why == "已送出 7 天" && prompt.sub == "送到 auth middleware 單元測試" && prompt.badge == "archives in 0d")
        #expect(prompt.reason == .sentPrompt(days: 7))

        let scratch = try #require(row("scratch-1015"))
        #expect(scratch.why == "SCRATCH" && scratch.sub == "快速筆記 7 天後自動封存" && scratch.badge == "archives in 6d")

        let dup = try #require(row("keynote-2"))
        guard case .duplicate(let other, let percent) = dup.reason else {
            Issue.record("expected a duplicate")
            return
        }
        #expect(other.rawValue == "keynote-3" && percent >= 80)
        #expect(dup.why == "近似重複（與第 3 章 \(percent)% 相同）")
        #expect(dup.sub == "對照「keynote 第 3 章大綱」" && dup.badge == "dup \(percent)%")
        #expect(dup.aiHint == .condense && dup.aiHintText == "適合濃縮" && dup.suggestsCondense)
        #expect(row("keynote-3") == nil)  // reported once, on the older note

        let long = try #require(row("daily-log"))
        #expect(long.why == "長期筆記 · 9 段超過 30 天" && long.sub == "9/01–9/12 的段落" && long.badge == "9 段 > 30d")
        #expect(long.aiHintText == "適合濃縮舊段落" && long.suggestsCondense)
        #expect(long.reason == .longNote(sections: 9, olderThanDays: 30))

        let draft = try #require(row("draft-18"))
        #expect(draft.why == "草稿 18 天未動" && draft.sub == "從未送出" && draft.badge == "stale 18d")

        let idle = try #require(row("idle-27"))
        #expect(idle.why == "27 天無活動" && idle.sub == "3 天後自動封存" && idle.badge == "archives in 3d")
        #expect(idle.reason == .archivesSoon(days: 3))

        // Unused images: only 2b7e04 (aaaaaa is linked, cccccc is in a snapshot, dddddd is new).
        let unused = all.filter { if case .unusedAsset = $0.reason { return true }; return false }
        #expect(unused.map(\.title) == ["2b7e04.png"])
        #expect(unused.first?.why == "未使用的圖片 · 2b7e04.png" && unused.first?.badge == "unused 12d")
        #expect(unused.first?.rowKey == "img-note#assets/img-note/2b7e04.png")
        #expect(row("img-note") == nil)

        // `保留 30 天` removes a note from the list.
        await lib.keep(.of("idle-27"), until: Self.now.addingTimeInterval(30 * 86_400))
        #expect(await lib.cleanupCandidates(liveSessions: []).contains { $0.id.rawValue == "idle-27" } == false)
        await lib.close()
    }

    @Test func datedSectionsFormats() async throws {
        let root = TempRoot()
        let body = """
            # 日誌

            ## 2026-09-03 會議
            第一段

            ### 9/05 小節
            內容

            ## 09/07：其他
            內容
            ```
            ## 9/08 在程式碼裡不算
            ```

            ## 沒有日期
            x

            ## 10/14 太新
            y

            ## 12/25 去年的聖誕
            z
            """
        root.write("log.md", "---\nid: log-note\n---\n" + body)
        let lib = makeLibrary(root, clock: ManualClock(RetentionTests.now))
        _ = try await lib.open()
        let old = try await lib.datedSections(.of("log-note"), olderThanDays: 30)
        #expect(old.map(\.heading) == ["2026-09-03 會議", "9/05 小節", "09/07：其他", "12/25 去年的聖誕"])
        #expect(old[0].date == iso("2026-09-03T00:00:00+08:00"))
        #expect(old[3].date == iso("2025-12-25T00:00:00+08:00"))
        // The H2 runs to the next H2 and includes its H3; the H3 to the next heading.
        #expect(old[0].text == "## 2026-09-03 會議\n第一段\n\n### 9/05 小節\n內容\n\n")
        #expect(old[1].text == "### 9/05 小節\n內容\n\n")
        #expect((body as NSString).substring(with: old[2].range) == old[2].text)
        #expect(old[2].text.contains("## 9/08 在程式碼裡不算"))
        let all = try await lib.datedSections(.of("log-note"), olderThanDays: 0)
        #expect(all.count == 5)
        await lib.close()
    }

    @Test func differenceLabel() {
        #expect(Similarity.differenceLabel(mine: "keynote 第 2 章大綱", other: "keynote 第 3 章大綱") == "第 3 章")
        #expect(Similarity.differenceLabel(mine: "會議紀錄", other: "會議紀錄 v2") == "「會議紀錄 v2」")
        #expect(Similarity.differenceLabel(mine: "abc", other: "xyz") == "「xyz」")
        let a = Similarity.trigrams("同一段文字同一段文字同一段文字")
        #expect(Similarity.jaccard(a, a) == 1)
    }
}
