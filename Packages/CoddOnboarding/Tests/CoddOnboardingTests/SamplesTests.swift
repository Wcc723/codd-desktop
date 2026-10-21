import Foundation
import Testing
@testable import CoddOnboarding

@Suite("OnboardingSamples (the artboard's data)")
struct SamplesTests {
    @Test("187 projects, 9 checked, the artboard's groups, rows, dates and counts")
    func artboard() {
        let model = OnboardingSamples.artboard()
        let step = model.importStep
        #expect(model.flow.current == .importProjects)
        #expect(model.flow.progress[.detect] == .done)
        #expect(step.catalog.visibleTotal == 187)
        #expect(step.catalog.hiddenCount == 2)
        #expect(step.checkedCount == 9)
        #expect(step.summary == "9 個專案 → 3 個群組")
        #expect(step.options.map(\.name) == ["藍鵲 · 實驗室", "藍鵲 · 網站", "個人 · Github", "CODD", "未分類"])
        #expect(step.options.map(\.color) == ["orange", "blue", "green", "purple", nil])
        let rows = step.selection.visible(in: step.catalog)
        #expect(rows.count == 12)
        #expect(rows.map { ($0.prefix ?? "") + $0.name } == [
            "agent-lab-2026/原型試做", "整合範例/MCP", "整合範例/Skills", "orb-toolkit-backend", "orb-toolkit-frontend",
            "Northstar invoice system", "Gear3D", "keynote-deck", "pixel-town-demo", "UsageBar",
            "chat-bot-mcp", "mysite.github.io",
        ])
        #expect(rows.map { LastUsedFormat.text($0.lastUsed, now: step.now, timeZone: step.timeZone) } == [
            "今天 10:34", "今天 10:12", "今天 08:50", "今天 08:21", "昨天 22:47", "昨天 18:05", "10/13", "10/13", "10/11", "10/09", "10/02", "9/21",
        ])
        #expect(rows.map(\.transcripts) == [14, 9, 6, 31, 23, 8, 17, 5, 12, 4, 3, 2])
        #expect(rows.map { step.selection.checked.contains($0.path) } == [true, true, false, true, true, true, true, true, true, false, false, true])
        #expect(rows.map { step.option(step.selection.groupKey(for: $0.path)).name } == [
            "藍鵲 · 實驗室", "藍鵲 · 實驗室", "藍鵲 · 實驗室", "藍鵲 · 網站", "藍鵲 · 網站", "藍鵲 · 網站",
            "個人 · Github", "個人 · Github", "個人 · Github", "個人 · Github", "未分類", "個人 · Github",
        ])
        let site = OnboardingSamples.home + "/Github/mysite.github.io"
        #expect(step.suggestion[site] == "existing:g-github")
        #expect(rows.first?.displayPath == "~/Project/Northstar/lab/agent-lab-2026/原型試做")
        #expect(model.boot.header == "4 OK · 1 待處理")
        #expect(model.showsWebImportLink)
    }

    @Test("hidden rows appear between the artboard's rows with the toggle")
    func hidden() {
        let step = OnboardingSamples.step(.importProjects, variant: .showHidden).importStep
        let rows = step.selection.visible(in: step.catalog)
        #expect(rows.count == 12)
        #expect(rows[2].hidden == .worktree)
        #expect(rows.contains { $0.hidden == .sdk })
    }

    @Test("every step and variant has its state")
    func steps() {
        for step in OnboardingStep.allCases {
            let model = OnboardingSamples.step(step)
            #expect(model.flow.current == step)
            #expect(model.boot.lines.count == 6)
        }
        #expect(OnboardingSamples.step(.done).flow.progress[.hooks] == .skipped)
        #expect(OnboardingSamples.step(.done).done.notifications == .notAsked)
        #expect(OnboardingSamples.step(.done, variant: .notificationsGranted).done.notifications == .granted)
        #expect(OnboardingSamples.step(.accounts, variant: .cswapMissing).accounts.availabilityNote == "找不到 cswap")
        #expect(OnboardingSamples.step(.detect, variant: .claudeMissing).detect.first?.glyph == "▲")
        #expect(OnboardingSamples.step(.hooks, variant: .hooksUpToDate).hooks.pending == 0)
        #expect(OnboardingSamples.step(.accounts).accounts.rows.count == 3)
    }
}
