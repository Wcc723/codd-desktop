import Foundation
import Testing
@testable import CoddNotes

@Suite(.serialized) struct PerformanceTests {
    static let words = ["打卡頁", "跑版", "注音輸入法", "筆記", "按鈕", "導覽列", "表格", "卡片", "間距", "時鐘", "登入", "權杖",
                        "發票", "匯出", "原型", "審查", "部署", "示範", "場景", "載入", "效能", "像素", "小鎮", "對話",
                        "sticky", "position", "bottom", "env", "safe-area", "media", "query", "auth", "token", "refresh",
                        "middleware", "vue", "tailwind", "component", "render", "layout"]

    /// About 4 KB of mixed CJK / ASCII Markdown.
    static func body(_ k: Int, rng: inout SplitMix) -> String {
        var s = "# 產生的筆記 \(k)\n\n## 段落\n"
        while s.utf8.count < 4000 {
            var line = "- "
            for _ in 0..<12 { line += words[Int(rng.next() % UInt64(words.count))] + (rng.next() % 3 == 0 ? " " : "") }
            s += line + "\n"
            if rng.next() % 7 == 0 { s += "\n## 小節 \(rng.next() % 100)\n" }
        }
        return s
    }

    static func generate(_ root: TempRoot, count: Int) {
        var rng = SplitMix(seed: 42)
        for k in 0..<count {
            let tags = "[\(words[k % 24 + 24 >= words.count ? 0 : k % 16 + 24]), gen]"
            let text = "---\nid: gen-\(k)\ntitle: 產生的筆記 \(k)\nkind: note\ntags: \(tags)\nai: read\nscope: global\npinned: false\nstatus: active\ncreated: 2026-10-01T09:00:00+08:00\nupdated: 2026-10-14T09:00:00+08:00\n---\n" + body(k, rng: &rng)
            root.write(String(format: "gen/2026-10-%02d-note-%04d.md", k % 28 + 1, k), text)
        }
    }

    static func p95(_ samples: [Double]) -> Double {
        let s = samples.sorted()
        return s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
    }

    @Test func thousandNotesBuildAndSearch() async throws {
        let root = TempRoot()
        Self.generate(root, count: 1000)
        let lib = makeLibrary(root)
        let started = ContinuousClock.now
        let report = try await lib.open()
        let wall = NotesLibrary.ms(since: started)
        #expect(report.count == 1000)
        print("PERF index build 1000 notes: buildMs=\(String(format: "%.0f", report.buildMs)) wall=\(String(format: "%.0f", wall)) ms")
        #expect(report.buildMs < 2000)

        for term in ["打", "打卡", "打卡頁", "注音", "position", "#gen 跑版"] {
            var samples: [Double] = []
            var hits = 0
            for _ in 0..<50 {
                let t = ContinuousClock.now
                hits = try await lib.search(NoteQuery(text: term)).count
                samples.append(NotesLibrary.ms(since: t))
            }
            let p = Self.p95(samples)
            print("PERF search \(term): p95=\(String(format: "%.2f", p)) ms median=\(String(format: "%.2f", samples.sorted()[25])) ms hits=\(hits)")
            if ["打", "打卡", "打卡頁"].contains(term) { #expect(p < 20, "p95 \(p) ms for \(term)") }
        }
        // Reopen with the index in place: the (path, mtime, size) comparison only.
        await lib.close()
        let again = makeLibrary(root)
        let t2 = ContinuousClock.now
        let r2 = try await again.open()
        print("PERF reopen 1000 notes (up to date): \(String(format: "%.0f", NotesLibrary.ms(since: t2))) ms rebuilt=\(r2.rebuilt)")
        let tc = ContinuousClock.now
        _ = try await again.counts()
        print("PERF counts over 1000 notes: \(String(format: "%.1f", NotesLibrary.ms(since: tc))) ms")
        let tl = ContinuousClock.now
        _ = try await again.list(.inbox, sort: .updated, limit: 200)
        print("PERF list inbox 200: \(String(format: "%.1f", NotesLibrary.ms(since: tl))) ms")
        await again.close()
    }

    @Test func readsInterleaveWithABuild() async throws {
        let root = TempRoot()
        Self.generate(root, count: 1000)
        let lib = makeLibrary(root)
        let opening = Task { try await lib.open() }
        var worst = 0.0
        var calls = 0
        while true {
            let t = ContinuousClock.now
            _ = await lib.resolve("codd://note/gen-1")
            worst = max(worst, NotesLibrary.ms(since: t))
            calls += 1
            if await lib.isOpenForTests { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let report = try await opening.value
        print("PERF reads during a 1000-note build: \(calls) calls, worst \(String(format: "%.1f", worst)) ms (build \(String(format: "%.0f", report.buildMs)) ms)")
        #expect(worst < 100)
        await lib.close()
    }

    @Test func rendererAndAITextTiming() async throws {
        let root = TempRoot()
        let url = root.base.appendingPathComponent("phone.png")
        try makeImage(width: 750, height: 1334).write(to: url)
        let a = try #require(ImageAnnotations.decode(AnnotationTests.withText))
        let t = ContinuousClock.now
        _ = try AnnotatedImageRenderer.render(image: url, annotations: a)
        print("PERF annotated render 750x1334: \(String(format: "%.1f", NotesLibrary.ms(since: t))) ms")
        let big = root.base.appendingPathComponent("big.png")
        try makeImage(width: 2576, height: 1932).write(to: big)
        let t2 = ContinuousClock.now
        _ = try AnnotatedImageRenderer.render(image: big, annotations: a)
        print("PERF annotated render 2576x1932: \(String(format: "%.1f", NotesLibrary.ms(since: t2))) ms")

        root.write("n.md", specNote1())
        let dir = root.notes.appendingPathComponent("assets/rwd-punch-k7x2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeImage(width: 750, height: 1334).write(to: dir.appendingPathComponent("9f3a1c.png"))
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let t3 = ContinuousClock.now
        _ = try await lib.aiText(.of("rwd-punch-k7x2"), offset: 0, maxChars: 12_000)
        print("PERF aiText n1 (first, renders the annotated copy): \(String(format: "%.1f", NotesLibrary.ms(since: t3))) ms")
        let t4 = ContinuousClock.now
        _ = try await lib.aiText(.of("rwd-punch-k7x2"), offset: 0, maxChars: 12_000)
        print("PERF aiText n1 (cached copy): \(String(format: "%.1f", NotesLibrary.ms(since: t4))) ms")
        let t5 = ContinuousClock.now
        _ = await lib.expansion(for: ["codd://note/rwd-punch-k7x2"], maxChars: 9500)
        print("PERF expansion n1: \(String(format: "%.1f", NotesLibrary.ms(since: t5))) ms")
        await lib.close()
    }
}
