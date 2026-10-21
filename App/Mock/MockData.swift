import CoddClaudeSettings
import CoddCore
import CoddHost
import Foundation
import CoddUI

/// Canonical mock data from design/SPEC.md §5 (names and numbers exactly as specified).
/// All times are relative to the mock "now": 2026-10-15 (週四) 10:42 Asia/Taipei.
@MainActor
enum MockData {
    /// Mock wall clock at launch.
    static let referenceDate: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 15
        parts.hour = 10
        parts.minute = 42
        parts.timeZone = TimeZone(identifier: "Asia/Taipei")
        return Calendar(identifier: .gregorian).date(from: parts) ?? Date()
    }()

    static func ago(_ seconds: TimeInterval) -> Date { referenceDate.addingTimeInterval(-seconds) }
    static func later(_ seconds: TimeInterval) -> Date { referenceDate.addingTimeInterval(seconds) }

    static let m: TimeInterval = 60
    static let h: TimeInterval = 3600
    static let d: TimeInterval = 86400

    // MARK: Groups → projects → sessions

    struct Layout {
        var groups: [GroupVM]
        var projects: [ProjectVM]
        var sessions: [SessionVM]
        var pinned: [SessionID]
    }

    static func layout() -> Layout {
        let groups = [
            GroupVM(id: "northlab", name: "藍鵲 · 實驗室", shortName: "藍鵲·實驗室", color: .orange,
                    projectIDs: ["proto", "mcp", "skills"]),
            GroupVM(id: "northweb", name: "藍鵲 · 網站", shortName: "藍鵲·網站", color: .blue,
                    projectIDs: ["backend", "frontend", "invoice"]),
            GroupVM(id: "github", name: "個人 · Github", shortName: "個人·Github", color: .green,
                    projectIDs: ["gear", "pixel", "keynote", "usagebar"]),
            GroupVM(id: "codd", name: "CODD", shortName: "CODD", color: .purple,
                    projectIDs: ["coddweb", "desk"], isCollapsed: true),
            GroupVM(id: "ungrouped", name: "未分類", shortName: "未分類", color: nil,
                    projectIDs: ["line"], isUngrouped: true),
        ]
        let projects = [
            ProjectVM(id: "proto", name: "原型試做", cwd: "~/Project/Northstar/lab/agent-lab-2026/原型試做",
                      groupID: "northlab", sessionIDs: ["s4", "s6"]),
            ProjectVM(id: "mcp", name: "MCP 整合範例", cwd: "~/Project/Northstar/lab/agent-lab-2026/整合範例/MCP",
                      groupID: "northlab", sessionIDs: ["s7"]),
            ProjectVM(id: "skills", name: "Skills 整合範例", cwd: "~/Project/Northstar/lab/agent-lab-2026/整合範例/Skills",
                      groupID: "northlab", sessionIDs: [], archivedCount: 3, isCollapsed: true),
            ProjectVM(id: "backend", name: "orb-toolkit-backend",
                      cwd: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend",
                      groupID: "northweb", sessionIDs: ["s1", "s8"]),
            ProjectVM(id: "frontend", name: "orb-toolkit-frontend",
                      cwd: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend",
                      groupID: "northweb", sessionIDs: ["s9"]),
            ProjectVM(id: "invoice", name: "Northstar invoice system",
                      cwd: "~/Project/Northstar/websites/業主/Northstar invoice system",
                      groupID: "northweb", sessionIDs: ["s2"]),
            ProjectVM(id: "gear", name: "Gear3D", cwd: "~/Github/Gear3D", groupID: "github", sessionIDs: ["s3"]),
            ProjectVM(id: "pixel", name: "pixel-town-demo", cwd: "~/Github/pixel-town-demo",
                      groupID: "github", sessionIDs: ["s10"]),
            ProjectVM(id: "keynote", name: "keynote-deck", cwd: "~/Github/keynote-deck",
                      groupID: "github", sessionIDs: ["s11"]),
            ProjectVM(id: "usagebar", name: "UsageBar", cwd: "~/Github/UsageBar", groupID: "github",
                      sessionIDs: ["s12"], isCollapsed: true),
            ProjectVM(id: "coddweb", name: "codd-web", cwd: "~/Github/codd-web",
                      groupID: "codd", sessionIDs: ["s13"]),
            ProjectVM(id: "desk", name: "codd-desktop", cwd: "~/Github/codd-desktop",
                      groupID: "codd", sessionIDs: ["s5"]),
            ProjectVM(id: "line", name: "claude-line-test", cwd: "~/Desktop/temp_測試專案/claude-line-test",
                      groupID: "ungrouped", sessionIDs: ["s14"]),
        ]
        return Layout(groups: groups, projects: projects, sessions: sessions(), pinned: ["s5"])
    }

    // MARK: Sessions (13 live, 1 exited)

    private static func sessions() -> [SessionVM] {
        var list: [SessionVM] = []
        func add(_ id: SessionID, _ project: ProjectID, _ title: String, _ state: SessionState, since: TimeInterval,
                 up: TimeInterval? = nil, configure: (SessionVM) -> Void = { _ in }) {
            let s = SessionVM(id: id, projectID: project, title: title, state: state, stateSince: ago(since))
            s.startedAt = up.map(ago)
            s.accountID = "3"
            configure(s)
            list.append(s)
        }

        add("s1", "backend", "修正登入 API 401", .waiting, since: 3 * m, up: 42 * m) {
            $0.waitingReason = .permission; $0.tag = .red; $0.tool = "Bash"; $0.detail = "npm test -- auth.spec.ts"
            $0.branch = "fix/login-401"; $0.model = "opus-5.5"; $0.contextPercent = 58; $0.costUSD = 2.14
            $0.remoteControl = true; $0.notesCount = 2
            $0.lastPrompt = "登入 API 在 token 過期後會回 401，幫我修好並補測試"
        }
        add("s2", "invoice", "發票匯出 CSV", .waiting, since: 12 * m, up: 1 * h + 5 * m) {
            $0.waitingReason = .question; $0.tool = "AskUserQuestion"; $0.detail = "CSV 要用 UTF-8 BOM 還是 Big5？"
            $0.answerOptions = ["UTF-8 BOM", "Big5", "UTF-8", "自行輸入"]
            $0.branch = "main"; $0.model = "sonnet-5.5"; $0.contextPercent = 71; $0.costUSD = 0.62
        }
        add("s3", "gear", "場景載入優化", .error, since: 1 * m, up: 2 * h + 12 * m) {
            $0.errorReason = "OVERLOADED"; $0.tag = .yellow; $0.detail = "API 529"; $0.branch = "perf/scene-load"
            $0.model = "opus-5.5"; $0.contextPercent = 34; $0.costUSD = 4.80; $0.notesCount = 1
            // §7.1 s3: both D26 actions usable (the mock terminal shows this prompt).
            $0.lastPrompt = "場景第一次載入要 6 秒，幫我找出瓶頸並優化"
            $0.resendPrompt = $0.lastPrompt
        }
        add("s4", "proto", "第二版原型 · 審查流程", .done, since: 4 * m, up: 38 * m) {
            $0.branch = "main"; $0.model = "sonnet-5.5"; $0.contextPercent = 62; $0.costUSD = 1.07
        }
        add("s5", "desk", "CODD Desktop 設計稿", .busy, since: 2 * m, up: 3 * h + 20 * m) {
            $0.tag = .purple; $0.tool = "Write"; $0.model = "opus-5.5"; $0.contextPercent = 47; $0.costUSD = 6.31
            $0.isPinned = true
        }
        add("s6", "proto", "產生程式碼審查清單", .idle, since: 2 * h, up: 3 * h + 10 * m) {
            $0.branch = "main"; $0.model = "sonnet-5.5"; $0.contextPercent = 80; $0.costUSD = 0.41; $0.notesCount = 1
        }
        add("s7", "mcp", "現場示範：連線 MCP", .busy, since: 1 * m + 12, up: 51 * m) {
            $0.tool = "Bash"; $0.branch = "main"; $0.model = "opus-5.5"; $0.contextPercent = 66; $0.costUSD = 1.88
            $0.accountID = "2"; $0.accountPinned = true; $0.notesCount = 1
        }
        add("s8", "backend", "npm run dev", .shell, since: 42 * m, up: 42 * m) {
            $0.kind = .shell; $0.detail = "zsh"; $0.branch = "fix/login-401"; $0.pid = 48211; $0.accountID = nil
        }
        add("s9", "frontend", "打卡頁 RWD 調整", .busy, since: 6 * m, up: 1 * h + 18 * m) {
            $0.tag = .pink; $0.tool = "Edit"; $0.branch = "feat/punch-rwd"; $0.model = "sonnet-5.5"
            $0.contextPercent = 49; $0.costUSD = 1.36; $0.notesCount = 2
        }
        add("s10", "pixel", "像素小鎮 NPC 對話", .compacting, since: 20, up: 4 * h + 2 * m) {
            $0.model = "opus-5.5"; $0.contextPercent = 9; $0.costUSD = 5.12
        }
        add("s11", "keynote", "keynote 第 3 章", .idle, since: 1 * d, up: 1 * d + 2 * h) {
            $0.isStale = true; $0.model = "sonnet-5.5"; $0.contextPercent = 55; $0.costUSD = 0.93; $0.notesCount = 1
        }
        add("s12", "usagebar", "選單列額度顯示", .exited, since: 3 * h) {
            $0.exitCode = 0; $0.accountID = nil
        }
        add("s13", "coddweb", "web: session 側欄", .idle, since: 5 * h) {
            $0.model = "sonnet-5.5"
        }
        add("s14", "line", "LINE bot 測試", .idle, since: 25 * m) {
            $0.externalInfo = ExternalInfo(pid: 48211, kind: "interactive", entrypoint: "cli",
                                           claudeSessionID: "3f2a91c0-7d4e-4b8a-9c11-2e6f0a5b8d73", version: "2.1.300")
            $0.pid = 48211
            $0.accountID = nil
        }
        return list
    }

    // MARK: Accounts (cswap 0.26.0; aliases only, plan MAX 20x)

    static func accounts() -> [AccountVM] {
        let list = [
            AccountVM(id: "3", slot: "#3", alias: "工作", plan: "MAX 20x",
                      fiveHour: QuotaWindow(remainingPercent: 91, resetsAt: later(2 * h + 57 * m)),
                      week: QuotaWindow(remainingPercent: 15, resetsAt: later(3 * d + 1 * h + 18 * m)),
                      source: "statusline", sourceAt: ago(12), sessionCount: 12, weekExhaustsAt: later(2 * d + 7 * h + 18 * m)),
            AccountVM(id: "2", slot: "#2", alias: "藍鵲", plan: "MAX 20x",
                      fiveHour: QuotaWindow(remainingPercent: 98, resetsAt: later(2 * h + 37 * m)),
                      week: QuotaWindow(remainingPercent: 46, resetsAt: later(1 * d + 12 * h + 17 * m)),
                      source: "cswap cache", sourceAt: ago(3 * m), sessionCount: 1),
            AccountVM(id: "1", slot: "#1", alias: "個人", plan: "MAX 20x",
                      fiveHour: QuotaWindow(remainingPercent: 100, resetsAt: nil, started: false),
                      week: QuotaWindow(remainingPercent: 100, resetsAt: later(4 * d + 9 * h + 18 * m)),
                      source: "cswap cache", sourceAt: ago(3 * m), sessionCount: 0),
        ]
        // The Status artboard: only #3's status line reported the per-model weekly window.
        list[0].scoped = [ScopedQuota(name: "Fable", remainingPercent: 100, resetsAt: list[0].week.resetsAt)]
        return list
    }

    /// Home's RECENTLY STOPPED transcripts (the NewSession artboard's resume list): two older
    /// conversations of orb-toolkit-backend, keyed by the folder Home reads them for.
    static func homeTranscripts() -> [String: [TranscriptSummary]] {
        let cwd = "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend"
        let folder = HolderSessionStore.standardize(PathFormat.expandTilde(cwd))
        return [folder: [
            TranscriptSummary(id: "3f2a91c0-1b7e-4c55-a0d2-7e1f9b6c2a10", path: folder + "/3f2a91c0.jsonl", cwd: folder,
                              title: "refresh token 流程改寫", titleSource: .custom, gitBranch: "fix/refresh",
                              lastActivity: ago(2 * d), sizeBytes: 1_258_291),
            TranscriptSummary(id: "8c41d2e7-5a90-4f1b-9e3c-0b6d7a2f4e85", path: folder + "/8c41d2e7.jsonl", cwd: folder,
                              title: "auth middleware 單元測試", titleSource: .ai, gitBranch: "main",
                              lastActivity: ago(5 * d), sizeBytes: 655_360),
        ]]
    }

    /// The ⌘N resume picker's list for orb-toolkit-backend (SPEC §5 past transcripts; `CI 設定` is
    /// 26 days old, so it shows `! resume 4 天後過期` with the default 30-day cleanup).
    static func resumeTranscripts() -> [String: [TranscriptSummary]] {
        var lists = homeTranscripts()
        guard let folder = lists.keys.first, var list = lists[folder] else { return lists }
        list += [
            TranscriptSummary(id: "5d0b7e21-9c34-4a8f-b1e6-3c9a2f7d8e40", path: folder + "/5d0b7e21.jsonl", cwd: folder,
                              title: "登入頁錯誤訊息 i18n", titleSource: .ai, gitBranch: "feat/i18n",
                              lastActivity: ago(12 * d), sizeBytes: 2_411_725),
            TranscriptSummary(id: "a7c93f10-2e48-4b6d-8f05-9d1e6b3c7a52", path: folder + "/a7c93f10.jsonl", cwd: folder,
                              title: "CI 設定", titleSource: .firstPrompt, gitBranch: "main",
                              lastActivity: ago(26 * d), sizeBytes: 184_320),
        ]
        lists[folder] = list
        return lists
    }

    /// `建議 · 來自 ~/.claude.json` in the ⌘N project list (NewSession artboard).
    static let claudeJsonProjects: [RecentProject] = [
        RecentProject(path: PathFormat.expandTilde("~/Project/Northstar/websites/orb-toolkit-suite/打卡紀錄前端介面"), lastUsed: ago(3 * h)),
        RecentProject(path: PathFormat.expandTilde("~/Github/chat-bot-mcp"), lastUsed: ago(2 * d)),
        RecentProject(path: PathFormat.expandTilde("~/Github/mysite.github.io"), lastUsed: ago(9 * d)),
    ]

    /// Claude's own settings in mock mode (D30 `預設 (opus-5.5)`).
    static let claudeSettings = ClaudeUserSettingsSummary(cleanupPeriodDays: 30, model: "opus-5.5")

    static let host = HostSummary(line: "cpu 23% · mem 21/36G · bat 86%", mcpEndpoint: "127.0.0.1:47821",
                                  mcpClients: 3, mcpRunning: true, hooksInstalled: true, hooksHealthy: true,
                                  cleanupSuggestions: 15)
}

// MARK: - STATUS (M3 I2): the Status artboard's HOST numbers and HOOKS findings

extension MockData {
    private static let gib: Double = 1_073_741_824

    private static func bytes(_ gigabytes: Double) -> UInt64 { UInt64(gigabytes * gib) }

    /// The artboard's sparkline heights (SVG y in a 0…40 box), oldest first.
    private static let cpuPoints: [Double] = [28, 26, 27.3, 22.7, 19.3, 21.3, 24, 25.3, 22, 16.7, 14.7, 20, 23.3, 26, 27.3, 24, 20.7, 22.7,
                                              25.3, 26.7, 24.7]
    private static let memoryPoints: [Double] = [17.1, 16.7, 16.3, 15.9, 16, 15.5, 14.8, 14.3, 14.5, 14.7, 13.9, 13.6, 14, 14.4, 14.1, 13.7,
                                                 13.5, 13.9, 14.1, 14.3, 14.1]

    /// SPEC §5 / Status artboard: studio-mbp, 23 % CPU (load 3.12, 12 cores), 21.4 / 36G, 412G free
    /// of 1T, swap 1.2 / 2G, battery 86 % on AC, booted 10/12 06:42.
    static func hostSample(at: Date = referenceDate, cpu: Double = 23, memoryFraction: Double? = nil) -> HostSample {
        let total = bytes(36)
        let used = memoryFraction.map { UInt64(Double(total) * $0) } ?? bytes(21.4)
        return HostSample(at: at, cpu: HostSample.CPU(user: cpu * 0.65, system: cpu * 0.35, total: cpu, load1: 3.12, load5: 2.8,
                                                       load15: 2.5, cores: 12),
                          memory: HostSample.Memory(total: total, used: used, app: bytes(13.8), wired: bytes(4.3), compressed: bytes(3.3),
                                                    pressure: .normal),
                          disk: HostSample.Disk(volumeName: "Macintosh HD", total: bytes(1024), available: bytes(412)),
                          swap: HostSample.Swap(total: bytes(2), used: bytes(1.2)),
                          battery: HostSample.Battery(percent: 86, charging: false, onAC: true),
                          bootedAt: referenceDate.addingTimeInterval(-(3 * d + 4 * h)), hostName: "studio-mbp")
    }

    /// Ten minutes of samples drawing the artboard's sparklines (CPU peak 38 %, now 23 %).
    static func hostHistory() -> HostHistory {
        var history = HostHistory()
        for (index, (cpuY, memoryY)) in zip(cpuPoints, memoryPoints).enumerated() {
            let at = referenceDate.addingTimeInterval(Double(index - cpuPoints.count + 1) * 30)
            history.append(hostSample(at: at, cpu: (1 - cpuY / 40) * 60, memoryFraction: 1 - memoryY / 40))
        }
        return history
    }

    /// The user's settings as the artboard shows them: CODD web leftovers on 10 events, hook-tap on
    /// 11 (PermissionRequest blocks 600 s), two osascript notifications, CODD's status line chaining
    /// hook-tap's.
    static let settingsInspection = ClaudeSettingsInspection(
        legacyHookEvents: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "PermissionRequest", "Stop",
                           "SubagentStop", "PreCompact", "SessionEnd"],
        legacyHandlerCount: 10,
        foreign: [ForeignHookTool(name: "hook-tap", code: "hook-tap",
                                  events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                                           "Notification", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "SessionEnd"],
                                  blocking: [("PermissionRequest", 600)]),
                  ForeignHookTool(name: "通知", code: "osascript", events: ["Notification", "Stop"])],
        statusLine: .coddDesktop(chain: "~/.hook-tap/bin/hook-tap statusline ~/.hook-tap/statusline.sh", current: true),
        duplicateNotificationHandlers: 2)
}
