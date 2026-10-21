import AppKit
import Testing
@testable import CoddTextKit

/// D11 budgets (debug build): a 1 MB note with 200 image lines loads in < 300 ms and a keystroke in
/// its middle restyles in < 30 ms (p95). Numbers are printed (`PERF …`) for the report. Other
/// agents compile on this Mac while tests run, so the load budget is checked on the best of five
/// loads (the intrinsic cost) and the median gets a looser bound.
@Suite("Performance", .serialized)
@MainActor
struct PerformanceTests {
    /// ≈ 1 MiB of UTF-8: sections with a heading, CJK / ASCII paragraphs with marks, lists, tasks,
    /// code, and 200 image lines each followed by its `codd-annotations` block.
    static func bigNote() -> (text: String, images: Int) {
        var parts: [String] = ["# 大型筆記效能測試\n\n"]
        var bytes = 0
        var section = 0
        var images = 0
        while bytes < 1 << 20 {
            var chunk = "## 第 \(section) 節：打卡頁 RWD 跑版紀錄\n"
            for line in 0 ..< 6 {
                chunk += "iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；**橫向時**表格溢出，見 `/punch/\(line)` 與 [說明](https://example.com/\(section)) 第 \(line) 行。\n"
            }
            chunk += "- 影響頁面：`/punch`（打卡）與 `/punch/history`\n- **Safari 底部工具列展開時**才會完全蓋住\n"
            chunk += "- [x] 先重現（Chrome DevTools 375 寬）\n- [ ] 表格改卡片式（<640px）\n\n"
            if images < 200, section % 2 == 0 {
                chunk += "![截圖 \(section)](assets/big-note-aaaa/\(String(format: "%06x", section)).png)\n"
                chunk += "```codd-annotations\n{\"v\":1,\"image\":\"assets/big-note-aaaa/x.png\",\"size\":[750,1334],\"items\":[{\"n\":1,\"type\":\"rect\",\"x\":20,\"y\":1150,\"w\":710,\"h\":120,\"note\":\"按鈕被蓋住\"}]}\n```\n\n"
                images += 1
            }
            if section % 5 == 0 {
                chunk += "```css\n@media (max-width: 640px) {\n  .punch-table { display: block; }\n}\n```\n\n"
            }
            parts.append(chunk)
            bytes += chunk.utf8.count
            section += 1
        }
        // Make sure there are exactly 200 image lines.
        while images < 200 {
            parts.append("![截圖 尾 \(images)](assets/big-note-aaaa/tail\(images).png)\n\n")
            images += 1
        }
        return (parts.joined(), images)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }

    static func milliseconds(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @Test func aOneMegabyteNoteLoadsAndTypesWithinBudget() {
        let (text, images) = Self.bigNote()
        let bytes = text.utf8.count
        #expect(bytes >= 1 << 20)
        #expect(MarkdownBlockParser.blocks(in: text).filter { if case .image = $0.kind { true } else { false } }.count == images)
        let harness = EditorHarness()
        defer { harness.tearDown() }
        // Unresolved images (the resolver knows none of them).
        harness.editor.imageResolver = { _ in nil }
        var loads: [Double] = []
        for _ in 0 ..< 5 {
            loads.append(Self.milliseconds {
                harness.editor.load(text, selection: NSRange(location: 0, length: 0))
                harness.editor.layoutSubtreeIfNeeded()
                harness.textView.displayIfNeeded()
            })
        }
        let load = Self.percentile(loads, 0.5)
        let best = loads.min() ?? load
        // A keystroke in the middle of the note.
        let middle = (text as NSString).range(of: "第 3 行", options: [], range: NSRange(location: (text as NSString).length / 2,
                                                                                         length: (text as NSString).length / 2)).location
        harness.select(middle)
        harness.textView.scrollRangeToVisible(harness.textView.selectedRange())
        harness.editor.layoutSubtreeIfNeeded()
        var keystrokes: [Double] = []
        var withLayout: [Double] = []
        for index in 0 ..< 60 {
            let typed = Self.milliseconds { harness.type(index % 7 == 6 ? " " : "字") }
            let laidOut = Self.milliseconds {
                harness.layoutManager.ensureLayout(forBoundingRect: harness.textView.visibleRect, in: harness.editor.container)
                harness.textView.displayIfNeeded()
            }
            keystrokes.append(typed)
            withLayout.append(typed + laidOut)
        }
        // Typing that changes the structure: a new heading in the middle.
        let structural = Self.milliseconds { harness.type("\n## 新段落\n") }
        let p50 = Self.percentile(keystrokes, 0.5)
        let p95 = Self.percentile(keystrokes, 0.95)
        let p95Layout = Self.percentile(withLayout, 0.95)
        print(String(format: "PERF note bytes=%d utf16=%d blocks=%d images=%d load median=%.1fms best=%.1fms loads=%@",
                     bytes, (text as NSString).length, harness.editor.blocks.count, images, load, best,
                     loads.map { String(format: "%.1f", $0) }.joined(separator: "/")))
        print(String(format: "PERF keystroke restyle p50=%.2fms p95=%.2fms max=%.2fms; with visible layout+display p95=%.2fms; newline+heading %.2fms",
                     p50, p95, keystrokes.max() ?? 0, p95Layout, structural))
        #expect(best < 300, "best load \(best) ms")
        #expect(load < 450, "median load \(load) ms")
        #expect(p95 < 30, "keystroke p95 \(p95) ms")
        // The edits are right.
        #expect(harness.editor.blocks == MarkdownBlockParser.blocks(in: harness.text))
    }
}
