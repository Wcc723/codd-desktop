import AppKit
import Testing
@testable import CoddCodeEditor

/// Budgets from the M4 plan (debug build): a 1 MB JavaScript file's first highlighted screen under
/// 150 ms and a keystroke under 16 ms. The numbers are printed (`PERF …`) for the report; each is
/// the best of a few runs so a busy machine does not decide the result.
@Suite("Performance", .serialized)
@MainActor
struct PerformanceTests {
    static let chunk = """
    import { defineStore } from 'pinia'
    // 打卡紀錄：每日清單與送出狀態
    export const usePunchStore = defineStore('punch', {
      state: () => ({ records: [], pending: false, error: null }),
      getters: {
        todayLabel: (state) => `${state.records.length} 筆 · ${new Date().toLocaleDateString('zh-TW')}`,
        isLate(state) { return /^(1[0-9]|2[0-3]):[0-5][0-9]$/.test(state.records.at(-1)?.time ?? '') },
      },
      actions: {
        async fetchToday() {
          const response = await fetch(`/api/punch/today?ts=${Date.now()}`)
          if (!response.ok) throw new Error(`HTTP ${response.status}`) /* retry later */
          this.records = (await response.json()).map((r, i) => ({ ...r, index: i * 2 + 1 }))
        },
      },
    })

    """

    static func megabyteOfJavaScript() -> String {
        var text = ""
        let target = 1 << 20
        var index = 0
        while text.utf8.count < target {
            text += chunk.replacingOccurrences(of: "usePunchStore", with: "usePunchStore\(index)")
            index += 1
        }
        return text
    }

    @Test func firstHighlightedScreenOfAOneMegabyteFile() throws {
        let text = Self.megabyteOfJavaScript()
        var best = Double.infinity
        for _ in 0 ..< 3 {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let editor = CodeEditorView()
            editor.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
            window.contentView = editor
            editor.layoutSubtreeIfNeeded()
            let start = CFAbsoluteTimeGetCurrent()
            editor.load(text, language: .javascript, readOnly: false, plainMode: false)
            editor.layoutSubtreeIfNeeded()
            editor.displayIfNeeded()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            best = min(best, elapsed)
            // The first screen is highlighted (`import` keyword on line 1).
            let color = editor.layoutManagerImpl.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
            #expect(color == editor.style.keyword)
            window.contentView = nil
            window.close()
        }
        print(String(format: "PERF first highlighted screen, 1 MB JavaScript (%d units): %.1f ms", (text as NSString).length, best))
        #expect(best < 150)
    }

    @Test func keystrokeInAOneMegabyteFile() throws {
        let text = Self.megabyteOfJavaScript()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = CodeEditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        window.contentView = editor
        editor.load(text, language: .javascript, readOnly: false, plainMode: false)
        editor.layoutSubtreeIfNeeded()
        editor.displayIfNeeded()
        window.makeFirstResponder(editor.textView)
        editor.goTo(line: 12, column: 9)
        editor.displayIfNeeded()
        var samples: [Double] = []
        for character in "constant value 中文 /* x */ `${y}` ".map(String.init) {
            let start = CFAbsoluteTimeGetCurrent()
            editor.textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        // Return adds a line: the line index shifts every line after it.
        for _ in 0 ..< 5 {
            let start = CFAbsoluteTimeGetCurrent()
            editor.textView.insertNewline(nil)
            editor.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "PERF keystroke in a 1 MB file: median %.2f ms, p90 %.2f ms, max %.2f ms (%d keys)",
                     median, sorted[sorted.count * 9 / 10], sorted.last!, sorted.count))
        #expect(median < 16)
        // Scrolling to the end lays out and lexes everything before it (printed only).
        let start = CFAbsoluteTimeGetCurrent()
        editor.goTo(line: editor.geometry.lines.count, column: 1)
        editor.layoutSubtreeIfNeeded()
        editor.displayIfNeeded()
        print(String(format: "PERF jump to the last line of a 1 MB file: %.1f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        window.contentView = nil
        window.close()
    }
}
