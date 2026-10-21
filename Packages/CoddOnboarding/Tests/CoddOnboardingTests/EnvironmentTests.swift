import Foundation
import Testing
@testable import CoddOnboarding

@Suite("EnvironmentReport (D11), DetectItem and the step models")
struct EnvironmentTests {
    static let home = OnboardingSamples.home
    static let zone = OnboardingSamples.timeZone

    static func report(_ facts: EnvironmentFacts, step: OnboardingStep = .importProjects, imported: Int? = nil) -> EnvironmentReport {
        EnvironmentReport.make(facts, step: step, imported: imported, timeZone: zone, home: home)
    }

    static func facts(claude: EnvironmentFacts.Claude? = nil, cswap: EnvironmentFacts.Cswap? = nil, hooks: EnvironmentFacts.Hooks? = nil,
                      root: EnvironmentFacts.DataRoot? = nil, projects: EnvironmentFacts.Projects? = nil) -> EnvironmentFacts {
        var facts = OnboardingSamples.facts()
        if let claude { facts.claude = claude }
        if let cswap { facts.cswap = cswap }
        if let hooks { facts.hooks = hooks }
        if let root { facts.dataRoot = root }
        if let projects { facts.projects = projects }
        return facts
    }

    @Test("the artboard's boot block (no node row; the data root and the import source)")
    func artboard() {
        let report = Self.report(OnboardingSamples.facts())
        #expect(report.lines == [
            BootLine(tag: .ok, name: "claude", value: "2.1.302", detail: "~/.local/bin/claude"),
            BootLine(tag: .ok, name: "cswap", value: "0.26.0 · 3 個帳號", detail: "~/.local/bin/cswap"),
            BootLine(tag: .pending, name: "hooks", value: "需要更新（4 個事件）",
                     detail: "~/.claude/settings.json · 舊版 CODD web：PreCompact / PostCompact / SubagentStart / SubagentStop"),
            BootLine(tag: .ok, name: "~/Library/Application Support/CODD", value: "可寫入", detail: "MCP 127.0.0.1:47821 可用"),
            BootLine(tag: .ok, name: "~/.claude.json", value: "187 個專案", detail: "只讀取，不會改動"),
            BootLine(tag: .waiting, name: "projects", value: "waiting for operator", cursor: true),
        ])
        #expect(report.header == "4 OK · 1 待處理")
        #expect(report.checked == "10:41:58 · 0.8s")
        #expect(report.summary == "4 項正常 · 1 項待處理")
        #expect(report.lines[0].tag.label == "[ OK ]")
        #expect(report.lines[2].tag.label == "[ .. ]")
        #expect(report.lines[0].spoken == "[ OK ] claude 2.1.302")
    }

    @Test("claude variants")
    func claude() {
        let missing = Self.report(Self.facts(claude: .missing))
        #expect(missing.lines[0] == BootLine(tag: .fail, name: "claude", value: "找不到", detail: "先安裝 Claude Code"))
        #expect(missing.lines[0].tag.label == "[FAIL]")
        #expect(missing.header == "3 OK · 1 待處理 · 1 失敗")
        #expect(missing.summary == "3 項正常 · 1 項待處理 · 1 項失敗")
        #expect(Self.report(Self.facts(claude: .failed("exit 1"))).lines[0].value == "無法執行")
    }

    @Test("cswap variants")
    func cswap() {
        #expect(Self.report(Self.facts(cswap: .missing)).lines[1]
                == BootLine(tag: .pending, name: "cswap", value: "沒有安裝", detail: "選用：要切換多個帳號再安裝（0.26 以上）"))
        #expect(Self.report(Self.facts(cswap: .unsupported("0.24.1"))).lines[1].value == "0.24.1 太舊")
        #expect(Self.report(Self.facts(cswap: .unreadable("sequence.json 壞了"))).lines[1].detail == "sequence.json 壞了")
        #expect(Self.report(Self.facts(cswap: .loading)).lines[1].value == "讀取中…")
        #expect(Self.report(Self.facts(cswap: .missing)).header == "3 OK · 2 待處理")
    }

    @Test("hooks variants (the Desktop wording: legacy CODD web events, never 缺)")
    func hooks() {
        let file = "\(Self.home)/.claude/settings.json"
        #expect(Self.report(Self.facts(hooks: .upToDate(file: file))).lines[2]
                == BootLine(tag: .ok, name: "hooks", value: "已是最新", detail: "~/.claude/settings.json"))
        #expect(Self.report(Self.facts(hooks: .statuslineOutdated(file: file))).lines[2]
                == BootLine(tag: .pending, name: "hooks", value: "需要更新（狀態列）", detail: "~/.claude/settings.json · 全域狀態列是舊版"))
        #expect(Self.report(Self.facts(hooks: .unreadable("不是 JSON"))).lines[2].tag == .fail)
        #expect(Self.report(Self.facts(hooks: .unknown)).lines[2] == BootLine(tag: .skipped, name: "hooks", value: "尚未檢查"))
        #expect(Self.report(Self.facts(hooks: .unknown)).lines[2].tag.label == "[ -- ]")
        let legacy = Self.report(Self.facts(hooks: .legacy(events: ["Stop", "Notification"], file: file)))
        #expect(legacy.lines[2].value == "需要更新（2 個事件）")
        #expect(legacy.lines[2].detail == "~/.claude/settings.json · 舊版 CODD web：Stop / Notification")
        #expect(!legacy.lines.contains { $0.detail.contains("缺") })
    }

    @Test("data root and MCP variants")
    func dataRoot() {
        let path = "\(Self.home)/Library/Application Support/CODD"
        let locked = Self.report(Self.facts(root: .init(path: path, writable: false, mcpEndpoint: "127.0.0.1:47821", mcpRunning: true)))
        #expect(locked.lines[3].tag == .fail)
        #expect(locked.lines[3].value == "無法寫入")
        let down = Self.report(Self.facts(root: .init(path: path, writable: true, mcpEndpoint: "127.0.0.1:47821", mcpRunning: false)))
        #expect(down.lines[3] == BootLine(tag: .pending, name: "~/Library/Application Support/CODD", value: "可寫入",
                                          detail: "MCP 127.0.0.1:47821 未啟動"))
        let none = Self.report(Self.facts(root: .init(path: path, writable: true, mcpEndpoint: nil, mcpRunning: false)))
        #expect(none.lines[3].detail == "MCP 未啟動")
    }

    @Test("the import source row, then what was imported, then each step's own last line")
    func projectsAndSteps() {
        let missing = Self.report(Self.facts(projects: .missing(source: "\(Self.home)/.claude.json")))
        #expect(missing.lines[4] == BootLine(tag: .skipped, name: "~/.claude.json", value: "找不到", detail: "還沒用過 Claude Code？"))
        #expect(Self.report(Self.facts(projects: .unreadable(source: "\(Self.home)/.claude.json", reason: "太大"))).lines[4].tag == .pending)
        #expect(Self.report(Self.facts(projects: .unknown)).lines.count == 5)
        let hooksStep = Self.report(OnboardingSamples.facts(), step: .hooks, imported: 9)
        #expect(hooksStep.lines[4] == BootLine(tag: .ok, name: "projects", value: "已匯入 9 個"))
        #expect(hooksStep.lines.last == BootLine(tag: .waiting, name: "hooks", value: "waiting for operator", cursor: true))
        #expect(hooksStep.header == "4 OK · 1 待處理")
        #expect(Self.report(OnboardingSamples.facts(), step: .notebook, imported: 0).lines[4]
                == BootLine(tag: .skipped, name: "projects", value: "未匯入"))
        #expect(Self.report(OnboardingSamples.facts(), step: .done, imported: 9).lines.last == BootLine(tag: .ok, name: "ready", value: ""))
        #expect(Self.report(OnboardingSamples.facts(), step: .detect).lines.last?.name == "detect")
        #expect(Self.report(OnboardingSamples.facts(), step: .accounts, imported: 9).lines.last?.name == "accounts")
    }

    @Test("durations: one decimal, at least 0.1s")
    func durations() {
        #expect(EnvironmentReport.duration(800) == "0.8s")
        #expect(EnvironmentReport.duration(45) == "0.1s")
        #expect(EnvironmentReport.duration(12_345) == "12.3s")
    }

    @Test("step 1's attention lines and their buttons")
    func detectItems() {
        let fine = DetectItem.items(for: Self.facts(hooks: .upToDate(file: "\(Self.home)/.claude/settings.json")), home: Self.home)
        #expect(fine == [DetectItem(glyph: "//", tone: "comment", text: "一切正常，按 下一步 繼續", button: nil, target: nil)])
        let artboard = DetectItem.items(for: OnboardingSamples.facts(), home: Self.home)
        #expect(artboard == [DetectItem(glyph: "◆", tone: "amber", text: "~/.claude/settings.json 有舊版 CODD web 的 hooks：第 3 步可以預覽並移除。",
                                        button: "第 3 步 →", target: .hooks)])
        let problems = DetectItem.items(for: Self.facts(claude: .missing, cswap: .missing), home: Self.home)
        #expect(problems.map(\.glyph) == ["▲", "○", "◆"])
        #expect(problems[0].text == "找不到 claude：先安裝 Claude Code，裝好後按 ↻ 重新偵測。")
        #expect(problems[0].button == "↻ 重新偵測")
        #expect(problems[0].target == nil)
        #expect(problems[1].text == "沒有 cswap：CODD 仍可使用目前登入的帳號；要切換多個帳號再安裝 cswap（0.26 以上）。")
        #expect(problems[1].target == .accounts)
        let locked = DetectItem.items(for: Self.facts(root: .init(path: "/Volumes/x/CODD", writable: false, mcpEndpoint: nil, mcpRunning: false)),
                                      home: Self.home)
        #expect(locked.contains { $0.text == "資料夾無法寫入：/Volumes/x/CODD" })
    }

    @Test("stepper details (§2.4, D11)")
    func stepDetails() {
        let model = OnboardingSamples.artboard()
        #expect(model.stepDetails[.detect] == "4 項正常 · 1 項待處理")
        #expect(model.stepDetails[.importProjects] == "已選 9 / 187")
        #expect(model.stepDetails[.hooks] == "◆ 需要更新 · 舊版 4 個事件")
        #expect(model.stepDetails[.notebook] == "~/…/CODD/notes · :47821")
        #expect(model.stepDetails[.accounts] == "偵測到 3 個帳號")
        #expect(model.stepDetails[.done] == "開第一個 session")
        #expect(OnboardingSamples.step(.hooks, variant: .hooksUpToDate).stepDetails[.hooks] == "● 已是最新")
        #expect(OnboardingSamples.step(.accounts, variant: .cswapMissing).stepDetails[.accounts] == "找不到 cswap")
        #expect(OnboardingViewModel.versionLine(shortVersion: "1.0.0", build: "412", os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1))
                == "1.0.0 (build 412) · macOS 27.0")
    }

    @Test("hooks, notebook, accounts and done models")
    func stepModels() {
        let hooks = HooksStepModel.make(hooks: OnboardingSamples.facts().hooks, foreign: [.init(command: "hook-tap", name: "hook-tap", count: 11)])
        #expect(hooks.rows.map(\.label) == ["SESSION HOOKS", "LEGACY", "STATUSLINE", "FOREIGN"])
        #expect(hooks.rows[0].state == "● 14 / 14")
        #expect(hooks.rows[1].detail == "PreCompact / PostCompact / SubagentStart / SubagentStop")
        #expect(hooks.rows[2].state == "○ 未安裝全域版")
        #expect(hooks.rows[3].detail == "×11 · 保持不動", "a tool known only by its command is named once")
        let named = HooksStepModel.make(hooks: .upToDate(file: "/x"), foreign: [.init(command: "osascript", name: "通知", count: 2)])
        #expect(named.rows.last?.detail == "通知 ×2 · 保持不動")
        #expect(hooks.pending == 1)
        #expect(hooks.canPreview)
        let current = HooksStepModel.make(hooks: .upToDate(file: "/x"), statusline: .installed)
        #expect(current.pending == 0)
        #expect(!current.canPreview)
        #expect(current.rows[1].state == "● 沒有舊版設定")

        let notebook = NotebookStepModel.make(notesPath: "~/Library/Application Support/CODD/notes", mcpEndpoint: "127.0.0.1:47821",
                                              mcpRunning: true, claudeCodeRegistered: false)
        #expect(notebook.mcpLine == "127.0.0.1:47821 · ● 運作中")
        #expect(notebook.claudeCodeState == "○ 未註冊")
        #expect(notebook.claudeCodeButton == "註冊…")
        #expect(NotebookStepModel.make(notesPath: "x", mcpEndpoint: nil, mcpRunning: false, claudeCodeRegistered: true).mcpLine
                == "○ 未啟動 · hooks 連接埠被占用")

        let missing = AccountsStepModel.make(cswap: .missing, rows: OnboardingSamples.accountRows)
        #expect(missing.availabilityNote == "找不到 cswap")
        #expect(missing.rows.isEmpty)
        #expect(!missing.canAdd)
        #expect(AccountsStepModel.make(cswap: .unsupported("0.24.1"), rows: []).availabilityNote == "cswap 0.24.1 太舊，需要 0.26 以上")
        #expect(AccountsStepModel.make(cswap: .unreadable("壞了"), rows: []).availabilityNote == "讀不到 cswap 狀態：壞了")
        #expect(OnboardingSamples.accountRows.map(\.slot) == ["#2", "#3", "#1"])

        let done = DoneStepModel.make(imported: (9, 3), hooks: .skipped, notesPath: "~/Library/Application Support/CODD/notes", accounts: 3,
                                      notifications: .notAsked)
        #expect(done.summary.map(\.spoken) == ["[ OK ] projects 匯入 9 個專案 → 3 個群組", "[ -- ] hooks 略過",
                                               "[ OK ] notebook ~/…/CODD/notes", "[ OK ] accounts 3 個帳號"])
    }
}
